import Foundation

/// Bounds one decoded Anthropic SSE event before the stream decoder projects
/// content blocks, text deltas, and tool-input fragments.
public enum ProviderAnthropicResponseShapePolicyError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case invalidEventShape
    case eventNestingTooDeep
    case eventObjectTooLarge
    case eventArrayTooLarge
    case eventStringTooLarge
    case eventStringBudgetExceeded
    case contentBlocksTooMany
    case toolInputTooDeep
    case toolInputTooLarge
    case toolInputFragmentTooLarge
    case toolInputStructureTooComplex

    public var errorDescription: String? {
        switch self {
        case .invalidEventShape:
            return "Anthropic stream event shape is invalid"
        case .eventNestingTooDeep:
            return "Anthropic stream event is too deeply nested"
        case .eventObjectTooLarge:
            return "Anthropic stream event object is too large"
        case .eventArrayTooLarge:
            return "Anthropic stream event array is too large"
        case .eventStringTooLarge:
            return "Anthropic stream event string is too large"
        case .eventStringBudgetExceeded:
            return "Anthropic stream event text budget was exceeded"
        case .contentBlocksTooMany:
            return "Anthropic stream contains too many content blocks"
        case .toolInputTooDeep:
            return "Anthropic tool input is too deeply nested"
        case .toolInputTooLarge:
            return "Anthropic tool input is too large"
        case .toolInputFragmentTooLarge:
            return "Anthropic tool input fragment is too large"
        case .toolInputStructureTooComplex:
            return "Anthropic tool input structure is too complex"
        }
    }

    public var description: String {
        errorDescription ?? "Anthropic stream event rejected"
    }
}

/// Shape and projection limits for a single decoded Anthropic SSE event.
public enum ProviderAnthropicResponseShapePolicy {
    public static let maximumEventNestingDepth = 16
    public static let maximumContentBlocks = 64
    public static let maximumObjectKeys = 256
    public static let maximumArrayElements = 256
    public static let maximumStringBytes = 256 * 1024
    public static let maximumTotalStringBytes = 512 * 1024

    public static let maximumToolInputNestingDepth = 8
    public static let maximumToolInputObjectKeys = 64
    public static let maximumToolInputArrayElements = 64
    public static let maximumToolInputStringBytes = 64 * 1024
    public static let maximumToolInputTotalStringBytes = 256 * 1024
    public static let maximumToolInputFragmentBytes = 64 * 1024
    public static let maximumToolInputStructuralTokens = 512

    /// Validates the decoded JSON object before `AnthropicStreamDecoder`
    /// projects this event's content, text, usage, or tool-input fields.
    public static func validate(_ event: [String: Any]) throws {
        guard let type = event["type"] as? String, !type.isEmpty else {
            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
        }

        try validateContentContainers(in: event)
        try validateToolInputFields(in: event)

        var budget = StringBudget(
            maximumStringBytes: maximumStringBytes,
            maximumTotalStringBytes: maximumTotalStringBytes,
            stringTooLarge: .eventStringTooLarge,
            budgetExceeded: .eventStringBudgetExceeded
        )
        try walk(event, depth: 0, budget: &budget)
    }

    private struct StringBudget {
        var maximumStringBytes: Int
        var maximumTotalStringBytes: Int
        var stringTooLarge: ProviderAnthropicResponseShapePolicyError
        var budgetExceeded: ProviderAnthropicResponseShapePolicyError
        var totalBytes = 0

        mutating func consume(_ value: String) throws {
            let bytes = value.utf8.count
            guard bytes <= maximumStringBytes else {
                throw stringTooLarge
            }
            let projected = totalBytes.addingReportingOverflow(bytes)
            guard !projected.overflow,
                  projected.partialValue <= maximumTotalStringBytes else {
                throw budgetExceeded
            }
            totalBytes = projected.partialValue
        }
    }

    private static func walk(
        _ value: Any,
        depth: Int,
        budget: inout StringBudget
    ) throws {
        guard depth <= maximumEventNestingDepth else {
            throw ProviderAnthropicResponseShapePolicyError.eventNestingTooDeep
        }
        switch value {
        case let string as String:
            try budget.consume(string)
        case let object as [String: Any]:
            guard object.count <= maximumObjectKeys else {
                throw ProviderAnthropicResponseShapePolicyError.eventObjectTooLarge
            }
            for (key, nested) in object {
                try budget.consume(key)
                try walk(nested, depth: depth + 1, budget: &budget)
            }
        case let array as [Any]:
            guard array.count <= maximumArrayElements else {
                throw ProviderAnthropicResponseShapePolicyError.eventArrayTooLarge
            }
            for nested in array {
                try walk(nested, depth: depth + 1, budget: &budget)
            }
        case is NSNumber, is NSNull:
            break
        default:
            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
        }
    }

    private static func validateContentContainers(in event: [String: Any]) throws {
        if let message = event["message"] {
            guard let message = message as? [String: Any] else {
                throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
            }
            try validateContentBlocks(message["content"])
        }
        try validateContentBlocks(event["content"])

        if let contentBlock = event["content_block"] {
            guard let contentBlock = contentBlock as? [String: Any] else {
                throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
            }
            if let input = contentBlock["input"],
               contentBlock["type"] as? String == "tool_use" {
                guard let input = input as? [String: Any] else {
                    throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
                }
                try validateToolInput(input)
            }
        }
    }

    private static func validateContentBlocks(_ raw: Any?) throws {
        guard let raw else { return }
        guard let blocks = raw as? [[String: Any]] else {
            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
        }
        guard blocks.count <= maximumContentBlocks else {
            throw ProviderAnthropicResponseShapePolicyError.contentBlocksTooMany
        }
    }

    private static func validateToolInputFields(in event: [String: Any]) throws {
        guard let delta = event["delta"] else { return }
        guard let delta = delta as? [String: Any] else {
            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
        }
        guard delta["type"] as? String == "input_json_delta" else { return }
        guard let fragment = delta["partial_json"] as? String else {
            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
        }
        guard fragment.utf8.count <= maximumToolInputFragmentBytes else {
            throw ProviderAnthropicResponseShapePolicyError.toolInputFragmentTooLarge
        }
        try validateToolInputFragment(fragment)
    }

    private static func validateToolInput(_ input: [String: Any]) throws {
        var budget = StringBudget(
            maximumStringBytes: maximumToolInputStringBytes,
            maximumTotalStringBytes: maximumToolInputTotalStringBytes,
            stringTooLarge: .toolInputTooLarge,
            budgetExceeded: .toolInputTooLarge
        )
        try walkToolInput(input, depth: 0, budget: &budget)
    }

    private static func walkToolInput(
        _ value: Any,
        depth: Int,
        budget: inout StringBudget
    ) throws {
        guard depth <= maximumToolInputNestingDepth else {
            throw ProviderAnthropicResponseShapePolicyError.toolInputTooDeep
        }
        switch value {
        case let string as String:
            try budget.consume(string)
        case let object as [String: Any]:
            guard object.count <= maximumToolInputObjectKeys else {
                throw ProviderAnthropicResponseShapePolicyError.toolInputTooLarge
            }
            for (key, nested) in object {
                try budget.consume(key)
                try walkToolInput(nested, depth: depth + 1, budget: &budget)
            }
        case let array as [Any]:
            guard array.count <= maximumToolInputArrayElements else {
                throw ProviderAnthropicResponseShapePolicyError.toolInputTooLarge
            }
            for nested in array {
                try walkToolInput(nested, depth: depth + 1, budget: &budget)
            }
        case is NSNumber, is NSNull:
            break
        default:
            throw ProviderAnthropicResponseShapePolicyError.invalidEventShape
        }
    }

    /// `partial_json` is intentionally allowed to be incomplete across SSE
    /// events. Scan only structural delimiters outside quoted strings so a
    /// fragment can be rejected for pathological depth/token count without
    /// requiring a complete JSON document.
    private static func validateToolInputFragment(_ fragment: String) throws {
        var depth = 0
        var tokenCount = 0
        var inString = false
        var escaped = false

        for byte in fragment.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B: // { [
                depth += 1
                tokenCount += 1
                guard depth <= maximumToolInputNestingDepth else {
                    throw ProviderAnthropicResponseShapePolicyError.toolInputTooDeep
                }
            case 0x7D, 0x5D: // } ]
                if depth > 0 {
                    depth -= 1
                }
                tokenCount += 1
            case 0x2C, 0x3A: // , :
                tokenCount += 1
            default:
                break
            }

            guard tokenCount <= maximumToolInputStructuralTokens else {
                throw ProviderAnthropicResponseShapePolicyError.toolInputStructureTooComplex
            }
        }
    }
}
