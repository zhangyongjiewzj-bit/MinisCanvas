import Foundation

/// Shared fail-closed admission for provider and text-envelope tool calls.
///
/// Tool-call fields originate outside the process and are later handed to the
/// approval and execution gates.  Keeping one bounded parser for the three
/// production ingress shapes prevents a missing field from becoming a
/// synthetic identity or an empty argument object.
public enum ProviderToolCallBoundary {
    public static let maximumCalls = 64
    public static let maximumIdentifierBytes = 256
    public static let maximumToolNameBytes = 256
    public static let maximumArgumentsBytes = 64 * 1024
    public static let maximumObjectKeys = 64
    public static let maximumArrayElements = 64
    public static let maximumNestingDepth = 8
    public static let maximumTotalStringBytes = 256 * 1024
    public static let maximumEnvelopeBytes = 256 * 1024

    /// Parse one OpenAI-compatible `tool_calls[]` item.  The wire type, ID,
    /// function name, and JSON object arguments are all mandatory.
    public static func parseOpenAI(_ item: [String: Any]) -> LLMToolCall? {
        guard item["type"] as? String == "function",
              let id = boundedIdentifier(item["id"], maximumBytes: maximumIdentifierBytes),
              let function = item["function"] as? [String: Any],
              let name = boundedIdentifier(function["name"], maximumBytes: maximumToolNameBytes),
              let rawArguments = function["arguments"] as? String,
              let arguments = parseArguments(rawArguments) else {
            return nil
        }
        return LLMToolCall(
            id: id,
            name: name,
            rawArguments: rawArguments,
            arguments: arguments
        )
    }

    /// Parse one Anthropic `tool_use` content block.  Anthropic IDs are
    /// normalized to the provider's accepted alphabet after bounded admission,
    /// preserving the historical re-injection behavior without accepting an
    /// absent or control-bearing identity.
    public static func parseAnthropic(_ item: [String: Any]) -> LLMToolCall? {
        guard item["type"] as? String == "tool_use",
              let rawID = boundedIdentifier(item["id"], maximumBytes: maximumIdentifierBytes),
              let name = boundedIdentifier(item["name"], maximumBytes: maximumToolNameBytes),
              let input = item["input"] as? [String: Any],
              validateInputObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              data.count <= maximumArgumentsBytes,
              let rawArguments = String(data: data, encoding: .utf8) else {
            return nil
        }
        let id = sanitizeAnthropicIdentifier(rawID)
        guard !id.isEmpty else { return nil }
        return LLMToolCall(id: id, name: name, rawArguments: rawArguments, arguments: input)
    }

    // MARK: Oversized arguments (V-6)

    /// 超限调用的固定工具错误：不带服务端或模型给的任何原文，由 AgentLoop 作为错误工具结果回给模型。
    public static let oversizedArgumentsToolResult =
        "[参数过大] 这次工具调用的参数超过单次上限（约 64KB，数组或对象最多 64 项），没有执行。"
        + "请把内容拆成多次较小的调用：长文件分段写入或分段编辑，批量参数分批传入。"
    /// 流式组装时给超限调用打的内部标记（候选字典里的键），仅在本文件的 admitting 解析里读取。
    static let oversizedMarkerKey = "_minis_arguments_oversized"

    private static func oversizedCall(id: String, name: String) -> LLMToolCall {
        var call = LLMToolCall(id: id, name: name, rawArguments: "{}", arguments: [:])
        call.argumentsExceedLimit = true
        return call
    }

    /// 与 `parseOpenAI` 相同；唯一区别：参数 JSON 合法但超出上限（或流式组装时已标记超限）的调用，
    /// 不再返回 nil，而是返回带 `argumentsExceedLimit` 的占位调用（参数为空对象）。
    /// 参数不是合法 JSON（例如被输出上限截断）仍返回 nil，保持原有处理。
    public static func parseOpenAIAdmittingOversized(_ item: [String: Any]) -> LLMToolCall? {
        if let call = parseOpenAI(item) { return call }
        guard item["type"] as? String == "function",
              let id = boundedIdentifier(item["id"], maximumBytes: maximumIdentifierBytes),
              let function = item["function"] as? [String: Any],
              let name = boundedIdentifier(function["name"], maximumBytes: maximumToolNameBytes) else {
            return nil
        }
        let raw = function["arguments"] as? String ?? ""
        guard item[oversizedMarkerKey] as? Bool == true || argumentsExceedLimits(raw) else { return nil }
        return oversizedCall(id: id, name: name)
    }

    /// 与 `parseAnthropic` 相同，超限处理同 `parseOpenAIAdmittingOversized`。
    public static func parseAnthropicAdmittingOversized(_ item: [String: Any]) -> LLMToolCall? {
        if let call = parseAnthropic(item) { return call }
        guard item["type"] as? String == "tool_use",
              let rawID = boundedIdentifier(item["id"], maximumBytes: maximumIdentifierBytes),
              let name = boundedIdentifier(item["name"], maximumBytes: maximumToolNameBytes) else {
            return nil
        }
        let id = sanitizeAnthropicIdentifier(rawID)
        guard !id.isEmpty else { return nil }
        var exceeds = item[oversizedMarkerKey] as? Bool == true
        if !exceeds, let input = item["input"] as? [String: Any] {
            exceeds = !validateInputObject(input)
                || ((try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                    .map { $0.count > maximumArgumentsBytes } ?? false)
        }
        return exceeds ? oversizedCall(id: id, name: name) : nil
    }

    /// 合法 JSON 对象、但超出字节或形状上限。
    private static func argumentsExceedLimits(_ raw: String) -> Bool {
        if raw.utf8.count > maximumArgumentsBytes { return true }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        return !validateInputObject(dictionary)
    }

    /// The legacy text protocol carries calls as an object containing a
    /// `tool_calls` array.  This parser intentionally returns a small boundary
    /// value so the agent loop can construct its existing `ParsedToolCall`.
    public struct TextCall: @unchecked Sendable {
        public let id: String
        public let name: String
        public let input: [String: Any]

        public init(id: String, name: String, input: [String: Any]) {
            self.id = id
            self.name = name
            self.input = input
        }
    }

    public static func parseTextEnvelopeCall(_ item: [String: Any]) -> TextCall? {
        guard let id = boundedIdentifier(item["id"], maximumBytes: maximumIdentifierBytes),
              let name = boundedIdentifier(item["name"], maximumBytes: maximumToolNameBytes),
              let input = item["input"] as? [String: Any],
              validateInputObject(input) else {
            return nil
        }
        return TextCall(id: id, name: name, input: input)
    }

    /// Parse a complete JSON argument string.  Top-level arrays, scalars,
    /// malformed JSON, and oversized or deeply nested values are rejected.
    public static func parseArguments(_ raw: String) -> [String: Any]? {
        guard raw.utf8.count <= maximumArgumentsBytes,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              validateInputObject(dictionary) else {
            return nil
        }
        return dictionary
    }

    public static func validateInputObject(_ object: [String: Any]) -> Bool {
        var budget = Budget()
        return walk(object, depth: 0, budget: &budget)
    }

    public static func boundedIdentifier(_ value: Any?, maximumBytes: Int) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { scalar in
                  scalar.value < 0x20 || scalar.value == 0x7F
              }) else {
            return nil
        }
        return value
    }

    public static func hasUniqueIdentifiers(_ calls: [LLMToolCall]) -> Bool {
        Set(calls.map(\.id)).count == calls.count
    }

    private struct Budget {
        var totalStringBytes = 0
        var nodeCount = 0

        mutating func consumeNode() -> Bool {
            nodeCount += 1
            return nodeCount <= 512
        }

        mutating func consumeString(_ value: String) -> Bool {
            let bytes = value.utf8.count
            guard bytes <= maximumArgumentsBytes else { return false }
            let (total, overflow) = totalStringBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumTotalStringBytes else { return false }
            totalStringBytes = total
            return true
        }
    }

    private static func walk(_ value: Any, depth: Int, budget: inout Budget) -> Bool {
        guard depth <= maximumNestingDepth, budget.consumeNode() else { return false }
        switch value {
        case let object as [String: Any]:
            guard object.count <= maximumObjectKeys else { return false }
            for (key, nested) in object {
                guard budget.consumeString(key), walk(nested, depth: depth + 1, budget: &budget) else {
                    return false
                }
            }
            return true
        case let array as [Any]:
            guard array.count <= maximumArrayElements else { return false }
            for nested in array {
                guard walk(nested, depth: depth + 1, budget: &budget) else { return false }
            }
            return true
        case let string as String:
            return budget.consumeString(string)
        case let number as NSNumber:
            return number.doubleValue.isFinite
        case is NSNull:
            return true
        default:
            return false
        }
    }

    private static func sanitizeAnthropicIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
    }
}
