import Foundation

/// 后端提供方类型：本地 or 云端
public enum ProviderKind: String, Codable, Sendable, Equatable {
    case local
    case cloud
}

/// 节点级模型配置（漫剧画布灵魂功能：每个节点可自定义选择本地/云端模型）
///
/// 默认 `nil`（节点未配置时）表示使用全局默认模型；配置后该节点覆盖全局默认。
public struct NodeBackendConfig: Codable, Equatable, Sendable {
    /// 提供方类型：本地 / 云端
    public var providerType: ProviderKind
    /// 提供方 ID，如 "bailian" / "openai" / "comfyui-local" / "kling" / "jimeng"
    public var providerID: String
    /// 模型 ID，如 "qwen3.8-max-preview" / "gpt-5.5" / "gpt-image-2-official"
    public var modelID: String
    /// 节点类型相关参数：temperature / maxTokens / size / duration 等
    public var params: [String: String]

    public init(
        providerType: ProviderKind = .cloud,
        providerID: String = "",
        modelID: String = "",
        params: [String: String] = [:]
    ) {
        self.providerType = providerType
        self.providerID = providerID
        self.modelID = modelID
        self.params = params
    }

    /// 供 UI 徽标显示的摘要："providerID · modelID"
    public var displayName: String {
        "\(providerID) · \(modelID)"
    }
}
