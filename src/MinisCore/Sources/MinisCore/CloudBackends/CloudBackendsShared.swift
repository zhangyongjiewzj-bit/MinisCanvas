import Foundation

// MARK: - Errors

/// 云端后端统一错误类型。
/// 无 API key、HTTP 失败、任务失败等均返回明确错误而非崩溃（优雅降级）。
public enum CloudBackendError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    /// 环境变量中未配置该后端的 API key。
    case missingAPIKey(providerID: String, envVar: String)
    case invalidURL(providerID: String, url: String)
    case httpError(providerID: String, statusCode: Int, body: String)
    case decodeFailed(providerID: String, detail: String)
    case taskFailed(providerID: String, taskID: String, message: String)
    case pollTimeout(providerID: String, taskID: String)
    case unknownProvider(String)
    /// 该后端的接入骨架已就位，但真实 API 尚未实现（缺少 API 文档/密钥）。
    case notImplemented(providerID: String, detail: String)

    // Associated strings can contain upstream response bodies, URLs, task IDs,
    // or caller-supplied labels. Ordinary display and logging use only fixed text.
    public var description: String { errorDescription ?? "云端后端错误" }
    public var debugDescription: String { description }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "云端后端未配置 API key，请检查凭据设置"
        case .invalidURL:
            return "云端后端请求 URL 无效，请检查地址设置"
        case .httpError(_, let code, _):
            return "云端后端 HTTP \(code)，请检查服务状态与授权"
        case .decodeFailed:
            return "云端后端响应解析失败，请检查接口版本"
        case .taskFailed:
            return "云端后端任务失败，请检查任务状态后重试"
        case .pollTimeout:
            return "云端后端任务轮询超时，请稍后重试"
        case .unknownProvider:
            return "未知云端后端，请检查后端选择"
        case .notImplemented:
            return "云端后端尚未接入真实 API，请检查接入配置"
        }
    }
}

// MARK: - Capability / Descriptor

/// 云端后端能力维度（对齐 NodeBackendConfig 的三类节点：LLM / 生图 / 生视频）。
public enum CloudBackendCapability: String, Sendable, CaseIterable {
    case llm
    case image
    case video
}

/// 云端后端的静态描述（供 UI 模型选择面板列出 provider 分组）。
public struct CloudBackendDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { providerID }
    /// 与 NodeBackendConfig.providerID 对齐，如 "bailian" / "openai" / "gimage2" / "kling" / "jimeng"。
    public let providerID: String
    public let displayName: String
    public let capabilities: Set<CloudBackendCapability>
    /// API key 环境变量名（DASHSCOPE_API_KEY / OPENAI_API_KEY / KLING_API_KEY / JIMENG_API_KEY）。
    public let envVar: String
    /// 常用模型（UI 置顶展示用）。
    public let defaultModels: [String]

    public init(providerID: String, displayName: String, capabilities: Set<CloudBackendCapability>, envVar: String, defaultModels: [String]) {
        self.providerID = providerID
        self.displayName = displayName
        self.capabilities = capabilities
        self.envVar = envVar
        self.defaultModels = defaultModels
    }

    /// 当前进程环境中是否已配置该后端的 API key。
    public var isConfigured: Bool {
        EnvCredentials.apiKey(envVar: envVar) != nil
    }
}

// MARK: - Media Items

/// 单个生成产物：远程 URL 或内联 base64（二选一或兼有）。
public struct CloudMediaItem: Sendable, Equatable {
    public var url: String?
    public var base64Data: String?
    public var mimeType: String?

    public init(url: String? = nil, base64Data: String? = nil, mimeType: String? = nil) {
        self.url = url
        self.base64Data = base64Data
        self.mimeType = mimeType
    }

    public var hasContent: Bool { url != nil || base64Data != nil }
}

// MARK: - Image Generation

/// 生图请求（size/count 等按各厂商规格透传）。
public struct CloudImageRequest: Sendable, Equatable {
    public var prompt: String
    public var negativePrompt: String?
    /// 尺寸：OpenAI 形如 "1024x1024"；即梦支持 "1K"/"2K"/"4K" 或宽x高。
    public var size: String?
    public var count: Int
    /// 覆盖默认模型 ID（对应 NodeBackendConfig.modelID）。
    public var modelOverride: String?
    /// 图生图（img2img）参考图：本地路径或远程 URL（U-2/AJ-11：上游 image 输入端口透传）。
    /// nil = 纯文生图（txt2img）。
    public var imageURL: String?
    /// 厂商特定额外参数（原样并入 payload）。
    public var extraParams: [String: String]

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        size: String? = nil,
        count: Int = 1,
        modelOverride: String? = nil,
        imageURL: String? = nil,
        extraParams: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.size = size
        self.count = count
        self.modelOverride = modelOverride
        self.imageURL = imageURL
        self.extraParams = extraParams
    }
}

public struct CloudImageResult: Sendable, Equatable {
    public var providerID: String
    public var model: String
    public var images: [CloudMediaItem]
    public var revisedPrompt: String?

    public init(providerID: String, model: String, images: [CloudMediaItem], revisedPrompt: String? = nil) {
        self.providerID = providerID
        self.model = model
        self.images = images
        self.revisedPrompt = revisedPrompt
    }
}

/// 云端生图后端协议（同步返回模式，如 OpenAI Images / 即梦 Ark images）。
public protocol CloudImageGenerator: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    /// API key 是否已配置（未配置时调用 generateImage 抛 missingAPIKey 错误）。
    var isConfigured: Bool { get }
    func generateImage(_ request: CloudImageRequest) async throws -> CloudImageResult
}

// MARK: - Video Generation (submit + poll)

/// 生视频请求。
public struct CloudVideoRequest: Sendable, Equatable {
    public var prompt: String
    /// 图生视频参考图 URL（可选；可灵 image / Seedance 首帧）。
    public var imageURL: String?
    /// 宽高比，如 "16:9"（可灵）。
    public var aspectRatio: String?
    /// 时长（秒，字符串透传，如 "5"）。
    public var duration: String?
    public var modelOverride: String?
    public var extraParams: [String: String]

    public init(
        prompt: String,
        imageURL: String? = nil,
        aspectRatio: String? = nil,
        duration: String? = nil,
        modelOverride: String? = nil,
        extraParams: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.imageURL = imageURL
        self.aspectRatio = aspectRatio
        self.duration = duration
        self.modelOverride = modelOverride
        self.extraParams = extraParams
    }
}

/// 异步任务状态（生图/生视频多为 submit+poll 模式）。
public struct CloudTaskState: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case queued
        case running
        case succeeded
        case failed
        case canceled
        case unknown
    }

    public var phase: Phase
    public var message: String?
    public var videoURL: String?
    public var images: [CloudMediaItem]

    public init(phase: Phase, message: String? = nil, videoURL: String? = nil, images: [CloudMediaItem] = []) {
        self.phase = phase
        self.message = message
        self.videoURL = videoURL
        self.images = images
    }

    public var isFinished: Bool {
        phase == .succeeded || phase == .failed || phase == .canceled
    }
}

public struct CloudVideoResult: Sendable, Equatable {
    public var providerID: String
    public var taskID: String
    public var videoURL: String?

    public init(providerID: String, taskID: String, videoURL: String?) {
        self.providerID = providerID
        self.taskID = taskID
        self.videoURL = videoURL
    }
}

/// 远端取消请求的明确结果。`.unsupported` 表示 Provider 没有可证实的
/// 远端取消能力，不代表任务已经被取消。
public enum CloudVideoCancellationOutcome: String, Codable, Sendable, Equatable {
    case accepted
    case alreadyCanceled
    case unsupported
}

/// 云端生视频后端协议（submit+poll 异步任务模式）。
public protocol CloudVideoGenerator: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }
    /// 提交生成任务，返回任务 ID。
    func submitVideo(_ request: CloudVideoRequest) async throws -> String
    /// 查询任务状态（一次轮询）。
    func pollVideo(taskID: String) async throws -> CloudTaskState
    /// 尽力取消已提交的远端任务，并返回可证实的远端结果。
    func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome
}

extension CloudVideoGenerator {
    public func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        .unsupported
    }

    /// 便捷方法：提交任务并轮询直至完成或超时。
    public func generateVideo(
        _ request: CloudVideoRequest,
        pollInterval: TimeInterval = 5,
        timeout: TimeInterval = 600
    ) async throws -> CloudVideoResult {
        try Task.checkCancellation()
        let taskID = try await submitVideo(request)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            let state = try await pollVideo(taskID: taskID)
            try Task.checkCancellation()
            switch state.phase {
            case .succeeded:
                return CloudVideoResult(providerID: providerID, taskID: taskID, videoURL: state.videoURL)
            case .failed:
                throw CloudBackendError.taskFailed(providerID: providerID, taskID: taskID, message: state.message ?? "unknown")
            case .canceled:
                throw CloudBackendError.taskFailed(providerID: providerID, taskID: taskID, message: "任务已取消")
            case .queued, .running, .unknown:
                break
            }
            if Date() >= deadline {
                throw CloudBackendError.pollTimeout(providerID: providerID, taskID: taskID)
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}

// MARK: - HTTP Helper

/// 云端后端共用的小型 HTTP/JSON 工具（URLSession + async/await）。
public enum CloudHTTP {
    /// 生图/提交任务用较长超时；轮询查询用默认短超时。
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 900
        // Cloud providers attach credentials; reject unsafe redirect hops.
        return URLSession(configuration: config, delegate: ProviderRedirectGuard.shared, delegateQueue: nil)
    }()

    /// POST JSON，返回解析后的 JSON 字典；非 2xx 抛 httpError（含响应体）。
    public static func postJSON(
        providerID: String,
        url: URL,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval = 120
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send(providerID: providerID, request: request)
    }

    /// GET JSON（用于轮询任务状态）。
    public static func getJSON(
        providerID: String,
        url: URL,
        headers: [String: String],
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(providerID: providerID, request: request)
    }

    private static func send(providerID: String, request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudBackendError.httpError(providerID: providerID, statusCode: statusCode, body: body)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw CloudBackendError.decodeFailed(providerID: providerID, detail: snippet)
        }
        return json
    }
}
