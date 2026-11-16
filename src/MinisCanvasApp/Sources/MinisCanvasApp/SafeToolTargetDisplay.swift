import Foundation
import MinisCore

/// A per-turn App-owned side channel; raw stream event args cannot impersonate
/// this source. Only structured tool calls admitted by the production loop
/// can populate it. No file contents or command arguments are retained.
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
    static func display(tool: String, input: [String: Any]) -> String? {
        let value: String
        switch tool {
        case "file_read", "file_write", "file_edit", "file_delete", "file_grep", "file_glob":
            guard let path = input["path"] as? String, path.hasPrefix("/") else { return nil }
            value = SensitiveFilePolicy.contains(path) ? "敏感文件" : URL(fileURLWithPath: path).lastPathComponent
        case "skill_create", "skill_update", "skill_delete":
            guard let id = input["skillID"] as? String, SkillStore.isSafeSkillID(id) else { return nil }
            value = id
        case "shell_execute":
            guard let command = input["command"] as? String,
                  let first = command.split(whereSeparator: { $0.isWhitespace }).first,
                  first.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }) else { return nil }
            value = URL(fileURLWithPath: String(first)).lastPathComponent
        case "orchestrate":
            guard let tasks = input["tasks"] as? [Any] else { return nil }
            value = "子任务 \(tasks.count) 个"
        default: return nil
        }
        return String(ConversationEventRedactor.redact(value).prefix(120))
    }
}
