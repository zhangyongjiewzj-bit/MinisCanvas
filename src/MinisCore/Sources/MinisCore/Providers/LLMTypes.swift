import Foundation

public struct ModelModality: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(from decoder: Decoder) throws {
        let scalar = try decoder.singleValueContainer()
        rawValue = try scalar.decode(Int.self)
    }
    public func encode(to encoder: Encoder) throws {
        var scalar = encoder.singleValueContainer()
        try scalar.encode(rawValue)
    }
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let textInput = Self(rawValue: 1)
    public static let textOutput = Self(rawValue: 2)
    public static let imageInput = Self(rawValue: 4)
    public static let pdfInput = Self(rawValue: 8)
    public static let audioInput = Self(rawValue: 16)
    public static let videoInput = Self(rawValue: 32)
    public static let imageOutput = Self(rawValue: 64)
    public static let audioOutput = Self(rawValue: 128)
    public static let videoOutput = Self(rawValue: 256)
    public static let allInputs: Self = [.textInput, .imageInput, .pdfInput, .audioInput, .videoInput]
    public static let allOutputs: Self = [.textOutput, .imageOutput, .audioOutput, .videoOutput]
    public static let textOnly: Self = [.textInput, .textOutput]
    public static let vision: Self = [.textInput, .textOutput, .imageInput, .pdfInput]
    public static let fullMultimodalInput: Self = [.textInput, .textOutput, .imageInput, .pdfInput, .audioInput, .videoInput]
    public static let fullMultimodal = fullMultimodalInput
    public var inputs: Self { intersection(.allInputs) }
    public var outputs: Self { intersection(.allOutputs) }
}

public enum ProviderAuthMethod: String, Codable, Hashable, Sendable {
    case apiKey, oauth
}

public struct ModelCapabilities: Codable, Hashable, Sendable {
    public let supportedModalities: ModelModality
    public let supportedAuth: Set<ProviderAuthMethod>
    public init(supportedModalities: ModelModality, supportedAuth: Set<ProviderAuthMethod>) {
        self.supportedModalities = supportedModalities
        self.supportedAuth = supportedAuth
    }
}

public struct LLMModel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let provider: String
    public var modalityOverride: ModelModality?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsReasoning: Bool?
    public var interleavedReasoningField: String?

    public init(id: String, displayName: String, provider: String,
                modalityOverride: ModelModality? = nil, contextWindow: Int? = nil,
                maxOutputTokens: Int? = nil, supportsReasoning: Bool? = nil,
                interleavedReasoningField: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.modalityOverride = modalityOverride
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsReasoning = supportsReasoning
        self.interleavedReasoningField = interleavedReasoningField
    }

    public var capabilities: ModelCapabilities {
        let native: ModelModality
        switch provider {
        case "Google": native = .fullMultimodalInput
        case "Anthropic", "OpenAI", "OpenRouter", "DashScope", "LUNA", "Local": native = .vision
        default: native = .textOnly
        }
        let auth: Set<ProviderAuthMethod> = ["Anthropic", "OpenAI", "OpenRouter", "Google"].contains(provider)
            ? [.apiKey, .oauth] : [.apiKey]
        return ModelCapabilities(supportedModalities: modalityOverride ?? native, supportedAuth: auth)
    }

    public func withModalityOverride(_ value: ModelModality) -> Self {
        var result = self
        result.modalityOverride = value
        return result
    }

    public var contextWindowTokens: Int {
        if let contextWindow, contextWindow > 0 { return contextWindow }
        return ModelContextWindowCatalog.window(forModelID: id) ?? 128_000
    }

    public static func inferDedicatedVoiceModality(id: String, displayName: String) -> ModelModality? {
        let names = [id.lowercased(), displayName.lowercased()]
        let recognition = ["-asr", "asr-", "_asr", "asr_", "whisper", "transcrib", "speech-to-text", "speech2text", "stt-", "-stt", "_stt", "stt_", "voice-input", "voice_input"]
        let synthesis = ["tts", "text-to-speech", "text2speech", "audio-gen", "audio-generation", "seed-tts", "voice-output", "voice_output"]
        if names.contains(where: { name in recognition.contains(where: name.contains) }) { return [.audioInput, .textOutput] }
        if names.contains(where: { name in synthesis.contains(where: name.contains) }) { return [.textInput, .audioOutput] }
        return nil
    }

    public static func inferOutputModality(id: String, displayName: String) -> ModelModality? {
        let names = [id.lowercased(), displayName.lowercased()]
        let categories: [(ModelModality, [String])] = [
            (.imageOutput, ["image-gen", "image-generation", "imagen", "dall-e", "dalle", "gpt-5-image", "gpt-5.1-image", "flash-image", "pro-image", "image-output", "img-gen", "img-output"]),
            (.audioOutput, ["tts", "audio-gen", "audio-generation", "speech", "gpt-audio", "4o-audio"]),
            (.videoOutput, ["video-gen", "video-generation", "veo", "sora"])
        ]
        var found: ModelModality = []
        for (modality, markers) in categories where names.contains(where: { name in markers.contains(where: name.contains) }) {
            found.formUnion(modality)
        }
        return found.isEmpty ? nil : found
    }
}

public func modelDisplayName(from id: String) -> String {
    let capitals = ["GPT", "GLM", "OSS", "AI", "XL", "XXL", "VL", "LLM", "MOE", "API", "HD", "SD", "RP", "SFT", "RL", "DPO", "GGUF", "FP16", "BF16", "INT4", "INT8"]
    let brands = ["OpenAI", "DeepSeek", "ChatGPT", "Llama", "Gemma", "Phi", "Mistral", "Mixtral", "Qwen", "Yi"]
    let fixed = Dictionary(uniqueKeysWithValues: (capitals + brands).map { ($0.lowercased(), $0) })
    return id.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == " " }).map { part in
        let word = String(part)
        return fixed[word.lowercased()] ?? (String(word.prefix(1)).uppercased() + word.dropFirst())
    }.joined(separator: " ")
}

extension LLMModel {
    public static let claudeFable5 = LLMModel(id: "claude-fable-5", displayName: "Claude Fable 5", provider: "Anthropic", contextWindow: 1000000, maxOutputTokens: 128000)
    public static let claudeOpus5 = LLMModel(id: "claude-opus-5", displayName: "Claude Opus 5", provider: "Anthropic", contextWindow: 1000000, maxOutputTokens: 128000)
    public static let claudeOpus48 = LLMModel(id: "claude-opus-4-8", displayName: "Claude Opus 4.8", provider: "Anthropic", contextWindow: 1000000, maxOutputTokens: 128000)
    public static let claudeOpus46 = LLMModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: "Anthropic", contextWindow: 1000000, maxOutputTokens: 128000)
    public static let claudeSonnet5 = LLMModel(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", provider: "Anthropic", contextWindow: 1000000, maxOutputTokens: 64000)
    public static let claudeSonnet46 = LLMModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: "Anthropic", contextWindow: 1000000, maxOutputTokens: 64000)
    public static let claudeHaiku45 = LLMModel(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: "Anthropic", contextWindow: 200000, maxOutputTokens: 64000)
    public static let allAnthropic: [LLMModel] = [.claudeFable5, .claudeOpus5, .claudeOpus48, .claudeOpus46, .claudeSonnet5, .claudeSonnet46, .claudeHaiku45]

    public static let gemini31ProPreview = LLMModel(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro (Preview)", provider: "Google")
    public static let gemini3ProPreview = LLMModel(id: "gemini-3-pro-preview", displayName: "Gemini 3 Pro (Preview)", provider: "Google")
    public static let gemini3FlashPreview = LLMModel(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash (Preview)", provider: "Google")
    public static let gemini25Pro = LLMModel(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: "Google")
    public static let gemini25Flash = LLMModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: "Google")
    public static let gemini25FlashLite = LLMModel(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash Lite", provider: "Google")
    public static let allGemini: [LLMModel] = [.gemini31ProPreview, .gemini3ProPreview, .gemini3FlashPreview, .gemini25Pro, .gemini25Flash, .gemini25FlashLite]

    public static let gpt54 = LLMModel(id: "gpt-5.4", displayName: "GPT-5.4", provider: "OpenAI")
    public static let gpt53 = LLMModel(id: "gpt-5.3", displayName: "GPT-5.3", provider: "OpenAI")
    public static let gpt52 = LLMModel(id: "gpt-5.2", displayName: "GPT-5.2", provider: "OpenAI")
    public static let gpt5 = LLMModel(id: "gpt-5", displayName: "GPT-5", provider: "OpenAI")
    public static let gpt41 = LLMModel(id: "gpt-4.1", displayName: "GPT-4.1", provider: "OpenAI")
    public static let gpt4o = LLMModel(id: "gpt-4o", displayName: "GPT-4o", provider: "OpenAI")
    public static let gpt4oMini = LLMModel(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: "OpenAI")
    public static let o3 = LLMModel(id: "o3", displayName: "o3", provider: "OpenAI")
    public static let o3Mini = LLMModel(id: "o3-mini", displayName: "o3 Mini", provider: "OpenAI")
    public static let o4Mini = LLMModel(id: "o4-mini", displayName: "o4 Mini", provider: "OpenAI")
    public static let codexMini = LLMModel(id: "codex-mini-latest", displayName: "Codex Mini", provider: "OpenAI")
    public static let allOpenAI: [LLMModel] = [.gpt54, .gpt53, .gpt52, .gpt5, .gpt41, .gpt4o, .gpt4oMini, .o3, .o3Mini, .o4Mini, .codexMini]

    public static let orClaudeSonnet4 = LLMModel(id: "anthropic/claude-sonnet-4", displayName: "Claude Sonnet 4", provider: "OpenRouter")
    public static let orGemini25Flash = LLMModel(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: "OpenRouter")
    public static let orGPT4o = LLMModel(id: "openai/gpt-4o", displayName: "GPT-4o", provider: "OpenRouter")
    public static let orLlama4Maverick = LLMModel(id: "meta-llama/llama-4-maverick", displayName: "Llama 4 Maverick", provider: "OpenRouter")
    public static let allOpenRouter: [LLMModel] = [.orClaudeSonnet4, .orGemini25Flash, .orGPT4o, .orLlama4Maverick]

    public static let qwen38MaxPreview = LLMModel(id: "qwen3.8-max-preview", displayName: "Qwen3.8 Max (Preview)", provider: "DashScope", contextWindow: 128000, maxOutputTokens: 32000)
    public static let qwen37Max = LLMModel(id: "qwen3.7-max", displayName: "Qwen3.7 Max", provider: "DashScope", contextWindow: 128000, maxOutputTokens: 32000)
    public static let qwen37Plus = LLMModel(id: "qwen3.7-plus", displayName: "Qwen3.7 Plus", provider: "DashScope", contextWindow: 128000, maxOutputTokens: 32000)
    public static let qwenMaxLatest = LLMModel(id: "qwen-max-latest", displayName: "Qwen Max (Latest)", provider: "DashScope", contextWindow: 128000, maxOutputTokens: 32000)
    public static let qwenPlusLatest = LLMModel(id: "qwen-plus-latest", displayName: "Qwen Plus (Latest)", provider: "DashScope", contextWindow: 128000, maxOutputTokens: 32000)
    public static let qwenTurboLatest = LLMModel(id: "qwen-turbo-latest", displayName: "Qwen Turbo (Latest)", provider: "DashScope", contextWindow: 128000, maxOutputTokens: 32000)
    public static let qwen3VLPlus = LLMModel(id: "qwen3-vl-plus", displayName: "Qwen3-VL Plus (视觉)", provider: "DashScope", modalityOverride: .vision, contextWindow: 128000, maxOutputTokens: 32000)
    public static let allDashScope: [LLMModel] = [.qwen38MaxPreview, .qwen37Max, .qwen37Plus, .qwenMaxLatest, .qwenPlusLatest, .qwenTurboLatest, .qwen3VLPlus]

    public static let deepSeekChat = LLMModel(id: "deepseek-chat", displayName: "DeepSeek Chat (V3)", provider: "DeepSeek", contextWindow: 128000, maxOutputTokens: 8192)
    public static let deepSeekReasoner = LLMModel(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner (R1)", provider: "DeepSeek", contextWindow: 128000, maxOutputTokens: 8192, supportsReasoning: true, interleavedReasoningField: "reasoning_content")
    public static let deepSeekV4Flash = LLMModel(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", provider: "DeepSeek", contextWindow: 128000, maxOutputTokens: 8192, supportsReasoning: true, interleavedReasoningField: "reasoning_content")
    public static let deepSeekV4Pro = LLMModel(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", provider: "DeepSeek", contextWindow: 128000, maxOutputTokens: 8192, supportsReasoning: true, interleavedReasoningField: "reasoning_content")
    public static let deepSeekFlash = LLMModel(id: "deepseek-flash", displayName: "DeepSeek Flash", provider: "DeepSeek", modalityOverride: .textOnly, contextWindow: 128000, maxOutputTokens: 8192)
    public static let allDeepSeek: [LLMModel] = [.deepSeekChat, .deepSeekReasoner, .deepSeekV4Flash, .deepSeekV4Pro, .deepSeekFlash]

    public static let allModels: [LLMModel] = allAnthropic + allGemini + allOpenAI + allOpenRouter + allDashScope + allDeepSeek
}

public enum ModelSpeedTier: String, Codable, CaseIterable, Hashable, Sendable {
    case ultraFast, fast, balanced, quality
    public var displayName: String {
        switch self { case .ultraFast: return "极快"; case .fast: return "快"; case .balanced: return "均衡"; case .quality: return "质量" }
    }
    public var icon: String {
        switch self { case .ultraFast: return "⚡"; case .fast: return "🚀"; case .balanced: return "⚖️"; case .quality: return "💎" }
    }
    public var defaultModelID: String {
        switch self { case .ultraFast: return "deepseek-chat"; case .fast: return "qwen-turbo-latest"; case .balanced: return "qwen3.8-max-preview"; case .quality: return "deepseek-reasoner" }
    }
    public var defaultModel: LLMModel? { LLMModel.allModels.first { $0.id == defaultModelID } }
    private var modelIDs: Set<String> {
        switch self {
        case .ultraFast:
            return ["qwen-turbo-latest", "gemini-2.5-flash-lite", "gpt-4o-mini", "o4-mini", "codex-mini-latest"]
        case .fast:
            return ["deepseek-chat", "qwen3.7-plus", "qwen-plus-latest", "gemini-2.5-flash", "gemini-3-flash-preview", "gpt-4.1", "gpt-4o", "o3-mini", "claude-haiku-4-5", "google/gemini-2.5-flash", "openai/gpt-4o", "meta-llama/llama-4-maverick"]
        case .balanced:
            return ["qwen3.8-max-preview", "qwen-max-latest", "gemini-2.5-pro", "gemini-3-pro-preview", "gpt-5", "gpt-5.2", "claude-sonnet-5", "claude-sonnet-4-6", "anthropic/claude-sonnet-4"]
        case .quality:
            return ["deepseek-reasoner", "qwen3.7-max", "gemini-3.1-pro-preview", "gpt-5.3", "gpt-5.4", "o3", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-6", "claude-fable-5"]
        }
    }
    public static func tier(forModelID id: String) -> Self? { allCases.first { $0.modelIDs.contains(id) } }
    public static func tier(for model: LLMModel) -> Self? { tier(forModelID: model.id) }
    public func models(in candidates: [LLMModel] = LLMModel.allModels) -> [LLMModel] { candidates.filter { modelIDs.contains($0.id) } }
}


extension LLMModel {
    public var catalogMaxThinkingLevel: ThinkingLevel {
        if supportsReasoning == false { return .off }
        return ThinkingLevelCatalog.declaredMaxLevel(for: id) ?? .xhigh
    }

    public var capabilityPromptFragment: String? {
        let media: [(ModelModality, String)] = [(.imageInput, "images"), (.pdfInput, "PDFs"),
                                              (.audioInput, "audio"), (.videoInput, "video")]
        let modalities = capabilities.supportedModalities
        let supported = media.filter { modalities.contains($0.0) }.map { $0.1 }
        let unsupported = media.filter { !modalities.contains($0.0) }.map { $0.1 }
        if unsupported.isEmpty { return nil }
        var sentences: [String] = []
        if !supported.isEmpty {
            sentences.append("You can natively process " + supported.joined(separator: " and ") + " in this conversation.")
        }
        sentences.append("You cannot natively process " + unsupported.joined(separator: " or ") + ".")
        sentences.append("To handle unsupported media, use shell_execute to run ffmpeg or other CLI tools.")
        return sentences.joined(separator: " ")
    }
}

public struct LLMMessage: Sendable {
    public enum Role: String, Sendable { case user, assistant, tool }
    public struct ImageAttachment: Sendable {
        public let mimeType: String
        public let data: Data
        public init(mimeType: String, data: Data) { self.mimeType = mimeType; self.data = data }
    }
    public struct AudioAttachment: Sendable {
        public let format: String
        public let base64Data: String
        public init(format: String, base64Data: String) { self.format = format; self.base64Data = base64Data }
    }
    public let role: Role
    public let content: String
    public var images: [ImageAttachment]
    public var audios: [AudioAttachment]
    public var toolCallID: String?
    public var toolCalls: [LLMToolCall]
    public var legacyToolOutputSummary: ToolOutputSummary?
    public init(role: Role, content: String, images: [ImageAttachment] = [], audios: [AudioAttachment] = [],
                toolCallID: String? = nil, toolCalls: [LLMToolCall] = [], legacyToolOutputSummary: ToolOutputSummary? = nil) {
        self.role = role
        self.content = content
        self.images = images
        self.audios = audios
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.legacyToolOutputSummary = legacyToolOutputSummary
    }
}

public struct LLMMediaAttachment: Sendable {
    public enum MediaType: String, Sendable { case image, audio, video }
    public let type: MediaType
    public let mimeType: String
    public let data: Data
    public init(type: MediaType, mimeType: String, data: Data) {
        self.type = type
        self.mimeType = mimeType
        self.data = data
    }
}

public struct LLMToolCall: @unchecked Sendable {
    public let id: String
    public let name: String
    public let rawArguments: String
    public let arguments: [String: Any]
    public init(id: String, name: String, rawArguments: String, arguments: [String: Any]) {
        self.id = id
        self.name = name
        self.rawArguments = rawArguments
        self.arguments = arguments
    }
    public var openAIDict: [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": rawArguments]]
    }
}

struct DiscardedToolCallNotice: Sendable {
    let offeredNames: [String]
    let additionalOfferedNameCount: Int
    let unknownToolCallCount: Int

    init?(candidateNames: [String?], offeredNames: [String]?, count: Int) {
        guard count > 0, candidateNames.count == count, let offeredNames else { return nil }
        var matched: [String] = []
        var unknown = 0
        for candidate in candidateNames {
            guard let candidate, let offered = offeredNames.first(where: {
                $0.utf8.elementsEqual(candidate.utf8)
            }) else {
                unknown += 1
                continue
            }
            if !matched.contains(where: { $0.utf8.elementsEqual(offered.utf8) }) {
                matched.append(offered)
            }
        }
        self.offeredNames = Array(matched.prefix(8))
        self.additionalOfferedNameCount = max(0, matched.count - 8)
        self.unknownToolCallCount = unknown
    }
}

public struct LLMResponse: Sendable {
    public let text: String
    public let stopReason: String?
    public let usage: LLMUsage?
    public var mediaAttachments: [LLMMediaAttachment]
    public var toolCalls: [LLMToolCall]
    let discardedToolCallCount: Int
    let discardedToolCallNotice: DiscardedToolCallNotice?
    public init(text: String, stopReason: String?, usage: LLMUsage?, mediaAttachments: [LLMMediaAttachment] = [], toolCalls: [LLMToolCall] = []) {
        self.init(text: text, stopReason: stopReason, usage: usage,
                  mediaAttachments: mediaAttachments, toolCalls: toolCalls,
                  discardedToolCallCount: 0)
    }

    init(text: String, stopReason: String?, usage: LLMUsage?,
         mediaAttachments: [LLMMediaAttachment], toolCalls: [LLMToolCall],
         discardedToolCallCount: Int, discardedToolCallNotice: DiscardedToolCallNotice? = nil) {
        self.text = text
        self.stopReason = stopReason
        self.usage = usage
        self.mediaAttachments = mediaAttachments
        self.toolCalls = toolCalls
        self.discardedToolCallCount = discardedToolCallCount
        self.discardedToolCallNotice = discardedToolCallNotice
    }
}

public enum LLMStreamChunk: Sendable {
    case started
    case text(String)
    case usage(LLMUsage)
    case finished(stopReason: String?)
}

public struct LLMUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheHitInputTokens: Int?
    public init(inputTokens: Int, outputTokens: Int, cacheCreationInputTokens: Int? = nil,
                cacheReadInputTokens: Int? = nil, cacheHitInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheHitInputTokens = cacheHitInputTokens
    }
    static func anthropicCacheHitInputTokens(_ usage: [String: Any]) -> Int? {
        let names = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let tokens = names.map { usage[$0] as? Int }
        if tokens[0] == nil { return nil }
        let components = tokens.map { $0 ?? 0 }
        if components.contains(where: { $0 < 0 }) { return nil }
        var available = Int.max
        for component in components {
            if component > available { return nil }
            available -= component
        }
        return Int.max - available
    }
}
