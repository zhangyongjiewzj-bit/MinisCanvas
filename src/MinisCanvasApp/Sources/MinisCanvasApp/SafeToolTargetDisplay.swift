import Foundation
import MinisCore

/// A per-turn App-owned side channel; raw stream event args cannot impersonate
/// this source. Only structured tool calls admitted by the production loop
/// can populate it. 保留的只有脱敏后的命令/路径/检索模式摘要，不含文件内容。
final class ToolTargetDisplayStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func record(_ call: LLMToolCall) {
        guard let bytes = call.rawArguments.data(using: .utf8),
              bytes.count <= 1_048_576,
              let args = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let value = Self.display(tool: call.name, input: args) else { return }
        lock.lock(); defer { lock.unlock() }
        values[call.id] = value
    }
    func display(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return values[id]
    }
    private static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/").suffix(2)
        return parts.isEmpty ? path : parts.joined(separator: "/")
    }

    static func display(tool: String, input: [String: Any]) -> String? {
        let value: String
        switch tool {
        case "file_read", "file_write", "file_edit", "file_delete":
            guard let path = input["path"] as? String, path.hasPrefix("/") else { return nil }
            // 摘要行显示"上级目录/文件名"：事件层会把以 / 开头的本地路径整体替换成占位，
            // 所以完整路径放在展开详情里（ToolOutputSummary.captureWithDetail）。
            value = SensitiveFilePolicy.contains(path) ? "敏感文件" : Self.shortPath(path)
        case "file_grep", "file_glob":
            let pattern = (input["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let path = input["path"] as? String
            let scope = path.flatMap { $0.hasPrefix("/") ? (SensitiveFilePolicy.contains($0) ? "敏感文件" : Self.shortPath($0)) : nil }
            guard !pattern.isEmpty || scope != nil else { return nil }
            value = [pattern.isEmpty ? nil : pattern, scope].compactMap { $0 }.joined(separator: " · ")
        case "skill_create", "skill_update", "skill_delete":
            guard let id = input["skillID"] as? String, SkillStore.isSafeSkillID(id) else { return nil }
            value = id
        case "shell_execute":
            // 完整命令（脱敏后单行显示；事件层会截断并把命令里的本地路径换成占位，完整内容见展开详情）。
            guard let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { return nil }
            value = command.replacingOccurrences(of: "\n", with: " ")
        case "orchestrate":
            guard let tasks = input["tasks"] as? [Any] else { return nil }
            value = "子任务 \(tasks.count) 个"
        default: return nil
        }
        return String(ConversationEventRedactor.redact(ContentSecretRedactor.redact(value)).prefix(120))
    }
}
