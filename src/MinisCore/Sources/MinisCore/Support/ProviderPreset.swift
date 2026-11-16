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

    public static let all: [ProviderPreset] = [deepSeek, dashScope, newAPI]

    var suggestion: ProviderSuggestion {
        ProviderSuggestion(
            baseURL: baseURL,
            modelNames: modelNames,
            protocolType: protocolType,
            providerLabel: displayName
        )
    }
}
