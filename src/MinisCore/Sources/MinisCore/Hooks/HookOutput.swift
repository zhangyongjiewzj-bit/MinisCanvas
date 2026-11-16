import Foundation

// MARK: - Goal18 Hooks: stdout protocol, payload shaping, result annotation

/// What a hook command said on stdout.
public struct HookParsedOutput: Sendable, Equatable {
    /// nil = the hook expressed no decision (and therefore changes nothing).
    public let verdict: HookLayerVerdict?
    public let reason: String?
    public let additionalContext: String?

    public init(verdict: HookLayerVerdict?, reason: String?, additionalContext: String?) {
        self.verdict = verdict
        self.reason = reason
        self.additionalContext = additionalContext
    }
}

public enum HookOutputParseResult: Sendable, Equatable {
    case parsed(HookParsedOutput)
    case invalid(String)
}

/// Parses the JSON object a hook prints. The accepted subset follows Claude Code:
///
/// - PreToolUse: `{"hookSpecificOutput":{"permissionDecision":"allow|deny|ask",
///   "permissionDecisionReason":"..."}}`, or the legacy `{"decision":"approve|block","reason":"..."}`.
/// - UserPromptSubmit: `{"decision":"block","reason":"..."}`.
/// - Context for the model: `hookSpecificOutput.additionalContext`.
/// - `{"continue":false,"stopReason":"..."}` is read as deny for PreToolUse/UserPromptSubmit.
///
/// Anything else (empty output, unknown values) is "no decision".
public enum HookOutputParser {
    public static let maximumReasonLength = 500
    public static let maximumContextLength = 4000

    public static func parse(stdout: Data, event: HookEvent) -> HookOutputParseResult {
        let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return .parsed(HookParsedOutput(verdict: nil, reason: nil, additionalContext: nil))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .invalid("stdout 不是 JSON 对象")
        }
        let specific = object["hookSpecificOutput"] as? [String: Any]
        var verdict: HookLayerVerdict?
        var reason = (specific?["permissionDecisionReason"] as? String) ?? (object["reason"] as? String)
        let continueFlag = object["continue"] as? Bool

        switch event {
        case .preToolUse:
            if let raw = specific?["permissionDecision"] as? String {
                verdict = layerVerdict(raw)
            } else if let raw = object["decision"] as? String {
                verdict = layerVerdict(raw)
            }
            if verdict == nil, continueFlag == false {
                verdict = .deny
                reason = reason ?? (object["stopReason"] as? String)
            }
        case .userPromptSubmit:
            if (object["decision"] as? String) == "block" {
                verdict = .deny
            } else if continueFlag == false {
                verdict = .deny
                reason = reason ?? (object["stopReason"] as? String)
            }
        case .postToolUse, .sessionStart, .stop:
            break
        }

        var context = (specific?["additionalContext"] as? String) ?? (object["additionalContext"] as? String)
        if event == .postToolUse, context == nil, (object["decision"] as? String) == "block" {
            // The tool already ran: a "block" can only be feedback to the model.
            context = reason
        }
        return .parsed(HookParsedOutput(
            verdict: verdict,
            reason: clean(reason, limit: maximumReasonLength),
            additionalContext: clean(context, limit: maximumContextLength)
        ))
    }

    private static func layerVerdict(_ raw: String) -> HookLayerVerdict? {
        switch raw.lowercased() {
        case "allow", "approve": return .allow
        case "deny", "block": return .deny
        case "ask": return .ask
        default: return nil
        }
    }

    static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let redacted = ContentSecretRedactor.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return nil }
        return redacted.count > limit ? String(redacted.prefix(limit)) + "…" : redacted
    }
}

/// Builds the JSON a hook receives on stdin. Tool input and output are redacted
/// and length-capped; no environment value, API key or credential is ever added.
enum HookPayload {
    static let maximumStringLength = 4096
    static let maximumToolResponseLength = 8000

    static func jsonValue(from value: ComposerInputValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .integer(let number): return number
        case .number(let number): return number
        case .string(let text): return sanitize(text, limit: maximumStringLength)
        case .array(let items): return items.map { jsonValue(from: $0) }
        case .object(let fields): return fields.mapValues { jsonValue(from: $0) }
        }
    }

    static func sanitize(_ text: String, limit: Int) -> String {
        let redacted = ContentSecretRedactor.redact(text)
        return redacted.count > limit ? String(redacted.prefix(limit)) + "…[truncated]" : redacted
    }

    /// True when any string in the tool input names a path SensitiveFilePolicy
    /// treats as sensitive (.env, key files, ~/.ssh, app state...). The tool's
    /// result is then not sent to hooks at all: redaction cannot be relied on to
    /// recognise an arbitrary secret in the file body.
    static func touchesSensitivePath(_ input: ComposerToolInput) -> Bool {
        func scan(_ value: ComposerInputValue) -> Bool {
            switch value {
            case .string(let text):
                return !text.isEmpty && text.utf8.count <= 4096 && SensitiveFilePolicy.contains(text)
            case .array(let items): return items.contains(where: scan)
            case .object(let fields): return fields.values.contains(where: scan)
            case .null, .bool, .integer, .number: return false
            }
        }
        return input.values.values.contains(where: scan)
    }

    static func toolInput(_ input: ComposerToolInput) -> [String: Any] {
        input.values.mapValues { jsonValue(from: $0) }
    }

    enum PayloadEncodingError: Error { case invalidJSONObject }

    static func data(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw PayloadEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Appends PostToolUse context to a tool result without breaking a JSON result.
public enum HookOutputAnnotation {
    public static let jsonKey = "hook_additional_context"
    /// File-change tools return a fixed summary line ("Wrote N bytes to ...",
    /// "Edited ...") that `ToolOutputSummary` recognises with an anchored pattern;
    /// appended text would break it. Their hook context is not added to the result.
    public static let unannotatedTools: Set<String> = ["file_write", "file_edit"]

    public static func annotate(output: String, context: String, toolName: String? = nil) -> String {
        if let toolName, unannotatedTools.contains(toolName) { return output }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
           (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) is [String: Any],
           let encoded = try? JSONEncoder().encode(context),
           let encodedText = String(data: encoded, encoding: .utf8) {
            let body = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = body.hasSuffix("{") ? "" : ","
            return body + separator + "\"" + jsonKey + "\":" + encodedText + "}"
        }
        return output + "\n\n[PostToolUse hook] " + context
    }
}
