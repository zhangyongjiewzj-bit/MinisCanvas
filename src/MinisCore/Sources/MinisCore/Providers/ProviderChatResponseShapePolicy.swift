import Foundation

/// Bounds the JSON shape that the OpenAI-compatible response projector walks.
/// The body-size gate protects transport memory; this policy protects the
/// dynamic dictionary/array projection that follows JSONSerialization.
public enum ProviderChatResponseShapePolicyError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case invalidRootShape
    case nestingTooDeep
    case objectTooLarge
    case arrayTooLarge
    case stringTooLarge
    case stringBudgetExceeded
    case choicesTooMany
    case contentBlocksTooMany
    case toolCallsTooMany
    /// 流里（或 200 响应里）出现了只有 `error`、没有 `choices` 的错误帧。
    case upstreamErrorFrame

    public var errorDescription: String? {
        switch self {
        case .upstreamErrorFrame:
            return "Provider returned an error frame instead of a completion"
        case .invalidRootShape:
            return "Provider response shape is invalid"
        case .nestingTooDeep:
            return "Provider response shape is too deeply nested"
        case .objectTooLarge:
            return "Provider response object is too large"
        case .arrayTooLarge:
            return "Provider response array is too large"
        case .stringTooLarge:
            return "Provider response string is too large"
        case .stringBudgetExceeded:
            return "Provider response text budget was exceeded"
        case .choicesTooMany:
            return "Provider response contains too many choices"
        case .contentBlocksTooMany:
            return "Provider response contains too many content blocks"
        case .toolCallsTooMany:
            return "Provider response contains too many tool calls"
        }
    }

    public var description: String {
        errorDescription ?? "Provider response shape rejected"
    }
}

/// Shape limits for the OpenAI-compatible chat-completions projection.
public enum ProviderChatResponseShapePolicy {
    public static let maximumChoices = 64
    public static let maximumContentBlocks = 256
    public static let maximumToolCalls = 64
    public static let maximumObjectKeys = 256
    public static let maximumArrayElements = 256
    public static let maximumNestingDepth = 16
    public static let maximumStringBytes = 1 * 1024 * 1024
    public static let maximumTotalStringBytes = 4 * 1024 * 1024

    /// Validates the decoded JSON object before the provider projects dynamic
    /// choices, message content, media, and tool-call dictionaries.
    public static func validate(_ json: [String: Any]) throws {
        try validateNesting(json, depth: 0)

        // 兼容服务商在流中途发 {"error":{...}} 再接 [DONE]：不能当成正常结束（半截回答会被当成完整回复）。
        // 带 choices 的形态（如 finish_reason 为 error）仍走原有分支。
        if let error = json["error"], !(error is NSNull), json["choices"] == nil {
            throw ProviderChatResponseShapePolicyError.upstreamErrorFrame
        }

        if let rawChoices = json["choices"] {
            guard let choices = rawChoices as? [[String: Any]] else {
                throw ProviderChatResponseShapePolicyError.invalidRootShape
            }
            guard choices.count <= maximumChoices else {
                throw ProviderChatResponseShapePolicyError.choicesTooMany
            }
            for choice in choices {
                try validateChoice(choice)
            }
        }

        var budget = StringBudget()
        try walk(json, depth: 0, budget: &budget)
    }

    /// Check nesting before schema-specific casts can classify a deeply
    /// nested dynamic value as merely an invalid content shape. Oversized
    /// containers are left to the existing budget walk so their stable error
    /// categories keep their current precedence.
    private static func validateNesting(_ value: Any, depth: Int) throws {
        guard depth <= maximumNestingDepth else {
            throw ProviderChatResponseShapePolicyError.nestingTooDeep
        }
        switch value {
        case let object as [String: Any]:
            guard object.count <= maximumObjectKeys else { return }
            for nested in object.values {
                try validateNesting(nested, depth: depth + 1)
            }
        case let array as [Any]:
            guard array.count <= maximumArrayElements else { return }
            for nested in array {
                try validateNesting(nested, depth: depth + 1)
            }
        default:
            break
        }
    }

    private struct StringBudget {
        var totalBytes = 0

        mutating func consume(_ value: String) throws {
            let bytes = value.utf8.count
            guard bytes <= maximumStringBytes else {
                throw ProviderChatResponseShapePolicyError.stringTooLarge
            }
            let projected = totalBytes.addingReportingOverflow(bytes)
            guard !projected.overflow,
                  projected.partialValue <= maximumTotalStringBytes else {
                throw ProviderChatResponseShapePolicyError.stringBudgetExceeded
            }
            totalBytes = projected.partialValue
        }
    }

    private static func walk(
        _ value: Any,
        depth: Int,
        budget: inout StringBudget
    ) throws {
        guard depth <= maximumNestingDepth else {
            throw ProviderChatResponseShapePolicyError.nestingTooDeep
        }
        switch value {
        case let string as String:
            try budget.consume(string)
        case let object as [String: Any]:
            guard object.count <= maximumObjectKeys else {
                throw ProviderChatResponseShapePolicyError.objectTooLarge
            }
            for (key, nested) in object {
                try budget.consume(key)
                try walk(nested, depth: depth + 1, budget: &budget)
            }
        case let array as [Any]:
            guard array.count <= maximumArrayElements else {
                throw ProviderChatResponseShapePolicyError.arrayTooLarge
            }
            for nested in array {
                try walk(nested, depth: depth + 1, budget: &budget)
            }
        case is NSNumber, is NSNull:
            break
        default:
            throw ProviderChatResponseShapePolicyError.invalidRootShape
        }
    }

    private static func validateChoice(_ choice: [String: Any]) throws {
        if let message = choice["message"] {
            guard let message = message as? [String: Any] else {
                throw ProviderChatResponseShapePolicyError.invalidRootShape
            }
            try validateMessage(message)
        }
    }

    private static func validateMessage(_ message: [String: Any]) throws {
        if let content = message["content"] {
            if let blocks = content as? [[String: Any]] {
                guard blocks.count <= maximumContentBlocks else {
                    throw ProviderChatResponseShapePolicyError.contentBlocksTooMany
                }
            } else if !(content is String), !(content is NSNull) {
                throw ProviderChatResponseShapePolicyError.invalidRootShape
            }
        }
        if let images = message["images"] {
            guard let images = images as? [[String: Any]],
                  images.count <= maximumContentBlocks else {
                throw ProviderChatResponseShapePolicyError.contentBlocksTooMany
            }
        }
        if let toolCalls = message["tool_calls"] {
            guard let toolCalls = toolCalls as? [[String: Any]],
                  toolCalls.count <= maximumToolCalls else {
                throw ProviderChatResponseShapePolicyError.toolCallsTooMany
            }
        }
    }
}
