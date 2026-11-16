import Foundation

/// Gimage2 — 云端生图 Provider（OpenAI Images API 兼容风格）。
///
/// 请求走 `POST {base}/v1/images/generations`，payload 与 OpenAI
/// `images.generate` 兼容：`{ model, prompt, n, size, response_format: "b64_json" }`，
/// 模型 ID 固定为 `gpt-image-2-official`。响应解析 OpenAI Images 格式：
/// `{ data: [ { b64_json } | { url } ] }`，统一映射为 `CloudMediaItem`。
///
/// API key 解析链：注入 key → `HERMES_CUSTOM_IMAGE2_API_KEY` →
/// `IMAGE2_API_KEY` → `GIMAGE2_API_KEY`（环境变量）。
///
/// TODO(待实测): `gpt-image-2-official` 的确切端点/响应格式以实际服务方文档为准。
/// 若服务方提供自定义 base URL，请设置环境变量 `HERMES_CUSTOM_IMAGE2_BASE_URL`
///（含 /v1 时自动去重）；默认回落到 OpenAI 官方 Images 端点。
///
/// 同时实现 `LLMProvider` 仅为满足 `ProviderFactory` 注册制（Builder 返回
/// `any LLMProvider`）；本 provider 是生图后端，LLM 聊天方法一律抛
/// `notImplemented` 错误，请通过 `CloudImageGenerator` 能力使用。
public final class Gimage2Provider: CloudImageGenerator, LLMProvider, @unchecked Sendable {
    public var capabilities: Set<ProviderCapability> { [.image] }
    public static let defaultBaseURL = "https://api.openai.com"
    public static let defaultModel = "gpt-image-2-official"
    /// API key 环境变量解析顺序。
    public static let apiKeyEnvVars: [String] = [
        "HERMES_CUSTOM_IMAGE2_API_KEY",
        "IMAGE2_API_KEY",
        "GIMAGE2_API_KEY",
    ]

    public let providerID = "gimage2"
    public let displayName = "Gimage2"

    /// 生图模型 ID（OpenAI Images API 的 model 字段）。
    public var modelID: String
    public var baseURL: String
    /// 当前解析到的 API key（nil 表示未配置）。
    public let resolvedAPIKey: String?
    /// 本地参考图托管上传能力（P1-13）。nil = 无托管，本地路径参考图会被阻断并提示先上传。
    private let mediaHosting: (any MediaReferenceHosting)?

    /// LLMProvider 桩：供注册制工厂使用，聊天调用会抛 notImplemented。
    public var name: String { displayName }
    private var llmModel: LLMModel

    /// URLSession（测试可注入 mock URLProtocol）；默认复用 CloudHTTP 共享会话
    /// （含 ProviderRedirectGuard 重定向守卫），与 JimengProvider 的同名注入点一致。
    var session: URLSession = CloudHTTP.session

    public init(apiKey: String? = nil, model: String = Gimage2Provider.defaultModel,
                baseURL: String? = nil,
                mediaHosting: (any MediaReferenceHosting)? = nil) {
        self.resolvedAPIKey = Self.resolveAPIKey(injected: apiKey)
        self.modelID = model
        self.baseURL = baseURL ?? EnvCredentials.value(for: "HERMES_CUSTOM_IMAGE2_BASE_URL")
            ?? Gimage2Provider.defaultBaseURL
        self.llmModel = LLMModel(id: model, displayName: "Gimage2", provider: "Gimage2")
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

    // MARK: - LLMProvider (桩 — 生图 Provider 不支持聊天)

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
            detail: "Gimage2 是生图后端，不支持 LLM 聊天；请通过 CloudImageGenerator.generateImage 使用"
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
            detail: "Gimage2 是生图后端，不支持 LLM 流式聊天"
        )
    }

    /// 构造 OpenAI Images API 请求体（供测试与后续兼容调整复用）。
    /// imageURL 为图生图（img2img）参考图：调用方（`generateImage`）必须先经
    /// `MediaReferenceGate` 把关，只允许传入云端可访问 URL（P1-13）；
    /// 以 `image` 字段并入 payload（OpenAI 兼容生图端点惯用 `image` 字段承载参考图；
    /// 具体字段名以中转站文档为准）。
    static func buildRequestBody(model: String, prompt: String, n: Int, size: String?, imageURL: String? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": max(1, n),
            "response_format": "b64_json",
        ]
        if let size, !size.isEmpty {
            body["size"] = size
        }
        if let imageURL, !imageURL.isEmpty {
            body["image"] = imageURL
        }
        return body
    }

    // MARK: - CloudImageGenerator

    public func generateImage(_ request: CloudImageRequest) async throws -> CloudImageResult {
        guard let key = resolvedAPIKey else {
            throw CloudBackendError.missingAPIKey(providerID: providerID, envVar: Self.apiKeyEnvVars.joined(separator: " / "))
        }
        let model = request.modelOverride ?? modelID
        // P1-13：参考图必须云端可访问——本地路径/file:///data: 引用在此上传托管或
        // 阻断（见 MediaReferenceGate），且发生在组装 body 与计费请求之前。
        // 参考图来源：request.imageURL 优先，其次 extraParams["image"]（空/纯空白视为未提供），
        // 使 extraParams 不能绕过关卡把同一 body 键写成本地路径。
        let rawReference = Self.nonEmpty(request.imageURL) ?? Self.nonEmpty(request.extraParams["image"])
        let referenceURL = try await MediaReferenceGate.resolveForCloud(rawReference, hoster: mediaHosting)
        var body = Self.buildRequestBody(
            model: model,
            prompt: request.prompt,
            n: request.count,
            size: request.size,
            imageURL: referenceURL
        )
        if let negative = request.negativePrompt, !negative.isEmpty {
            body["negative_prompt"] = negative
        }
        // `image` 由上方已把关的参考图独占：extraParams 不得再写入该键。
        for (k, v) in request.extraParams where k != "image" { body[k] = v }

        // S4：自定义 base URL 必须通过 scheme/host 校验（https，或显式
        // loopback http；不得内嵌凭据），否则 fail-closed，不把 Bearer 发往不安全目的地。
        do {
            _ = try CustomProviderURL.validate(baseURL)
        } catch let failure as CustomProviderURL.Failure {
            throw CloudBackendError.invalidURL(
                providerID: providerID,
                url: "unsafe custom base URL: \(failure.localizedDescription)"
            )
        }
        let url = URLBuilding.joinURL(baseURL, "/v1", "/images/generations")
        guard let url else {
            throw CloudBackendError.invalidURL(providerID: providerID, url: "\(baseURL)/v1/images/generations")
        }

        // A canceled caller must not start the billable image-generation request.
        try Task.checkCancellation()
        let json = try await postJSON(
            url: url,
            headers: ["Authorization": "Bearer \(key)"],
            body: body
        )

        return try Self.parseImageResponse(providerID: providerID, model: model, json: json)
    }

    /// POST JSON（与 `CloudHTTP.postJSON` 语义一致，见 CloudBackendsShared.swift:293：
    /// 同超时 120s、sortedKeys JSON 编码、非 2xx 抛 httpError、解析失败抛 decodeFailed），
    /// 但走本 provider 可注入的 `session`，使测试能确证出站请求数
    /// （注入点先例：JimengProvider.swift:80/330）。
    private func postJSON(url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw CloudBackendError.httpError(providerID: providerID, statusCode: statusCode, body: bodyText)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            throw CloudBackendError.decodeFailed(providerID: providerID, detail: snippet)
        }
        return json
    }

    /// 空串/纯空白参考图视为「未提供」（空串视为未设置的同文件先例：resolveAPIKey 的空白过滤, :63）。
    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    /// 解析 OpenAI Images 格式响应 `{ created, data: [{ b64_json | url, revised_prompt }] }`。
    static func parseImageResponse(providerID: String, model: String, json: [String: Any]) throws -> CloudImageResult {
        guard let data = json["data"] as? [[String: Any]] else {
            throw CloudBackendError.decodeFailed(
                providerID: providerID,
                detail: "missing data array in response: \(String(describing: json).prefix(300))"
            )
        }
        var items: [CloudMediaItem] = []
        for entry in data {
            if let b64 = entry["b64_json"] as? String, !b64.isEmpty {
                items.append(CloudMediaItem(base64Data: b64, mimeType: "image/png"))
            } else if let url = entry["url"] as? String, !url.isEmpty {
                items.append(CloudMediaItem(url: url))
            }
        }
        guard !items.isEmpty else {
            throw CloudBackendError.decodeFailed(
                providerID: providerID,
                detail: "no image data entries in response: \(String(describing: json).prefix(300))"
            )
        }
        let revised = data.first(where: { ($0["revised_prompt"] as? String) != nil })?["revised_prompt"] as? String
        return CloudImageResult(providerID: providerID, model: model, images: items, revisedPrompt: revised)
    }
}
