import Foundation

// MARK: - providerID ↔ ProviderType 映射（I8 P1-2 修复）
//
// 画布节点（CanvasCore.NodeBackendConfig.providerID）使用字符串 ID：
// "bailian" / "openai" / "claude" / "gimage2" / "kling" / "jimeng" / "ollama" 等；
// MinisCore Provider 抽象使用 ProviderType 枚举（rawValue 为 "dashScope" / "openAI" …）。
// 本表是两套 ID 命名空间的唯一映射层：ProviderFactory 注册表驱动（每个注册的
// ProviderType 都能拿到画布 ID），也覆盖画布 ModelCatalog 里出现的全部 providerID。

/// 画布 providerID（NodeBackendConfig.providerID）↔ MinisCore ProviderType 双向映射。
public enum ProviderIDMap {
    /// 画布 providerID → ProviderType 的权威映射（手写表，覆盖全部注册 provider + 画布目录）。
    static let canonical: [String: ProviderType] = [
        // 云端 LLM
        "bailian": .dashScope,          // 阿里云百炼（DashScope）
        "openai": .openAI,              // OpenAI
        "claude": .anthropic,           // Anthropic Claude（画布目录短名）
        "anthropic": .anthropic,        // Anthropic（ProviderType rawValue 风格）
        "openrouter": .openRouter,      // OpenRouter 聚合
        "gemini": .gemini,              // Google Gemini
        "openai-responses": .openAIResponses, // OpenAI Responses API（/v1/responses）
        // DeepSeek credential aliases are persisted by different package
        // generations. They identify the same provider, never a new one.
        "DEEPSEEK_API_KEY": .deepSeek,
        "HERMES_CUSTOM_DEEPSEEK_API_KEY": .deepSeek,
        // 云端生图 / 生视频
        "gimage2": .gimage2,            // Gimage2 生图
        "kling": .kling,                // 可灵生视频
        "jimeng": .jimeng,              // 即梦生视频
        "deepseek": .deepSeek,          // DeepSeek 官方 API（独立 ProviderType）
        // 本地后端（全部映射到 .local —— LocalOpenAIProvider 统一承载）
        "local": .local,
        "ollama": .local,               // Ollama（LLM）
        "comfyui-local": .local,        // 本地 ComfyUI（生图工作流）
        "stable-diffusion-local": .local, // 本地 SD WebUI
        "wan-local": .local,            // 本地 Wan（生视频，常托管于 ComfyUI）
    ]

    /// 画布 providerID → ProviderType；未知 ID 返回 nil。
    /// 回退：尝试把 ID 直接当作 ProviderType rawValue 解析（如 "openAI" / "dashScope"）。
    public static func providerType(fromID id: String) -> ProviderType? {
        canonical[id] ?? ProviderType(rawValue: id).flatMap { $0.isUnsupported ? nil : $0 }
    }

    /// Return the one stable canvas identity for an ID or credential alias.
    /// Unknown names deliberately return nil rather than being guessed from
    /// substrings or case-folding.
    public static func canonicalProviderID(fromID id: String) -> String? {
        guard let type = providerType(fromID: id) else { return nil }
        return providerID(from: type)
    }

    /// ProviderType → 画布 providerID（规范化短名）。
    /// `.unsupported` 与未知类型返回 nil。
    public static func providerID(from type: ProviderType) -> String? {
        switch type {
        case .dashScope: return "bailian"
        case .openAI: return "openai"
        case .anthropic: return "claude"
        case .openRouter: return "openrouter"
        case .deepSeek: return "deepseek"
        case .gemini: return "gemini"
        case .openAIResponses: return "openai-responses"
        case .gimage2: return "gimage2"
        case .kling: return "kling"
        case .jimeng: return "jimeng"
        case .local: return "local"
        case .unsupported: return nil
        }
    }

    /// 当前 ProviderFactory 已注册的 provider 对应的画布 providerID 列表
    /// （注册表驱动：新增注册自动出现在列表里，供 UI 目录/面板用）。
    public static var registeredProviderIDs: [String] {
        ProviderFactory.shared.registeredTypes.compactMap { providerID(from: $0) }
    }

    /// 校验：当前注册表里每个 ProviderType 都必须有画布 ID（双向映射完备性）。
    public static func validateRegistrationCoverage() -> [ProviderType] {
        ProviderFactory.shared.registeredTypes.filter { providerID(from: $0) == nil }
    }
}
