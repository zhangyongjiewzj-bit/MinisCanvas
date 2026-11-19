import Foundation

/// Declarative description of how to find and project one external agent's
/// on-disk conversation transcripts (lightweight external-session read, line R).
///
/// Field names are taken from the existing JSONL adapter's parsing code; the
/// real on-disk shapes have NOT been verified against live sessions.
/// Only user/assistant text is ever projected: tool calls and outputs, reasoning,
/// system rows and attachments are not matched by any rule.
struct ExternalSessionFormatMap: Sendable {
    struct Match: Sendable {
        let path: [String]
        let equals: String
    }

    struct Rule: Sendable {
        let when: [Match]
        /// Fixed role, used when `rolePath` is nil.
        let role: String
        /// When set, the role is read from this path in the row (Claude Code rows).
        let rolePath: [String]?
        /// Tried in order; the first path yielding non-empty text wins.
        let textPaths: [[String]]
    }

    struct QualifiedRoot: Sendable, Equatable {
        let source: String
        /// Real path of the mounted `.../.codex/sessions` or `.../.claude/projects`.
        let path: String
    }

    let source: String
    /// Last two directory names of a qualifying mounted root.
    let rootSuffix: [String]
    /// Number of path components (directories + file) of a session file below the root.
    let fileDepth: Int
    let fileNamePattern: @Sendable (String) -> String?
    /// A row qualifies as a header row (used to read `cwd`) when all matches hold.
    let metaRow: [Match]
    let cwdPath: [String]
    let titleRoles: Set<String>
    let rules: [Rule]
    let textBlockTypes: Set<String>
    let rowIDFilter: (path: [String], mustEqualSessionID: Bool)?

    // MARK: Instances

    static let codex = ExternalSessionFormatMap(
        source: "codex",
        rootSuffix: [".codex", "sessions"],
        fileDepth: 4,
        fileNamePattern: { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let stem = String(name.dropLast(".jsonl".count))
            guard stem.hasPrefix("rollout-") else { return nil }
            let suffix = stem.split(separator: "-").suffix(5).joined(separator: "-")
            return UUID(uuidString: suffix) != nil ? suffix : nil
        },
        metaRow: [Match(path: ["type"], equals: "session_meta")],
        cwdPath: ["payload", "cwd"],
        titleRoles: ["user"],
        rules: [
            Rule(when: [Match(path: ["type"], equals: "event_msg"),
                        Match(path: ["payload", "type"], equals: "user_message")],
                 role: "user", rolePath: nil, textPaths: [["payload", "message"]]),
            Rule(when: [Match(path: ["type"], equals: "event_msg"),
                        Match(path: ["payload", "type"], equals: "agent_message")],
                 role: "assistant", rolePath: nil, textPaths: [["payload", "message"]]),
            Rule(when: [Match(path: ["type"], equals: "event_msg"),
                        Match(path: ["payload", "type"], equals: "item_completed"),
                        Match(path: ["payload", "item", "type"], equals: "UserMessage")],
                 role: "user", rolePath: nil,
                 textPaths: [["payload", "item", "content"], ["payload", "item", "text"]]),
            Rule(when: [Match(path: ["type"], equals: "event_msg"),
                        Match(path: ["payload", "type"], equals: "item_completed"),
                        Match(path: ["payload", "item", "type"], equals: "AgentMessage")],
                 role: "assistant", rolePath: nil,
                 textPaths: [["payload", "item", "content"], ["payload", "item", "text"]])
        ],
        textBlockTypes: ["input_text", "output_text", "text", "Text"],
        rowIDFilter: nil
    )

    static let claudeCode = ExternalSessionFormatMap(
        source: "claude_code",
        rootSuffix: [".claude", "projects"],
        fileDepth: 2,
        fileNamePattern: { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let stem = String(name.dropLast(".jsonl".count))
            return UUID(uuidString: stem) != nil ? stem : nil
        },
        metaRow: [],
        cwdPath: ["cwd"],
        titleRoles: ["user"],
        rules: [
            Rule(when: [Match(path: ["type"], equals: "user")],
                 role: "", rolePath: ["message", "role"], textPaths: [["message", "content"]]),
            Rule(when: [Match(path: ["type"], equals: "assistant")],
                 role: "", rolePath: ["message", "role"], textPaths: [["message", "content"]])
        ],
        textBlockTypes: ["input_text", "output_text", "text", "Text"],
        rowIDFilter: (path: ["sessionId"], mustEqualSessionID: true)
    )

    static let all: [ExternalSessionFormatMap] = [codex, claudeCode]

    static func map(forSource source: String) -> ExternalSessionFormatMap? {
        all.first { $0.source == source }
    }

    // MARK: Root qualification

    /// A mounted folder qualifies only if its last two path components are
    /// exactly one map's `rootSuffix`, it is a real (non-symlink) directory
    /// owned by the current user, and its real path keeps that suffix.
    /// Mounting a parent (`~/.codex`, `~`) is NOT authorization. Unmatched
    /// roots are rejected lexically, with no filesystem access.
    static func qualifiedRoots(from roots: [URL]) -> [QualifiedRoot] {
        var result: [QualifiedRoot] = []
        var seen = Set<String>()
        for root in roots {
            guard let qualified = qualify(path: root.path),
                  seen.insert(qualified.source + "\u{0}" + qualified.path).inserted else { continue }
            result.append(qualified)
        }
        return result
    }

    /// Single-path form of the qualification rule; the one place it is defined.
    static func qualify(path: String) -> QualifiedRoot? {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        let components = lexical.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let suffix = Array(components.suffix(2))
        guard let map = all.first(where: { $0.rootSuffix == suffix }) else { return nil }
        var info = stat()
        guard lstat(lexical, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              let resolved = realpath(lexical, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        guard Array(real.split(separator: "/").map(String.init).suffix(2)) == suffix else { return nil }
        return QualifiedRoot(source: map.source, path: real)
    }

    // MARK: Row projection

    func value(at path: [String], in row: [String: Any]) -> Any? {
        var current: Any? = row
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    private func matches(_ conditions: [Match], _ row: [String: Any]) -> Bool {
        conditions.allSatisfy { (value(at: $0.path, in: row) as? String) == $0.equals }
    }

    func isMetaRow(_ row: [String: Any]) -> Bool { matches(metaRow, row) }

    func cwd(from row: [String: Any]) -> String? {
        guard isMetaRow(row), let cwd = value(at: cwdPath, in: row) as? String, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// The user/assistant text carried by one parsed row, or nil if the row is
    /// not a conversational message under this map.
    func message(from row: [String: Any], fileSessionID: String) -> (role: String, text: String)? {
        if let filter = rowIDFilter, filter.mustEqualSessionID {
            guard let rowID = value(at: filter.path, in: row) as? String,
                  rowID.lowercased() == fileSessionID.lowercased() else { return nil }
        }
        for rule in rules where matches(rule.when, row) {
            let role: String
            if let rolePath = rule.rolePath {
                guard let found = value(at: rolePath, in: row) as? String else { continue }
                role = found
            } else {
                role = rule.role
            }
            guard role == "user" || role == "assistant" else { continue }
            for path in rule.textPaths {
                let fragments = textFragments(value(at: path, in: row))
                let text = fragments.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (role, text) }
            }
        }
        return nil
    }

    /// 工具调用与工具结果（仅在调用方要求 `include_tools` 时使用）：角色为 `tool_call` / `tool_result`，
    /// 文本是“工具名 + 参数”或结果的紧凑文本。字段名按两家 CLI 常见的行格式推断，未对真实会话文件逐一核对；
    /// 对不上的行直接忽略。调用方负责脱敏和限长。
    func toolItems(from row: [String: Any], fileSessionID: String) -> [(role: String, text: String)] {
        if let filter = rowIDFilter, filter.mustEqualSessionID {
            guard let rowID = value(at: filter.path, in: row) as? String,
                  rowID.lowercased() == fileSessionID.lowercased() else { return [] }
        }
        var items: [(role: String, text: String)] = []
        switch source {
        case "claude_code":
            guard let type = row["type"] as? String, type == "assistant" || type == "user",
                  let blocks = value(at: ["message", "content"], in: row) as? [Any] else { return [] }
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    let name = (block["name"] as? String) ?? "未知工具"
                    items.append(("tool_call", name + " " + Self.compactJSON(block["input"])))
                case "tool_result":
                    items.append(("tool_result", Self.resultText(block["content"])))
                default: break
                }
            }
        case "codex":
            guard (row["type"] as? String) == "response_item",
                  let payload = row["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { return [] }
            switch type {
            case "function_call", "custom_tool_call":
                let name = (payload["name"] as? String) ?? "未知工具"
                let arguments = (payload["arguments"] as? String) ?? (payload["input"] as? String)
                    ?? Self.compactJSON(payload["arguments"] ?? payload["input"])
                items.append(("tool_call", name + " " + arguments))
            case "function_call_output", "custom_tool_call_output":
                items.append(("tool_result", Self.resultText(payload["output"])))
            default: break
            }
        default: break
        }
        return items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func compactJSON(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func resultText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let blocks = value as? [Any] {
            let texts = blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let object = value as? [String: Any], let content = object["content"] as? String { return content }
        return compactJSON(value)
    }

    func textFragments(_ content: Any?) -> [String] {
        if let string = content as? String { return [string] }
        guard let blocks = content as? [Any] else { return [] }
        return blocks.compactMap { element -> String? in
            guard let block = element as? [String: Any],
                  let type = block["type"] as? String, textBlockTypes.contains(type) else { return nil }
            return block["text"] as? String
        }
    }
}

/// Public judgement shared by the tools and the Settings "first mount" notice,
/// so both sides agree on what counts as an external-session folder.
public enum ExternalSessionMountQualification {
    /// "codex" or "claude_code" when `path` is a real (non-symlink, user-owned)
    /// directory whose last two components are exactly `.codex/sessions` or
    /// `.claude/projects` and whose realpath keeps that suffix; otherwise nil.
    /// Mounting a parent folder (`~/.codex`, `~`) does not qualify.
    public static func qualifyingSource(forMountedPath path: String) -> String? {
        ExternalSessionFormatMap.qualify(path: path)?.source
    }

    public static func isQualifyingMount(_ path: String) -> Bool {
        qualifyingSource(forMountedPath: path) != nil
    }

    /// Whether mounting `path` must first show the one-time external-session
    /// disclosure. Defined as exactly the read tool's qualification (lexical
    /// suffix, real user-owned directory, realpath keeps the suffix), so the
    /// notice appears if and only if the tools would accept this mount.
    public static func requiresDisclosure(forMountedPath path: String) -> Bool {
        isQualifyingMount(path)
    }
}
