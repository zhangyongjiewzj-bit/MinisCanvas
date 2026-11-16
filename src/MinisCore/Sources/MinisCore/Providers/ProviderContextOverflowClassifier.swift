import Foundation

/// C2：识别 Provider 的“上下文超长”HTTP 错误。
///
/// 只回答是/否，不返回也不保留任何正文片段（与 ProviderHTTPErrorAdapter 的纪律一致）。
/// 判定只认固定特征，且必须是 400 与可解析的 JSON 错误体：
/// - OpenAI 兼容 / Responses：`error.code == "context_length_exceeded"`（设计稿与先例 b53f1e7e；
///   OpenAI 官方 error-codes 页未收录该 code，其他兼容端是否沿用该 code 未核实）。
/// - Anthropic：`error.type == "invalid_request_error"` 且 `error.message` 以 “prompt is too long” 开头
///   （官方 context-windows 页：输入本身超窗时返回 400 invalid_request_error “prompt is too long”；
///   “输入 + max_tokens 超窗”的旧模型校验错误措辞未核实，故不识别）。
enum ProviderContextOverflowClassifier {
    private static let maximumBodyBytes = 64 * 1024

    static func isOpenAIStyleOverflow(statusCode: Int, body: String) -> Bool {
        guard statusCode == 400, let error = errorObject(in: body) else { return false }
        return (error["code"] as? String) == "context_length_exceeded"
    }

    static func isAnthropicOverflow(statusCode: Int, body: String) -> Bool {
        guard statusCode == 400, let error = errorObject(in: body),
              (error["type"] as? String) == "invalid_request_error",
              let message = error["message"] as? String else { return false }
        return message.lowercased().hasPrefix("prompt is too long")
    }

    private static func errorObject(in body: String) -> [String: Any]? {
        let data = Data(body.utf8.prefix(maximumBodyBytes))
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["error"] as? [String: Any]
    }
}
