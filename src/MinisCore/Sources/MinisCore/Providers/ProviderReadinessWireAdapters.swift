import Foundation

public enum ProviderReadinessWireAdapterError: Error, Equatable, Sendable {
    case unsupportedProtocol(ProviderWireProtocol)
    case missingModelID
    case malformedModelCatalog
    case malformedModelResponse
}

public protocol ProviderReadinessWireAdapter: Sendable {
    var protocolType: ProviderWireProtocol { get }

    func makeRequest(
        operation: ProviderReadinessTransportCall,
        baseURL: URL,
        modelID: String?,
        apiKey: String
    ) throws -> URLRequest

    func decodeModelCatalog(from data: Data) throws -> [ProviderReadinessModel]

    /// 目录请求：`afterID` 是上一页返回的游标。不分页的协议忽略它。
    func makeCatalogPageRequest(
        baseURL: URL,
        apiKey: String,
        afterID: String?
    ) throws -> URLRequest

    /// 目录还有下一页时返回游标（Anthropic：`has_more` 为真时的 `last_id`），否则 nil。
    func nextCatalogPageCursor(from data: Data) -> String?

    /// Inspect a successful minimal model response before readiness accepts it.
    /// Failures must be typed; provider response content never enters a report.
    func validateModelRequestResponse(from data: Data) throws
}

public extension ProviderReadinessWireAdapter {
    // Existing Chat Completions and Anthropic callers retain their prior
    // status-only behavior until their response contracts are separately scoped.
    func validateModelRequestResponse(from data: Data) throws {}

    func makeCatalogPageRequest(
        baseURL: URL,
        apiKey: String,
        afterID: String?
    ) throws -> URLRequest {
        try makeRequest(operation: .modelCatalog, baseURL: baseURL, modelID: nil, apiKey: apiKey)
    }

    func nextCatalogPageCursor(from data: Data) -> String? { nil }
}

public enum ProviderReadinessWireAdapterFactory {
    public static func make(
        for protocolType: ProviderWireProtocol,
        baseURL: URL? = nil
    ) -> any ProviderReadinessWireAdapter {
        switch protocolType {
        case .openaiCompatible:
            return OpenAICompatibleReadinessAdapter()
        case .openaiResponses:
            return OpenAIResponsesReadinessAdapter()
        case .anthropic:
            return AnthropicReadinessAdapter(usesDeepSeekCatalog: baseURL.map(isDeepSeekAnthropicBaseURL) ?? false)
        case .other:
            return UnsupportedReadinessAdapter(protocolType: .other)
        }
    }
}

/// The Responses runtime uses appendV1Suffix=true for custom providers. Add
/// `/v1` once, even when a caller saved that suffix explicitly, then use its
/// real `/responses` route. A `/models` catalog remains a required stage.
private func normalizedResponsesReadinessBaseURL(_ baseURL: URL) -> URL {
    let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard path != "v1", !path.hasSuffix("/v1") else { return baseURL }
    return baseURL.appendingPathComponent("v1")
}

private struct OpenAIResponsesReadinessAdapter: ProviderReadinessWireAdapter {
    let protocolType: ProviderWireProtocol = .openaiResponses

    func makeRequest(
        operation: ProviderReadinessTransportCall,
        baseURL: URL,
        modelID: String?,
        apiKey: String
    ) throws -> URLRequest {
        let normalizedBaseURL = normalizedResponsesReadinessBaseURL(baseURL)
        let headers = ["Authorization": "Bearer \(apiKey)"]
        switch operation {
        case .reachability, .authentication, .modelCatalog:
            return makeGETRequest(
                endpoint: normalizedBaseURL.appendingPathComponent("models"),
                headers: headers
            )
        case .modelRequest(let requestedModelID):
            guard let modelID = normalizedModelID(modelID ?? requestedModelID) else {
                throw ProviderReadinessWireAdapterError.missingModelID
            }
            let deepSeek = isDeepSeekReadinessBaseURL(baseURL, paths: ["", "/", "/v1", "/v1/"])
            var body: [String: Any] = [
                "model": modelID,
                "input": [[
                    "role": "user",
                    "content": [["type": "input_text", "text": deepSeek ? "Reply with only OK." : "ping"]]
                ]],
                "max_output_tokens": deepSeek ? 32 : readinessMinimalOutputTokens,
                "stream": false
            ]
            if deepSeek { body["reasoning"] = ["effort": "none"] }
            return try makePOSTRequest(
                endpoint: normalizedBaseURL.appendingPathComponent("responses"),
                headers: headers,
                body: body
            )
        }
    }

    func decodeModelCatalog(from data: Data) throws -> [ProviderReadinessModel] {
        let catalog: OpenAIModelCatalog
        do {
            try validateWireCatalogEnvelope(data)
            catalog = try JSONDecoder().decode(OpenAIModelCatalog.self, from: data)
        } catch {
            throw ProviderReadinessWireAdapterError.malformedModelCatalog
        }
        return try normalizedModels(catalog.data.map(\.id))
    }

    func validateModelRequestResponse(from data: Data) throws {
        do {
            guard data.count <= maxProviderModelCatalogBytes,
                  String(data: data, encoding: .utf8) != nil else {
                throw ProviderReadinessWireAdapterError.malformedModelResponse
            }
            var validator = JSONDuplicateKeyValidator(bytes: Array(data))
            try validator.validate()
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["status"] as? String == "completed",
                  response["output"] is [[String: Any]],
                  (response["error"] == nil || response["error"] is NSNull) else {
                throw ProviderReadinessWireAdapterError.malformedModelResponse
            }
            // The production non-streaming provider also uses this parser; a
            // 2xx chat-completions object or empty Responses output must fail.
            _ = try ResponsesAPIResponseParser.extractResponse(from: response)
        } catch {
            throw ProviderReadinessWireAdapterError.malformedModelResponse
        }
    }
}

// 真实中转站的模型目录可以很大（聚合类服务常有上千条），放宽到 16 MB / 5000 条。
private let maxProviderModelCatalogBytes = 16 * 1_048_576
private let maxProviderModelCatalogEntries = 5_000
private let maxProviderModelCatalogObjectKeys = 10_000
/// 就绪检查的最小对话请求：OpenAI Responses 要求输出上限不小于 16，三种协议统一用 16。
private let readinessMinimalOutputTokens = 16

public struct ProviderReadinessHTTPFailure: Error, Equatable, Sendable {
    public let statusCode: Int
    public let failureCategory: ProviderReadinessFailureCategory
    public let retryAfterSeconds: Int?
    public let redactedDetail: String

    public static func make(
        statusCode: Int,
        headers: [String: String],
        body _: String,
        secrets _: [String] = []
    ) -> ProviderReadinessHTTPFailure? {
        guard !(200..<300).contains(statusCode) else { return nil }

        // `body` and `secrets` remain source-compatible inputs for existing
        // callers, but are intentionally not read. The adapter retains only
        // status and Retry-After metadata, so no response/header payload can
        // enter readiness state.
        let classification = ProviderHTTPErrorAdapter.classify(
            statusCode: statusCode,
            headers: headers
        )

        return ProviderReadinessHTTPFailure(
            statusCode: statusCode,
            failureCategory: classification.category,
            retryAfterSeconds: classification.retryAfterSeconds,
            redactedDetail: "HTTP \(classification.statusCode)"
        )
    }
}

private struct OpenAICompatibleReadinessAdapter: ProviderReadinessWireAdapter {
    let protocolType: ProviderWireProtocol = .openaiCompatible

    func makeRequest(
        operation: ProviderReadinessTransportCall,
        baseURL: URL,
        modelID: String?,
        apiKey: String
    ) throws -> URLRequest {
        let normalizedBaseURL = normalizedOpenAICompatibleReadinessBaseURL(baseURL)
        let endpoint: URL
        switch operation {
        case .reachability:
            // DeepSeek's bare OpenAI-compatible host exposes the authenticated
            // catalog at `/models`; probing the bare host returns a misleading
            // 404 and makes the whole readiness chain fail before auth/model
            // discovery. Keep the historical root probe for generic proxies.
            endpoint = isDeepSeekBareHost(baseURL)
                ? normalizedBaseURL.appendingPathComponent(
                    DeepSeekProviderContract.ReadinessRoute.models.rawValue
                )
                : normalizedBaseURL
        case .authentication, .modelCatalog:
            endpoint = normalizedBaseURL.appendingPathComponent(
                DeepSeekProviderContract.ReadinessRoute.models.rawValue
            )
        case .modelRequest(let requestedModelID):
            guard let modelID = normalizedModelID(modelID ?? requestedModelID) else {
                throw ProviderReadinessWireAdapterError.missingModelID
            }
            endpoint = normalizedBaseURL.appendingPathComponent(
                DeepSeekProviderContract.ReadinessRoute.chatCompletions.rawValue
            )
            return try makePOSTRequest(
                endpoint: endpoint,
                headers: [
                    "Authorization": "Bearer \(apiKey)"
                ],
                body: [
                    "model": modelID,
                    "messages": [["role": "user", "content": "ping"]],
                    // 与对话请求同一规则（MC4-012）：OpenAI 官方端点与推理模型用 max_completion_tokens，其余兼容端点用 max_tokens。
                    OpenAIOutputCapField.name(endpointHost: baseURL.host, scheme: baseURL.scheme,
                        modelID: modelID): readinessMinimalOutputTokens,
                    "stream": false
                ]
            )
        }

        return makeGETRequest(
            endpoint: endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
    }

    func decodeModelCatalog(from data: Data) throws -> [ProviderReadinessModel] {
        let catalog: OpenAIModelCatalog
        do {
            try validateWireCatalogEnvelope(data)
            catalog = try JSONDecoder().decode(OpenAIModelCatalog.self, from: data)
        } catch {
            throw ProviderReadinessWireAdapterError.malformedModelCatalog
        }
        return try normalizedModels(catalog.data.map(\.id))
    }
}

/// Readiness callers store a provider base URL, so a bare OpenAI-compatible
/// host needs the conventional `/v1` prefix before the shared `models` and
/// `chat/completions` paths are appended. Existing `/v1` and custom paths are
/// preserved verbatim. The documented bare DeepSeek host is the one explicit
/// OpenAI-compatible exception: its paths are rooted directly at `/models`
/// and `/chat/completions`.
private func normalizedOpenAICompatibleReadinessBaseURL(_ baseURL: URL) -> URL {
    // DeepSeek documents `https://api.deepseek.com` as the base URL and does
    // not require the conventional `/v1` prefix for its readiness/chat paths.
    // An explicitly supplied path (including `/v1`) remains authoritative.
    guard !isDeepSeekBareHost(baseURL) else { return baseURL }
    guard OpenAICompatibleVersionPath.needsV1(baseURL.path) else { return baseURL }
    guard var components = URLComponents(
        url: baseURL,
        resolvingAgainstBaseURL: false
    ) else { return baseURL }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path + "/v1"
    return components.url ?? baseURL
}

/// OpenAI 兼容地址是否需要补 `/v1`：路径里没有任何版本段（v1、v1beta、v4、v2alpha…）时才补。
/// `https://host`、`https://openrouter.ai/api` → 补；`/v1`、`/v1beta/openai`（Gemini）、`/api/paas/v4`（智谱）→ 原样。
/// 对话请求与连接检查共用这一条规则。
enum OpenAICompatibleVersionPath {
    static func needsV1(_ path: String) -> Bool {
        !path.split(separator: "/").contains { segment in
            segment.range(of: "^v[0-9]+([a-z]+[0-9]*)?$", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

private func isDeepSeekBareHost(_ baseURL: URL) -> Bool {
    DeepSeekProviderContract.isCanonicalBaseURL(baseURL.absoluteString)
}

// Match only documented DeepSeek bases, preserving the configured origin. The
// shared contract supplies the canonical host/HTTPS/credential/query checks.
private func isDeepSeekReadinessBaseURL(_ baseURL: URL, paths: Set<String>) -> Bool {
    guard paths.contains(baseURL.path), baseURL.port == nil || baseURL.port == 443,
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return false }
    components.path = ""
    guard let origin = components.url else { return false }
    return DeepSeekProviderContract.isCanonicalBaseURL(origin.absoluteString)
}

private func isDeepSeekAnthropicBaseURL(_ baseURL: URL) -> Bool {
    isDeepSeekReadinessBaseURL(baseURL, paths: ["/anthropic", "/anthropic/", "/anthropic/v1", "/anthropic/v1/"])
}

private struct AnthropicReadinessAdapter: ProviderReadinessWireAdapter {
    let protocolType: ProviderWireProtocol = .anthropic
    let usesDeepSeekCatalog: Bool
    private let anthropicVersion = "2023-06-01"

    func makeRequest(
        operation: ProviderReadinessTransportCall,
        baseURL: URL,
        modelID: String?,
        apiKey: String
    ) throws -> URLRequest {
        let deepSeek = usesDeepSeekCatalog && isDeepSeekAnthropicBaseURL(baseURL)
        if deepSeek {
            switch operation {
            case .reachability, .authentication, .modelCatalog:
                guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                    throw ProviderReadinessWireAdapterError.malformedModelCatalog
                }
                components.path = DeepSeekProviderContract.modelsPath
                guard let endpoint = components.url else {
                    throw ProviderReadinessWireAdapterError.malformedModelCatalog
                }
                return makeGETRequest(endpoint: endpoint, headers: ["Authorization": "Bearer \(apiKey)"])
            case .modelRequest:
                break
            }
        }
        let endpoint: URL
        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": anthropicVersion
        ]
        // 与对话路径（AnthropicProvider）同一条规则：路径最后一段不是 v1 就补 /v1。
        let versionedBase = deepSeek ? baseURL : anthropicVersionedBaseURL(baseURL)

        switch operation {
        case .reachability:
            endpoint = baseURL
        case .authentication:
            endpoint = versionedBase.appendingPathComponent("models")
        case .modelCatalog:
            endpoint = anthropicCatalogEndpoint(baseURL: versionedBase, afterID: nil)
        case .modelRequest(let requestedModelID):
            guard let modelID = normalizedModelID(modelID ?? requestedModelID) else {
                throw ProviderReadinessWireAdapterError.missingModelID
            }
            endpoint = (deepSeek ? normalizedResponsesReadinessBaseURL(baseURL) : versionedBase)
                .appendingPathComponent("messages")
            return try makePOSTRequest(
                endpoint: endpoint,
                headers: headers,
                body: [
                    "model": modelID,
                    "max_tokens": readinessMinimalOutputTokens,
                    "messages": [["role": "user", "content": "ping"]]
                ]
            )
        }

        return makeGETRequest(endpoint: endpoint, headers: headers)
    }

    func makeCatalogPageRequest(
        baseURL: URL,
        apiKey: String,
        afterID: String?
    ) throws -> URLRequest {
        guard !(usesDeepSeekCatalog && isDeepSeekAnthropicBaseURL(baseURL)) else {
            return try makeRequest(operation: .modelCatalog, baseURL: baseURL, modelID: nil, apiKey: apiKey)
        }
        return makeGETRequest(
            endpoint: anthropicCatalogEndpoint(baseURL: anthropicVersionedBaseURL(baseURL), afterID: afterID),
            headers: ["x-api-key": apiKey, "anthropic-version": anthropicVersion]
        )
    }

    /// 对话路径（AnthropicProvider）的同一规则：去掉末尾斜杠后，最后一段不是 `v1` 就补 `/v1`。
    private func anthropicVersionedBaseURL(_ baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard var url = components.url else { return baseURL }
        if url.lastPathComponent != "v1" { url.appendPathComponent("v1") }
        return url
    }

    func nextCatalogPageCursor(from data: Data) -> String? {
        guard !usesDeepSeekCatalog,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["has_more"] as? Bool == true,
              let lastID = (root["last_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastID.isEmpty else { return nil }
        return lastID
    }

    /// 带 `limit=1000`（官方上限）拉模型列表；后续页用 `after_id` 翻页。
    private func anthropicCatalogEndpoint(baseURL: URL, afterID: String?) -> URL {
        let modelsURL = baseURL.appendingPathComponent("models")
        guard var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false) else {
            return modelsURL
        }
        var items = [URLQueryItem(name: "limit", value: "1000")]
        if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
        components.queryItems = items
        return components.url ?? modelsURL
    }

    func decodeModelCatalog(from data: Data) throws -> [ProviderReadinessModel] {
        if usesDeepSeekCatalog {
            // DeepSeek publishes the OpenAI catalog on its own origin; require
            // its typed envelope rather than accepting arbitrary id arrays.
            do {
                try validateWireCatalogEnvelope(data)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["object"] as? String == "list",
                      let entries = root["data"] as? [[String: Any]],
                      entries.allSatisfy({ $0["object"] as? String == "model" }) else {
                    throw ProviderReadinessWireAdapterError.malformedModelCatalog
                }
                return try OpenAICompatibleReadinessAdapter().decodeModelCatalog(from: data)
            } catch {
                throw ProviderReadinessWireAdapterError.malformedModelCatalog
            }
        }
        let catalog: AnthropicModelCatalog
        do {
            try validateWireCatalogEnvelope(data)
            catalog = try JSONDecoder().decode(AnthropicModelCatalog.self, from: data)
        } catch {
            throw ProviderReadinessWireAdapterError.malformedModelCatalog
        }
        return try normalizedModels(
            catalog.data
                .filter { $0.type == "model" }
                .map(\.id)
        )
    }
}

private struct UnsupportedReadinessAdapter: ProviderReadinessWireAdapter {
    let protocolType: ProviderWireProtocol

    func makeRequest(
        operation: ProviderReadinessTransportCall,
        baseURL: URL,
        modelID: String?,
        apiKey: String
    ) throws -> URLRequest {
        throw ProviderReadinessWireAdapterError.unsupportedProtocol(protocolType)
    }

    func decodeModelCatalog(from data: Data) throws -> [ProviderReadinessModel] {
        throw ProviderReadinessWireAdapterError.unsupportedProtocol(protocolType)
    }
}

private struct OpenAIModelCatalog: Decodable {
    let data: [OpenAIModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        // 中转站常在根上多带 success、code 等键，忽略即可，只要有 data 数组。
        guard keys.contains("data"),
              let dataKey = AnyCodingKey(stringValue: "data") else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected OpenAI catalog root keys"
            ))
        }
        let decodedData = try container.decode([OpenAIModel].self, forKey: dataKey)
        guard decodedData.count <= maxProviderModelCatalogEntries else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "OpenAI catalog exceeds entry limit"
            ))
        }
        data = decodedData
    }
}

private struct OpenAIModel: Decodable {
    let id: String
}

private struct AnthropicModelCatalog: Decodable {
    let data: [AnthropicModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys.contains("data"),
              let dataKey = AnyCodingKey(stringValue: "data") else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected Anthropic catalog root keys"
            ))
        }
        let decodedData = try container.decode([AnthropicModel].self, forKey: dataKey)
        guard decodedData.count <= maxProviderModelCatalogEntries else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Anthropic catalog exceeds entry limit"
            ))
        }
        data = decodedData
    }
}

private struct AnthropicModel: Decodable {
    let type: String
    let id: String
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private func validateWireCatalogEnvelope(_ data: Data) throws {
    guard data.count <= maxProviderModelCatalogBytes,
          String(data: data, encoding: .utf8) != nil else {
        throw ProviderReadinessWireAdapterError.malformedModelCatalog
    }

    var validator = JSONDuplicateKeyValidator(
        bytes: Array(data),
        maxObjectKeys: maxProviderModelCatalogObjectKeys
    )
    try validator.validate()
}

struct JSONDuplicateKeyValidator {
    private let bytes: [UInt8]
    private let maxDepth: Int
    private let maxObjectKeys: Int
    private let maxStringBytes: Int
    private let canonicalIntegerKeys: Set<String>
    private var index = 0

    init(
        bytes: [UInt8],
        maxDepth: Int = 64,
        maxObjectKeys: Int = 256,
        maxStringBytes: Int = 64 * 1024,
        canonicalIntegerKeys: Set<String> = []
    ) {
        self.bytes = bytes
        self.maxDepth = maxDepth
        self.maxObjectKeys = maxObjectKeys
        self.maxStringBytes = maxStringBytes
        self.canonicalIntegerKeys = canonicalIntegerKeys
    }

    mutating func validate() throws {
        try value(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw ValidationError.malformed }
    }

    private enum ValidationError: Error {
        case malformed
        case duplicateKey
    }

    private mutating func value(depth: Int) throws {
        skipWhitespace()
        guard let byte = peek else { throw ValidationError.malformed }
        guard depth <= maxDepth else { throw ValidationError.malformed }
        switch byte {
        case 0x7B:
            try object(depth: depth)
        case 0x5B:
            try array(depth: depth)
        case 0x22:
            _ = try string()
        case 0x74:
            try literal(Array("true".utf8))
        case 0x66:
            try literal(Array("false".utf8))
        case 0x6E:
            try literal(Array("null".utf8))
        case 0x2D, 0x30...0x39:
            try number()
        default:
            throw ValidationError.malformed
        }
    }

    private mutating func object(depth: Int) throws {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) { return }

        var keys = Set<String>()
        while true {
            skipWhitespace()
            let key = try string()
            guard keys.insert(key).inserted else {
                throw ValidationError.duplicateKey
            }
            guard keys.count <= maxObjectKeys else {
                throw ValidationError.malformed
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            if canonicalIntegerKeys.contains(key) {
                try canonicalInteger()
            } else {
                try value(depth: depth + 1)
            }
            skipWhitespace()
            if consumeIfPresent(0x7D) { return }
            try consume(0x2C)
        }
    }

    private mutating func array(depth: Int) throws {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) { return }

        while true {
            try value(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x5D) { return }
            try consume(0x2C)
        }
    }

    private mutating func string() throws -> String {
        let start = index
        try consume(0x22)
        while let byte = peek {
            switch byte {
            case 0x22:
                index += 1
                let token = Data(bytes[start..<index])
                guard let value = try? JSONSerialization.jsonObject(
                    with: token,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw ValidationError.malformed
                }
                guard value.utf8.count <= maxStringBytes else {
                    throw ValidationError.malformed
                }
                return value
            case 0x5C:
                index += 1
                guard let escaped = peek else { throw ValidationError.malformed }
                index += 1
                if escaped == 0x75 {
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy({
                              0x30...0x39 ~= $0 || 0x41...0x46 ~= $0 || 0x61...0x66 ~= $0
                          }) else {
                        throw ValidationError.malformed
                    }
                    index += 4
                }
            case 0x00...0x1F:
                throw ValidationError.malformed
            default:
                index += 1
            }
        }
        throw ValidationError.malformed
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        guard index + expected.count <= bytes.count,
              bytes[index..<(index + expected.count)].elementsEqual(expected) else {
            throw ValidationError.malformed
        }
        index += expected.count
    }

    private mutating func number() throws {
        _ = consumeIfPresent(0x2D)
        guard let first = peek else { throw ValidationError.malformed }
        if first == 0x30 {
            index += 1
        } else if 0x31...0x39 ~= first {
            index += 1
            while let byte = peek, 0x30...0x39 ~= byte { index += 1 }
        } else {
            throw ValidationError.malformed
        }

        if consumeIfPresent(0x2E) {
            guard let byte = peek, 0x30...0x39 ~= byte else {
                throw ValidationError.malformed
            }
            while let byte = peek, 0x30...0x39 ~= byte { index += 1 }
        }

        if consumeIfPresent(0x65) || consumeIfPresent(0x45) {
            _ = consumeIfPresent(0x2D) || consumeIfPresent(0x2B)
            guard let byte = peek, 0x30...0x39 ~= byte else {
                throw ValidationError.malformed
            }
            while let byte = peek, 0x30...0x39 ~= byte { index += 1 }
        }
    }

    private mutating func canonicalInteger() throws {
        guard let first = peek else {
            throw ValidationError.malformed
        }
        if first == 0x30 {
            index += 1
            return
        }
        guard 0x31...0x39 ~= first else {
            throw ValidationError.malformed
        }
        index += 1
        while let byte = peek, 0x30...0x39 ~= byte {
            index += 1
        }
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else { throw ValidationError.malformed }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard peek == expected else { return false }
        index += 1
        return true
    }
}

/// 连接检查的超时：本机和局域网的本地大模型冷启动常常很慢，放宽到 90 秒；远端服务约 30 秒。
func readinessTimeoutSeconds(for endpoint: URL) -> TimeInterval {
    guard let host = endpoint.host?.lowercased() else { return 30 }
    if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
        return 90
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4 {
        if parts[0] == 127 || parts[0] == 10
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) {
            return 90
        }
    }
    return 30
}

private func makeGETRequest(
    endpoint: URL,
    headers: [String: String]
) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = readinessTimeoutSeconds(for: endpoint)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    return request
}

private func makePOSTRequest(
    endpoint: URL,
    headers: [String: String],
    body: [String: Any]
) throws -> URLRequest {
    var request = makeGETRequest(endpoint: endpoint, headers: headers)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
}

private func normalizedModelID(_ raw: String) -> String? {
    let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return modelID.isEmpty ? nil : modelID
}

private func normalizedModels(_ rawIDs: [String]) throws -> [ProviderReadinessModel] {
    var seen = Set<Data>()
    var models: [ProviderReadinessModel] = []
    models.reserveCapacity(rawIDs.count)

    // 重复 ID 去重、空 ID 跳过；只有一个有效 ID 都没有才算目录异常。
    for rawID in rawIDs {
        guard let modelID = normalizedModelID(rawID),
              seen.insert(Data(modelID.utf8)).inserted else {
            continue
        }

        models.append(ProviderReadinessModel(id: modelID))
    }

    guard !models.isEmpty else {
        throw ProviderReadinessWireAdapterError.malformedModelCatalog
    }
    return models
}
