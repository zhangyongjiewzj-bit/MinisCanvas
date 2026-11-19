import CryptoKit
import Foundation

// MARK: - Goal18 Hooks: configuration model

// Hooks extend the existing `ComposerHookInvocation` / `HookDecisionReducer`
// seam (P3-HOOK-01). They run user-configured commands at lifecycle events.
// A hook can only tighten the outcome (deny / ask); it can never widen what the
// policy, approval, sensitive-file and settings-approval layers already refused.

/// Lifecycle events a hook can subscribe to. Raw values match Claude Code's
/// event names so a hook script can be shared between the two tools.
public enum HookEvent: String, Codable, Sendable, CaseIterable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case userPromptSubmit = "UserPromptSubmit"
    case sessionStart = "SessionStart"
    case stop = "Stop"
    /// 以下四个事件对齐 Claude Code，只做观察（不改变决策）：
    /// 通知、子代理结束、压缩前、会话结束。
    case notification = "Notification"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case sessionEnd = "SessionEnd"

    /// Only tool events consult `HookDefinition.matcher`.
    public var usesToolMatcher: Bool { self == .preToolUse || self == .postToolUse }
}

public enum HookSource: String, Codable, Sendable {
    case user
    case project
    /// 读取自 Claude Code 格式的 settings.json（用户级、项目级、项目本地级）。
    case claudeSettings
}

/// One configured hook command.
public struct HookDefinition: Codable, Sendable, Equatable, Identifiable {
    public static let defaultTimeoutSeconds: Double = 60
    public static let maximumTimeoutSeconds: Double = 120
    public static let maximumCommandLength = 4096

    public var id: String
    public var event: HookEvent
    /// Tool-name filter for PreToolUse / PostToolUse: nil, "" or "*" match every
    /// tool; otherwise a regular expression that must match the whole tool name
    /// (对齐 Claude Code，例如 "Edit|Write"、"file_.*"). The old exact-name list
    /// "a|b" is also a valid regular expression and keeps working; an invalid
    /// expression matches nothing.
    public var matcher: String?
    public var command: String
    public var timeoutSeconds: Double?
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString,
        event: HookEvent,
        matcher: String? = nil,
        command: String,
        timeoutSeconds: Double? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, event, matcher, command, timeoutSeconds, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.event = try container.decode(HookEvent.self, forKey: .event)
        self.matcher = try container.decodeIfPresent(String.self, forKey: .matcher)
        self.command = try container.decode(String.self, forKey: .command)
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Timeout actually applied: the configured value, clamped; default 60 s.
    public var effectiveTimeout: TimeInterval {
        guard let value = timeoutSeconds, value.isFinite, value > 0 else {
            return Self.defaultTimeoutSeconds
        }
        return min(value, Self.maximumTimeoutSeconds)
    }

    /// A definition that can ever be executed.
    public var isRunnable: Bool {
        !id.isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && command.utf8.count <= Self.maximumCommandLength
            && !command.contains("\0")
    }

    public func matches(toolName: String?) -> Bool {
        guard event.usesToolMatcher else { return true }
        guard let raw = matcher?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "*" else { return true }
        guard let toolName else { return false }
        // Claude Code 的钩子按它的工具名写（Bash、Edit……）；本 App 的工具名不同，两套名字都认。
        var candidates = [toolName] + Self.claudeCodeToolNames[toolName, default: []]
        let claudeName = HookPayload.claudeToolName(toolName)
        if !candidates.contains(claudeName) { candidates.append(claudeName) }
        // 旧写法：以 "|" 分隔的精确名字（允许两侧有空格）。
        let alternatives = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if candidates.contains(where: { alternatives.contains($0) }) { return true }
        guard let expression = try? NSRegularExpression(pattern: "^(?:" + raw + ")$") else { return false }
        return candidates.contains { name in
            expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }

    /// 本 App 工具名 -> 对应的 Claude Code 工具名。
    static let claudeCodeToolNames: [String: [String]] = [
        "shell_execute": ["Bash"],
        "file_read": ["Read"],
        "file_write": ["Write"],
        "file_edit": ["Edit", "MultiEdit"],
        "file_grep": ["Grep"],
        "file_glob": ["Glob"],
        "web_fetch": ["WebFetch"],
    ]
}

/// On-disk shape shared by the user file and the project file.
public struct HookConfigurationFile: Codable, Sendable, Equatable {
    public var hooks: [HookDefinition]

    public init(hooks: [HookDefinition] = []) {
        self.hooks = hooks
    }

    private enum CodingKeys: String, CodingKey { case hooks }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hooks = try container.decodeIfPresent([HookDefinition].self, forKey: .hooks) ?? []
    }

    public var hasDuplicateIDs: Bool {
        Set(hooks.map(\.id)).count != hooks.count
    }
}

/// Stable key for diagnostics and the Settings list.
public func hookKey(source: HookSource, id: String) -> String {
    source.rawValue + ":" + id
}

public enum HookDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Verdict merge

/// Multi-hook merge with the same fixed precedence as `HookDecisionReducer`
/// (`deny > ask > allow`). The merged verdict is then fed to the reducer as the
/// single hook layer, so the reducer remains the one authority.
public enum HookVerdictMerge {
    public static func merge(_ verdicts: [HookLayerVerdict]) -> HookLayerVerdict {
        if verdicts.contains(.deny) { return .deny }
        if verdicts.contains(.ask) { return .ask }
        return .allow
    }
}

// MARK: - Run diagnostics

public enum HookRunStatus: String, Codable, Sendable, Equatable {
    /// Exit code 0 and stdout was empty or a valid JSON object.
    case completed
    /// Exit code != 0: no effect on the decision, diagnostics only.
    case nonZeroExit
    case timedOut
    case launchFailed
    /// Exit code 0 but stdout was not a JSON object: no effect on the decision.
    case invalidOutput
    /// The calling task was cancelled; the process group was terminated.
    case cancelled
}

public struct HookRunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key + "@" + String(startedAt.timeIntervalSince1970) }
    public let key: String
    public let source: HookSource
    public let hookID: String
    public let event: HookEvent
    public let startedAt: Date
    public let durationMilliseconds: Int
    public let status: HookRunStatus
    public let exitCode: Int32?
    /// "allow" / "deny" / "ask" when the hook returned a decision.
    public let decision: String?
    /// Redacted and length-capped; never carries the full stdout.
    public let summary: String

    public init(
        key: String, source: HookSource, hookID: String, event: HookEvent,
        startedAt: Date, durationMilliseconds: Int, status: HookRunStatus,
        exitCode: Int32?, decision: String?, summary: String
    ) {
        self.key = key
        self.source = source
        self.hookID = hookID
        self.event = event
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.status = status
        self.exitCode = exitCode
        self.decision = decision
        self.summary = summary
    }
}

// MARK: - Errors surfaced to the turn

/// Thrown when a UserPromptSubmit hook refuses the user's message.
public struct HookPromptRejection: Error, Equatable, Sendable, LocalizedError {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? {
        reason.isEmpty ? "提交被 Hook 拒绝" : "提交被 Hook 拒绝：" + reason
    }
}
