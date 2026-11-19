import Foundation

/// C2：识别 Provider 的“上下文超长”HTTP 错误。
///
/// 只回答是/否，不返回也不保留任何正文片段（与 ProviderHTTPErrorAdapter 的纪律一致）。
/// 判定只认固定特征：413 一律算请求太大（不看正文，网关常返回 HTML 或纯文本）；400 须带可解析的 JSON 错误体；
/// 除下列 code / 开头外，也认 `overflowPhrases` 里的 message 固定写法：
/// - OpenAI 兼容 / Responses：`error.code == "context_length_exceeded"`（设计稿与先例 b53f1e7e；
///   OpenAI 官方 error-codes 页未收录该 code，其他兼容端是否沿用该 code 未核实）。
/// - Anthropic：`error.type == "invalid_request_error"` 且 `error.message` 以 “prompt is too long” 开头
///   （官方 context-windows 页：输入本身超窗时返回 400 invalid_request_error “prompt is too long”；
///   较新模型对“输入 + max_tokens 超窗”回的说明写作 “input length and `max_tokens` exceed context limit: …”，
///   见 `overflowPhrases` 里的 "exceed context limit"）。
enum ProviderContextOverflowClassifier {
    private static let maximumBodyBytes = 64 * 1024

    /// 兼容端不沿用 `context_length_exceeded` 这个 code，只在 message 里写原因时的固定写法
    /// （只用于 400 / 413，匹配时不区分大小写）：
    /// - "maximum context length"：OpenAI、DeepSeek、vLLM 系（"This model's maximum context length is N tokens"）。
    /// - "exceeds the context window"：OpenAI Responses（"Your input exceeds the context window of this model"）。
    /// - "range of input length should be"：通义 DashScope 兼容模式（"Range of input length should be [1, N]"）。
    /// - "exceeded max context length"：Ollama（"prompt too long; exceeded max context length by N tokens"）。
    /// - "prompt is too long"：Anthropic，及转发 Anthropic 报错的网关。
    private static let overflowPhrases = [
        "maximum context length",
        "exceeds the context window",
        "range of input length should be",
        "exceeded max context length",
        "prompt is too long",
        // Anthropic：输入加 max_tokens 超过窗口（"input length and `max_tokens` exceed context limit"）。
        "exceed context limit",
        // 请求体字节过大（历史里的图片/音频太多）：同样走“压缩或省略较早媒体后重试”。
        "maximum allowed number of bytes",
        "request body is too large",
        "payload too large",
    ]

    static func isOpenAIStyleOverflow(statusCode: Int, body: String) -> Bool {
        // 413 本身就是“请求体太大”：网关（nginx、CDN）常返回 HTML 或纯文本，不看正文。
        if statusCode == 413 { return true }
        guard statusCode == 400, let error = errorObject(in: body) else { return false }
        if (error["code"] as? String) == "context_length_exceeded" { return true }
        return messageIndicatesOverflow(error["message"] as? String)
    }

    static func isAnthropicOverflow(statusCode: Int, body: String) -> Bool {
        // Anthropic 请求体超过字节上限：413 + request_too_large；网关返回的 HTML / 纯文本 413 同样是请求太大。
        if statusCode == 413 { return true }
        guard statusCode == 400, let error = errorObject(in: body) else { return false }
        guard (error["type"] as? String) == "invalid_request_error" else { return false }
        return messageIndicatesOverflow(error["message"] as? String)
    }

    private static func messageIndicatesOverflow(_ message: String?) -> Bool {
        guard let lowered = message?.lowercased() else { return false }
        return overflowPhrases.contains { lowered.contains($0) }
    }

    private static func errorObject(in body: String) -> [String: Any]? {
        let data = Data(body.utf8.prefix(maximumBodyBytes))
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["error"] as? [String: Any]
    }
}
