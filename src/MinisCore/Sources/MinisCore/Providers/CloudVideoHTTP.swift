import Foundation

// MARK: - 通用生视频 submit+poll 基础设施（M2g · 不绑定具体厂商 endpoint）
//
// 可灵 / 即梦等「提交任务 → 轮询 → 取结果 URL」的异步生视频后端共享同一套
// URLSession + JSON 传输与状态映射逻辑。各 Provider（KlingProvider /
// JimengProvider）接入时只需：
//   1. 按 API 文档构造 submit / query 的 URL（文档未到之前一律 TODO，不臆造）；
//   2. 调用 `submitTask` / `pollTask` 完成传输与解析；
//   3. 轮询循环与超时控制由 `CloudVideoGenerator.generateVideo`（协议扩展）
//      统一提供。
//
// 错误处理模式（与 CloudBackendError 对齐，供 generateVideo 统一抛出）：
//   - 未配置 API key   → .missingAPIKey（Provider 层拦截，不进 HTTP）
//   - URL 非法         → .invalidURL
//   - HTTP 非 2xx      → .httpError（含响应体，4xx 立即失败）
//   - JSON 解析失败    → .decodeFailed
//   - 任务失败/取消    → .taskFailed（generateVideo 轮询到终态时抛出）
//   - 轮询超时         → .pollTimeout（generateVideo 超过 timeout 抛出）
//
// 超时与重试策略：
//   - 提交（submit）用长超时（默认 120s）：厂商侧建任务可能较慢；
//   - 轮询（poll）用短超时（默认 30s）：单次查询应快速返回；
//   - 轮询间隔 pollInterval 与总超时 timeout 由 generateVideo 参数控制
//     （默认 5s / 600s）；
//   - 幂等性铁律：submit（POST，创建计费任务）绝对不重试 —— 5xx 时服务端
//     可能已创建任务但响应丢失，盲目重试会重复扣费。只有轮询 poll（GET，
//     只读）才允许重试。
//   - 瞬时故障重试仅用于 poll：5xx / 429 / URLError 网络抖动用
//     `withTransientRetry` 指数退避，默认最多 3 次；429 优先尊重服务端
//     `Retry-After` 头；4xx 与解析类错误不重试，立即上抛。
public enum CloudVideoHTTP {

    // MARK: - Submit（提交任务 → taskID）

    /// 提交生视频任务：POST JSON 到 `submitURL`，从响应 JSON 中提取任务 ID 返回。
    ///
    /// 任务 ID 字段名按 `taskIDKeys` 顺序查找（各厂商命名不同：
    /// `task_id` / `taskID` / `id`，也可能嵌套在 `data` 下）。
    ///
    /// - Parameters:
    ///   - submitURL: 提交 endpoint（由 Provider 按 API 文档构造）。
    ///   - headers: 鉴权等请求头（如 `Authorization: Bearer <key>`）。
    ///   - body: 请求体（prompt / image_url / aspect_ratio / duration / extraParams）。
    ///   - session: 可注入的 URLSession（测试用 URLProtocol mock 替换）。
    public static func submitTask(
        providerID: String,
        submitURL: URL,
        headers: [String: String],
        body: [String: Any],
        taskIDKeys: [String] = ["task_id", "taskID", "id"],
        session: URLSession = CloudHTTP.session,
        timeout: TimeInterval = 120
    ) async throws -> String {
        let json = try await send(
            providerID: providerID,
            method: "POST",
            url: submitURL,
            headers: headers,
            body: body,
            timeout: timeout,
            session: session
        )
        return try extractTaskID(providerID: providerID, json: json, keys: taskIDKeys)
    }

    /// 从提交响应 JSON 提取任务 ID：先查顶层，再查 `data` 嵌套；按 `keys` 顺序。
    static func extractTaskID(providerID: String, json: [String: Any], keys: [String]) throws -> String {
        if let id = firstString(json, keys: keys) {
            return id
        }
        throw CloudBackendError.decodeFailed(
            providerID: providerID,
            detail: "无法从提交响应提取任务 ID（查找字段 \(keys.joined(separator: "/"))）：\(String(describing: json).prefix(300))"
        )
    }

    // MARK: - Poll（查询状态 → CloudTaskState）

    /// 轮询一次任务状态：GET `queryURL`，把厂商状态字段映射为 `CloudTaskState.Phase`，
    /// 并从响应中提取结果视频 URL / 消息。
    ///
    /// 厂商状态取值各异（英文大写/小写/中文均有），通过 `queuedValues` /
    /// `runningValues` / `successValues` / `failedValues` / `canceledValues`
    /// 集合映射；未命中任何集合时归为 `.unknown`（generateVideo 继续轮询）。
    /// 结果 URL 字段按 `resultURLKeys` 顺序查找（顶层 / `data` 嵌套 /
    /// `videos` 数组首元素兜底）。
    ///
    /// - Parameters:
    ///   - queryURL: 查询 endpoint（由 Provider 按 API 文档构造，通常含 taskID）。
    ///   - taskID: 任务 ID（仅用于错误信息）。
    public static func pollTask(
        providerID: String,
        queryURL: URL,
        headers: [String: String],
        taskID: String,
        statusKey: String = "status",
        queuedValues: Set<String> = ["queued", "pending", "submitted", "created", "INIT", "排队中"],
        runningValues: Set<String> = ["running", "processing", "PROCESSING", "生成中"],
        successValues: Set<String> = ["succeeded", "success", "completed", "done", "SUCCEEDED", "已完成"],
        failedValues: Set<String> = ["failed", "failure", "error", "FAILED", "失败"],
        canceledValues: Set<String> = ["canceled", "cancelled", "CANCELED", "已取消"],
        resultURLKeys: [String] = ["video_url", "videoURL", "url", "result_url"],
        messageKeys: [String] = ["message", "msg", "error", "fail_reason", "reason"],
        session: URLSession = CloudHTTP.session,
        timeout: TimeInterval = 30
    ) async throws -> CloudTaskState {
        let json = try await send(
            providerID: providerID,
            method: "GET",
            url: queryURL,
            headers: headers,
            body: nil,
            timeout: timeout,
            session: session
        )
        return try parseTaskState(
            providerID: providerID,
            taskID: taskID,
            json: json,
            statusKey: statusKey,
            queuedValues: queuedValues,
            runningValues: runningValues,
            successValues: successValues,
            failedValues: failedValues,
            canceledValues: canceledValues,
            resultURLKeys: resultURLKeys,
            messageKeys: messageKeys
        )
    }

    /// 把厂商轮询响应 JSON 映射为 `CloudTaskState`（顶层与 `data` 嵌套都支持）。
    static func parseTaskState(
        providerID: String,
        taskID: String,
        json: [String: Any],
        statusKey: String,
        queuedValues: Set<String>,
        runningValues: Set<String>,
        successValues: Set<String>,
        failedValues: Set<String>,
        canceledValues: Set<String>,
        resultURLKeys: [String],
        messageKeys: [String]
    ) throws -> CloudTaskState {
        let status = firstString(json, keys: [statusKey]) ?? ""
        let phase: CloudTaskState.Phase
        if successValues.contains(status) {
            phase = .succeeded
        } else if failedValues.contains(status) {
            phase = .failed
        } else if canceledValues.contains(status) {
            phase = .canceled
        } else if runningValues.contains(status) {
            phase = .running
        } else if queuedValues.contains(status) {
            phase = .queued
        } else {
            phase = .unknown
        }

        var videoURL = firstString(json, keys: resultURLKeys)
        if videoURL == nil {
            // 兜底：videos 数组首元素的 url / video_url。
            if let videos = json["videos"] as? [[String: Any]], let first = videos.first {
                videoURL = firstString(first, keys: ["url", "video_url", "videoURL"])
            }
        }
        let message = firstString(json, keys: messageKeys)
        return CloudTaskState(phase: phase, message: message, videoURL: videoURL)
    }

    // MARK: - 瞬时故障重试（指数退避，仅供 poll 使用）

    /// 带指数退避的瞬时故障重试包装：5xx / 429 / URLError（网络抖动/超时）时重试，
    /// 4xx、解析失败等非瞬时错误立即上抛。默认最多 3 次、首延迟 1s。
    ///
    /// ⚠️ 幂等性铁律：本包装只能用于 poll（GET 只读查询）。**严禁**用它包装
    /// submit（POST 创建计费任务）—— 5xx 时服务端可能已建任务但响应丢失，
    /// 重试会重复创建任务导致重复扣费。
    ///
    /// 429 处理：优先尊重服务端 `Retry-After` 头（≈ 服务端建议等待秒数，
    /// 通过 `send` 编码进 httpError 的 body）；无该头时退化为指数退避。
    public static func withTransientRetry<T>(
        providerID: String,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as CloudBackendError {
                switch error {
                case .httpError(_, let code, let body) where code == 429:
                    // 429 限流：优先尊重服务端 Retry-After，否则指数退避。
                    guard attempt < maxRetries else { throw error }
                    attempt += 1
                    let delay = retryAfterSeconds(fromEncodedBody: body)
                        ?? baseDelay * pow(2.0, Double(attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                case .httpError(_, let code, _) where code >= 500:
                    guard attempt < maxRetries else { throw error }
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(baseDelay * pow(2.0, Double(attempt - 1)) * 1_000_000_000))
                default:
                    throw error
                }
            } catch let error as URLError {
                // URLSession reports request cancellation as URLError(.cancelled);
                // cancellation is terminal and must never re-enter poll retry.
                guard !ProviderCancellationPolicy.isCancellation(error) else { throw error }
                guard attempt < maxRetries else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(baseDelay * pow(2.0, Double(attempt - 1)) * 1_000_000_000))
            }
        }
    }

    // MARK: - 瞬时错误判定（供各 Provider 决定是否可重试）

    /// 判断 `CloudBackendError` 是否为可安全重试的瞬时错误（429 / 5xx / URLError）。
    /// 4xx、解析失败等非瞬时错误返回 false。
    ///
    /// 供 submit 路径防御性使用：跨 Provider 一致地让 submit 永不重试。
    public static func isTransient(_ error: Error) -> Bool {
        switch error {
        case let error as CloudBackendError:
            switch error {
            case .httpError(_, let code, _):
                return code == 429 || code >= 500
            default:
                return false
            }
        case let error as URLError:
            return !ProviderCancellationPolicy.isCancellation(error)
        default:
            return false
        }
    }

    // MARK: - Retry-After 解析

    /// 从 HTTPURLResponse 提取 `Retry-After` 秒数（支持 HTTP-date 与秒值两种格式）。
    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        // 秒值格式："5" / "1.5"
        if let seconds = Double(raw), seconds >= 0 { return seconds < 60 * 60 ? seconds : 60 * 60 }
        // HTTP-date 格式（RFC 1123）：如 "Wed, 21 Oct 2015 07:28:00 GMT"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let seconds = date.timeIntervalSinceNow
            return seconds > 0 ? min(seconds, 60 * 60) : 0
        }
        return nil
    }

    /// 把 `Retry-After` 编码进 httpError 的 body（供 `withTransientRetry` 读取）。
    /// 仅当 status 为 429 且存在 Retry-After 头时追加哨兵，避免污染普通错误消息。
    static func bodyWithRetryAfter(_ body: String, from response: HTTPURLResponse) -> String {
        guard let retryAfter = retryAfterSeconds(from: response) else { return body }
        return "\(body)\n[retry-after:\(Int(retryAfter))]"
    }

    /// 从编码后的 body 解析 `[retry-after:N]` 哨兵中的秒数。
    static func retryAfterSeconds(fromEncodedBody body: String) -> TimeInterval? {
        guard let range = body.range(of: "[retry-after:") else { return nil }
        let rest = body[range.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        return Double(rest[..<end])
    }

    // MARK: - 内部传输

    /// 发送请求并解析 JSON 字典；session 可注入（测试用 mock URLProtocol）。
    private static func send(
        providerID: String,
        method: String,
        url: URL,
        headers: [String: String],
        body: [String: Any]?,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
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
                body: httpResponse.map { Self.bodyWithRetryAfter(bodyText, from: $0) } ?? bodyText
            )
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw CloudBackendError.decodeFailed(providerID: providerID, detail: snippet)
        }
        return json
    }

    /// 按 keys 顺序在顶层 / `data` 嵌套中查找第一个非空字符串。
    private static func firstString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        if let data = json["data"] as? [String: Any] {
            for key in keys {
                if let value = data[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}
