import Foundation
import Testing
@testable import MinisCore

struct SessionTodoProgressTests {
    private func exchange(_ todos: [[String: String]], id: String) throws -> [LLMMessage] {
        let input: [String: Any] = ["progress": ["todos": todos]]
        return [LLMMessage(role: .assistant, content: "", toolCalls: [
            LLMToolCall(id: id, name: "todo_write", rawArguments: "{}", arguments: input)
        ]), LLMMessage(role: .tool, content: try SessionTodoProgress.execute(input: input), toolCallID: id)]
    }

    @Test func progressUpdatesPersistAndRewindWithTranscript() throws {
        let start = try exchange([
            ["content": "读取文件", "status": "completed"],
            ["content": "写入报告", "status": "in_progress", "activeForm": "写入报告"],
            ["content": "复核", "status": "pending"]
        ], id: "start")
        let finish = try exchange([
            ["content": "读取文件", "status": "completed"],
            ["content": "写入报告", "status": "completed"],
            ["content": "复核", "status": "completed"]
        ], id: "finish")
        let session = ChatSession(id: "session-a", messages: start + finish)
        let restored = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        #expect(SessionTodoProgress.latest(in: restored.messages)?.summary == "3/3 · 已完成")
        #expect(SessionTodoProgress.latest(in: Array(restored.messages.prefix(start.count)))?.summary == "1/3 · 正在：写入报告")
        #expect(SessionTodoProgress.latest(in: ChatSession(id: "session-b").messages) == nil)
    }

    @Test func legacyResultsRequireMatchingAssistantAndIgnoreErrors() throws {
        let payload = try SessionTodoProgress.execute(input: ["progress": ["todos": [
            ["content": "读取文件", "status": "in_progress"]
        ]]])
        let result = String(decoding: try JSONSerialization.data(withJSONObject: [[
            "type": "tool_result", "tool_use_id": "todo-1", "content": payload, "is_error": false
        ]]), as: UTF8.self)
        let call = LLMMessage(role: .assistant, content: "{\"tool_calls\":[{\"id\":\"todo-1\",\"name\":\"todo_write\",\"input\":{}}]}")
        #expect(SessionTodoProgress.latest(in: [.init(role: .user, content: result)]) == nil)
        #expect(SessionTodoProgress.latest(in: [call, .init(role: .user, content: result)])?.summary == "0/1 · 正在：读取文件")
        let error = String(decoding: try JSONSerialization.data(withJSONObject: [[
            "type": "tool_result", "tool_use_id": "todo-1", "content": payload, "is_error": true
        ]]), as: UTF8.self)
        #expect(SessionTodoProgress.latest(in: [call, .init(role: .user, content: error)]) == nil)
    }

    @Test func malformedSuccessfulResultNeverPublishesProgress() throws {
        let valid = try exchange([["content": "已记录步骤", "status": "pending"]], id: "valid")
        let call = LLMMessage(role: .assistant, content: "", toolCalls: [
            LLMToolCall(id: "broken", name: "todo_write", rawArguments: "{}", arguments: [:])
        ])
        for malformed in ["not JSON", "{\"todos\":[{\"content\":\"读取\",\"status\":\"unknown\"}]}", "{}"] {
            let failed = [call, LLMMessage(role: .tool, content: malformed, toolCallID: "broken")]
            #expect(SessionTodoProgress.latest(in: failed) == nil)
            #expect(SessionTodoProgress.latest(in: valid + failed)?.summary == "0/1 · 待办")
            let legacyResult = String(decoding: try JSONSerialization.data(withJSONObject: [[
                "type": "tool_result", "tool_use_id": "broken", "content": malformed, "is_error": false
            ]]), as: UTF8.self)
            #expect(SessionTodoProgress.latest(in: [call, .init(role: .user, content: legacyResult)]) == nil)
        }
    }

    @Test func invalidStatesRejectedAndEmptyChecklistClears() throws {
        #expect(throws: ToolExecutorError.self) {
            _ = try SessionTodoProgress.execute(input: ["progress": ["todos": [
                ["content": "第一步", "status": "in_progress"],
                ["content": "第二步", "status": "in_progress"]
            ]]])
        }
        let safe = try #require(SessionTodoProgress.childDisplayResult(
            try SessionTodoProgress.execute(input: ["progress": ["todos": [
                ["content": "读取 /Users/private/secret.txt", "status": "pending"]
            ]]])))
        #expect(!safe.contains("/Users/private/secret.txt"))
        #expect(SessionTodoProgress.childDisplayResult("tool execution failed") == nil)
        let cleared = try exchange([], id: "clear")
        #expect(SessionTodoProgress.latest(in: cleared)?.todos.isEmpty == true)
    }
}
