import Foundation

/// 阿里云百炼 DashScope — OpenAI 兼容模式（/compatible-mode/v1）LLM Provider。
///
/// 复用 `OpenAICompatibleProvider` 的全部请求/流式解析逻辑（百炼 compatible-mode
/// 的 wire 格式与 OpenAI Chat Completions 一致），本类型只负责：
///   - 默认端点：`https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`
///   - API key 解析链：注入 key → `HERMES_CUSTOM_QWEN38_API_KEY`（已购模型，M2l 优先）→
///     `BAILIAN_TOKEN_PLAN_API_KEY`（未购模型，403 兜底）→ `DASHSCOPE_API_KEY`（均为环境变量）
///   - 默认模型 `qwen3.8-max-preview`
///
/// 支持 `sendMessage`、`streamMessage` 与含工具的 `streamAssistantMessage`。
public final class DashScopeProvider: AssistantStreamingLLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    /// 百炼 OpenAI 兼容模式端点（自带 /v1）。
    public static let defaultBaseURL = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    /// API key 环境变量解析顺序。
    public static let apiKeyEnvVars: [String] = [
        "HERMES_CUSTOM_QWEN38_API_KEY",
        "BAILIAN_TOKEN_PLAN_API_KEY",
        "DASHSCOPE_API_KEY",
    ]

    public var name: String { "DashScope" }

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
    ///   - apiKey: 直接注入的 key；为空时按 `apiKeyEnvVars` 顺序从环境变量解析。
    ///   - model: 默认 `qwen3.8-max-preview`。
    ///   - customBaseURL: 自定义端点；nil 时使用 `defaultBaseURL`。
    public init(apiKey: String? = nil, model: LLMModel = .qwen38MaxPreview, customBaseURL: String? = nil) {
        let resolved = Self.resolveAPIKey(injected: apiKey)
        self.resolvedAPIKey = resolved
        self.inner = OpenAICompatibleProvider(
            apiKey: resolved ?? "",
            model: model,
            customBaseURL: customBaseURL ?? Self.defaultBaseURL,
            appendV1Suffix: true
        )
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
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, temperature: temperature, thinkingLevel: nil)
    }

    public func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        try await inner.streamAssistantMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: maxTokens,
            temperature: temperature, thinkingLevel: thinkingLevel
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
