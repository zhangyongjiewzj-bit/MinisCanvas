import Foundation

/// Request rewriting required by ChatGPT plan usage through
/// `POST https://api.openai.com/v1/responses` (preview limitations page).
public enum ChatGPTAccountRequestPolicy {
    /// Fields the route rejects.
    static let unsupportedFields: [String] = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
        "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature",
        "top_logprobs", "top_p", "truncation", "user", "previous_response_id"
    ]
    /// Function tools are grouped in one namespace; calls echoed back carry the same namespace.
    static let toolNamespace = "minis_tools"

    public static func rewrite(_ body: inout [String: Any]) {
        for field in unsupportedFields { body.removeValue(forKey: field) }
        body["store"] = false
        body["stream"] = true

        if let input = body["input"] as? [[String: Any]] {
            body["input"] = input.compactMap(rewriteInputItem)
        }
        if let tools = body["tools"] as? [[String: Any]] {
            let functions = tools.filter { ($0["type"] as? String) == "function" || ($0["type"] as? String) == "custom" }
            if functions.isEmpty {
                body.removeValue(forKey: "tools")
            } else {
                body["tools"] = [[
                    "type": "namespace", "name": toolNamespace,
                    "description": "MinisCanvas 本地工具", "tools": functions
                ] as [String: Any]]
            }
        }
    }

    private static func rewriteInputItem(_ item: [String: Any]) -> [String: Any]? {
        var result = item
        // System-role items are rejected; developer messages are accepted.
        if result["role"] as? String == "system" { result["role"] = "developer" }
        if result["type"] as? String == "function_call" { result["namespace"] = toolNamespace }
        // Audio input is not supported on this route.
        if let parts = result["content"] as? [[String: Any]] {
            result["content"] = parts.map { part -> [String: Any] in
                guard part["type"] as? String == "input_audio" else { return part }
                return ["type": "input_text", "text": "[音频输入在 ChatGPT 账号模式下不受支持，已省略]"]
            }
        }
        return result
    }
}

/// Error codes of ChatGPT plan usage and the Chinese guidance shown for them.
public enum ChatGPTAccountErrors {
    public static func code(inBody data: Data) -> String? {
        guard !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data.prefix(16 * 1024))) as? [String: Any] else { return nil }
        if let nested = object["error"] as? [String: Any], let code = nested["code"] as? String { return code }
        if let code = object["code"] as? String { return code }
        return nil
    }

    /// Fixed local text only; server messages never enter the result.
    public static func llmError(code: String?) -> LLMError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .providerError(message: "ChatGPT 套餐的用量已达上限。可在设置里的 ChatGPT 账号卡片点“管理用量”查看，稍后再试或改用其他模型供应商。")
        case "subscription_sharing_usage_unavailable":
            return .transientError(message: "暂时无法确认 ChatGPT 套餐用量，请稍后重试。")
        case "subscription_sharing_user_unavailable":
            return .transientError(message: "暂时无法获取 ChatGPT 账号信息，请稍后重试。")
        case "subscription_sharing_user_not_eligible":
            return .providerError(message: "你的 ChatGPT 账号或工作区设置不允许在此应用使用套餐额度。请改用其他模型供应商。")
        case "subscription_sharing_unsupported_capability":
            return .providerError(message: "本次请求使用了 ChatGPT 套餐暂不支持的功能而被拒绝。请换用其他模型供应商，或关闭相关功能后重试。")
        case "subscription_sharing_route_not_supported":
            return .providerError(message: "ChatGPT 套餐不支持这种请求类型。")
        case "subscription_sharing_invalid_user":
            return .providerError(message: "ChatGPT 登录需要更新。请到“设置 → 模型供应商”重新登录 ChatGPT 账号。")
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .providerError(message: "本应用没有权限用你的 ChatGPT 账号执行该操作。请到 ChatGPT 设置 → 用量检查应用授权，或重新登录。")
        default:
            return nil
        }
    }

    /// 本地固定文案集合：上面各错误码与状态码对应的提示，加上登录会话自己的提示。
    private static let fixedGuidanceTexts: Set<String> = {
        let codes = [
            "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable",
            "subscription_sharing_user_unavailable", "subscription_sharing_user_not_eligible",
            "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported",
            "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized",
            "chatpass_v2_invalid_authorization_context"
        ]
        var errors = codes.compactMap { ChatGPTAccountErrors.llmError(code: $0) }
        errors += [401, 403, 503].compactMap { ChatGPTAccountErrors.llmError(statusCode: $0, body: Data()) }
        var texts = Set<String>()
        for error in errors {
            switch error {
            case .providerError(let message), .transientError(let message): texts.insert(message)
            default: break
            }
        }
        for failure in ChatGPTAccountError.allCases {
            if let description = failure.errorDescription { texts.insert(description) }
        }
        return texts
    }()

    /// 对话失败文案：错误本身就是 ChatGPT 账号的本地固定文案（用量上限、需重新登录、账号不符合条件等）时
    /// 原样返回，让界面直接说清原因；其他错误返回 nil，由调用方走通用文案。
    public static func fixedGuidance(for error: LLMError) -> String? {
        let message: String
        switch error {
        case .providerError(let text), .transientError(let text): message = text
        default: return nil
        }
        return fixedGuidanceTexts.contains(message) ? message : nil
    }

    /// 本机诊断摘要：状态码 + error.type/code/param（仅限形如标识符的短值）。
    /// 不含 error.message 和非 JSON 正文：服务端自由文本可能带用户内容，日志以 public 写入。
    public static func diagnosticSummary(statusCode: Int, body: Data) -> String {
        var parts = ["status=\(statusCode)"]
        if let object = (try? JSONSerialization.jsonObject(with: body.prefix(16 * 1024))) as? [String: Any] {
            let error = (object["error"] as? [String: Any]) ?? object
            for key in ["type", "code", "param"] {
                if let value = error[key] as? String, isIdentifierLike(value) { parts.append("\(key)=\(value)") }
            }
        }
        return parts.joined(separator: " ")
    }

    private static func isIdentifierLike(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 95 || $0 == 45 || $0 == 46
        }
    }

    /// Non-2xx before a stream opens. Unknown 429 stays a plain rate limit (nil = use the default mapping).
    public static func llmError(statusCode: Int, body: Data) -> LLMError? {
        if let mapped = llmError(code: code(inBody: body)) { return mapped }
        switch statusCode {
        case 401: return .providerError(message: "无法验证你的 ChatGPT 账号。请到“设置 → 模型供应商”重新登录。")
        case 403: return .providerError(message: "ChatGPT 套餐在当前地区或策略下不可用。请改用其他模型供应商。")
        case 503: return .transientError(message: "ChatGPT 套餐暂时不可用，请稍后重试。")
        default: return nil
        }
    }
}

/// Readiness probes for the ChatGPT account record: catalog is `models[].slug`, and the
/// minimal request must be streamed (`store:false`, `stream:true`, no output limit).
public struct ChatGPTAccountReadinessAdapter: ProviderReadinessWireAdapter {
    public let protocolType: ProviderWireProtocol = .openaiResponses
    public init() {}

    public func makeRequest(
        operation: ProviderReadinessTransportCall,
        baseURL: URL,
        modelID: String?,
        apiKey: String
    ) throws -> URLRequest {
        var request: URLRequest
        switch operation {
        case .reachability, .authentication, .modelCatalog:
            request = URLRequest(url: ChatGPTAccountEndpoints.models)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
        case .modelRequest(let requestedModelID):
            let model = (modelID ?? requestedModelID).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { throw ProviderReadinessWireAdapterError.missingModelID }
            var body: [String: Any] = [
                "model": model,
                "instructions": "Reply with OK.",
                "input": [["role": "user", "content": [["type": "input_text", "text": "ping"]]]]
            ]
            ChatGPTAccountRequestPolicy.rewrite(&body)
            request = URLRequest(url: ChatGPTAccountEndpoints.models.deletingLastPathComponent().appendingPathComponent("responses"))
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func decodeModelCatalog(from data: Data) throws -> [ProviderReadinessModel] {
        guard let models = ChatGPTAccountCatalog.decode(data), !models.isEmpty else {
            throw ProviderReadinessWireAdapterError.malformedModelCatalog
        }
        return models.map { ProviderReadinessModel(id: $0.slug) }
    }

    /// The streamed probe is accepted only when it reaches `response.completed`.
    public func validateModelRequestResponse(from data: Data) throws {
        guard data.count <= 4 * 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw ProviderReadinessWireAdapterError.malformedModelResponse
        }
        var completed = false
        for line in text.split(separator: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            if type == "response.failed" || type == "error" { throw ProviderReadinessWireAdapterError.malformedModelResponse }
            if type == "response.completed" { completed = true }
        }
        guard completed else { throw ProviderReadinessWireAdapterError.malformedModelResponse }
    }
}
