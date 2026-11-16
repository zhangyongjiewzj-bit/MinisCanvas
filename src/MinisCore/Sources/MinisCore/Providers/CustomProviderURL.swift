import Foundation

/// S4 安全切片：自定义 Provider URL 校验 + Bearer 泄漏防护。
///
/// 自定义 base URL 是用户可控的（设置页 / envvars.json / 环境变量），会被
/// OpenAI 兼容 / Responses / 生图 Provider 用来拼接 API endpoint，并附上
/// \`Authorization: Bearer <apiKey>\`。为阻止把凭据发往不安全目的地，本类型
/// 提供统一校验规则：
///
/// - 仅允许 \`https\`（任意 host）与**显式 loopback** 的 \`http\`
///   （\`localhost\` / \`127.0.0.0/8\` / IPv6 \`::1\`）；
/// - 拒绝其它 scheme（\`ftp\` / \`file\` / \`javascript:\` 等）、缺失 scheme、
///   空 host、以及内嵌凭据（\`user:pass@host\`，可被用于凭据混淆/钓鱼）；
/// - **fail-closed**：校验失败即抛错；任何携带 Bearer 的请求在发出前都必须
///   通过该校验，否则请求根本不构造。
///
/// 另外提供 \`ProviderRedirectGuard\`：URLSession 默认跟随 3xx 重定向并可能把
/// 请求头（含 Authorization）带到新地址；携带凭据的 Provider 会话用它把重定向
/// 限制在 https / loopback http 目的地，其余一律取消（fail-closed）。
public enum CustomProviderURL {

    /// 校验失败原因（Sendable / Equatable，可精确断言）。
    public enum Failure: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
        /// 无法解析为合法 URL。
        case invalidURL(String)
        /// scheme 缺失或不是 http/https。
        case unsupportedScheme(String?)
        /// 缺少 host。
        case emptyHost
        /// URL 内嵌 userinfo 凭据。
        case embeddedCredentials
        /// scheme 为 http 但 host 不是显式 loopback。
        case nonHTTPSHost(String)
        /// query 中包含可能承载凭据的字段。
        case credentialInQuery
        /// fragment 中包含可能承载凭据的字段。
        case credentialInFragment
        /// URL 或其 percent-decoded component 含控制字符。
        case controlCharacter

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "not a valid URL"
            case .unsupportedScheme(let scheme):
                let shown = scheme ?? "<missing>"
                return "unsupported scheme '\(shown)'; only https (or explicit loopback http) is allowed"
            case .emptyHost:
                return "missing host"
            case .embeddedCredentials:
                return "URL must not embed userinfo credentials"
            case .nonHTTPSHost(let host):
                return "non-HTTPS destination (http is allowed only for loopback hosts): \(host)"
            case .credentialInQuery:
                return "URL query must not contain credential-like fields"
            case .credentialInFragment:
                return "URL fragment must not contain credential-like fields"
            case .controlCharacter:
                return "URL must not contain control characters"
            }
        }

        /// Never use the enum's synthesized representation, which would
        /// include the legacy invalidURL associated value.
        public var description: String {
            errorDescription ?? "invalid provider URL"
        }
    }

    /// 校验一个自定义 Provider base URL 字符串。
    ///
    /// - Parameter raw: 用户提供的 base URL（允许首尾空白，会被 trim）。
    /// - Returns: 校验通过后的 \`URL\`。
    /// - Throws: \`Failure\`，说明该 URL 为何不能承载凭据。
    public static func validate(_ raw: String) throws -> URL {
        do {
            return try ProviderEndpointPolicy.canonicalize(raw).canonicalURL
        } catch let failure as ProviderEndpointPolicyError {
            switch failure {
            case .invalidURL:
                throw Failure.invalidURL(raw)
            case .unsupportedScheme(let scheme):
                throw Failure.unsupportedScheme(scheme)
            case .emptyHost:
                throw Failure.emptyHost
            case .embeddedCredentials:
                throw Failure.embeddedCredentials
            case .credentialInQuery:
                throw Failure.credentialInQuery
            case .credentialInFragment:
                throw Failure.credentialInFragment
            case .controlCharacter:
                throw Failure.controlCharacter
            case .nonHTTPSHost:
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = URLComponents(string: trimmed)?.host ?? "unknown"
                throw Failure.nonHTTPSHost(host)
            }
        }
    }

    /// 判断某个（完整）URL 是否可作为携带凭据请求的安全目的地
    /// （https 任意 host；http 仅 loopback；无内嵌凭据）。用于重定向目标校验。
    public static func isSafeDestination(_ url: URL) -> Bool {
        ProviderEndpointPolicy.isSafeDestination(url)
    }

    /// host 是否为显式 loopback：\`localhost\`、IPv4 \`127.0.0.0/8\`、IPv6 \`::1\`。
    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost
        // URLComponents 对 IPv6 字面量会保留方括号（"[::1]"）。
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let lower = host.lowercased()
        if lower == "localhost" { return true }
        if lower == "::1" || lower == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".")
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.dropFirst().allSatisfy { UInt8($0) != nil }
    }
}

/// A narrower destination policy for the disposable packaged-field chat fixture.
/// The ordinary provider policy deliberately permits public HTTPS endpoints.
public enum ControlledFieldLoopbackPolicy {
    public static func accepts(_ url: URL) -> Bool {
        guard (try? CustomProviderURL.validate(url.absoluteString)) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        return true
    }
}

/// A redirect response is returned to the provider as a non-2xx error. The
/// field fixture has no reason to follow redirects, even to another loopback.
private final class ControlledFieldNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ControlledFieldNoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum ControlledFieldLoopbackSession {
    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        // Do not send a loopback fixture request through a process/system proxy.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        return URLSession(configuration: configuration,
                          delegate: ControlledFieldNoRedirect.shared, delegateQueue: nil)
    }
}

/// URLSessionTaskDelegate：拒绝跟随到不安全目的地的重定向（fail-closed）。
///
/// URLSession 默认会跟随 3xx 并把请求头（含 Authorization）带到新地址；S4
/// 要求携带凭据的 Provider 请求只能跟随到 https / loopback http 目的地。
/// 对不安全目标调用 \`completionHandler(nil)\` 会取消该次重定向，请求以 3xx
/// 原响应返回，被 Provider 按非 2xx 处理。
public final class ProviderRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 进程级单例：URLSession 对 delegate 是弱引用，必须由外部强持有。
    public static let shared = ProviderRedirectGuard()

    /// An immutable resolver snapshot can be injected by a caller that has
    /// already resolved the provider host. The shared guard remains strict:
    /// hostname redirects without a snapshot fail closed.
    public let resolutionSnapshot: ProviderAddressResolutionSnapshot?

    private struct RedirectChainState {
        var currentCanonicalURL: String
        var visitedCanonicalURLs: Set<String>
        var hopCount: Int
        var resolvedAddressesByHost: [String: [String]]
    }

    private let stateLock = NSLock()
    private var chainStates: [ObjectIdentifier: RedirectChainState] = [:]

    public init(resolutionSnapshot: ProviderAddressResolutionSnapshot? = nil) {
        self.resolutionSnapshot = resolutionSnapshot
        super.init()
    }

    /// 无 source 时的静态重定向决策，保留旧的纯函数调用契约；实际
    /// URLSession delegate 使用下面的 per-task source-aware 路径。
    public static func guardedRedirect(for request: URLRequest) -> URLRequest? {
        guard let url = request.url else { return nil }
        return ProviderRedirectPolicy.redirectedRequest(
            from: url,
            to: request,
            hopCount: 1,
            requireResolution: false
        )
    }

    /// Source-aware pure redirect decision for callers that already track the
    /// current URL and chain. Cross-origin credential stripping is applied.
    public static func guardedRedirect(
        from source: URL,
        to request: URLRequest,
        hopCount: Int,
        visitedCanonicalURLs: Set<String> = [],
        resolutionSnapshot: ProviderAddressResolutionSnapshot? = nil
    ) -> URLRequest? {
        ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: request,
            hopCount: hopCount,
            visitedCanonicalURLs: visitedCanonicalURLs,
            resolutionSnapshot: resolutionSnapshot
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(guardedRedirect(for: task, source: response.url, request: request))
    }

    /// URLSession's delegate path is stateful per task so loops and excessive
    /// chains cannot be bypassed by repeatedly presenting a safe destination.
    private func guardedRedirect(for task: URLSessionTask, source: URL?, request: URLRequest) -> URLRequest? {
        guard let source,
              let sourceIdentity = try? ProviderEndpointPolicy.canonicalize(source.absoluteString),
              let destination = request.url,
              let destinationIdentity = try? ProviderEndpointPolicy.canonicalize(destination.absoluteString),
              let sourceAddresses = ProviderRedirectPolicy.resolvedAddresses(
                  for: source,
                  using: resolutionSnapshot
              ),
              let destinationAddresses = ProviderRedirectPolicy.resolvedAddresses(
                  for: destination,
                  using: resolutionSnapshot
              ) else {
            clearState(for: task)
            return nil
        }

        let taskID = ObjectIdentifier(task)
        stateLock.lock()
        defer { stateLock.unlock() }

        var state = chainStates[taskID] ?? RedirectChainState(
            currentCanonicalURL: sourceIdentity.identity,
            visitedCanonicalURLs: [sourceIdentity.identity],
            hopCount: 0,
            resolvedAddressesByHost: [hostKey(for: sourceIdentity.host): sourceAddresses]
        )
        guard state.currentCanonicalURL == sourceIdentity.identity else {
            chainStates.removeValue(forKey: taskID)
            return nil
        }
        let nextHop = state.hopCount + 1
        guard !state.visitedCanonicalURLs.contains(destinationIdentity.identity),
              let redirected = ProviderRedirectPolicy.redirectedRequest(
                  from: source,
                  to: request,
                  hopCount: nextHop,
                  visitedCanonicalURLs: state.visitedCanonicalURLs,
                  resolutionSnapshot: resolutionSnapshot,
                  resolvedAddressHistory: state.resolvedAddressesByHost
              ) else {
            chainStates.removeValue(forKey: taskID)
            return nil
        }

        state.currentCanonicalURL = destinationIdentity.identity
        state.visitedCanonicalURLs.insert(destinationIdentity.identity)
        state.resolvedAddressesByHost[hostKey(for: destinationIdentity.host)] = destinationAddresses
        state.hopCount = nextHop
        chainStates[taskID] = state
        return redirected
    }

    private func clearState(for task: URLSessionTask) {
        stateLock.lock()
        chainStates.removeValue(forKey: ObjectIdentifier(task))
        stateLock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        clearState(for: task)
    }

    private func hostKey(for host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}
