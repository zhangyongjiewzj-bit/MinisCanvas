import Foundation

/// 新增供应商表单的预设：`EnvVarStore.providerSuggestion` 的数据单一来源。
public struct ProviderPreset: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let protocolType: ProviderWireProtocol
    public let credentialName: String
    public let modelNames: [String]

    public static let dashScope = ProviderPreset(
        id: "dashscope",
        displayName: "DashScope（阿里云百炼）",
        baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
        protocolType: .openaiCompatible,
        credentialName: "DASHSCOPE_API_KEY",
        modelNames: ["qwen3.8-max-preview"]
    )

    public static let deepSeek = ProviderPreset(
        id: DeepSeekProviderContract.providerID,
        displayName: "DeepSeek",
        baseURL: DeepSeekProviderContract.baseURL,
        protocolType: .openaiCompatible,
        credentialName: DeepSeekProviderContract.apiKeyEnvironmentVariable,
        modelNames: DeepSeekProviderContract.supportedModelIDs
    )

    /// B16：New API（5678ai）中转站 — OpenAI 兼容端点 + gpt-5.5 系列模型清单。
    /// 与 Hermes 侧 `HERMES_CUSTOM_NEW_API_KEY` 配置保持一致。
    public static let newAPI = ProviderPreset(
        id: "newapi",
        displayName: "New API（5678ai）",
        baseURL: "https://5678ai.cn/v1",
        protocolType: .openaiCompatible,
        credentialName: "HERMES_CUSTOM_NEW_API_KEY",
        modelNames: ["gpt-5.5", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra"]
    )

    /// 官方 Anthropic：地址与内置路由一致（含 /v1），凭据名即内置供应商的 Key 名。
    public static let anthropic = ProviderPreset(
        id: "anthropic",
        displayName: "Anthropic",
        baseURL: "https://api.anthropic.com/v1",
        protocolType: .anthropic,
        credentialName: "ANTHROPIC_API_KEY",
        modelNames: [LLMModel.claudeSonnet5.id]
    )

    public static let openAI = ProviderPreset(
        id: "openai",
        displayName: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        protocolType: .openaiCompatible,
        credentialName: "OPENAI_API_KEY",
        modelNames: [LLMModel.gpt41.id]
    )

    public static let openRouter = ProviderPreset(
        id: "openrouter",
        displayName: "OpenRouter",
        baseURL: "https://openrouter.ai/api/v1",
        protocolType: .openaiCompatible,
        credentialName: "OPENROUTER_API_KEY",
        modelNames: [LLMModel.orClaudeSonnet4.id]
    )

    /// 本机模型服务：不需要 API Key（保存时内部使用占位值）；模型名取决于本机已下载的模型，
    /// 留空后用“获取模型列表”选择。
    public static let ollama = ProviderPreset(
        id: "ollama",
        displayName: "Ollama（本机）",
        baseURL: "http://localhost:11434/v1",
        protocolType: .openaiCompatible,
        credentialName: "OLLAMA_API_KEY",
        modelNames: []
    )

    public static let lmStudio = ProviderPreset(
        id: "lmstudio",
        displayName: "LM Studio（本机）",
        baseURL: "http://localhost:1234/v1",
        protocolType: .openaiCompatible,
        credentialName: "LMSTUDIO_API_KEY",
        modelNames: []
    )

    /// 以下四家只补地址、协议和凭据名，不写死模型名（各家模型更新很快）；
    /// 填好 Key 后用“获取模型列表”选择。
    public static let gemini = ProviderPreset(
        id: "gemini",
        displayName: "Google Gemini",
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        protocolType: .openaiCompatible,
        credentialName: "GEMINI_API_KEY",
        modelNames: []
    )

    public static let kimi = ProviderPreset(
        id: "kimi",
        displayName: "Kimi（月之暗面）",
        baseURL: "https://api.moonshot.cn/v1",
        protocolType: .openaiCompatible,
        credentialName: "MOONSHOT_API_KEY",
        modelNames: []
    )

    public static let zhipu = ProviderPreset(
        id: "zhipu",
        displayName: "智谱 GLM",
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        protocolType: .openaiCompatible,
        credentialName: "ZHIPU_API_KEY",
        modelNames: []
    )

    public static let siliconFlow = ProviderPreset(
        id: "siliconflow",
        displayName: "硅基流动",
        baseURL: "https://api.siliconflow.cn/v1",
        protocolType: .openaiCompatible,
        credentialName: "SILICONFLOW_API_KEY",
        modelNames: []
    )

    public static let all: [ProviderPreset] = [
        deepSeek, dashScope, newAPI, anthropic, openAI, openRouter, gemini, kimi, zhipu, siliconFlow, ollama, lmStudio
    ]

    /// 凭据名对应的预设默认地址；基础地址留空时用它（没有预设返回 nil）。
    public static func defaultBaseURL(forCredentialName name: String) -> String? {
        let canonical = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return all.first { $0.credentialName == canonical }?.baseURL
    }

    var suggestion: ProviderSuggestion {
        ProviderSuggestion(
            baseURL: baseURL,
            modelNames: modelNames,
            protocolType: protocolType,
            providerLabel: displayName
        )
    }
}
