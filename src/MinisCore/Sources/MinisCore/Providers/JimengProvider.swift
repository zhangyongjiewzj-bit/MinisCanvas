import Foundation
import CryptoKit

/// 即梦 Jimeng — 云端生视频 Provider（M2i · 已按火山引擎官方文档接入）。
///
/// API 规格来源（火山引擎「即梦AI」文档中心，已核对 2026-08）：
///   - 产品：即梦AI-视频生成3.0 Pro（文档 85621/1777001，接口文档）
///   - 接入形态：CVSync2Async 异步任务模式：
///       1. 提交任务 `POST https://visual.volcengineapi.com?Action=CVSync2AsyncSubmitTask&Version=2022-08-31`
///          Body：`req_key`（服务标识，如 `jimeng_ti2v_v30_pro`）、`prompt`（文生视频必选）、
///          `image_urls` / `binary_data_base64`（图生视频首帧，二选一）、`frames`（121=5s / 241=10s）、
///          `aspect_ratio`（16:9 / 4:3 / 1:1 / 3:4 / 9:16 / 21:9）、`seed`（可选）。
///          成功返回 `data.task_id`（外层 `code == 10000` 才有效）。
///       2. 查询任务 `POST ...?Action=CVSync2AsyncGetResult&Version=2022-08-31`
///          Body：`req_key` + `task_id`；返回 `data.status`：
///          `in_queue`（排队中）/ `generating`（生成中）/ `done`（完成，按外层 code&message
///          判断成败，成功时 `data.video_url` 为结果视频 URL，有效期 1 小时）/
///          `not_found`（未找到，可能是传播延迟，继续轮询）/ `expired`（任务过期，视为失败）。
///   - 鉴权：火山引擎签名 V4（HMAC-SHA256），本服务固定 Region=`cn-north-1`、Service=`cv`，
///     凭证为 AccessKey/SecretKey（不是 Bearer token）。签名实现见 `VolcSigner`。
///
/// 凭证解析（环境变量）：
///   - AccessKey：`JIMENG_ACCESS_KEY` / `VOLC_ACCESSKEY` / `VOLC_ACCESS_KEY`
///   - SecretKey：`JIMENG_SECRET_KEY` / `VOLC_SECRETKEY` / `VOLC_SECRET_KEY`
///   - 兼容旧骨架：`JIMENG_API_KEY` / `SEEDANCE_API_KEY`（API key 语义，已配置时计入
///     `resolvedAPIKey`；但真实鉴权仍要求 AK/SK，见 `isConfigured`）。
///
/// 同时实现 `LLMProvider` 仅为满足 `ProviderFactory` 注册制（Builder 返回
/// `any LLMProvider`）；本 provider 是生视频后端，LLM 聊天方法一律抛
/// `notImplemented` 错误，请通过 `CloudVideoGenerator` 能力使用。
public final class JimengProvider: CloudVideoGenerator, LLMProvider, @unchecked Sendable {
    public var capabilities: Set<ProviderCapability> { [.video] }
    // MARK: - 常量（按即梦AI-视频生成3.0 Pro 接口文档）

    /// 火山引擎视觉 API 公共接入点。
    public static let baseURL = "https://visual.volcengineapi.com"
    /// 提交任务 Action。
    public static let submitAction = "CVSync2AsyncSubmitTask"
    /// 查询任务 Action。
    public static let queryAction = "CVSync2AsyncGetResult"
    /// API 版本号（文档固定值）。
    public static let apiVersion = "2022-08-31"
    /// 本服务固定签名 Region。
    public static let region = "cn-north-1"
    /// 本服务固定签名 Service。
    public static let service = "cv"
    /// 默认服务标识（req_key，视频生成 3.0 Pro）。
    public static let defaultReqKey = "jimeng_ti2v_v30_pro"

    /// 兼容旧骨架的 API key 环境变量（Bearer 语义；真实鉴权见 AK/SK）。
    public static let apiKeyEnvVars: [String] = [
        "JIMENG_API_KEY",
        "SEEDANCE_API_KEY",
    ]
    /// AccessKey 环境变量解析顺序。
    public static let accessKeyEnvVars: [String] = [
        "JIMENG_ACCESS_KEY",
        "VOLC_ACCESSKEY",
        "VOLC_ACCESS_KEY",
    ]
    /// SecretKey 环境变量解析顺序。
    public static let secretKeyEnvVars: [String] = [
        "JIMENG_SECRET_KEY",
        "VOLC_SECRETKEY",
        "VOLC_SECRET_KEY",
    ]

    public let providerID = "jimeng"
    public let displayName = "即梦 (Jimeng)"

    /// 生视频模型 ID，即请求体里的 `req_key`（如 `jimeng_ti2v_v30_pro`）。
    public var modelID: String
    /// 兼容旧骨架：解析到的 API key（nil 表示未配置；真实鉴权用 AK/SK）。
    public let resolvedAPIKey: String?
    /// 火山引擎 AccessKey（签名凭证）。
    public let accessKey: String?
    /// 火山引擎 SecretKey（签名凭证）。
    public let secretKey: String?
    /// URLSession（测试可注入 mock URLProtocol）。
    var session: URLSession = CloudHTTP.session
    /// 本地参考图托管上传能力（P1-13）。nil = 无托管，本地路径参考图会被阻断并提示先上传。
    private let mediaHosting: (any MediaReferenceHosting)?

    /// LLMProvider 桩：供注册制工厂使用，聊天调用会抛 notImplemented。
    public var name: String { displayName }
    private var llmModel: LLMModel

    public init(
        apiKey: String? = nil,
        model: String = JimengProvider.defaultReqKey,
        accessKey: String? = nil,
        secretKey: String? = nil,
        mediaHosting: (any MediaReferenceHosting)? = nil
    ) {
        self.resolvedAPIKey = Self.resolveAPIKey(injected: apiKey)
        self.accessKey = Self.resolveAccessKey(injected: accessKey)
        self.secretKey = Self.resolveSecretKey(injected: secretKey)
        self.modelID = model
        self.llmModel = LLMModel(id: model, displayName: "即梦 (Jimeng)", provider: "Jimeng")
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

    /// 解析 AccessKey：注入值优先，其次按序查环境变量。
    public static func resolveAccessKey(injected: String?) -> String? {
        if let key = injected?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        for envVar in accessKeyEnvVars {
            if let key = EnvCredentials.apiKey(envVar: envVar) {
                return key
            }
        }
        return nil
    }

    /// 解析 SecretKey：注入值优先，其次按序查环境变量。
    public static func resolveSecretKey(injected: String?) -> String? {
        if let key = injected?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        for envVar in secretKeyEnvVars {
            if let key = EnvCredentials.apiKey(envVar: envVar) {
                return key
            }
        }
        return nil
    }

    /// 是否已配置凭证。兼容旧语义：注入/解析到 API key（`JIMENG_API_KEY` 系）即视为
    /// 已配置；真实请求（submit/poll）额外要求 AK/SK 签名凭证齐全，否则抛 missingAPIKey。
    public var isConfigured: Bool {
        if let key = resolvedAPIKey, !key.isEmpty { return true }
        guard let ak = accessKey, !ak.isEmpty, let sk = secretKey, !sk.isEmpty else { return false }
        return true
    }

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
            detail: "即梦是生视频后端，不支持 LLM 聊天；请通过 CloudVideoGenerator 使用"
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
            detail: "即梦是生视频后端，不支持 LLM 流式聊天"
        )
    }

    // MARK: - CloudVideoGenerator（已按即梦 API 文档实现）

    /// 提交生视频任务，返回 taskID（`data.task_id`）。
    ///
    /// 按文档组装 body：`req_key`（= modelID 或 request.modelOverride）、`prompt`、
    /// `image_urls`（图生视频首帧，request.imageURL）、`frames`（duration 5s→121 / 10s→241）、
    /// `aspect_ratio`（request.aspectRatio），extraParams 可覆盖/追加字段。
    public func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        try ensureConfigured()
        let reqKey = request.modelOverride ?? modelID
        // P1-13：参考图必须云端可访问——本地路径在此上传托管或阻断（见 MediaReferenceGate）。
        // 把关发生在组装 body 与 submit（计费任务创建）之前，本地路径绝不进云端请求体。
        // 首帧来源：request.imageURL 优先，其次 extraParams["image_urls"]（空串视为未提供）。
        let rawReference = Self.nonEmpty(request.imageURL) ?? Self.nonEmpty(request.extraParams["image_urls"])
        let imageURL = try await MediaReferenceGate.resolveForCloud(rawReference, hoster: mediaHosting)
        var body: [String: Any] = ["req_key": reqKey]
        if !request.prompt.isEmpty {
            body["prompt"] = request.prompt
        }
        if let imageURL {
            body["image_urls"] = [imageURL]
        }
        if let aspectRatio = request.aspectRatio, !aspectRatio.isEmpty {
            body["aspect_ratio"] = aspectRatio
        }
        if let duration = request.duration, let seconds = Int(duration), seconds > 0 {
            // 文档：帧数 = 24 * n + 1（n 为秒数，支持 5s / 10s）。
            body["frames"] = 24 * seconds + 1
        }
        // `image_urls` 由上方已把关的参考图独占：extraParams 不得绕过该关卡写入本地路径。
        for (key, value) in request.extraParams where key != "image_urls" {
            body[key] = value
        }

        // submit（POST 创建计费任务）绝不重试：5xx 时服务端可能已建任务但响应丢失，
        // 盲目重试会重复创建任务导致重复扣费。失败直接上抛，由调用方决定是否重试。
        // A canceled caller must not start the billable task-creation request.
        try Task.checkCancellation()
        let json = try await self.sendJSON(
            action: Self.submitAction,
            body: body,
            timeout: 120
        )
        try Self.ensureBusinessOK(json, providerID: providerID)
        return try CloudVideoHTTP.extractTaskID(providerID: providerID, json: json, keys: ["task_id"])
    }

    /// 轮询一次任务状态（文档 Action=CVSync2AsyncGetResult，同样为 POST）。
    ///
    /// 状态映射：`in_queue`/`not_found` → queued（继续轮询）；`generating` → running；
    /// `done`（code==10000）→ succeeded（带 video_url）；`expired` 或 `done` 但
    /// code!=10000 → failed（message 取自外层 message）。
    public func pollVideo(taskID: String) async throws -> CloudTaskState {
        try ensureConfigured()
        let body: [String: Any] = [
            "req_key": modelID,
            "task_id": taskID,
        ]
        try Task.checkCancellation()
        let json = try await CloudVideoHTTP.withTransientRetry(providerID: providerID) {
            try await self.sendJSON(
                action: Self.queryAction,
                body: body,
                timeout: 30
            )
        }

        // Buffered transports can return a response after cancellation; keep it terminal.
        try Task.checkCancellation()
        // 文档：优先判断 code == 10000，再判断 data.status。
        if let code = json["code"] as? Int, code != 10000 {
            let message = (json["message"] as? String) ?? "code=\(code)"
            let status = (json["data"] as? [String: Any])?["status"] as? String
            // done 但业务码非 10000 = 任务执行失败（如输出审核不过）；expired = 任务过期。
            if status == "done" || status == "expired" {
                return CloudTaskState(phase: .failed, message: message)
            }
            // 其余业务错误（参数错误/限流/内部错误等）立即上抛，不继续轮询。
            throw CloudBackendError.httpError(providerID: providerID, statusCode: 400, body: "code=\(code) \(message)")
        }

        return try CloudVideoHTTP.parseTaskState(
            providerID: providerID,
            taskID: taskID,
            json: json,
            statusKey: "status",
            queuedValues: ["in_queue", "not_found"],
            runningValues: ["generating"],
            successValues: ["done"],
            failedValues: ["expired"],
            canceledValues: [],
            resultURLKeys: ["video_url", "videoURL", "url"],
            messageKeys: ["message", "msg", "error"]
        )
    }

    /// 当前即梦接入只证明 submit/poll 契约，未发现可核验的取消 action。
    public func cancelVideo(taskID: String) async throws -> CloudVideoCancellationOutcome {
        .unsupported
    }

    // MARK: - 内部

    /// 空串/纯空白视为「未提供」，避免把空参考图当成有效引用。
    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    private func ensureConfigured() throws {
        guard isConfigured else {
            throw CloudBackendError.missingAPIKey(
                providerID: providerID,
                envVar: (Self.accessKeyEnvVars + Self.secretKeyEnvVars).joined(separator: " / ")
            )
        }
    }

    /// 文档约定：`code == 10000` 表示业务成功，否则 message 为错误信息。
    private static func ensureBusinessOK(_ json: [String: Any], providerID: String) throws {
        if let code = json["code"] as? Int, code != 10000 {
            let message = (json["message"] as? String) ?? "code=\(code)"
            throw CloudBackendError.httpError(providerID: providerID, statusCode: 400, body: "code=\(code) \(message)")
        }
    }

    /// 构造带签名头的 URL：`baseURL?Action=xxx&Version=yyyy-mm-dd`。
    private static func makeURL(action: String) throws -> URL {
        let urlString = "\(baseURL)?Action=\(action)&Version=\(apiVersion)"
        guard let url = URL(string: urlString) else {
            throw CloudBackendError.invalidURL(providerID: "jimeng", url: urlString)
        }
        return url
    }

    /// POST JSON 到即梦 API（火山引擎 V4 签名），返回解析后的 JSON 字典。
    private func sendJSON(action: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let ak = accessKey, let sk = secretKey else {
            throw CloudBackendError.missingAPIKey(
                providerID: providerID,
                envVar: (Self.accessKeyEnvVars + Self.secretKeyEnvVars).joined(separator: " / ")
            )
        }
        let url = try Self.makeURL(action: action)
        let query = "Action=\(action)&Version=\(Self.apiVersion)"
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let signer = VolcSigner(
            accessKey: ak,
            secretKey: sk,
            region: Self.region,
            service: Self.service,
            host: Self.baseURL.replacingOccurrences(of: "https://", with: "")
        )
        let signedHeaders = signer.headers(method: "POST", path: "/", query: query, body: bodyData)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = bodyData

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

// MARK: - 火山引擎签名 V4（HMAC-SHA256，Header 场景）

/// 火山引擎开放平台签名 V4 实现（对应文档「公共参数 - 签名参数 - 在Header中的场景」）。
///
/// 算法与 AWS SigV4 同构，差异：签名 Key 前缀为 `volcenginev4`，算法标识 `HMAC-SHA256`。
/// 签名参与项（canonical request）固定为：`content-type`、`host`、`x-content-sha256`、`x-date`。
/// 本 provider 的请求体均为 JSON（无 form），故无需额外参与项。
///
/// 参考：火山引擎「API 签名调用指南」（签名方法 V4）。
public struct VolcSigner: Sendable {
    public let accessKey: String
    public let secretKey: String
    public let region: String
    public let service: String
    public let host: String

    public init(accessKey: String, secretKey: String, region: String, service: String, host: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
        self.host = host
    }

    /// 生成签名请求头：`x-date`、`x-content-sha256`、`Authorization`。
    /// - Parameter xDate: 可注入固定时间（格式 `yyyyMMdd'T'HHmmss'Z'`），默认当前 UTC 时间（测试用）。
    public func headers(
        method: String,
        path: String,
        query: String,
        body: Data,
        xDate: String? = nil
    ) -> [String: String] {
        let date = xDate ?? Self.currentXDate()
        let bodyHash = Self.sha256Hex(body)
        let canonicalHeaders = Self.canonicalHeaders(contentType: "application/json", host: host, bodyHash: bodyHash, xDate: date)
        let signedHeaders = Self.signedHeadersList
        let canonicalRequest = "\(method)\n\(path)\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(bodyHash)"
        let scope = "\(date.prefix(8))/\(region)/\(service)/request"
        let stringToSign = "HMAC-SHA256\n\(date)\n\(scope)\n\(Self.sha256Hex(Data(canonicalRequest.utf8)))"
        let signature = Self.signature(secretKey: secretKey, region: region, service: service, stringToSign: stringToSign, date: String(date.prefix(8)))
        let authorization = "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return [
            "x-date": date,
            "x-content-sha256": bodyHash,
            "Authorization": authorization,
        ]
    }

    /// 计算签名（独立暴露，供测试做 known-answer 校验）。
    public func signature(
        method: String,
        path: String,
        query: String,
        body: Data,
        xDate: String
    ) -> String {
        let bodyHash = Self.sha256Hex(body)
        let canonicalHeaders = Self.canonicalHeaders(contentType: "application/json", host: host, bodyHash: bodyHash, xDate: xDate)
        let canonicalRequest = "\(method)\n\(path)\n\(query)\n\(canonicalHeaders)\n\(Self.signedHeadersList)\n\(bodyHash)"
        let scope = "\(xDate.prefix(8))/\(region)/\(service)/request"
        let stringToSign = "HMAC-SHA256\n\(xDate)\n\(scope)\n\(Self.sha256Hex(Data(canonicalRequest.utf8)))"
        return Self.signature(secretKey: secretKey, region: region, service: service, stringToSign: stringToSign, date: String(xDate.prefix(8)))
    }

    // MARK: - 签名算法（与火山引擎文档一致）

    /// 参与签名的 header 列表（按字母序）。
    public static let signedHeadersList = "content-type;host;x-content-sha256;x-date"

    private static func canonicalHeaders(contentType: String, host: String, bodyHash: String, xDate: String) -> String {
        "content-type:\(contentType)\nhost:\(host)\nx-content-sha256:\(bodyHash)\nx-date:\(xDate)\n"
    }

    /// 签名 Key 派生：volcenginev4+SK → date → region → service → "request"。
    static func signingKey(secretKey: String, region: String, service: String, date: String) -> Data {
        let kDate = hmacSHA256(key: Data(("volcenginev4" + secretKey).utf8), message: Data(date.utf8))
        let kRegion = hmacSHA256(key: kDate, message: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, message: Data(service.utf8))
        return hmacSHA256(key: kService, message: Data("request".utf8))
    }

    static func signature(secretKey: String, region: String, service: String, stringToSign: String, date: String) -> String {
        let key = signingKey(secretKey: secretKey, region: region, service: service, date: date)
        return hmacSHA256(key: key, message: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
        return Data(mac)
    }

    /// 当前 UTC 时间，格式 `yyyyMMdd'T'HHmmss'Z'`。
    static func currentXDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}
