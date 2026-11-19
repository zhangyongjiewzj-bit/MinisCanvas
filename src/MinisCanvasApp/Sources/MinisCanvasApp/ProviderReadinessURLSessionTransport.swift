import Foundation
import MinisCore

/// Settings 页使用的真实 HTTP readiness transport。
///
/// 它只负责把 readiness operation 交给明确的 wire adapter，再执行 URLSession；
/// 阶段顺序、报告状态和脱敏由 SettingsCenter 持有。所有请求都必须带有
/// 非空凭据并通过 CustomProviderURL 校验，重定向一律取消。
struct URLSessionProviderReadinessTransport: SettingsProviderReadinessTransport {
    private let session: URLSession
    private let ownedMMOutboundLedger: OwnedMMOutboundLedger?
    private let liveEvidenceEnabled: Bool
    private let requestURLPolicy: (@Sendable (URLRequest) throws -> URLRequest)?

    var canProduceLiveEvidence: Bool { liveEvidenceEnabled }

    init() {
        session = .shared
        ownedMMOutboundLedger = nil
        liveEvidenceEnabled = true
        requestURLPolicy = nil
    }

    /// Test-only remote contract seam. The URLProtocol-backed session still
    /// exercises the production URLSession and wire adapters, while the
    /// explicit name distinguishes it from an unverified mock transport.
    init(remoteContractSession: URLSession) {
        session = remoteContractSession
        ownedMMOutboundLedger = nil
        liveEvidenceEnabled = true
        requestURLPolicy = nil
    }

    init(session: URLSession, canProduceLiveEvidence: Bool = false,
         requestURLPolicy: (@Sendable (URLRequest) throws -> URLRequest)? = nil,
         ownedMMOutboundLedger: OwnedMMOutboundLedger? = nil) {
        self.session = session
        self.ownedMMOutboundLedger = ownedMMOutboundLedger
        liveEvidenceEnabled = canProduceLiveEvidence
        self.requestURLPolicy = requestURLPolicy
    }

    func send(
        _ incoming: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        // A cancelled readiness task is a stale request after a retry,
        // configuration change, or process re-entry. Reject it before the
        // credential ever reaches URLSession and re-check after the async
        // boundary before accepting provider data.
        try Task.checkCancellation()
        // ChatGPT account record: its stored "key" is a placeholder; probe with the live
        // access token against the official host only.
        let usesChatGPTAccount = incoming.apiKey == ChatGPTAccountSession.credentialPlaceholder
        let request: ProviderReadinessTransportRequest
        if usesChatGPTAccount {
            guard incoming.baseURL.host?.lowercased() == ChatGPTAccountEndpoints.responsesHost,
                  let account = ChatGPTAccountSessions.shared else {
                throw SettingsProviderReadinessTransportError.missingCredential
            }
            let token: String
            do { token = try await account.accessToken() }
            catch { throw SettingsProviderReadinessTransportError.missingCredential }
            request = ProviderReadinessTransportRequest(
                ownedMMAction: incoming.ownedMMAction, operation: incoming.operation,
                providerID: incoming.providerID, baseURL: incoming.baseURL, apiKey: token,
                modelID: incoming.modelID, protocolType: incoming.protocolType)
        } else {
            request = incoming
        }
        guard !request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsProviderReadinessTransportError.missingCredential
        }
        guard CustomProviderURL.isSafeDestination(request.baseURL) else {
            throw SettingsProviderReadinessTransportError.invalidURL
        }
        guard !request.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsProviderReadinessTransportError.invalidResponse
        }

        let assembledRequest = try makeURLRequest(for: request, account: usesChatGPTAccount)
        let urlRequest = try requestURLPolicy?(assembledRequest) ?? assembledRequest
        let ownedPermit = try ownedMMOutboundLedger?.beforeSend(action: request.ownedMMAction,
            phase: Self.ownedPhase(request.operation))
        let redirectDelegate = ReadinessRedirectDelegate(audit: ownedPermit?.taskDelegate())
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: urlRequest,
                delegate: redirectDelegate
            )
            let auditedStatus = (response as? HTTPURLResponse)?.statusCode
            ownedPermit?.completeAfterResponse(status: auditedStatus)
            if let auditedStatus, (200..<300).contains(auditedStatus) {
                try await ownedPermit?.waitForFinish()
            }
        } catch {
            ownedPermit?.fail()
            try Task.checkCancellation()
            if redirectDelegate.rejectedRedirect {
                throw SettingsProviderReadinessTransportError.redirectRejected
            }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw SettingsProviderReadinessTransportError.timeout
            }
            throw SettingsProviderReadinessTransportError.unavailable
        }

        try Task.checkCancellation()
        guard !redirectDelegate.rejectedRedirect else {
            throw SettingsProviderReadinessTransportError.redirectRejected
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SettingsProviderReadinessTransportError.invalidResponse
        }

        if case .minimalModelRequest = request.operation,
           (200..<300).contains(httpResponse.statusCode) {
            let adapter = wireAdapter(for: request, account: usesChatGPTAccount)
            do {
                try adapter.validateModelRequestResponse(from: data)
            } catch {
                // A 2xx Chat Completions, failed Responses envelope, or
                // oversized/malformed body is not successful readiness.
                // The provider body never leaves this transport.
                return ProviderReadinessTransportResponse(
                    statusCode: httpResponse.statusCode,
                    body: "",
                    modelIDs: [],
                    errorCategory: .malformedResponse
                )
            }
        }

        let modelIDs: [String]
        if request.operation == .modelDiscovery,
           (200..<300).contains(httpResponse.statusCode) {
            let adapter = wireAdapter(for: request, account: usesChatGPTAccount)
            do {
                var decodedModelIDs = try adapter.decodeModelCatalog(from: data).map(\.id)
                if request.protocolType == .anthropic {
                    // Anthropic 模型目录分页：沿游标继续拉取，最多 20 页。
                    var cursor = adapter.nextCatalogPageCursor(from: data)
                    var pageCount = 1
                    while let afterID = cursor, pageCount < 20 {
                        pageCount += 1
                        guard let pageData = try await fetchCatalogPage(
                            adapter: adapter,
                            request: request,
                            afterID: afterID
                        ) else { break }
                        decodedModelIDs += try adapter.decodeModelCatalog(from: pageData).map(\.id)
                        cursor = adapter.nextCatalogPageCursor(from: pageData)
                    }
                }
                guard let safeModelIDs = safeModelIDs(
                    decodedModelIDs,
                    excludingCredential: request.apiKey
                ) else {
                    return ProviderReadinessTransportResponse(
                        statusCode: httpResponse.statusCode,
                        body: "",
                        modelIDs: [],
                        errorCategory: .malformedResponse
                    )
                }
                modelIDs = safeModelIDs
            } catch ProviderReadinessWireAdapterError.malformedModelCatalog
                    where isValidEmptyModelCatalog(data, protocolType: request.protocolType) {
                // A structurally valid empty catalog is a product state, not a
                // malformed response; SettingsCenter maps it to `.empty`.
                modelIDs = []
            } catch ProviderReadinessWireAdapterError.malformedModelCatalog {
                // Never forward provider payloads. A malformed catalog is a
                // typed, fail-closed readiness result with no model identity.
                return ProviderReadinessTransportResponse(
                    statusCode: httpResponse.statusCode,
                    body: "",
                    modelIDs: [],
                    errorCategory: .malformedResponse
                )
            }
        } else {
            modelIDs = []
        }
        return ProviderReadinessTransportResponse(
            statusCode: httpResponse.statusCode,
            // Response bodies are intentionally not retained or forwarded:
            // provider errors may echo credentials or user content. Readiness
            // consumers receive only status, typed category and model IDs.
            body: "",
            modelIDs: modelIDs,
            errorCategory: quotaExhausted(statusCode: httpResponse.statusCode, data: data)
                ? .permissionDenied : failureCategory(for: httpResponse.statusCode)
        )
    }

    /// 余额或额度用尽（只按固定白名单关键词判断，正文不保留）：归入“无访问权限/额度”类，
    /// 不按限流重试，提示里写明去检查账户额度。
    private func quotaExhausted(statusCode: Int, data: Data) -> Bool {
        guard !(200..<300).contains(statusCode), statusCode != 401, !data.isEmpty else { return false }
        let body = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        return ProviderHTTPErrorAdapter.indicatesQuotaExhausted(statusCode: statusCode, body: body)
    }

    private static func ownedPhase(_ operation: ProviderReadinessOperation) -> OwnedMMPhase {
        switch operation {
        case .reachability: .reachability
        case .authentication: .authentication
        case .modelDiscovery: .modelDiscovery
        case .minimalModelRequest: .minimalText
        }
    }

    /// 拉取目录的后续一页；非 2xx 或网络失败时返回 nil，沿用已取得的前几页。
    private func fetchCatalogPage(
        adapter: any ProviderReadinessWireAdapter,
        request: ProviderReadinessTransportRequest,
        afterID: String
    ) async throws -> Data? {
        try Task.checkCancellation()
        let assembled = try adapter.makeCatalogPageRequest(
            baseURL: request.baseURL,
            apiKey: request.apiKey,
            afterID: afterID
        )
        let urlRequest = try requestURLPolicy?(assembled) ?? assembled
        let redirectDelegate = ReadinessRedirectDelegate(audit: nil)
        do {
            let (pageData, pageResponse) = try await session.data(
                for: urlRequest,
                delegate: redirectDelegate
            )
            try Task.checkCancellation()
            guard !redirectDelegate.rejectedRedirect,
                  let http = pageResponse as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return pageData
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func safeModelIDs(
        _ modelIDs: [String],
        excludingCredential credential: String
    ) -> [String]? {
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var safe: [String] = []
        for rawModelID in modelIDs {
            let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty,
                  !modelID.contains(trimmedCredential),
                  modelID.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  seen.insert(modelID).inserted else {
                return nil
            }
            safe.append(modelID)
        }
        return safe.isEmpty ? nil : safe
    }

    private func wireAdapter(
        for request: ProviderReadinessTransportRequest,
        account: Bool
    ) -> any ProviderReadinessWireAdapter {
        account
            ? ChatGPTAccountReadinessAdapter()
            : ProviderReadinessWireAdapterFactory.make(for: request.protocolType, baseURL: request.baseURL)
    }

    private func makeURLRequest(
        for request: ProviderReadinessTransportRequest,
        account: Bool
    ) throws -> URLRequest {
        let adapter = wireAdapter(for: request, account: account)
        let operation: ProviderReadinessTransportCall
        switch request.operation {
        case .reachability:
            operation = .reachability
        case .authentication:
            operation = .authentication
        case .modelDiscovery:
            operation = .modelCatalog
        case .minimalModelRequest(let modelID):
            operation = .modelRequest(modelID: modelID)
        }

        return try adapter.makeRequest(
            operation: operation,
            baseURL: request.baseURL,
            modelID: request.modelID,
            apiKey: request.apiKey
        )
    }

    private func failureCategory(for statusCode: Int) -> ProviderReadinessFailureCategory? {
        guard !(200..<300).contains(statusCode) else { return nil }
        switch statusCode {
        case 400, 422:
            return .invalidConfiguration
        case 401:
            return .unauthorized
        case 402, 403:
            return .permissionDenied
        case 404:
            return .notFound
        case 408:
            return .timeout
        case 429:
            return .rateLimited
        case 500...599:
            return .server
        default:
            return .transport
        }
    }

    private func isValidEmptyModelCatalog(
        _ data: Data,
        protocolType: ProviderWireProtocol
    ) -> Bool {
        switch protocolType {
        case .openaiCompatible, .openaiResponses:
            return (try? JSONDecoder().decode(
                EmptyOpenAIModelCatalog.self,
                from: data
            ))?.data.isEmpty == true
        case .anthropic:
            return (try? JSONDecoder().decode(
                EmptyAnthropicModelCatalog.self,
                from: data
            ))?.data.isEmpty == true
        case .other:
            return false
        }
    }
}

/// A packaged session-field journey may probe its explicitly configured local
/// synthetic Provider without acquiring general external network capability.
/// The underlying production transport rejects every HTTP redirect, so an
/// authorized loopback base cannot move a credential to another origin.
struct ControlledLoopbackProviderReadinessTransport: SettingsProviderReadinessTransport {
    private let transport: URLSessionProviderReadinessTransport

    var canProduceLiveEvidence: Bool { true }

    init(session: URLSession? = nil) {
        transport = URLSessionProviderReadinessTransport(
            session: session ?? Self.makeDirectLoopbackSession(),
            canProduceLiveEvidence: true
        )
    }

    private static func makeDirectLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        // A loopback URL routed through a process/system proxy is no longer a
        // local request. Keep the field probe direct even on a proxied host.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        return URLSession(configuration: configuration)
    }

    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        guard Self.accepts(request.baseURL) else {
            throw SettingsProviderReadinessTransportError.invalidURL
        }
        return try await transport.send(request)
    }

    static func accepts(_ baseURL: URL) -> Bool {
        guard CustomProviderURL.isSafeDestination(baseURL),
              let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["127.0.0.1", "::1", "localhost"].contains(host),
              components.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        return true
    }
}

enum ProviderReadinessTransportComposition {
    static func make(
        profile: RuntimeIsolationProfile,
        sessionFieldJourney: Bool,
        sessionFieldPreparationSucceeded: Bool
    ) -> (any SettingsProviderReadinessTransport)? {
        if profile.allowsExternalNetwork { return nil }
        guard profile.mode == .packagedField,
              sessionFieldJourney,
              sessionFieldPreparationSucceeded,
              profile.isDisposableRootIntact else {
            return FailClosedProviderReadinessTransport()
        }
        return ControlledLoopbackProviderReadinessTransport()
    }
}

private struct EmptyOpenAIModelCatalog: Decodable {
    let data: [EmptyOpenAIModel]
}

private struct EmptyOpenAIModel: Decodable {
    let id: String
}

private struct EmptyAnthropicModelCatalog: Decodable {
    let data: [EmptyAnthropicModel]
}

private struct EmptyAnthropicModel: Decodable {
    let type: String
    let id: String
}

private final class ReadinessRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didRejectRedirect = false
    private let audit: OwnedMMTaskAudit?
    init(audit: OwnedMMTaskAudit? = nil) { self.audit = audit }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        audit?.urlSession(session, task: task, didFinishCollecting: metrics)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        audit?.urlSession(session, task: task, didCompleteWithError: error)
    }

    var rejectedRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRejectRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        didRejectRedirect = true
        lock.unlock()
        audit?.permit.fail()
        completionHandler(nil)
    }
}
