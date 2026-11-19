import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("App typed retry failure language boundary")
struct ChatRetryFailureLocalizationTests {
    @Test(arguments: [401, 403, 404, 429, 500, 503])
    func typedHTTPUsesChineseBeforeCanonicalStorage(code: Int) {
        let error = LLMError.httpStatus(code: code,
            detail: "Authorization: Bearer synthetic-locale-private")
        let actual = AgentLoopChatEngine.retryFailureMessage(for: error)
        #expect(actual == error.friendlyMessage(locale: Locale(identifier: "zh_CN")))
        #expect(actual.contains(String(code)))
        #expect(actual.contains(HTTPStatusMessages.message(for: code).zh))
        #expect(!actual.contains("synthetic-locale-private"))
        // Explicit Core English remains independently selectable.
        let english = error.friendlyMessage(locale: Locale(identifier: "en_US"))
        #expect(english.contains(HTTPStatusMessages.message(for: code).en))
        #expect(actual != english)
    }

    /// The loop reports prior-turn history plus this attempt's output. Only the
    /// turn's own user message may reach the envelope, otherwise Core's
    /// partial-history validation rejects every failure in a multi-turn session.
    @Test func retryPartialMessagesKeepOnlyTheCurrentUserInput() {
        let history = [
            LLMMessage(role: .user, content: "第一问"),
            LLMMessage(role: .assistant, content: "第一答"),
            LLMMessage(role: .user, content: "第二问"),
        ]
        let noTools = normalizedRetryFailurePartialMessages(history, acceptedToolCallIDs: [])
        #expect(noTools.map(\.content) == ["第二问"])
        #expect(noTools.map(\.role) == [.user])
    }

    @Test func retryPartialMessagesKeepProducedToolRoundAfterCurrentUserInput() {
        let call = LLMToolCall(id: "call-1", name: "file_read", rawArguments: "{}", arguments: [:])
        let messages = [
            LLMMessage(role: .user, content: "第一问"),
            LLMMessage(role: .assistant, content: "第一答"),
            LLMMessage(role: .user, content: "第二问"),
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: "ok", toolCallID: "call-1"),
        ]
        let normalized = normalizedRetryFailurePartialMessages(messages, acceptedToolCallIDs: ["call-1"])
        #expect(normalized.map(\.role) == [.user, .assistant, .tool])
        #expect(normalized.first?.content == "第二问")
    }

    private func toolRound(_ id: String, _ name: String, _ args: [String: Any]) -> [ChatMessageUI] {
        [
            ChatMessageUI(role: .assistant, content: "", toolCalls: [
                LLMToolCall(id: id, name: name, rawArguments: "{}", arguments: args),
            ]),
            ChatMessageUI(role: .tool, content: "ok", toolCallID: id),
        ]
    }

    /// MC4-025：只有最后一条用户消息之后、已拿到结果的改动类工具才算；只读工具和没拿到结果的调用不算。
    @Test func completedSideEffectToolsSkipReadOnlyUnansweredAndEarlierTurns() {
        let messages: [ChatMessageUI] =
            [ChatMessageUI(role: .user, content: "上一问")]
            + toolRound("old", "file_write", ["path": "/tmp/old.txt"])
            + [ChatMessageUI(role: .user, content: "这一问")]
            + toolRound("r1", "file_read", ["path": "/tmp/a.txt"])
            + toolRound("w1", "file_write", ["path": "/tmp/b.txt"])
            + toolRound("s1", "shell_execute", ["command": "make build"])
            + [ChatMessageUI(role: .assistant, content: "", toolCalls: [
                LLMToolCall(id: "pending", name: "file_edit", rawArguments: "{}", arguments: ["path": "/tmp/c.txt"]),
            ])]
        let found = ChatStore.completedSideEffectTools(afterLastUserIn: messages)
        #expect(found == [
            ChatStore.RetryDiscardedSideEffect(toolName: "file_write", target: "/tmp/b.txt"),
            ChatStore.RetryDiscardedSideEffect(toolName: "shell_execute", target: "make build"),
        ])
        #expect(ChatStore.completedSideEffectTools(afterLastUserIn: [ChatMessageUI(role: .user, content: "只有问")]).isEmpty)
    }

    @Test func retryConfirmationBodyListsAtMostFiveAndKeepsPathsVerbatim() {
        let items = (1...7).map { ChatStore.RetryDiscardedSideEffect(toolName: "file_write", target: "/tmp/文件 \($0).txt") }
        let body = ChatStore.retryConfirmationBody(items)
        #expect(body.contains("/tmp/文件 1.txt") && body.contains("/tmp/文件 5.txt"))
        #expect(!body.contains("/tmp/文件 6.txt"))
        #expect(body.contains("另有 2 项"))
        #expect(body.contains("可能再做一遍"))
    }

    @MainActor
    @Test func retryAsksFirstWhenTheDiscardedOutputHasCompletedWritesAndCancelKeepsEverything() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("改一下文件")
        for message in toolRound("w1", "file_write", ["path": "/tmp/mc4-025.txt"]) { chat.messages.append(message) }
        chat.markExecutionRunning(sessionID: sessionID, turnID: 1, taskID: "mc4-025")
        chat.markExecutionFailed(sessionID: sessionID, reason: "provider failure")
        let identity = try #require(chat.sessionList.first?.retryIdentity)
        let before = chat.messages.map(\.id)
        var asked: [ChatStore.RetryDiscardedSideEffect] = []
        chat.retryConfirmation = { items in asked = items; return false }

        #expect(!chat.retryFailedSession(identity))
        #expect(asked.map(\.target) == ["/tmp/mc4-025.txt"])
        #expect(chat.messages.map(\.id) == before)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
    }

    @Test func typedTimeoutUsesChineseWithoutRewritingAnUntypedMessage() {
        let timeout = LLMError.networkError(underlying: URLError(.timedOut))
        #expect(AgentLoopChatEngine.retryFailureMessage(for: timeout).contains("请求超时"))
        let ordinary = NSError(domain: "owned-locale", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "owned English diagnostic"])
        // 八组：非供应商、非中文固定文案的错误不再把英文原文带进界面。
        let shown = AgentLoopChatEngine.retryFailureMessage(for: ordinary)
        #expect(!shown.contains("owned English diagnostic"))
        #expect(UserFacingErrorText.containsChinese(shown))
        // 中文固定文案的本项目错误仍原样显示。
        let owned = NSError(domain: "owned-locale", code: 8,
            userInfo: [NSLocalizedDescriptionKey: "目标会话已被移走"])
        #expect(UserFacingErrorText.describe(owned) == "目标会话已被移走")
    }
}
