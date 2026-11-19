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

struct SessionTodoReminderTests {
    private func exchange(_ todos: [[String: String]], id: String) throws -> [LLMMessage] {
        let input: [String: Any] = ["progress": ["todos": todos]]
        return [LLMMessage(role: .assistant, content: "", toolCalls: [
            LLMToolCall(id: id, name: "todo_write", rawArguments: "{}", arguments: input)
        ]), LLMMessage(role: .tool, content: try SessionTodoProgress.execute(input: input), toolCallID: id)]
    }

    private let openList: [[String: String]] = [
        ["content": "读取文件", "status": "completed"],
        ["content": "写入报告", "status": "in_progress"],
        ["content": "复核", "status": "pending"]
    ]

    @Test func remindsAfterThreeRoundsWithoutUpdateAndListsOnlyOpenItems() throws {
        let history = try exchange(openList, id: "t1")
        var reminder = SessionTodoReminder(history: history)
        for _ in 0..<(SessionTodoReminder.roundsBeforeReminder - 1) {
            reminder.recordRound(toolNames: ["file_read"], messages: history)
            #expect(reminder.requestReminder() == nil)
        }
        reminder.recordRound(toolNames: ["file_read"], messages: history)
        let textValue = reminder.requestReminder()
        let text = try #require(textValue)
        #expect(text.contains("写入报告") && text.contains("复核"))
        #expect(!text.contains("读取文件"))
        // Emitting restarts the window: no repeat on the very next request.
        #expect(reminder.requestReminder() == nil)
    }

    @Test func todoWriteRoundResetsTheCount() throws {
        let history = try exchange(openList, id: "t1")
        var reminder = SessionTodoReminder(history: history)
        for _ in 0..<2 { reminder.recordRound(toolNames: ["file_read"], messages: history) }
        reminder.recordRound(toolNames: ["todo_write"], messages: history)
        reminder.recordRound(toolNames: ["file_read"], messages: history)
        #expect(reminder.requestReminder() == nil)
    }

    @Test func completedOrMissingChecklistNeverReminds() throws {
        let done = try exchange([["content": "读取文件", "status": "completed"]], id: "t1")
        var finished = SessionTodoReminder(history: done)
        var none = SessionTodoReminder(history: [])
        for _ in 0..<5 {
            finished.recordRound(toolNames: ["file_read"], messages: done)
            none.recordRound(toolNames: ["file_read"], messages: [])
        }
        #expect(finished.requestReminder() == nil)
        #expect(none.requestReminder() == nil)
    }

    @Test func updateToAllCompletedStopsReminding() throws {
        let open = try exchange(openList, id: "t1")
        let finish = try exchange([["content": "读取文件", "status": "completed"]], id: "t2")
        var reminder = SessionTodoReminder(history: open)
        for _ in 0..<5 { reminder.recordRound(toolNames: ["file_read"], messages: open) }
        reminder.recordRound(toolNames: ["todo_write"], messages: open + finish)
        for _ in 0..<5 { reminder.recordRound(toolNames: ["file_read"], messages: open + finish) }
        #expect(reminder.requestReminder() == nil)
    }

    private final class ScriptedProvider: LLMProvider {
        let name = "Todo reminder fixture"
        var model: LLMModel = .claudeHaiku45
        let capabilities: Set<ProviderCapability> = [.tools]
        var responses: [String]
        private(set) var systemPrompts: [String?] = []
        private(set) var receivedHistory: [[LLMMessage]] = []

        init(responses: [String]) { self.responses = responses }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                         temperature: Double?) async throws -> LLMResponse {
            systemPrompts.append(systemPrompt)
            receivedHistory.append(messages)
            return LLMResponse(text: responses.isEmpty ? "done" : responses.removeFirst(),
                               stopReason: nil, usage: nil)
        }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                         maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                                  maxTokens: maxTokens, temperature: temperature)
        }

        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                           temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private struct TodoAwareExecutor: ToolExecutor {
        func execute(name: String, input: [String: Any]) async throws -> String {
            name == SessionTodoProgress.toolName ? try SessionTodoProgress.execute(input: input) : "ok"
        }
    }

    private func envelope(_ id: String, _ name: String, _ input: [String: Any]) -> String {
        let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func loopAddsReminderToRequestPromptOnlyAndKeepsItOutOfTranscript() async throws {
        let base = "Trusted fixture instruction."
        let provider = ScriptedProvider(responses: [
            envelope("todo-1", "todo_write", ["progress": ["todos": openList]]),
            envelope("p-1", "probe", [:]),
            envelope("p-2", "probe", [:]),
            envelope("p-3", "probe", [:]),
            "done"
        ])
        let root = try minisCoreToolContractRoot("todo-reminder")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await AgentLoop(
            maxIterations: 8,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        ).run(
            messages: [LLMMessage(role: .user, content: "做三件事")],
            systemPrompt: base,
            provider: provider,
            toolExecutor: TodoAwareExecutor(),
            tools: minisCoreToolContractCatalog(["todo_write", "probe"]),
            executionIdentity: minisCoreToolContractIdentity("todo-reminder")
        )
        #expect(provider.systemPrompts.count == 5)
        #expect(provider.systemPrompts.prefix(4).allSatisfy { $0 == base })
        let last = try #require(provider.systemPrompts.last ?? nil)
        #expect(last.hasPrefix(base) && last.contains("[Todo reminder]") && last.contains("写入报告"))
        #expect(!result.messages.contains { $0.content.contains("[Todo reminder]") })
        #expect(!provider.receivedHistory.joined().contains { $0.content.contains("[Todo reminder]") })
    }
}
