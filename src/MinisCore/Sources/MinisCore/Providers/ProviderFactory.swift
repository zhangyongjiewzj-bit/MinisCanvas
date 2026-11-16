import Foundation

private final class FactoryRuntimeIdentityProvider: UsageRouteIdentityProviding, LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    private var base: any LLMProvider
    private let runtimeProviderID: String
    var runtimeConfigurationMaterial: String?

    init(
        base: any LLMProvider,
        runtimeProviderID: String,
        runtimeConfigurationMaterial: String? = nil
    ) {
        self.base = base
        self.runtimeProviderID = runtimeProviderID
        self.runtimeConfigurationMaterial = runtimeConfigurationMaterial
    }

    var usageRouteIdentity: UsageServedRoute? {
        guard let inner = UsageTelemetryContext.directRoute(of: base) else { return nil }
        return UsageServedRoute(provider: runtimeProviderID, model: inner.model)
    }

    var name: String { runtimeProviderID }

    var model: LLMModel {
        get {
            let value = base.model
            return LLMModel(
                id: value.id,
                displayName: value.displayName,
                provider: runtimeProviderID,
                modalityOverride: value.modalityOverride,
                contextWindow: value.contextWindow,
                maxOutputTokens: value.maxOutputTokens,
                supportsReasoning: value.supportsReasoning,
                interleavedReasoningField: value.interleavedReasoningField
            )
        }
        set {
            base.model = LLMModel(
                id: newValue.id,
                displayName: newValue.displayName,
                provider: runtimeProviderID,
                modalityOverride: newValue.modalityOverride,
                contextWindow: newValue.contextWindow,
                maxOutputTokens: newValue.maxOutputTokens,
                supportsReasoning: newValue.supportsReasoning,
                interleavedReasoningField: newValue.interleavedReasoningField
            )
        }
    }

    var capabilities: Set<ProviderCapability> {
        base.capabilities
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await base.sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await base.sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        try await base.streamMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }
}

// Factory identity wrapping must not erase an explicit parent/child level.
// nil deliberately retains this wrapper's original buffered behavior.
extension FactoryRuntimeIdentityProvider: AssistantStreamingLLMProvider {
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let response = try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature)
        return llmAssistantCompletedStream(response)
    }

    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
        tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        if thinkingLevel != nil, let streaming = base as? any AssistantStreamingLLMProvider {
            return try await streaming.streamAssistantMessage(messages: messages, systemPrompt: systemPrompt,
                tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: thinkingLevel)
        }
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature)
    }
}

/// Shared factory for creating LLMProvider instances from a ProviderConfig.
///
/// Ported from OpenMinis `Providers/LLMProviderFactory.swift` and turned into
/// a registration-based registry: instead of a hardcoded switch over
/// keychain-backed instances, providers register a builder closure per
/// ProviderType. Built-in OpenAI/Anthropic/OpenRouter/Responses/Local builders
/// are pre-registered; callers can override or add their own.
public final class ProviderFactory: @unchecked Sendable {
    public static let shared = ProviderFactory()

    /// A provider can be configured correctly while its credential is
    /// temporarily unavailable (for example while another provider remains
    /// usable).  Callers that enumerate providers should be able to preserve
    /// that typed state without turning one missing key into a fatal factory
    /// failure.
    public enum UnavailableReason: Error, Equatable, Sendable, LocalizedError {
        case missingCredential(String)

        public var errorDescription: String? {
            switch self {
            case .missingCredential(let label):
                return "Provider \"\(label)\" is unavailable because no credential is configured"
            }
        }
    }

    /// Non-fatal result for callers that want to construct all configured
    /// providers independently.  Unknown provider types and builder errors
    /// still throw from `makeProviderResult`; only a missing credential is a
    /// typed, non-fatal unavailable result.
    public enum MakeResult {
        case ready(any LLMProvider)
        case unavailable(UnavailableReason)
    }

    public enum FactoryError: Error, Equatable, LocalizedError {
        case noBuilder(ProviderType)
        case noCredentials(String)
        case providerDisabled(String)
        case invalidBaseURL(String)
        case auditReceiptDenied
        case auditReceiptReplayed
        case auditReceiptConflict
        case auditLedgerSaturated
        case auditPolicyRevisionMismatch
        case auditConfigurationMismatch
        case auditBindingMismatch

        public var errorDescription: String? {
            switch self {
            case .noBuilder(let type):
                return "No provider builder registered for type \(type.rawValue)"
            case .noCredentials(let label):
                return "No API key configured for provider \"\(label)\" (set its apiKeyEnvVar or apiKey)"
            case .providerDisabled(let label):
                return "Provider \"\(label)\" is disabled"
            case .invalidBaseURL(let label):
                return "Provider \"\(label)\" has an invalid base URL"
            case .auditReceiptDenied:
                return "Provider route audit receipt was denied"
            case .auditReceiptReplayed:
                return "Provider route audit receipt was already consumed"
            case .auditReceiptConflict:
                return "Provider route audit receipt identity conflicts with its consumed binding"
            case .auditLedgerSaturated:
                return "Provider route audit ledger is saturated; provider creation is denied"
            case .auditPolicyRevisionMismatch:
                return "Provider route audit policy revision does not match current settings"
            case .auditConfigurationMismatch:
                return "Provider route audit configuration fingerprint does not match current settings"
            case .auditBindingMismatch:
                return "Provider route audit binding does not match the created provider"
            }
        }
    }

    /// Builder signature: given a config, produce a provider instance.
    public typealias Builder = @Sendable (ProviderConfig) throws -> any LLMProvider

    private let lock = NSLock()
    private var builders: [ProviderType: Builder] = [:]

    public init() {
        registerBuiltIns()
    }

    // MARK: - Registration

    /// Register (or replace) the builder for a provider type.
    public func register(_ type: ProviderType, builder: @escaping Builder) {
        lock.lock()
        builders[type] = builder
        lock.unlock()
    }

    /// Remove the builder for a provider type.
    public func unregister(_ type: ProviderType) {
        lock.lock()
        builders.removeValue(forKey: type)
        lock.unlock()
    }

    /// The set of provider types that currently have a registered builder.
    public var registeredTypes: [ProviderType] {
        lock.lock()
        defer { lock.unlock() }
        return builders.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func hasBuilder(for type: ProviderType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return builders[type] != nil
    }

    // MARK: - Factory

    /// Resolve one provider without making a missing credential fatal.
    ///
    /// This is intentionally additive: the legacy `makeProvider` API keeps
    /// its throwing contract for existing callers, while enumeration-oriented
    /// callers can distinguish `.unavailable` from an unknown provider or a
    /// real builder failure.
    public func makeProviderResult(
        for config: ProviderConfig,
        requireCredentials: Bool = true
    ) throws -> MakeResult {
        guard config.isEnabled else {
            throw FactoryError.providerDisabled(config.label)
        }
        if config.controlledFieldLoopbackOnly {
            guard config.providerType == .openAI,
                  let base = config.effectiveCustomBaseURL,
                  let url = URL(string: base),
                  ControlledFieldLoopbackPolicy.accepts(url) else {
                throw FactoryError.invalidBaseURL(config.label)
            }
        }
        lock.lock()
        let builder = builders[config.providerType]
        lock.unlock()
        guard let builder else {
            // Unsupported/unknown provider types remain fail-closed and are
            // never represented as an unavailable credential.
            throw FactoryError.noBuilder(config.providerType)
        }
        if requireCredentials, config.effectiveAPIKey() == nil {
            return .unavailable(.missingCredential(config.label))
        }
        let provider = try builder(config)
        if let identity = provider as? any ProviderRuntimeConfigurationIdentity {
            identity.runtimeConfigurationMaterial = config.runtimeConfigurationMaterial
        }
        return .ready(provider)
    }

    /// Create an LLMProvider for the given config.
    /// Requires the config to be enabled and to resolve an API key
    /// (direct `apiKey` or via `apiKeyEnvVar`) unless the builder is
    /// credential-free (e.g. local Ollama without auth).
    public func makeProvider(for config: ProviderConfig, requireCredentials: Bool = true) throws -> any LLMProvider {
        switch try makeProviderResult(for: config, requireCredentials: requireCredentials) {
        case .ready(let provider):
            return provider
        case .unavailable(.missingCredential(let label)):
            // Preserve the historical throwing surface for callers that
            // explicitly request a concrete provider instance.
            throw FactoryError.noCredentials(label)
        }
    }

    /// Create a provider only from an admitted, typed route audit receipt that
    /// matches the current policy and settings fingerprints. The receipt is
    /// consumed before provider construction so retries cannot revive a stale
    /// route after a credential or builder failure.
    public func makeProvider(
        for config: ProviderConfig,
        auditReceipt: ProviderRoutePolicyAuditReceipt,
        expectedPolicyRevision: String,
        expectedConfigurationFingerprint: String,
        requireCredentials: Bool = true
    ) throws -> any LLMProvider {
        guard auditReceipt.decision == .admitted,
              !auditReceipt.receiptID.isEmpty,
              let route = auditReceipt.route,
              let bindingFingerprint = auditReceipt.bindingFingerprint,
              let policyRevision = auditReceipt.policyRevision else {
            throw FactoryError.auditReceiptDenied
        }
        guard Self.exactIdentifierMatch(policyRevision, expectedPolicyRevision) else {
            throw FactoryError.auditPolicyRevisionMismatch
        }
        guard let configurationFingerprint = route.configurationFingerprint,
              Self.exactIdentifierMatch(configurationFingerprint, expectedConfigurationFingerprint) else {
            throw FactoryError.auditConfigurationMismatch
        }
        switch ProviderFactoryAuditLedger.shared.consume(
            receiptID: auditReceipt.receiptID,
            bindingFingerprint: bindingFingerprint
        ) {
        case .consumed:
            break
        case .replayed:
            throw FactoryError.auditReceiptReplayed
        case .conflict:
            throw FactoryError.auditReceiptConflict
        case .saturated:
            throw FactoryError.auditLedgerSaturated
        }

        let provider = try makeProvider(for: config, requireCredentials: requireCredentials)
        guard Self.exactIdentifierMatch(provider.name, route.providerID),
              Self.exactIdentifierMatch(provider.model.id, route.modelID) else {
            throw FactoryError.auditBindingMismatch
        }
        return provider
    }

    private static func exactIdentifierMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// No provider construction or credentials. Uses the exact capabilities of
    /// the built-in wire implementation; the live provider must still match.
    /// A custom builder with different configuration/capabilities is rejected
    /// by the dispatch fingerprint check rather than gaining a new identity.
    public func configurationFingerprintMetadata(for config: ProviderConfig, modelID: String) -> String? {
        guard registeredTypes.contains(config.providerType) else { return nil }
        let capabilities: Set<ProviderCapability>
        switch config.providerType {
        case .anthropic: capabilities = AnthropicProvider.wireCapabilities
        case .openAIResponses: capabilities = OpenAIResponsesProvider.wireCapabilities
        case .openAI, .openRouter, .deepSeek, .dashScope, .local:
            capabilities = OpenAICompatibleProvider.wireCapabilities
        default: return nil
        }
        return ProviderRuntimeSnapshot.configurationFingerprint(
            providerID: config.runtimeProviderID ?? config.providerType.runtimeProviderID,
            modelID: modelID, capabilities: capabilities,
            configurationMaterial: config.runtimeConfigurationMaterial)
    }

    // MARK: - Built-ins

    private func registerBuiltIns() {
        // OpenAI — official or any OpenAI-compatible /v1/chat/completions endpoint.
        register(.openAI) { config in
            let runtimeID = config.runtimeProviderID ?? config.providerType.runtimeProviderID
            let provider = OpenAICompatibleProvider(
                apiKey: config.effectiveAPIKey() ?? "",
                model: .gpt4oMini,
                customBaseURL: config.effectiveCustomBaseURL,
                appendV1Suffix: config.appendV1Suffix,
                session: config.controlledFieldLoopbackOnly
                    ? ControlledFieldLoopbackSession.make() : nil,
                controlledFieldLoopbackOnly: config.controlledFieldLoopbackOnly,
                providerName: runtimeID
            )
            provider.model = LLMModel(
                id: provider.model.id,
                displayName: provider.model.displayName,
                provider: runtimeID
            )
            return provider
        }
        // Anthropic — Messages API (custom base = Anthropic-compat proxy).
        register(.anthropic) { config in
            let runtimeID = config.runtimeProviderID ?? config.providerType.runtimeProviderID
            return FactoryRuntimeIdentityProvider(
                base: AnthropicProvider(
                    apiKey: config.effectiveAPIKey() ?? "",
                    model: .claudeSonnet46,
                    basePath: config.effectiveCustomBaseURL
                ),
                runtimeProviderID: runtimeID
            )
        }
        // OpenRouter — OpenAI-compatible with attribution headers.
        register(.openRouter) { config in
            let runtimeID = config.runtimeProviderID ?? config.providerType.runtimeProviderID
            let provider = OpenAICompatibleProvider(
                apiKey: config.effectiveAPIKey() ?? "",
                model: .orClaudeSonnet4,
                customBaseURL: config.effectiveCustomBaseURL ?? "https://openrouter.ai/api",
                appendV1Suffix: config.effectiveCustomBaseURL == nil,
                providerName: runtimeID
            )
            provider.extraHeaders = [
                "X-Title": "MinisCanvas",
            ]
            provider.useOpenRouterCompat = true
            provider.model = LLMModel(
                id: provider.model.id,
                displayName: provider.model.displayName,
                provider: runtimeID
            )
            return provider
        }
        // OpenAI Responses API — 真 Responses 协议（POST /v1/responses，
        // input/instructions/SSE response.* 事件），供 wire_api=responses 中转站使用。
        register(.openAIResponses) { config in
            let runtimeID = config.runtimeProviderID ?? config.providerType.runtimeProviderID
            let provider = OpenAIResponsesProvider(
                apiKey: config.effectiveAPIKey() ?? "",
                model: .gpt4oMini,
                customBaseURL: config.effectiveCustomBaseURL,
                appendV1Suffix: config.appendV1Suffix,
                session: nil,
                providerName: runtimeID,
                attemptCheckpointDirectory: config.attemptCheckpointDirectory
            )
            provider.model = LLMModel(
                id: provider.model.id,
                displayName: provider.model.displayName,
                provider: runtimeID
            )
            return provider
        }
        // Local — Ollama / local ComfyUI OpenAI-compatible endpoints.
        register(.local) { config in
            let base = config.effectiveCustomBaseURL ?? "http://127.0.0.1:11434"
            guard let baseURL = URL(string: base) else {
                throw FactoryError.invalidBaseURL(config.label)
            }
            let provider = OpenAICompatibleProvider(
                apiKey: config.effectiveAPIKey() ?? "",
                model: LLMModel(id: "qwen2.5", displayName: "Qwen 2.5 (Local)", provider: "Local"),
                customBaseURL: base,
                appendV1Suffix: config.appendV1Suffix
            )
            return LocalOpenAIProvider(wrapping: provider, baseURL: baseURL)
        }
        // DashScope（阿里云百炼）— OpenAI 兼容模式；key 按 BAILIAN_TOKEN_PLAN_API_KEY
        // → HERMES_CUSTOM_QWEN38_API_KEY → DASHSCOPE_API_KEY 顺序解析。
        register(.dashScope) { config in
            DashScopeProvider(
                apiKey: config.effectiveAPIKey(),
                model: .qwen38MaxPreview,
                customBaseURL: config.effectiveCustomBaseURL
            )
        }
        // DeepSeek 官方 API — OpenAI 兼容模式；key 按
        // HERMES_CUSTOM_DEEPSEEK_API_KEY → DEEPSEEK_API_KEY 顺序解析。
        register(.deepSeek) { config in
            DeepSeekProvider(
                apiKey: config.effectiveAPIKey(),
                model: .deepSeekV4Flash,
                customBaseURL: config.effectiveCustomBaseURL
            )
        }
        // Gimage2 — OpenAI Images API 风格云端生图。
        register(.gimage2) { config in
            Gimage2Provider(apiKey: config.effectiveAPIKey())
        }
        // 可灵 Kling — 生视频（骨架，真实 API 待接入）。
        register(.kling) { config in
            KlingProvider(apiKey: config.effectiveAPIKey())
        }
        // 即梦 Jimeng — 生视频（骨架，真实 API 待接入）。
        register(.jimeng) { config in
            JimengProvider(apiKey: config.effectiveAPIKey())
        }
    }
}

/// Process-local one-shot fence for the factory consumer. Audit receipts are
/// evidence, not durable authorization; a given receipt identity may create a
/// provider once in this runtime, and the bounded ledger saturates fail-closed
/// instead of evicting old identities and reviving stale routes.
private final class ProviderFactoryAuditLedger: @unchecked Sendable {
    enum ConsumeResult {
        case consumed
        case replayed
        case conflict
        case saturated
    }

    static let shared = ProviderFactoryAuditLedger()
    private static let capacity = 4_096

    private let lock = NSLock()
    private var consumedFingerprints: [String: String] = [:]

    func consume(receiptID: String, bindingFingerprint: String) -> ConsumeResult {
        lock.lock()
        defer { lock.unlock() }
        if let consumed = consumedFingerprints[receiptID] {
            return consumed == bindingFingerprint ? .replayed : .conflict
        }
        guard consumedFingerprints.count < Self.capacity else { return .saturated }
        consumedFingerprints[receiptID] = bindingFingerprint
        return .consumed
    }
}
