import Foundation

/// Chat Completions 请求里"输出上限"该用哪个字段名。
/// 对齐 OpenAI 官方语义：官方端点（api.openai.com）与推理模型（o 系列、gpt-5 系列）只认
/// `max_completion_tokens`；其余自定义兼容端点（各类网关、DeepSeek、通义等）普遍只认 `max_tokens`，默认用它。
enum OpenAIOutputCapField {
    static func name(endpointHost: String?, scheme: String?, modelID: String) -> String {
        if scheme?.lowercased() == "https", endpointHost?.lowercased() == "api.openai.com" {
            return "max_completion_tokens"
        }
        return isReasoningModel(modelID) ? "max_completion_tokens" : "max_tokens"
    }

    /// 取最后一个 "/" 之后的名字（兼容 `openai/gpt-5` 这类网关写法）；o1、o3、o4-mini、gpt-5.x 视为推理模型。
    static func isReasoningModel(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        let name = id.split(separator: "/").last.map(String.init) ?? id
        if name.hasPrefix("gpt-5") { return true }
        let chars = Array(name)
        return chars.count >= 2 && chars[0] == "o" && chars[1].isASCII && chars[1].isNumber
    }
}
