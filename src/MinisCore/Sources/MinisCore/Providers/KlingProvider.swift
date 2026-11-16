import Foundation

/// 可灵 Kling — 云端生视频 Provider（真实 API 接入，M2h）。
///
/// 接入形态：可灵 API 为「提交任务 → 轮询任务状态 → 取视频 URL」的异步模式，
/// 与 `CloudVideoGenerator`（submitVideo / pollVideo）完全对应。
///
/// API 规格（docs/kling-api-spec.md，v2.0）：
/// - 认证：`Authorization: Bearer <API Key>`（key 从环境变量 `KLING_API_KEY` 读）
/// - 域名：`https://api-singapore.klingai.com`（新加坡区）
/// - 创建任务：POST `/image-to-video/kling-3.0`（图生视频）或
///   POST `/text-to-video/kling-3.0`（文生视频，contents 只含 prompt）
/// - 查询任务：GET `/tasks?task_ids=<id>`（响应 data 是数组）
/// - code == 0 才成功，否则 message 含失败原因（含内容风控触发说明）
///
/// 请求体组装：
/// - contents：prompt + first_frame / last_frame（首帧 = request.imageURL，
///   尾帧 = extraParams["last_frame_url"]；无任何帧时自动走文生视频变体）
/// - settings：resolution（extraParams 或默认 "1080p"）、duration（3-15 秒，
///   默认 10）、audio（默认 "off"，后期加配音）、multi_shot（多镜头提示词透传，
///   extraParams["multi_shot"] == "true" 时开启）
/// - options：watermark_info.enabled = false（去水印）
///
/// 同时实现 `LLMProvider` 仅为满足 `ProviderFactory` 注册制（Builder 返回
/// `any LLMProvider`）；本 provider 是生视频后端，LLM 聊天方法一律抛
/// `notImplemented` 错误，请通过 `CloudVideoGenerator` 能力使用。
public final class KlingProvider: CloudVideoGenerator, LLMProvider, @unchecked Sendable {
    public var capabilities: Set<ProviderCapability> { [.video] }
    /// API key 环境变量解析顺序。
    public static let apiKeyEnvVars: [String] = [
        "KLING_API_KEY",
        "KING_API_KEY",
    ]

    public let providerID = "kling"
    public let displayName = "可灵 (Kling)"

    /// 生视频模型 ID（默认 kling-v1，兼容 ProviderFactory 注册）。
    public var modelID: String
    /// 当前解析到的 API key（nil 表示未配置）。
    public let resolvedAPIKey: String?

    /// LLMProvider 桩：供注册制工厂使用，聊天调用会抛 notImplemented。
    public var name: String { displayName }
    private var llmModel: LLMModel
    /// 可注入的 URLSession（测试用 URLProtocol mock 替换）。
    private let session: URLSession
    /// 本地参考图托管上传能力（P1-13）。nil = 无托管，本地路径参考图会被阻断并提示先上传。
    private let mediaHosting: (any MediaReferenceHosting)?

    /// 可灵开放平台域名（新加坡区）。
    public static let baseURL = "https://api-singapore.klingai.com"
    /// 图生视频（Kling 3.0）：POST /image-to-video/kling-3.0
    public static let imageToVideoPath = "/image-to-video/kling-3.0"
    /// 文生视频（Kling 3.0）：POST /text-to-video/kling-3.0
    public static let textToVideoPath = "/text-to-video/kling-3.0"
    /// 任务查询：GET /tasks?task_ids=xxx
    public static let tasksPath = "/tasks"

    public init(apiKey: String? = nil, model: String = "kling-v1", session: URLSession = CloudHTTP.session, mediaHosting: (any MediaReferenceHosting)? = nil) {
        self.resolvedAPIKey = Self.resolveAPIKey(injected: apiKey)
        self.modelID = model
        self.llmModel = LLMModel(id: model, displayName: "可灵 (Kling)", provider: "Kling")
        self.session = session
        self.mediaHosting = mediaHosting
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

    public var isConfigured: Bool { resolvedAPIKey != nil }

    // MARK: - LLMProvider (桩 — 生视频 Provider 不支持聊天)

    public var model: LLMModel {
        get { llmModel }
        set { llmModel = newValue }
    }

    public func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw CloudBackendError.notImplemented(
            providerID: providerID,
            detail: "可灵是生视频后端，不支持 LLM 聊天；请通过 CloudVideoGenerator 使用"
        )
    }

    public func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw CloudBackendError.notImplemented(
            providerID: providerID,
            detail: "可灵是生视频后端，不支持 LLM 流式聊天"
        )
    }

    // MARK: - CloudVideoGenerator (真实 API，M2h)

    /// 提交生视频任务，返回 taskID。
    ///
    /// 有首/尾帧 → POST /image-to-video/kling-3.0；无任何帧 → POST
    /// /text-to-video/kling-3.0（文生视频，contents 只含 prompt）。
    /// 响应 code == 0 时从 `data.id` 提取任务 ID，否则抛错带 message。
    public func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        guard let apiKey = resolvedAPIKey else {
            throw CloudBackendError.missingAPIKey(
                providerID: providerID,
                envVar: Self.apiKeyEnvVars.joined(separator: " / ")
            )
        }
        let firstFrameRaw = request.imageURL ?? request.extraParams["first_frame_url"]
        let lastFrameRaw = request.extraParams["last_frame_url"]
        // P1-13：参考图必须云端可访问——本地路径在此上传托管或阻断（见 MediaReferenceGate）。
        let firstFrame = try await MediaReferenceGate.resolveForCloud(firstFrameRaw, hoster: mediaHosting)
        let lastFrame = try await MediaReferenceGate.resolveForCloud(lastFrameRaw, hoster: mediaHosting)
        let isTextToVideo = firstFrame == nil && lastFrame == nil
        let submitURL = try Self.makeURL(path: isTextToVideo ? Self.textToVideoPath : Self.imageToVideoPath)

        var contents: [[String: Any]] = []
        if !request.prompt.isEmpty {
            contents.append(["type": "prompt", "text": request.prompt])
        }
        if let firstFrame {
            contents.append(["type": "first_frame", "url": firstFrame])
        }
        if let lastFrame {
            contents.append(["type": "last_frame", "url": lastFrame])
        }

        let duration = Int(request.duration ?? request.extraParams["duration"] ?? "") ?? 10
        let resolution = request.extraParams["resolution"] ?? "1080p"
        let audio = request.extraParams["audio"] ?? "off"
        let multiShot = (request.extraParams["multi_shot"] ?? "false") == "true"

        let body: [String: Any] = [
            "contents": contents,
            "settings": [
                "resolution": resolution,
                "duration": duration,
                "audio": audio,
                "multi_shot": multiShot,
            ],
            "options": [
                "watermark_info": ["enabled": false],
            ],
        ]

        // submit（POST 创建计费任务）绝不重试：5xx 时服务端可能已建任务但响应丢失，
        // 盲目重试会重复创建任务导致重复扣费。失败直接上抛，由调用方决定是否重试。
        // A canceled caller must not start the billable task-creation request.
        try Task.checkCancellation()
        let json = try await self.send(
            method: "POST",
            url: submitURL,
            headers: Self.authHeaders(apiKey: apiKey),
            body: body,
            timeout: 120
        )
        if let error = Self.vendorError(json) {
            throw CloudBackendError.decodeFailed(
                providerID: providerID,
                detail: "可灵创建任务失败 code=\(error.code)：\(error.message)"
            )
        }
        guard
            let data = json["data"] as? [String: Any],
            let taskID = data["id"] as? String,
            !taskID.isEmpty
        else {
            throw CloudBackendError.decodeFailed(
                providerID: providerID,
                detail: "可灵创建任务响应缺少 data.id：\(String(describing: json).prefix(300))"
            )
        }
        return taskID
    }

    /// 轮询一次任务状态：GET /tasks?task_ids=<id>，响应 data 为数组取首项。
    ///
    /// 状态映射：submitted→queued、processing→running、succeeded→succeeded、
    /// failed→failed；成功时从 `outputs[].url`（type == "video"）提取视频地址。
    /// code != 0 直接抛 taskFailed（带 message）。轮询间隔与总超时由
    /// `CloudVideoGenerator.generateVideo` 控制（默认 5s / 600s）。
    public func pollVideo(taskID: String) async throws -> CloudTaskState {
        guard let apiKey = resolvedAPIKey else {
            throw CloudBackendError.missingAPIKey(
                providerID: providerID,
                envVar: Self.apiKeyEnvVars.joined(separator: " / ")
            )
        }
        let queryURL = try Self.makeURL(
            path: Self.tasksPath,
            queryItems: [URLQueryItem(name: "task_ids", value: taskID)]
        )
        try Task.checkCancellation()
        let json = try await CloudVideoHTTP.withTransientRetry(providerID: providerID) {
            try await self.send(
                method: "GET",
                url: queryURL,
                headers: Self.authHeaders(apiKey: apiKey),
                body: nil,
                timeout: 30
            )
        }
        // Buffered transports can return a response after cancellation; keep it terminal.
        try Task.checkCancellation()
        if let error = Self.vendorError(json) {
            throw CloudBackendError.taskFailed(
                providerID: providerID,
                taskID: taskID,
                message: error.message
            )
        }
        guard
            let tasks = json["data"] as? [[String: Any]],
            let task = tasks.first
        else {
            throw CloudBackendError.decodeFailed(
                providerID: providerID,
                detail: "可灵查询任务响应缺少 data 数组：\(String(describing: json).prefix(300))"
            )
        }

        let status = (task["status"] as? String) ?? ""
        let phase: CloudTaskState.Phase
        switch status.lowercased() {
        case "submitted", "queued", "pending", "created", "init":
            phase = .queued
        case "processing", "running":
            phase = .running
        case "succeeded", "success", "completed", "done":
            phase = .succeeded
        case "failed", "failure", "error":
            phase = .failed
        case "canceled", "cancelled":
            phase = .canceled
        default:
            phase = .unknown
        }

        let message = (task["message"] as? String) ?? (json["message"] as? String)
        var videoURL: String?
        if let outputs = task["outputs"] as? [[String: Any]] {
            for output in outputs {
                let type = output["type"] as? String
                if type == nil || type == "video" {
                    if let url = output["url"] as? String, !url.isEmpty {
                        videoURL = url
                        break
                    }
                }
            }
        }
        if videoURL == nil {
            videoURL = task["url"] as? String
        }
        return CloudTaskState(phase: phase, message: message, videoURL: videoURL)
    }

    /// 当前可灵接入只证明 submit/poll 契约，未发现可核验的取消 action。
    public func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        .unsupported
    }

    // MARK: - 内部传输（Kling 特有：code 校验 + data 数组解析）

    /// 校验可灵业务码：code != 0 时返回 (code, message)，否则 nil。
    private static func vendorError(_ json: [String: Any]) -> (code: Int, message: String)? {
        guard let code = json["code"] as? Int, code != 0 else { return nil }
        let message = (json["message"] as? String) ?? "unknown error"
        return (code, message)
    }

    private static func authHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }

    private static func makeURL(path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        var components = URLComponents(string: baseURL)!
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw CloudBackendError.invalidURL(providerID: "kling", url: baseURL + path)
        }
        return url
    }

    private func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: [String: Any]?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let httpResponse = response as? HTTPURLResponse
            throw CloudBackendError.httpError(
                providerID: providerID,
                statusCode: statusCode,
                body: httpResponse.map { CloudVideoHTTP.bodyWithRetryAfter(bodyText, from: $0) } ?? bodyText
            )
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw CloudBackendError.decodeFailed(providerID: providerID, detail: snippet)
        }
        return json
    }
}
