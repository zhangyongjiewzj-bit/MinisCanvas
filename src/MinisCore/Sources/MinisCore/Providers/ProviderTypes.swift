import Foundation

public enum ProviderType: String, Codable, CaseIterable, Hashable, Sendable {
    case openAI, anthropic, gemini, openRouter, deepSeek, openAIResponses
    case local, dashScope, gimage2, kling, jimeng, unsupported

    public static func decoded(_ raw: String) -> ProviderType {
        Self(rawValue: raw) ?? .unsupported
    }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek"
        case .openAIResponses: return "Responses API (/v1/responses)"
        case .local: return "Local (Ollama/ComfyUI)"
        case .dashScope: return "阿里云百炼 (DashScope)"
        case .gimage2: return "Gimage2"
        case .kling: return "可灵 (Kling)"
        case .jimeng: return "即梦 (Jimeng)"
        case .unsupported: return "Unsupported"
        }
    }

    public var runtimeProviderID: String {
        switch self {
        case .openAIResponses: return "OpenAIResponses"
        case .local: return "Local"
        case .dashScope: return "DashScope"
        default: return displayName
        }
    }

    public var builtInModels: [LLMModel] {
        switch self {
        case .openAI, .openAIResponses: return LLMModel.allOpenAI
        case .anthropic: return LLMModel.allAnthropic
        case .gemini: return LLMModel.allGemini
        case .openRouter: return LLMModel.allOpenRouter
        case .deepSeek: return LLMModel.allDeepSeek
        case .dashScope: return LLMModel.allDashScope
        case .local, .gimage2, .kling, .jimeng, .unsupported: return []
        }
    }

    public var defaultModality: ModelModality {
        self == .gemini ? .fullMultimodal : .vision
    }

    public var isUnsupported: Bool { self == .unsupported }
}

public enum ProviderCredential: String, Codable, Hashable, Sendable {
    case apiKey, oauth
}
