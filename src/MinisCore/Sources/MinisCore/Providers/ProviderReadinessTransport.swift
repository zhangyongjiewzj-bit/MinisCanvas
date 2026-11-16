import Foundation

public enum ProviderReadinessStage: String, Codable, CaseIterable, Hashable, Sendable {
    case configuration
    case reachability
    case authentication
    case modelCatalog
    case modelRequest
}

public enum ProviderReadinessStageStatus: String, Codable, Hashable, Sendable {
    case passed
    case failed
}

public enum ProviderReadinessFailureCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case invalidConfiguration
    case missingCredential
    case unauthorized
    case timeout
    case rateLimited
    case permissionDenied
    case notFound
    case unavailable
    case server
    case malformedResponse
    case modelNotFound
    case transport
}

public enum ProviderReadinessCredential: Codable, Hashable, Sendable {
    case notRequired
    case present(source: String)
    case missing(source: String?)

    public var source: String? {
        switch self {
        case .notRequired:
            return nil
        case .present(let source):
            return source
        case .missing(let source):
            return source
        }
    }
}

public struct ProviderReadinessCheckRequest: Codable, Hashable, Sendable {
    public static let legacyConfigurationGeneration = "legacy"

    public let providerID: String
    public let modelID: String
    public let deployment: ProviderDeployment
    public var baseURL: String
    public var credential: ProviderReadinessCredential
    public let evidenceID: String?
    public let checkedAt: Date
    /// Secret-free configuration identity carried with the readiness attempt.
    /// A reconnect must not let a result from an older generation become green.
    public let configurationGeneration: String
    /// Opaque provider identity and freshness metadata; never a URL or secret.
    public let configurationFingerprint: String?
    public let expiresAt: Date?

    public init(
        providerID: String,
        modelID: String,
        deployment: ProviderDeployment,
        baseURL: String,
        credential: ProviderReadinessCredential,
        evidenceID: String? = nil,
        checkedAt: Date = Date(),
        configurationGeneration: String = Self.legacyConfigurationGeneration,
        configurationFingerprint: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.deployment = deployment
        self.baseURL = baseURL
        self.credential = credential
        self.evidenceID = evidenceID
        self.checkedAt = checkedAt
        let normalizedGeneration = configurationGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.configurationGeneration = normalizedGeneration.isEmpty
            ? Self.legacyConfigurationGeneration
            : normalizedGeneration
        self.configurationFingerprint = configurationFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.expiresAt = expiresAt
    }

    fileprivate var validationFailure: ProviderReadinessFailureCategory? {
        guard !providerID.trimmedNonEmpty.isEmpty,
              !modelID.trimmedNonEmpty.isEmpty,
              let url = URL(string: baseURL.trimmedNonEmpty),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              !configurationGeneration.isEmpty,
              checkedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            return .invalidConfiguration
        }
        return nil
    }
}

/// The identity that owns one transport attempt.  A provider/model pair is
/// not sufficient after a rebind: the configuration generation and opaque
/// fingerprint must travel with the attempt so a late response cannot be
/// accepted by a newer lifecycle.
public struct ProviderReadinessTransportAttemptIdentity: Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let deployment: ProviderDeployment
    public let configurationGeneration: String
    public let configurationFingerprint: String?

    public init(request: ProviderReadinessCheckRequest) {
        self.providerID = ProviderReadinessRevision.canonicalProviderID(request.providerID)
        self.modelID = ProviderReadinessRevision.canonicalModelID(request.modelID)
        self.deployment = request.deployment
        self.configurationGeneration = request.configurationGeneration
        self.configurationFingerprint = request.configurationFingerprint
    }
}

/// Opaque handle for one transport lifecycle.  It is intentionally not
/// Codable: an attempt token is process-local and cannot be replayed from a
/// persisted response.
public struct ProviderReadinessTransportAttempt: Hashable, Sendable {
    public let identity: ProviderReadinessTransportAttemptIdentity
    public let sequence: UInt64

    fileprivate init(
        identity: ProviderReadinessTransportAttemptIdentity,
        sequence: UInt64
    ) {
        self.identity = identity
        self.sequence = sequence
    }
}

/// Serializes provider rebind/restart with transport completion.  Starting a
/// newer attempt invalidates every older token; cancellation is checked by
/// the probe after each awaited transport operation before publishing a
/// report to the readiness persistence consumer.
public actor ProviderReadinessTransportAttemptFence {
    private var sequence: UInt64 = 0
    private var current: ProviderReadinessTransportAttempt?

    public init() {}

    public func begin(
        request: ProviderReadinessCheckRequest
    ) -> ProviderReadinessTransportAttempt {
        sequence &+= 1
        let attempt = ProviderReadinessTransportAttempt(
            identity: ProviderReadinessTransportAttemptIdentity(request: request),
            sequence: sequence
        )
        current = attempt
        return attempt
    }

    public func invalidate() {
        sequence &+= 1
        current = nil
    }

    public func accepts(_ attempt: ProviderReadinessTransportAttempt) -> Bool {
        current == attempt
    }
}

public enum ProviderReadinessTransportError: Error, Codable, Hashable, Sendable {
    case timeout
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case permissionDenied
    case notFound
    case unavailable
    case server(statusCode: Int?)
    case malformedResponse
    case transport

    public var category: ProviderReadinessFailureCategory {
        switch self {
        case .timeout:
            return .timeout
        case .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        case .permissionDenied:
            return .permissionDenied
        case .notFound:
            return .notFound
        case .unavailable:
            return .unavailable
        case .server:
            return .server
        case .malformedResponse:
            return .malformedResponse
        case .transport:
            return .transport
        }
    }

    public var retryAfterSeconds: Int? {
        guard case .rateLimited(let seconds) = self else { return nil }
        return seconds
    }
}

public struct ProviderReadinessStageResult: Codable, Hashable, Sendable {
    public let stage: ProviderReadinessStage
    public let status: ProviderReadinessStageStatus
    public let failureCategory: ProviderReadinessFailureCategory?
    public let retryAfterSeconds: Int?

    public init(
        stage: ProviderReadinessStage,
        status: ProviderReadinessStageStatus,
        failureCategory: ProviderReadinessFailureCategory? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.stage = stage
        self.status = status
        self.failureCategory = failureCategory
        self.retryAfterSeconds = retryAfterSeconds
    }

    fileprivate static func passed(_ stage: ProviderReadinessStage) -> Self {
        Self(stage: stage, status: .passed)
    }

    fileprivate static func failed(
        _ stage: ProviderReadinessStage,
        category: ProviderReadinessFailureCategory,
        retryAfterSeconds: Int? = nil
    ) -> Self {
        Self(
            stage: stage,
            status: .failed,
            failureCategory: category,
            retryAfterSeconds: retryAfterSeconds
        )
    }
}

public struct ProviderReadinessModel: Codable, Hashable, Sendable {
    public let id: String
    public let capabilities: Set<ProviderCapability>

    public init(id: String, capabilities: Set<ProviderCapability> = []) {
        self.id = id
        self.capabilities = capabilities
    }
}

public enum ProviderReadinessModelStatus: String, Codable, Hashable, Sendable {
    case passed
    case failed
}

public struct ProviderReadinessModelResult: Codable, Hashable, Sendable {
    public let modelID: String
    public let status: ProviderReadinessModelStatus
    public let failureCategory: ProviderReadinessFailureCategory?
    public let retryAfterSeconds: Int?

    public init(
        modelID: String,
        status: ProviderReadinessModelStatus,
        failureCategory: ProviderReadinessFailureCategory? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.modelID = modelID
        self.status = status
        self.failureCategory = failureCategory
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public struct ProviderReadinessCheckReport: Codable, Hashable, Sendable {
    public let readiness: ProviderReadiness
    public let stageResults: [ProviderReadinessStageResult]
    public let discoveredModels: [ProviderReadinessModel]
    public let modelResults: [String: ProviderReadinessModelResult]
    public let configurationGeneration: String
    public let configurationFingerprint: String?
    public let expiresAt: Date?

    public init(
        readiness: ProviderReadiness,
        stageResults: [ProviderReadinessStageResult],
        discoveredModels: [ProviderReadinessModel],
        modelResults: [String: ProviderReadinessModelResult],
        configurationGeneration: String = ProviderReadinessCheckRequest
            .legacyConfigurationGeneration,
        configurationFingerprint: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.readiness = readiness
        self.stageResults = stageResults
        self.discoveredModels = discoveredModels
        self.modelResults = modelResults
        let normalizedGeneration = configurationGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.configurationGeneration = normalizedGeneration.isEmpty
            ? ProviderReadinessCheckRequest.legacyConfigurationGeneration
            : normalizedGeneration
        self.configurationFingerprint = configurationFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.expiresAt = expiresAt
    }
}

public protocol ProviderReadinessTransport: Sendable {
    func checkReachability(
        _ request: ProviderReadinessCheckRequest
    ) async throws

    func authenticate(
        _ request: ProviderReadinessCheckRequest
    ) async throws

    func discoverModels(
        _ request: ProviderReadinessCheckRequest
    ) async throws -> [ProviderReadinessModel]

    func sendMinimumRequest(
        _ request: ProviderReadinessCheckRequest,
        modelID: String
    ) async throws
}

public enum ProviderReadinessTransportCall: Hashable, Sendable {
    case reachability
    case authentication
    case modelCatalog
    case modelRequest(modelID: String)
}

public struct MockProviderReadinessTransportScript: Sendable {
    public let reachability: Result<Void, ProviderReadinessTransportError>
    public let authentication: Result<Void, ProviderReadinessTransportError>
    public let modelCatalog: Result<[ProviderReadinessModel], ProviderReadinessTransportError>
    public let minimumRequests: [String: Result<Void, ProviderReadinessTransportError>]
    public let defaultMinimumRequest: Result<Void, ProviderReadinessTransportError>

    public init(
        reachability: Result<Void, ProviderReadinessTransportError> = .success(()),
        authentication: Result<Void, ProviderReadinessTransportError> = .success(()),
        modelCatalog: Result<[ProviderReadinessModel], ProviderReadinessTransportError>,
        minimumRequests: [String: Result<Void, ProviderReadinessTransportError>] = [:],
        defaultMinimumRequest: Result<Void, ProviderReadinessTransportError> = .success(())
    ) {
        self.reachability = reachability
        self.authentication = authentication
        self.modelCatalog = modelCatalog
        self.minimumRequests = minimumRequests
        self.defaultMinimumRequest = defaultMinimumRequest
    }
}

public actor MockProviderReadinessTransport: ProviderReadinessTransport {
    private let script: MockProviderReadinessTransportScript
    private var calls: [ProviderReadinessTransportCall] = []

    public init(script: MockProviderReadinessTransportScript) {
        self.script = script
    }

    public func checkReachability(
        _ request: ProviderReadinessCheckRequest
    ) async throws {
        calls.append(.reachability)
        try script.reachability.get()
    }

    public func authenticate(
        _ request: ProviderReadinessCheckRequest
    ) async throws {
        calls.append(.authentication)
        try script.authentication.get()
    }

    public func discoverModels(
        _ request: ProviderReadinessCheckRequest
    ) async throws -> [ProviderReadinessModel] {
        calls.append(.modelCatalog)
        return try script.modelCatalog.get()
    }

    public func sendMinimumRequest(
        _ request: ProviderReadinessCheckRequest,
        modelID: String
    ) async throws {
        calls.append(.modelRequest(modelID: modelID))
        let result = script.minimumRequests[modelID] ?? script.defaultMinimumRequest
        try result.get()
    }

    public func recordedCalls() -> [ProviderReadinessTransportCall] {
        calls
    }
}

public struct ProviderReadinessContractProbe: ProviderReadinessProbe, Sendable {
    public let request: ProviderReadinessCheckRequest
    private let transport: any ProviderReadinessTransport
    private let attemptFence: ProviderReadinessTransportAttemptFence?

    public init(
        request: ProviderReadinessCheckRequest,
        transport: any ProviderReadinessTransport,
        attemptFence: ProviderReadinessTransportAttemptFence? = nil
    ) {
        self.request = request
        self.transport = transport
        self.attemptFence = attemptFence
    }

    public func check() async -> ProviderReadinessCheckReport {
        var stageResults: [ProviderReadinessStageResult] = []
        var discoveredModels: [ProviderReadinessModel] = []
        var modelResults: [String: ProviderReadinessModelResult] = [:]
        let attempt = await attemptFence?.begin(request: request)

        guard await isCurrent(attempt) else {
            return invalidatedReport()
        }

        if let failure = request.validationFailure {
            stageResults.append(.failed(.configuration, category: failure))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        }
        stageResults.append(.passed(.configuration))

        if case .missing(let source) = request.credential {
            stageResults.append(.failed(.authentication, category: .missingCredential))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: [],
                credential: .missing(source: source)
            )
        }

        do {
            try await transport.checkReachability(request)
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.passed(.reachability))
        } catch let error as ProviderReadinessTransportError {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.failed(
                .reachability,
                category: error.category,
                retryAfterSeconds: error.retryAfterSeconds
            ))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        } catch {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.failed(.reachability, category: .transport))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        }

        do {
            try await transport.authenticate(request)
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.passed(.authentication))
        } catch let error as ProviderReadinessTransportError {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.failed(
                .authentication,
                category: error.category,
                retryAfterSeconds: error.retryAfterSeconds
            ))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        } catch {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.failed(.authentication, category: .transport))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        }

        do {
            discoveredModels = try await transport.discoverModels(request)
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
        } catch let error as ProviderReadinessTransportError {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.failed(
                .modelCatalog,
                category: error.category,
                retryAfterSeconds: error.retryAfterSeconds
            ))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        } catch {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            stageResults.append(.failed(.modelCatalog, category: .transport))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        }

        guard !discoveredModels.isEmpty else {
            stageResults.append(.failed(.modelCatalog, category: .malformedResponse))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        }
        stageResults.append(.passed(.modelCatalog))

        guard let target = discoveredModels.first(where: { $0.id == request.modelID }) else {
            stageResults.append(.failed(.modelRequest, category: .modelNotFound))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .unavailable,
                capabilities: []
            )
        }

        for model in discoveredModels {
            guard await isCurrent(attempt) else {
                return invalidatedReport()
            }
            do {
                try await transport.sendMinimumRequest(request, modelID: model.id)
                guard await isCurrent(attempt) else {
                    return invalidatedReport()
                }
                modelResults[model.id] = ProviderReadinessModelResult(
                    modelID: model.id,
                    status: .passed
                )
            } catch let error as ProviderReadinessTransportError {
                guard await isCurrent(attempt) else {
                    return invalidatedReport()
                }
                modelResults[model.id] = ProviderReadinessModelResult(
                    modelID: model.id,
                    status: .failed,
                    failureCategory: error.category,
                    retryAfterSeconds: error.retryAfterSeconds
                )
            } catch {
                guard await isCurrent(attempt) else {
                    return invalidatedReport()
                }
                modelResults[model.id] = ProviderReadinessModelResult(
                    modelID: model.id,
                    status: .failed,
                    failureCategory: .transport
                )
            }
        }

        guard await isCurrent(attempt) else {
            return invalidatedReport()
        }

        let targetResult = modelResults[request.modelID]
        if let targetResult, targetResult.status == .passed {
            let failedCategory = modelResults.values
                .first(where: { $0.status == .failed })?
                .failureCategory
            stageResults.append(.failed(
                .modelRequest,
                category: failedCategory ?? .transport
            ))
            return report(
                stageResults: stageResults,
                discoveredModels: discoveredModels,
                modelResults: modelResults,
                probe: .reachable,
                capabilities: target.capabilities
            )
        }

        let targetFailure = targetResult?.failureCategory ?? .transport
        stageResults.append(.failed(.modelRequest, category: targetFailure))
        return report(
            stageResults: stageResults,
            discoveredModels: discoveredModels,
            modelResults: modelResults,
            probe: .unavailable,
            capabilities: []
        )
    }

    public func probe() async -> ProviderReadiness {
        await check().readiness
    }

    private func isCurrent(
        _ attempt: ProviderReadinessTransportAttempt?
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let attemptFence else { return true }
        guard let attempt else { return false }
        return await attemptFence.accepts(attempt)
    }

    private func invalidatedReport() -> ProviderReadinessCheckReport {
        let readiness = ProviderReadiness.evaluate(
            providerID: "",
            modelID: "",
            deployment: request.deployment,
            probe: .unavailable,
            credential: request.providerCredentialStatus,
            capabilities: [],
            checkedAt: .distantPast,
            evidenceID: nil,
            errorCategory: .transport
        )
        return ProviderReadinessCheckReport(
            readiness: readiness,
            stageResults: [
                .failed(.configuration, category: .transport)
            ],
            discoveredModels: [],
            modelResults: [:],
            configurationGeneration: request.configurationGeneration,
            configurationFingerprint: request.configurationFingerprint,
            expiresAt: request.expiresAt
        )
    }

    private func report(
        stageResults: [ProviderReadinessStageResult],
        discoveredModels: [ProviderReadinessModel],
        modelResults: [String: ProviderReadinessModelResult],
        probe: ProviderProbeStatus,
        capabilities: Set<ProviderCapability>,
        credential: ProviderCredentialStatus? = nil
    ) -> ProviderReadinessCheckReport {
        let resolvedCredential = credential ?? request.providerCredentialStatus
        let readiness = ProviderReadiness.evaluate(
            providerID: request.providerID,
            modelID: request.modelID,
            deployment: request.deployment,
            probe: probe,
            credential: resolvedCredential,
            capabilities: capabilities,
            checkedAt: request.checkedAt,
            evidenceID: readinessEvidenceID(for: probe)
        )
        return ProviderReadinessCheckReport(
            readiness: readiness,
            stageResults: stageResults,
            discoveredModels: discoveredModels,
            modelResults: modelResults,
            configurationGeneration: request.configurationGeneration,
            configurationFingerprint: request.configurationFingerprint,
            expiresAt: request.expiresAt
        )
    }

    private func readinessEvidenceID(for probe: ProviderProbeStatus) -> String? {
        guard probe == .reachable else { return nil }
        return request.evidenceID
    }
}

private extension ProviderReadinessCheckRequest {
    var providerCredentialStatus: ProviderCredentialStatus {
        switch credential {
        case .notRequired:
            return .notRequired
        case .present(let source):
            return .available(source: source)
        case .missing(let source):
            return .missing(source: source)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
