import CryptoKit
import Foundation

/// Secret-free readiness/apply provenance for one frozen fallback model.
///
/// The provider ID is the route-facing ID used by the runtime provider map;
/// evidence and apply IDs are opaque receipt references only.
public struct ProviderRuntimeFallback: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case readinessEvidenceID
        case applyReceiptID
        case capabilities
        case configurationFingerprint
    }

    public let providerID: String
    public let modelID: String
    public let readinessEvidenceID: String
    public let applyReceiptID: String
    public let capabilities: Set<ProviderCapability>
    public let configurationFingerprint: String?

    public init(
        providerID: String,
        modelID: String,
        readinessEvidenceID: String,
        applyReceiptID: String,
        capabilities: Set<ProviderCapability> = [],
        configurationFingerprint: String? = nil
    ) {
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.readinessEvidenceID = readinessEvidenceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.applyReceiptID = applyReceiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.capabilities = capabilities
        self.configurationFingerprint = configurationFingerprint.map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } ?? nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: container.decode(String.self, forKey: .providerID),
            modelID: container.decode(String.self, forKey: .modelID),
            readinessEvidenceID: container.decode(String.self, forKey: .readinessEvidenceID),
            applyReceiptID: container.decode(String.self, forKey: .applyReceiptID),
            capabilities: container.decodeIfPresent(
                Set<ProviderCapability>.self,
                forKey: .capabilities
            ) ?? [],
            configurationFingerprint: container.decodeIfPresent(
                String.self,
                forKey: .configurationFingerprint
            )
        )
    }

    public var hasReadinessEvidence: Bool {
        !providerID.isEmpty
            && !modelID.isEmpty
            && !readinessEvidenceID.isEmpty
            && !applyReceiptID.isEmpty
            && ProviderRuntimeSnapshot.isValidReadinessEvidenceID(
                readinessEvidenceID
            )
            && ProviderRuntimeSnapshot.discoveryReceiptID(
                from: applyReceiptID
            ) != nil
    }
}

/// Secret-free provider facts captured at the start of one ordinary Chat turn.
///
/// Readiness and Apply receipts are deliberately carried as opaque identifiers.
/// Credentials, URLs, and transport payloads never enter this snapshot.
public struct ProviderRuntimeSnapshot: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case readinessEvidenceID
        case applyReceiptID
        case fallbackProviderIDs
        case fallbackProvenance
        case capabilities
        case configurationFingerprint
        case createdAt
        case routeReceiptID
    }

    public let providerID: String
    public let modelID: String
    public let readinessEvidenceID: String?
    public let applyReceiptID: String?
    public let fallbackProviderIDs: [String]
    public let fallbackProvenance: [ProviderRuntimeFallback]
    public let capabilities: Set<ProviderCapability>
    public let configurationFingerprint: String?
    public let createdAt: Date
    public let routeReceiptID: String

    /// Returns an opaque, secret-free fingerprint for provider configuration.
    /// Callers may include endpoint material, but the material is never stored
    /// or returned; only the SHA-256 digest crosses the runtime boundary.
    public static func configurationFingerprint(
        providerID: String,
        modelID: String,
        capabilities: Set<ProviderCapability>,
        configurationMaterial: String? = nil
    ) -> String {
        let canonical = [
            providerID.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            capabilities.map(\.rawValue).sorted().joined(separator: ","),
            configurationMaterial ?? "",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "provider-config:\(digest)"
    }

    public init(
        providerID: String,
        modelID: String,
        readinessEvidenceID: String? = nil,
        applyReceiptID: String? = nil,
        fallbackProviderIDs: [String] = [],
        fallbackProvenance: [ProviderRuntimeFallback] = [],
        capabilities: Set<ProviderCapability> = [],
        configurationFingerprint: String? = nil,
        createdAt: Date = Date()
    ) throws {
        let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !modelID.isEmpty else {
            throw ProviderRuntimeSnapshotError.invalidIdentity
        }
        guard let primaryReadinessEvidenceID = readinessEvidenceID.trimmedNonEmpty,
              let primaryApplyReceiptID = applyReceiptID.trimmedNonEmpty else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        guard Self.isValidReadinessEvidenceID(primaryReadinessEvidenceID) else {
            throw ProviderRuntimeSnapshotError.invalidReadinessEvidence
        }
        guard Self.discoveryReceiptID(from: primaryApplyReceiptID) != nil else {
            throw ProviderRuntimeSnapshotError.invalidApplyReceiptIdentity(
                providerID
            )
        }
        let normalizedFallbackIDs = fallbackProviderIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedFallbackIDs.contains(providerID) else {
            throw ProviderRuntimeSnapshotError.duplicateFallback
        }
        let provenanceIDs = fallbackProvenance.map(\.providerID)
        guard !provenanceIDs.contains(providerID) else {
            throw ProviderRuntimeSnapshotError.duplicateFallback
        }
        let fallbackIDs = normalizedFallbackIDs.isEmpty
            ? provenanceIDs
            : normalizedFallbackIDs
        guard fallbackProvenance.isEmpty || fallbackIDs == provenanceIDs else {
            throw ProviderRuntimeSnapshotError.invalidFallbackProvenance
        }
        guard fallbackProvenance.allSatisfy(\.hasReadinessEvidence) else {
            throw ProviderRuntimeSnapshotError.invalidFallbackProvenance
        }
        guard Set(fallbackIDs).count == fallbackIDs.count else {
            throw ProviderRuntimeSnapshotError.duplicateFallback
        }
        self.providerID = providerID
        self.modelID = modelID
        self.readinessEvidenceID = primaryReadinessEvidenceID
        self.applyReceiptID = primaryApplyReceiptID
        self.fallbackProviderIDs = fallbackIDs
        self.fallbackProvenance = fallbackProvenance
        self.capabilities = capabilities
        self.configurationFingerprint = configurationFingerprint.map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } ?? nil
        self.createdAt = createdAt
        let fallbackCanonical = fallbackProvenance.isEmpty
            ? fallbackIDs.joined(separator: ",")
            : fallbackProvenance.map {
                [
                    $0.providerID,
                    $0.modelID,
                    $0.readinessEvidenceID,
                    $0.applyReceiptID,
                    $0.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                    $0.configurationFingerprint ?? "",
                ].joined(separator: ":")
            }.joined(separator: ",")
        let canonical = [
            providerID,
            modelID,
            self.readinessEvidenceID ?? "",
            self.applyReceiptID ?? "",
            capabilities.map(\.rawValue).sorted().joined(separator: ","),
            self.configurationFingerprint ?? "",
            String(format: "%.6f", createdAt.timeIntervalSince1970),
            fallbackCanonical,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.routeReceiptID = "provider-route:\(digest)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: try container.decode(String.self, forKey: .providerID),
            modelID: try container.decode(String.self, forKey: .modelID),
            readinessEvidenceID: try container.decodeIfPresent(
                String.self,
                forKey: .readinessEvidenceID
            ),
            applyReceiptID: try container.decodeIfPresent(
                String.self,
                forKey: .applyReceiptID
            ),
            fallbackProviderIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .fallbackProviderIDs
            ) ?? [],
            fallbackProvenance: try container.decodeIfPresent(
                [ProviderRuntimeFallback].self,
                forKey: .fallbackProvenance
            ) ?? [],
            capabilities: try container.decodeIfPresent(
                Set<ProviderCapability>.self,
                forKey: .capabilities
            ) ?? [],
            configurationFingerprint: try container.decodeIfPresent(
                String.self,
                forKey: .configurationFingerprint
            ),
            createdAt: try container.decodeIfPresent(
                Date.self,
                forKey: .createdAt
            ) ?? Date()
        )
    }

    public var hasReadinessEvidence: Bool {
        guard let readinessEvidenceID,
              let applyReceiptID else {
            return false
        }
        return !readinessEvidenceID.isEmpty
            && !applyReceiptID.isEmpty
            && Self.isValidReadinessEvidenceID(readinessEvidenceID)
            && Self.discoveryReceiptID(from: applyReceiptID) != nil
    }

    public var hasCompleteFallbackProvenance: Bool {
        guard fallbackProviderIDs.count == fallbackProvenance.count else {
            return fallbackProviderIDs.isEmpty
        }
        return zip(fallbackProviderIDs, fallbackProvenance).allSatisfy {
            $0 == $1.providerID && $1.hasReadinessEvidence
        }
    }

    fileprivate static func isValidReadinessEvidenceID(
        _ evidenceID: String
    ) -> Bool {
        let schemes: [(prefix: String, digestLength: Int)] = [
            ("live-settings:", 64),
            ("http-readiness:", 32),
        ]
        for scheme in schemes where evidenceID.hasPrefix(scheme.prefix) {
            let digest = evidenceID.dropFirst(scheme.prefix.count)
            guard digest.count == scheme.digestLength else { return false }
            return digest.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
                    || (97...102).contains(scalar.value)
            }
        }
        return true
    }

    fileprivate static func discoveryReceiptID(
        from applyReceiptID: String
    ) -> String? {
        let prefix = "provider-readiness-apply:"
        let applyReceiptID = applyReceiptID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard applyReceiptID.hasPrefix(prefix) else { return nil }
        let discoveryReceiptID = String(applyReceiptID.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return discoveryReceiptID.isEmpty ? nil : discoveryReceiptID
    }
}

public enum ProviderRuntimeSnapshotError: Error, Equatable, Sendable {
    case invalidIdentity
    case missingPrimaryProvenance
    case invalidReadinessEvidence
    case invalidApplyReceiptIdentity(String)
    case duplicateFallback
    case invalidFallbackProvenance
    case missingFallbackProvenance
    case missingProvider(String)
    case providerBindingMismatch(String)
    case modelBindingMismatch(String)
    case capabilityBindingMismatch(String)
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        guard let self else { return nil }
        let value = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Return the live provider's secret-free configuration fingerprint when the
/// concrete implementation exposes one. Legacy providers and test doubles
/// may omit the optional identity and retain the older route behaviour.
public func providerRuntimeConfigurationFingerprint(
    _ provider: any LLMProvider
) -> String? {
    guard let identity = provider as? any ProviderRuntimeConfigurationIdentity,
          let material = identity.runtimeConfigurationMaterial else {
        return nil
    }
    return ProviderRuntimeSnapshot.configurationFingerprint(
        providerID: provider.name,
        modelID: provider.model.id,
        capabilities: provider.capabilities,
        configurationMaterial: material
    )
}

/// Bind a snapshot's optional configuration fact to a live provider. A
/// provider without the optional identity remains source-compatible with
/// legacy callers; factory-created production providers expose it and are
/// rejected on any endpoint/configuration drift.
private func validateProviderRuntimeConfiguration(
    _ provider: any LLMProvider,
    expectedFingerprint: String?,
    providerID: String
) throws {
    guard let expectedFingerprint else {
        return
    }
    guard let actualFingerprint = providerRuntimeConfigurationFingerprint(provider) else {
        throw ProviderRuntimeSnapshotError.providerBindingMismatch(providerID)
    }
    guard actualFingerprint == expectedFingerprint else {
        // Keep the existing body-free provider binding error surface. The
        // provider ID is bounded by the existing route identity checks.
        throw ProviderRuntimeSnapshotError.providerBindingMismatch(providerID)
    }
}

public enum ProviderRuntimeRouteStatus: Codable, Equatable, Sendable {
    case served
    case terminalFailure
}

public struct ProviderRuntimeRouteAttempt: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case providerID
        case attempt
        case failureDescription
        case failureKind
        case statusCode
    }

    public let providerID: String
    public let attempt: Int
    public let failureDescription: String
    /// D-PROVIDER-11/12: stable typed failure category projected from the
    /// fallback event (or terminal error) for this attempt. `nil` means the
    /// attempt succeeded or the failure failed closed to unclassified.
    /// Legacy persisted attempts decode to `nil`, never a guessed category.
    public let failureKind: ProviderRequestFailureKind?
    /// HTTP status when the typed failure carried one; wire-valid bounds only.
    public let statusCode: Int?

    public init(
        providerID: String,
        attempt: Int,
        failureDescription: String = "",
        failureKind: ProviderRequestFailureKind? = nil,
        statusCode: Int? = nil
    ) {
        self.providerID = FallbackRouter.FallbackEvent.boundedProviderID(providerID)
        self.attempt = attempt
        self.failureDescription = failureDescription
        self.failureKind = failureKind
        self.statusCode = statusCode.flatMap {
            (100...599).contains($0) ? $0 : nil
        }
    }

    /// Imported route observations use the same bounded identity projection
    /// as live observation construction; Codable storage is not a trust
    /// boundary for external provider IDs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(String.self, forKey: .providerID),
            attempt: try container.decode(Int.self, forKey: .attempt),
            failureDescription: try container.decode(
                String.self,
                forKey: .failureDescription
            ),
            failureKind: try container.decodeIfPresent(
                ProviderRequestFailureKind.self,
                forKey: .failureKind
            ),
            statusCode: try container.decodeIfPresent(Int.self, forKey: .statusCode)
        )
    }

    public var succeeded: Bool {
        failureDescription.isEmpty
    }
}

public struct ProviderRuntimeRouteObservation: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case routeReceiptID
        case servedProviderID
        case servedModelID
        case attempts
        case fallbackEvents
        case status
        case terminalErrorDescription
        case elapsedMilliseconds
    }

    public let routeReceiptID: String
    public let servedProviderID: String?
    public let servedModelID: String?
    public let attempts: [ProviderRuntimeRouteAttempt]
    public let fallbackEvents: [FallbackRouter.FallbackEvent]
    public let status: ProviderRuntimeRouteStatus
    public let terminalErrorDescription: String?
    /// Monotonic time through route acquisition and the existing observation
    /// boundary. Older journals have no value for this optional field.
    public let elapsedMilliseconds: Int?

    public init(
        routeReceiptID: String,
        servedProviderID: String?,
        fallbackEvents: [FallbackRouter.FallbackEvent] = [],
        servedModelID: String? = nil,
        attempts: [ProviderRuntimeRouteAttempt] = [],
        status: ProviderRuntimeRouteStatus = .served,
        terminalErrorDescription: String? = nil,
        elapsedMilliseconds: Int? = nil
    ) {
        self.routeReceiptID = routeReceiptID
        self.servedProviderID = servedProviderID.map {
            FallbackRouter.FallbackEvent.boundedProviderID($0)
        }
        self.servedModelID = servedModelID
        self.attempts = attempts
        self.fallbackEvents = fallbackEvents
        self.status = status
        self.terminalErrorDescription = terminalErrorDescription
        self.elapsedMilliseconds = elapsedMilliseconds.map { max(0, $0) }
    }

    /// Decode through the same consumer projection as live observations so a
    /// persisted route cannot reintroduce an unbounded external identity.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            routeReceiptID: try container.decode(String.self, forKey: .routeReceiptID),
            servedProviderID: try container.decodeIfPresent(
                String.self,
                forKey: .servedProviderID
            ),
            fallbackEvents: try container.decode(
                [FallbackRouter.FallbackEvent].self,
                forKey: .fallbackEvents
            ),
            servedModelID: try container.decodeIfPresent(
                String.self,
                forKey: .servedModelID
            ),
            attempts: try container.decode(
                [ProviderRuntimeRouteAttempt].self,
                forKey: .attempts
            ),
            status: try container.decode(
                ProviderRuntimeRouteStatus.self,
                forKey: .status
            ),
            terminalErrorDescription: try container.decodeIfPresent(
                String.self,
                forKey: .terminalErrorDescription
            ),
            elapsedMilliseconds: try container.decodeIfPresent(
                Int.self,
                forKey: .elapsedMilliseconds
            )
        )
    }

    public var attemptedProviderIDs: [String] {
        attempts.map(\.providerID)
    }

    public var isTerminalFailure: Bool {
        status == .terminalFailure
    }
}

public struct ProviderRuntimeServedReceipt: Codable, Equatable, Hashable, Sendable {
    public let routeReceiptID: String
    public let activeProviderID: String
    public let activeModelID: String
    public let activeReadinessEvidenceID: String
    public let activeDiscoveryReceiptID: String
    public let activeApplyReceiptID: String
    public let servedProviderID: String
    public let servedModelID: String
    public let servedReadinessEvidenceID: String
    public let servedDiscoveryReceiptID: String
    public let servedApplyReceiptID: String

    public var servedAfterFallback: Bool {
        activeProviderID != servedProviderID
    }
}

public struct ProviderRuntimeServedResponse: Sendable {
    public let response: LLMResponse
    public let receipt: ProviderRuntimeServedReceipt
}

public struct ProviderRuntimeServedStream: Sendable {
    public let stream: AsyncThrowingStream<LLMStreamChunk, Error>
    public let receipt: ProviderRuntimeServedReceipt
}

/// Only immutable identity and request values leave the route's provider owner.
private struct ProviderRuntimeRouteBinding: Sendable {
    let expectedProviderID: String
    let expectedModelID: String
    let expectedModelRevision: LLMModel
    let expectedCapabilities: Set<ProviderCapability>?
    let advertisedCapabilities: Set<ProviderCapability>
    let expectedConfigurationFingerprint: String?
}

/// The raw provider instances, including an injected shared override, remain
/// on the composition root's actor. Router factories receive the Sendable
/// proxy below, never an existential reference to one of these instances.
@MainActor
private final class ProviderRuntimeRouteStorage {
    private let providers: [String: any LLMProvider]
    private let observationSink: ProviderRuntimeRoute.ObservationSink?

    init(
        providers: [String: any LLMProvider],
        observationSink: ProviderRuntimeRoute.ObservationSink?
    ) {
        self.providers = providers
        self.observationSink = observationSink
    }

    func emitObservation(_ observation: ProviderRuntimeRouteObservation) async {
        await observationSink?(observation)
    }

    func preflight(_ binding: ProviderRuntimeRouteBinding) throws {
        _ = try validatedProvider(binding)
    }

    private func validatedProvider(
        _ binding: ProviderRuntimeRouteBinding
    ) throws -> any LLMProvider {
        let providerID = binding.expectedProviderID
        guard let provider = providers[providerID] else {
            throw ProviderRuntimeSnapshotError.missingProvider(providerID)
        }
        guard provider.name == providerID,
              provider.model.provider == providerID else {
            throw ProviderRuntimeSnapshotError.providerBindingMismatch(providerID)
        }
        guard provider.model.id == binding.expectedModelID,
              provider.model == binding.expectedModelRevision else {
            throw ProviderRuntimeSnapshotError.modelBindingMismatch(providerID)
        }
        if let expected = binding.expectedCapabilities,
           provider.capabilities != expected {
            throw ProviderRuntimeSnapshotError.capabilityBindingMismatch(providerID)
        }
        try validateProviderRuntimeConfiguration(
            provider,
            expectedFingerprint: binding.expectedConfigurationFingerprint,
            providerID: providerID
        )
        return provider
    }

    func sendMessage(
        _ binding: ProviderRuntimeRouteBinding,
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let provider = try validatedProvider(binding)
        return try await provider.sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func sendMessage(
        _ binding: ProviderRuntimeRouteBinding,
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let provider = try validatedProvider(binding)
        return try await provider.sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        _ binding: ProviderRuntimeRouteBinding,
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let provider = try validatedProvider(binding)
        return try await provider.streamMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamAssistantMessage(
        _ binding: ProviderRuntimeRouteBinding,
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        return try await streamAssistantMessage(binding, messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    func streamAssistantMessage(
        _ binding: ProviderRuntimeRouteBinding,
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let provider = try validatedProvider(binding)
        if let streaming = provider as? any AssistantStreamingLLMProvider {
            return try await streaming.streamAssistantMessage(
                messages: messages, systemPrompt: systemPrompt,
                tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: thinkingLevel
            )
        }
        let response: LLMResponse
        if tools.isEmpty {
            response = try await provider.sendMessage(
                messages: messages, systemPrompt: systemPrompt,
                maxTokens: maxTokens, temperature: temperature
            )
        } else {
            response = try await provider.sendMessage(
                messages: messages, systemPrompt: systemPrompt,
                tools: tools, maxTokens: maxTokens, temperature: temperature
            )
        }
        return llmAssistantCompletedStream(response)
    }
}

private struct ProviderRuntimeRouteProxy: AssistantStreamingLLMProvider, Sendable {
    let storage: ProviderRuntimeRouteStorage
    let binding: ProviderRuntimeRouteBinding

    var name: String { binding.expectedProviderID }
    var model: LLMModel {
        get {
            binding.expectedModelRevision
        }
        set {}
    }
    var capabilities: Set<ProviderCapability> {
        binding.advertisedCapabilities
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await storage.sendMessage(
            binding, messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await storage.sendMessage(
            binding, messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        try await storage.streamMessage(
            binding, messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await storage.streamAssistantMessage(
            binding, messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: thinkingLevel
        )
    }
}

/// LLMProvider adapter that consumes one frozen route and never re-reads Chat
/// settings while a turn is in flight.
public struct ProviderRuntimeRoute: UsageRouteIdentityProviding, AssistantStreamingLLMProvider, Sendable {
    public typealias ObservationSink =
        @Sendable (ProviderRuntimeRouteObservation) async -> Void

    private let storage: ProviderRuntimeRouteStorage
    private let expectedModels: [String: LLMModel]
    private let frozenCapabilities: [String: Set<ProviderCapability>]
    private let primaryCapabilities: Set<ProviderCapability>
    public let snapshot: ProviderRuntimeSnapshot
    private var retryPolicy: LLMRetryPolicy? = nil

    /// Enable leaf retries for an already admitted turn without rebuilding its frozen route.
    public func retryingProviderAttempts(_ policy: LLMRetryPolicy = .mainConversation()) -> Self {
        var route = self
        route.retryPolicy = policy
        return route
    }

    @MainActor
    public init(
        snapshot: ProviderRuntimeSnapshot,
        primary: any LLMProvider,
        fallbacks: [any LLMProvider] = [],
        observationSink: ObservationSink? = nil
    ) throws {
        guard snapshot.hasReadinessEvidence else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        guard snapshot.hasCompleteFallbackProvenance else {
            throw ProviderRuntimeSnapshotError.missingFallbackProvenance
        }
        guard primary.name == snapshot.providerID else {
            throw ProviderRuntimeSnapshotError.providerBindingMismatch(snapshot.providerID)
        }
        guard primary.model.provider == snapshot.providerID else {
            throw ProviderRuntimeSnapshotError.providerBindingMismatch(
                snapshot.providerID
            )
        }
        guard primary.model.id == snapshot.modelID else {
            throw ProviderRuntimeSnapshotError.modelBindingMismatch(snapshot.modelID)
        }
        guard snapshot.capabilities.isEmpty
            || primary.capabilities == snapshot.capabilities else {
            throw ProviderRuntimeSnapshotError.capabilityBindingMismatch(snapshot.providerID)
        }
        try validateProviderRuntimeConfiguration(
            primary,
            expectedFingerprint: snapshot.configurationFingerprint,
            providerID: snapshot.providerID
        )
        var providers: [String: any LLMProvider] = [
            snapshot.providerID: primary,
        ]
        var expectedModels: [String: LLMModel] = [
            snapshot.providerID: primary.model,
        ]
        var frozenCapabilities: [String: Set<ProviderCapability>] = [
            snapshot.providerID: primary.capabilities,
        ]
        guard fallbacks.count == snapshot.fallbackProviderIDs.count else {
            throw ProviderRuntimeSnapshotError.missingProvider(
                snapshot.fallbackProviderIDs.first ?? "<fallback>"
            )
        }
        for (providerID, provider) in zip(snapshot.fallbackProviderIDs, fallbacks) {
            guard providers[providerID] == nil else {
                throw ProviderRuntimeSnapshotError.duplicateFallback
            }
            guard provider.name == providerID else {
                throw ProviderRuntimeSnapshotError.providerBindingMismatch(providerID)
            }
            guard provider.model.provider == providerID else {
                throw ProviderRuntimeSnapshotError.providerBindingMismatch(
                    providerID
                )
            }
            guard let provenance = snapshot.fallbackProvenance.first(where: {
                $0.providerID == providerID
            }), provider.model.id == provenance.modelID else {
                throw ProviderRuntimeSnapshotError.modelBindingMismatch(providerID)
            }
            guard provenance.capabilities.isEmpty
                || provider.capabilities == provenance.capabilities else {
                throw ProviderRuntimeSnapshotError.capabilityBindingMismatch(providerID)
            }
            try validateProviderRuntimeConfiguration(
                provider,
                expectedFingerprint: provenance.configurationFingerprint,
                providerID: providerID
            )
            providers[providerID] = provider
            expectedModels[providerID] = provider.model
            frozenCapabilities[providerID] = provider.capabilities
        }
        self.storage = ProviderRuntimeRouteStorage(
            providers: providers,
            observationSink: observationSink
        )
        self.expectedModels = expectedModels
        self.frozenCapabilities = frozenCapabilities
        self.primaryCapabilities = primary.capabilities
        self.snapshot = snapshot
    }

    /// Compatibility initializer for the legacy session runtime. Production
    /// App wiring uses the async sink above so route completion includes
    /// consumer delivery.
    @MainActor
    public init(
        snapshot: ProviderRuntimeSnapshot,
        primary: any LLMProvider,
        fallbacks: [any LLMProvider] = [],
        observationSink: (@Sendable (ProviderRuntimeRouteObservation) -> Void)?
    ) throws {
        let asyncSink: ObservationSink? = observationSink.map { sink in
            { @Sendable observation in
                sink(observation)
            }
        }
        try self.init(
            snapshot: snapshot,
            primary: primary,
            fallbacks: fallbacks,
            observationSink: asyncSink
        )
    }

    public var usageRouteIdentity: UsageServedRoute? {
        guard snapshot.fallbackProviderIDs.isEmpty else { return nil }
        return UsageServedRoute(provider: snapshot.providerID, model: snapshot.modelID)
    }

    public var name: String { snapshot.providerID }
    public var model: LLMModel {
        get {
            // Both initializers freeze this primary entry after validating its identity.
            expectedModels[snapshot.providerID]!
        }
        set {}
    }
    public var capabilities: Set<ProviderCapability> {
        snapshot.capabilities.isEmpty
            ? primaryCapabilities
            : snapshot.capabilities
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessageWithReceipt(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        ).response
    }

    public func sendMessageWithReceipt(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> ProviderRuntimeServedResponse {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        var router = makeRouter()
        do {
            let result = try await router.sendMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                temperature: temperature,
                factory: resolve
            )
            await emitObservation(
                router: router,
                servedProviderID: result.providerID,
                startedAtNanoseconds: startedAtNanoseconds
            )
            return ProviderRuntimeServedResponse(
                response: result.response,
                receipt: try servedReceipt(providerID: result.providerID)
            )
        } catch {
            await emitObservation(
                router: router,
                servedProviderID: nil,
                terminalError: error,
                startedAtNanoseconds: startedAtNanoseconds
            )
            throw terminalRequestError(error, router: router)
        }
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        if tools.isEmpty {
            return try await sendMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }
        return try await sendMessageWithReceipt(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        ).response
    }

    public func sendMessageWithReceipt(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> ProviderRuntimeServedResponse {
        if tools.isEmpty {
            return try await sendMessageWithReceipt(
                messages: messages,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        var router = makeRouter()
        do {
            let result = try await router.sendMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                factory: resolve
            )
            await emitObservation(
                router: router,
                servedProviderID: result.providerID,
                startedAtNanoseconds: startedAtNanoseconds
            )
            return ProviderRuntimeServedResponse(
                response: result.response,
                receipt: try servedReceipt(providerID: result.providerID)
            )
        } catch {
            await emitObservation(
                router: router,
                servedProviderID: nil,
                terminalError: error,
                startedAtNanoseconds: startedAtNanoseconds
            )
            throw terminalRequestError(error, router: router)
        }
    }

    public func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        try await streamMessageWithReceipt(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        ).stream
    }

    public func streamMessageWithReceipt(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> ProviderRuntimeServedStream {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        var router = makeRouter()
        do {
            let result = try await router.streamMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                temperature: temperature,
                factory: resolve
            )
            await emitObservation(
                router: router,
                servedProviderID: result.providerID,
                startedAtNanoseconds: startedAtNanoseconds
            )
            return ProviderRuntimeServedStream(
                stream: result.stream,
                receipt: try servedReceipt(providerID: result.providerID)
            )
        } catch {
            await emitObservation(
                router: router,
                servedProviderID: nil,
                terminalError: error,
                startedAtNanoseconds: startedAtNanoseconds
            )
            throw terminalRequestError(error, router: router)
        }
    }

    /// D-CHAT-03 assistant 增量流接缝（生产转发版）。
    ///
    /// 三个 wire provider（Anthropic / OpenAI-compatible / OpenAI Responses）
    /// 已符合 `AssistantStreamingLLMProvider`，因此经由 `FallbackRouter` 的
    /// tools-aware assistant 流式获取接缝转发它们的真实 `textDelta` 增量流；
    /// 有序 fallback 链、observation、终态错误语义与缓冲路径一致。不符形的
    /// provider 在同一路由器入口内保持缓冲 `sendMessage` 合成单 `.completed`
    /// 的旧路径（含空 tools 走无 tools 重载的既有委托），重试/POST 回放栅栏/
    /// 预算语义逐字节不变（零行为变化）。
    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        var router = makeRouter()
        do {
            let result = try await router.streamAssistantMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature, thinkingLevel: thinkingLevel,
                factory: resolve
            )
            await emitObservation(
                router: router,
                servedProviderID: result.providerID,
                startedAtNanoseconds: startedAtNanoseconds
            )
            return result.stream
        } catch {
            await emitObservation(
                router: router,
                servedProviderID: nil,
                terminalError: error,
                startedAtNanoseconds: startedAtNanoseconds
            )
            throw terminalRequestError(error, router: router)
        }
    }

    private var routeIDs: [String] {
        [snapshot.providerID] + snapshot.fallbackProviderIDs
    }

    private func terminalRequestError(_ error: any Error, router: FallbackRouter) -> any Error {
        guard !Task.isCancelled, let exhaustion = router.lastRetryExhaustion else { return error }
        if let llmError = error as? LLMError,
           case .httpStatus(let code, _) = llmError, code == exhaustion.statusCode {
            return exhaustion.preservingFact(with: error)
        }
        if let fallback = error as? FallbackRouterError,
           case .allProvidersFailed(let events) = fallback,
           !events.isEmpty, events.allSatisfy({ $0.statusCode == 429 || $0.statusCode == 529 }) {
            return exhaustion.preservingFact(with: error)
        }
        return error
    }

    private func makeRouter() -> FallbackRouter {
        var router = FallbackRouter(
            providerIDs: routeIDs,
            shouldFallback: { error in
                if error is ProviderRuntimeSnapshotError
                    || error is CancellationError
                    || error is InterruptedError {
                    return false
                }
                if let llmError = error as? LLMError {
                    return llmError.isFallbackable
                }
                return false
            },
            retryPolicy: retryPolicy
        )
        router.tracksRetryExhaustion = retryPolicy != nil
        return router
    }

    private func servedReceipt(
        providerID: String
    ) throws -> ProviderRuntimeServedReceipt {
        guard let activeEvidenceID = snapshot.readinessEvidenceID,
              let activeApplyReceiptID = snapshot.applyReceiptID,
              let activeDiscoveryReceiptID = ProviderRuntimeSnapshot
                .discoveryReceiptID(from: activeApplyReceiptID) else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }

        let servedModelID: String
        let servedEvidenceID: String
        let servedApplyReceiptID: String
        if providerID == snapshot.providerID {
            servedModelID = snapshot.modelID
            servedEvidenceID = activeEvidenceID
            servedApplyReceiptID = activeApplyReceiptID
        } else {
            guard let fallback = snapshot.fallbackProvenance.first(where: {
                $0.providerID == providerID
            }) else {
                throw ProviderRuntimeSnapshotError.missingProvider(providerID)
            }
            servedModelID = fallback.modelID
            servedEvidenceID = fallback.readinessEvidenceID
            servedApplyReceiptID = fallback.applyReceiptID
        }
        guard let servedDiscoveryReceiptID = ProviderRuntimeSnapshot
            .discoveryReceiptID(from: servedApplyReceiptID) else {
            throw ProviderRuntimeSnapshotError.invalidApplyReceiptIdentity(
                providerID
            )
        }
        return ProviderRuntimeServedReceipt(
            routeReceiptID: snapshot.routeReceiptID,
            activeProviderID: snapshot.providerID,
            activeModelID: snapshot.modelID,
            activeReadinessEvidenceID: activeEvidenceID,
            activeDiscoveryReceiptID: activeDiscoveryReceiptID,
            activeApplyReceiptID: activeApplyReceiptID,
            servedProviderID: providerID,
            servedModelID: servedModelID,
            servedReadinessEvidenceID: servedEvidenceID,
            servedDiscoveryReceiptID: servedDiscoveryReceiptID,
            servedApplyReceiptID: servedApplyReceiptID
        )
    }

    private func emitObservation(
        router: FallbackRouter,
        servedProviderID: String?,
        terminalError: Error? = nil,
        startedAtNanoseconds: UInt64
    ) async {
        let elapsedMilliseconds = ProviderRuntimeRoutePerformance.elapsedMilliseconds(
            startNanoseconds: startedAtNanoseconds,
            endNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        let attempts = routeAttempts(
            router: router,
            servedProviderID: servedProviderID,
            terminalError: terminalError
        )
        if terminalError == nil, let servedProviderID, let model = modelID(for: servedProviderID) {
            await UsageTelemetryContext.servedRouteCapture?.record(UsageServedRoute(provider: servedProviderID, model: model))
        }
        await storage.emitObservation(ProviderRuntimeRouteObservation(
            routeReceiptID: snapshot.routeReceiptID,
            servedProviderID: servedProviderID,
            fallbackEvents: router.events,
            servedModelID: servedProviderID.flatMap(modelID(for:)),
            attempts: attempts,
            status: terminalError == nil ? .served : .terminalFailure,
            terminalErrorDescription: terminalError.map {
                Self.safeTerminalErrorDescription(for: $0)
            },
            elapsedMilliseconds: elapsedMilliseconds
        ))
    }

    /// Return the only error surface allowed in a runtime observation.
    ///
    /// Provider response bodies, provider IDs, paths, and arbitrary error
    /// descriptions are never copied into a durable observation. Known LLM
    /// errors already expose a body-free description; a complete fallback
    /// trail and every unknown error use the generic provider projection.
    static func safeTerminalErrorDescription(for error: Error) -> String {
        if error is CancellationError {
            return LLMError.cancelled.errorDescription ?? "Request was cancelled"
        }
        if let fallbackError = error as? FallbackRouterError {
            switch fallbackError {
            case .allProvidersFailed:
                return "Provider error"
            case .emptyChain:
                return "Provider error"
            }
        }
        if let llmError = error as? LLMError {
            return llmError.errorDescription ?? "Provider error"
        }
        return "Provider error"
    }

    private func routeAttempts(
        router: FallbackRouter,
        servedProviderID: String?,
        terminalError: Error?
    ) -> [ProviderRuntimeRouteAttempt] {
        var attempts = router.events.map {
            ProviderRuntimeRouteAttempt(
                providerID: $0.providerID,
                attempt: $0.attempt,
                failureDescription: $0.errorDescription,
                failureKind: $0.failureKind,
                statusCode: $0.statusCode
            )
        }
        if let servedProviderID,
           attempts.last?.providerID != servedProviderID {
            attempts.append(
                ProviderRuntimeRouteAttempt(
                    providerID: servedProviderID,
                    attempt: attempts.count + 1
                )
            )
        } else if let terminalError {
            let attemptedIDs = Set(attempts.map(\.providerID))
            if let terminalProviderID = routeIDs.first(where: {
                !attemptedIDs.contains($0)
            }) {
                attempts.append(
                    ProviderRuntimeRouteAttempt(
                        providerID: terminalProviderID,
                        attempt: attempts.count + 1,
                        failureDescription: Self.safeTerminalErrorDescription(
                            for: terminalError
                        ),
                        failureKind: ProviderRequestFailureKind.classify(
                            terminalError
                        ),
                        statusCode: ProviderRequestFailureKind.httpStatusCode(
                            from: terminalError
                        )
                    )
                )
            }
        }
        return attempts
    }

    private func modelID(for providerID: String) -> String? {
        if providerID == snapshot.providerID {
            return snapshot.modelID
        }
        return snapshot.fallbackProvenance.first {
            $0.providerID == providerID
        }?.modelID
    }

    private func resolve(_ providerID: String) async throws -> any LLMProvider {
        let expectedModelID = try expectedModelID(for: providerID)
        guard let expectedModel = expectedModels[providerID] else {
            throw ProviderRuntimeSnapshotError.modelBindingMismatch(providerID)
        }
        let expectedConfigurationFingerprint: String?
        if providerID == snapshot.providerID {
            expectedConfigurationFingerprint = snapshot.configurationFingerprint
        } else {
            expectedConfigurationFingerprint = snapshot.fallbackProvenance.first {
                $0.providerID == providerID
            }?.configurationFingerprint
        }
        // An omitted capability claim still freezes the actual turn binding;
        // a mutable provider must not change its execution surface mid-route.
        let expectedCapabilities = frozenCapabilities[providerID]
        let binding = ProviderRuntimeRouteBinding(
            expectedProviderID: providerID,
            expectedModelID: expectedModelID,
            expectedModelRevision: expectedModel,
            expectedCapabilities: expectedCapabilities,
            advertisedCapabilities: expectedCapabilities ?? [],
            expectedConfigurationFingerprint: expectedConfigurationFingerprint
        )
        try await storage.preflight(binding)
        return ProviderRuntimeRouteProxy(storage: storage, binding: binding)
    }

    private func expectedModelID(for providerID: String) throws -> String {
        if providerID == snapshot.providerID {
            return snapshot.modelID
        }
        guard let fallback = snapshot.fallbackProvenance.first(where: {
            $0.providerID == providerID
        }) else {
            throw ProviderRuntimeSnapshotError.missingProvider(providerID)
        }
        return fallback.modelID
    }
}
