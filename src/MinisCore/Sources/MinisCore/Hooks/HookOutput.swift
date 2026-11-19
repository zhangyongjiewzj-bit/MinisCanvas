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
            // 对齐 Claude Code：会话开始、提交前、工具后的钩子，纯文本 stdout 直接作为附加上下文。
            // 以 { 或 [ 开头的视为写坏的 JSON，仍按无效输出处理。
            let looksLikeJSON = text.hasPrefix("{") || text.hasPrefix("[")
            if !looksLikeJSON, event == .sessionStart || event == .userPromptSubmit || event == .postToolUse {
                return .parsed(HookParsedOutput(
                    verdict: nil, reason: nil,
                    additionalContext: clean(text, limit: maximumContextLength)))
            }
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
        case .stop:
            // 对齐 Claude Code：Stop 钩子返回 {"decision":"block","reason":"…"} 表示要求继续，
            // reason 就是给模型的下一步指示。
            if (object["decision"] as? String) == "block" { verdict = .deny }
        case .postToolUse, .sessionStart, .notification, .subagentStop, .preCompact, .sessionEnd:
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
        var result = input.values.mapValues { jsonValue(from: $0) }
        // 对齐 Claude Code：文件类工具的路径字段叫 file_path；本 App 叫 path，两个都给。
        if result["file_path"] == nil, let path = result["path"] as? String {
            result["file_path"] = path
        }
        return result
    }

    /// Claude Code 风格的工具名：Bash、Edit、Read……；本 App 的 MCP 工具名
    /// `mcp_<服务器>_<工具>` 转成 `mcp__<服务器>__<工具>`（服务器名含下划线时为尽力对应）。
    /// 没有对应名字的工具原样返回。
    static func claudeToolName(_ appName: String) -> String {
        if let mapped = HookDefinition.claudeCodeToolNames[appName]?.first { return mapped }
        if appName.hasPrefix("mcp_"), !appName.hasPrefix("mcp__") {
            let rest = appName.dropFirst("mcp_".count)
            if let split = rest.firstIndex(of: "_") {
                return "mcp__" + rest[..<split] + "__" + rest[rest.index(after: split)...]
            }
        }
        return appName
    }

    /// 写进钩子 stdin 的工具名字段：tool_name 用 Claude Code 名，原名放 app_tool_name。
    static func addToolNames(_ object: inout [String: Any], appName: String) {
        object["tool_name"] = claudeToolName(appName)
        object["app_tool_name"] = appName
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
