import Foundation

// MARK: - Claude Code 格式的 settings.json 里的 hooks 段

/// 解析 Claude Code 的 settings.json：
///
///     { "hooks": { "PreToolUse": [ { "matcher": "Bash",
///         "hooks": [ { "type": "command", "command": "...", "timeout": 30 } ] } ] } }
///
/// 只认 `type == "command"`（缺省也当 command）和本 App 支持的事件名；其它一律跳过。
/// `disableAllHooks: true` 表示整份文件的钩子都不用。解析只产出定义，是否执行
/// 由 `HookConfigStore` 的内容哈希信任记录决定。
public enum ClaudeSettingsHooksParser {
    /// nil = 文件不是 JSON 对象；空数组 = 没有可用的钩子。
    public static func parse(_ data: Data, idPrefix: String) -> [HookDefinition]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if (root["disableAllHooks"] as? Bool) == true { return [] }
        guard let hooksObject = root["hooks"] as? [String: Any] else { return [] }
        var result: [HookDefinition] = []
        for eventName in hooksObject.keys.sorted() {
            guard let event = HookEvent(rawValue: eventName),
                  let groups = hooksObject[eventName] as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                let matcher = group["matcher"] as? String
                for (entryIndex, entry) in entries.enumerated() {
                    let type = (entry["type"] as? String) ?? "command"
                    guard type == "command", let command = entry["command"] as? String else { continue }
                    result.append(HookDefinition(
                        id: "\(idPrefix):\(eventName):\(groupIndex).\(entryIndex)",
                        event: event,
                        matcher: matcher,
                        command: command,
                        timeoutSeconds: (entry["timeout"] as? NSNumber)?.doubleValue
                    ))
                }
            }
        }
        return result
    }

    /// settings.json 里出现、但本 App 不支持而被忽略的事件名（例如 PermissionRequest），
    /// 供设置页提示；文件无法解析或没有 hooks 段时返回空数组。
    public static func ignoredEventNames(in data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooksObject = root["hooks"] as? [String: Any] else { return [] }
        return hooksObject.keys.filter { HookEvent(rawValue: $0) == nil }.sorted()
    }

    /// settings.json 里出现、但类型不是 command 而被忽略的钩子类型名（prompt、agent、http 等），
    /// 供设置页提示，不静默丢弃。
    public static func ignoredHookTypes(in data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooksObject = root["hooks"] as? [String: Any] else { return [] }
        var types = Set<String>()
        for case let groups as [[String: Any]] in hooksObject.values {
            for group in groups {
                for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                    let type = (entry["type"] as? String) ?? "command"
                    if type != "command" { types.insert(type) }
                }
            }
        }
        return types.sorted()
    }

    /// 信任哈希覆盖解析出的钩子（不含 settings.json 里的权限等其它内容）：
    /// 改权限不需要重新信任，改钩子命令必须重新信任。钩子引用的脚本另行并入
    /// （见 `HookConfigStore.claudeSettingsSnapshots`）。
    public static func contentHash(of hooks: [HookDefinition]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(hooks)) ?? Data()
        return HookDigest.sha256Hex(Data("miniscanvas-claude-settings-hooks-v1\n".utf8) + data)
    }
}

/// 一份 Claude Code 格式 settings 文件里的钩子及其信任状态。
public struct ClaudeSettingsHooksSnapshot: Sendable, Equatable, Identifiable {
    public enum Scope: String, Sendable, Equatable {
        /// ~/.claude/settings.json
        case user
        /// <项目>/.claude/settings.json
        case project
        /// <项目>/.claude/settings.local.json
        case projectLocal
    }

    public let scope: Scope
    /// settings 文件的标准化绝对路径，同时是信任记录的键。
    public let path: String
    /// `trust` 为 `.trusted` 时 `executableHooks` 才非空；其余状态只供设置页展示审阅。
    public let snapshot: ProjectHooksSnapshot

    public var id: String { path }

    public init(scope: Scope, path: String, snapshot: ProjectHooksSnapshot) {
        self.scope = scope
        self.path = path
        self.snapshot = snapshot
    }
}
