import Foundation

/// Extension point for LOCAL backends (Ollama, local ComfyUI's OpenAI-compatible
/// endpoint, llama.cpp, LM Studio, …).
///
/// Design intent (per MinisCanvas 硬性技术决策 #4: "复用 OpenMinis Provider
/// 抽象，新增 LocalProvider 类，不动 Agent 引擎"): the agent loop and UI only
/// ever talk to `LLMProvider` / `AgentProvider`. A `LocalProvider` is an
/// `LLMProvider` that additionally exposes its local endpoint, so the UI can
/// surface health checks / model listing and the canvas layer can reuse the
/// same local endpoint for image generation (ComfyUI).
public protocol LocalProvider: LLMProvider {
    /// The local endpoint base URL (e.g. http://127.0.0.1:11434 for Ollama).
    var baseURL: URL { get }
    /// Whether this backend supports SSE streaming.
    var supportsStreaming: Bool { get }
    /// Whether this backend typically requires an API key (Ollama does not by default).
    var requiresAPIKey: Bool { get }
}

/// Local OpenAI-compatible backend (Ollama / ComfyUI / llama.cpp / LM Studio).
///
/// Thin wrapper over `OpenAICompatibleProvider`: all request logic is shared
/// with cloud OpenAI-compatible providers; this type only adds the
/// `LocalProvider` surface.
public final class LocalOpenAIProvider: LocalProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    public let baseURL: URL
    public let supportsStreaming = true
    public let requiresAPIKey: Bool

    private let inner: OpenAICompatibleProvider
    private var runtimeConfigurationMaterialOverride: String? = nil

    public var runtimeConfigurationMaterial: String? {
        get { runtimeConfigurationMaterialOverride }
        set { runtimeConfigurationMaterialOverride = newValue }
    }

    public init(wrapping inner: OpenAICompatibleProvider, baseURL: URL, requiresAPIKey: Bool = false) {
        self.inner = inner
        self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey
    }

    public convenience init(apiKey: String = "", model: LLMModel, baseURL: URL, appendV1Suffix: Bool = true) {
        let inner = OpenAICompatibleProvider(
            apiKey: apiKey,
            model: model,
            customBaseURL: baseURL.absoluteString,
            appendV1Suffix: appendV1Suffix
        )
        self.init(wrapping: inner, baseURL: baseURL)
    }

    // MARK: - LLMProvider (forwarded)

    public var name: String { "Local" }
    public var model: LLMModel {
        get { inner.model }
        set { inner.model = newValue }
    }
    public var capabilities: Set<ProviderCapability> { inner.capabilities }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await inner.sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await inner.sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    public func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        try await inner.streamMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }
}
