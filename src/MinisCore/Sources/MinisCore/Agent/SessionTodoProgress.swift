import Foundation

/// A value projection of successful todo_write results in one canonical
/// transcript. It neither schedules work nor owns a second task ledger.
public struct SessionTodoProgress: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, in_progress, completed
    }

    public struct Item: Codable, Equatable, Sendable {
        public let content: String
        public let status: Status
        public let activeForm: String?

        public init(content: String, status: Status, activeForm: String? = nil) {
            self.content = content
            self.status = status
            self.activeForm = activeForm
        }
    }

    public static let toolName = "todo_write"
    public let todos: [Item]

    public init(todos: [Item]) { self.todos = todos }

    public var currentItem: Item? { todos.first { $0.status == .in_progress } }
    public var summary: String {
        let done = todos.filter { $0.status == .completed }.count
        let count = "\(done)/\(todos.count)"
        if let currentItem {
            return count + " · 正在：" + (currentItem.activeForm ?? currentItem.content)
        }
        return count + (done == todos.count ? " · 已完成" : " · 待办")
    }

    public static func definition() -> AgentToolDefinition {
        AgentToolDefinition(name: toolName,
            description: "Keep a visible checklist for work with three or more steps or several user requests; skip it for one-step or trivial tasks. Each call replaces the whole list, so resend every item. Keep exactly one item in_progress: mark it before starting, mark it completed as soon as it is done and add follow-ups you discover. Never mark an item completed while tests fail, work is partial or errors remain; add an item describing the blocker instead. Make the last item a check of the result. The argument is one object named progress, not a top-level todos field: {\"progress\":{\"todos\":[{\"content\":\"Run tests\",\"status\":\"in_progress\",\"activeForm\":\"Running tests\"}]}}. An empty todos array clears the list. No approval, no side effects, allowed in plan mode; it is not a goal and does not persist across sessions as a commitment. Child sessions keep their own list. After updating, do not repeat the whole list in chat; say what changed and what is next. Do not add filler steps or steps you cannot perform.",
            parameters: ["progress": AgentToolParam(type: .object,
                description: "Object {todos:[{content (non-empty), status: pending|in_progress|completed, activeForm (optional, non-empty)}]}. At most one in_progress item; the call fails otherwise")],
            required: ["progress"])
    }

    /// The existing loop records this returned value with the tool call. The
    /// canonical transcript supplies persistence, rewind and compaction retention.
    public static func execute(input: [String: Any]) throws -> String {
        guard let object = input["progress"] as? [String: Any] else {
            throw ToolExecutorError.missingParameter("progress")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let value: SessionTodoProgress
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ToolExecutorError.invalidParameter("progress requires todos with content and a valid status") }
        guard value.todos.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ($0.activeForm.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true) }),
              value.todos.filter({ $0.status == .in_progress }).count <= 1 else {
            throw ToolExecutorError.invalidParameter("Use nonempty task text and at most one in_progress task")
        }
        let output = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        // A truncated tool result cannot restore a checklist after restart.
        guard output.utf8.count <= ProductRedactionPolicy.maxTranscriptFieldLength else {
            throw ToolExecutorError.invalidParameter("Checklist exceeds the tool result limit")
        }
        return output
    }

    /// Child transcripts keep only a small, normalized display value. The
    /// caller must first match a successful result to a real todo_write call.
    static func childDisplayResult(_ content: String) -> String? {
        guard content.count <= ProductRedactionPolicy.maxTranscriptFieldLength,
              let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let normalized = try? execute(input: ["progress": object]),
              let progress = try? JSONDecoder().decode(Self.self, from: Data(normalized.utf8)) else { return nil }
        let safe = Self(todos: progress.todos.map {
            Item(content: ProductRedactionPolicy.redact($0.content), status: $0.status,
                 activeForm: $0.activeForm.map { ProductRedactionPolicy.redact($0) })
        })
        guard let data = try? JSONEncoder().encode(safe),
              data.count <= ProductRedactionPolicy.maxTranscriptFieldLength else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func latest(in messages: [LLMMessage]) -> Self? {
        var pending = Set<String>()
        var latest: Self?
        for message in messages {
            switch message.role {
            case .assistant:
                if !message.toolCalls.isEmpty {
                    pending = Set(message.toolCalls.filter { $0.name == toolName }.map(\.id))
                } else {
                    pending = Set((AgentLoop.parseToolCalls(from: message.content) ?? [])
                        .filter { $0.name == toolName }.map(\.id))
                }
            case .tool:
                if let id = message.toolCallID, pending.remove(id) != nil,
                   let value = try? JSONDecoder().decode(Self.self, from: Data(message.content.utf8)) {
                    latest = value
                }
            case .user:
                // Legacy results use user role, paired to the immediately
                // preceding assistant's exact tool IDs. Ordinary user text
                // cannot publish a checklist on its own.
                if !pending.isEmpty,
                   let parts = try? JSONSerialization.jsonObject(with: Data(message.content.utf8)) as? [[String: Any]] {
                    for part in parts {
                        guard part["type"] as? String == "tool_result",
                              let id = part["tool_use_id"] as? String,
                              pending.remove(id) != nil,
                              part["is_error"] as? Bool != true,
                              let content = part["content"] as? String,
                              let value = try? JSONDecoder().decode(Self.self, from: Data(content.utf8)) else { continue }
                        latest = value
                    }
                }
                pending.removeAll()
            }
        }
        return latest
    }
}
