import Foundation

/// DeepSeek 官方 API — OpenAI 兼容（/chat/completions）LLM Provider。
///
/// 复用 `OpenAICompatibleProvider` 的全部请求/流式解析逻辑（DeepSeek 的 wire
/// 格式与 OpenAI Chat Completions 一致，SSE 流式字段亦相同），本类型只负责：
///   - 默认端点：`https://api.deepseek.com`
///   - API key 解析链：注入 key → `HERMES_CUSTOM_DEEPSEEK_API_KEY` →
///     `DEEPSEEK_API_KEY`（均为环境变量）
///   - 默认模型 `deepseek-v4-flash`
///
/// 支持 `sendMessage`、`streamMessage` 与含工具的 `streamAssistantMessage`。
public final class DeepSeekProvider: AssistantStreamingLLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    /// DeepSeek 官方 OpenAI 兼容裸端点；请求路径由 provider 追加。
    public static let defaultBaseURL = DeepSeekProviderContract.baseURL
    /// API key 环境变量解析顺序。
    public static let apiKeyEnvVars = DeepSeekProviderContract.apiKeyEnvironmentAliases

    public var name: String { "DeepSeek" }

    public var model: LLMModel {
        get { inner.model }
        set { inner.model = newValue }
    }

    public var capabilities: Set<ProviderCapability> { inner.capabilities }

    /// 当前解析到的 API key（nil 表示未配置）。
    public let resolvedAPIKey: String?

    private let inner: OpenAICompatibleProvider
    private var runtimeConfigurationMaterialOverride: String? = nil

    public var runtimeConfigurationMaterial: String? {
        get { runtimeConfigurationMaterialOverride }
        set { runtimeConfigurationMaterialOverride = newValue }
    }

    /// - Parameters:
    ///   - apiKey: 注入 key；为空时按 `apiKeyEnvVars` 顺序从环境变量解析。
    ///   - model: 默认 `deepseek-v4-flash`。
    ///   - customBaseURL: 自定义端点；nil 时使用 `defaultBaseURL`。
    public init(apiKey: String? = nil, model: LLMModel = .deepSeekV4Flash, customBaseURL: String? = nil) {
        let resolved = Self.resolveAPIKey(injected: apiKey)
        self.resolvedAPIKey = resolved
        self.inner = OpenAICompatibleProvider(
            apiKey: resolved ?? "",
            model: model,
            customBaseURL: Self.normalizedOpenAICompatibleBaseURL(customBaseURL ?? Self.defaultBaseURL),
            appendV1Suffix: false
        )
    }

    /// Normalize user-entered OpenAI-compatible bases before handing them to
    /// the shared provider. DeepSeek routes are rooted at the bare host, so a
    /// legacy `/v1` suffix is removed (including incidental trailing slashes).
    static func normalizedOpenAICompatibleBaseURL(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if base.lowercased().hasSuffix("/v1") {
            base.removeLast(3)
        }
        return base.isEmpty ? Self.defaultBaseURL : base
    }

    /// 解析 API key：注入值优先，其次按序查环境变量。
    public static func resolveAPIKey(injected: String?) -> String? {
        if let key = injected?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        for envVar in apiKeyEnvVars {
            if let key = EnvCredentials.apiKey(envVar: envVar) {
                return key
            }
        }
        return nil
    }

    // MARK: - LLMProvider (forwarded)

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

    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await inner.streamAssistantMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature,
            thinkingLevel: thinkingLevel
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
