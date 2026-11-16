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
