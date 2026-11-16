import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - C4-2 转向（steer）+ 编辑消息接线测试
//
// 覆盖（C4 Codex 对照 Top2/Top3）：
// · O-06：生成中回车排队落盘，流不中断，结束后自动按 FIFO 正常发送。
//   原 system-steer 格式 helper 的独立测试保留，不恢复旧自动注入。
// · 转录「编辑」→ 内容填回输入框 → 回车 = 新建一轮重发（D-CHAT-09：
//   原消息与其后历史含持久化/provider 上下文不覆盖、不截断）。
//
// 说明：测试用 CapturingChatEngine 桩替换真实 Agent 引擎 —— 记录每次
// streamReply 收到的 systemPrompt / history / composerSnapshot（回合
// identity），流短暂延迟后结束，便于观察 isStreaming 窗口
// （不依赖 Ollama / 真实 Provider）。

/// 测试桩引擎：记录每次 streamReply 的 systemPrompt、history 与回合快照。
final class CapturingChatEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { true }
    private(set) var calls: [(history: [ChatMessageUI], systemPrompt: String)] = []
    private(set) var snapshots: [ComposerSubmissionSnapshot] = []
    /// 每次流的时长（默认 200ms，保证测试能观察到 isStreaming 状态）
    var streamDelay: Duration = .milliseconds(200)
    var preparationFailure: Error?

    func interrupt() {}

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        if let preparationFailure { throw preparationFailure }
        calls.append((history, systemPrompt))
        let delay = streamDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.textDelta("（测试回复）"))
                try? await Task.sleep(for: delay)
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 生产发送链路带 composerSnapshot 时走此 witness：记录回合 identity
    /// 后转发到 4 参数核心（保持 calls 计数语义不变）。
    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        snapshots.append(composerSnapshot)
        return try await streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens
        )
    }
}

// MARK: - 转向（steer）

@Suite("C4-2 转向（生成中回车）")
@MainActor
struct SteerTests {
    /// 等待流结束（超时兜底 10s）
    private func waitForStreamEnd(_ chat: ChatStore) async throws {
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(!chat.isStreaming)
    }

    @Test func enterDuringStreamingQueuesDurablyAndAutoSendsWithoutCancelling() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("o06-single-queue") { root async throws -> Void in
            let suite = "o06-single-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SessionStore(directory: root.appendingPathComponent("sessions"))
            let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
            let chat = ChatStore(preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("logs")))
            defer { chat.stopAllStreamingForSafety() }
            try #require(chat.attachPersistence(store))
            chat.attachDraftStore(drafts)
            chat.newMessageInterruptsGeneration = { false }
            let engine = CapturingChatEngine()
            chat.agentEngine = engine
            chat.streamingProviderOverride = MockProvider()
            chat.draftText = "第一个问题"
            chat.sendDraft()
            try await Task.sleep(for: .milliseconds(50))
            try #require(chat.isStreaming && engine.calls.count == 1)
            let sessionID = try #require(chat.activeSessionID)
            let firstIdentity = try #require(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
            let userCountBefore = chat.messages.filter { $0.role == .user }.count

            chat.draftText = "从现在起用中文回答"
            chat.sendDraft()
            #expect(chat.isStreaming && engine.calls.count == 1)
            #expect(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity == firstIdentity)
            #expect(chat.draftText.isEmpty)
            #expect(chat.messages.filter { $0.role == .user }.count == userCountBefore)
            let queued = chat.activeQueuedComposerMessages
            try #require(queued.count == 1)
            #expect(queued[0].sessionID == sessionID && queued[0].text == "从现在起用中文回答")
            #expect(chat.queuePersistenceNotice == nil)
            #expect(try ComposerQueuePersistence.load(using: drafts) == queued)
            #expect(chat.pendingSteers.isEmpty)
            #expect(!chat.messages.contains { $0.role == .system && $0.content.hasPrefix("↗ 转向：") })

            // O-06 auto-consumes the queue; no extra user submission starts it.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && (engine.calls.count < 2 || chat.isStreaming
                || !chat.activeQueuedComposerMessages.isEmpty || chat.turnTaskForTests(sessionID: sessionID) != nil) {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!chat.isStreaming && chat.turnTaskForTests(sessionID: sessionID) == nil)
            #expect(engine.calls.count == 2)
            #expect(engine.snapshots.count == 2 && Set(engine.snapshots.map(\.taskID)).count == 2)
            #expect(engine.calls.map { $0.history.last(where: { $0.role == .user })?.content }
                == ["第一个问题", "从现在起用中文回答"])
            #expect(engine.calls.allSatisfy { !$0.systemPrompt.contains("[转向指令]") })
            #expect(chat.terminalReceipt(for: firstIdentity)?.outcome == .succeeded)
            let lastIdentity = try #require(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
            #expect(lastIdentity != firstIdentity)
            #expect(chat.terminalReceipt(for: lastIdentity)?.outcome == .succeeded)
            #expect(chat.activeQueuedComposerMessages.isEmpty && chat.pendingSteers.isEmpty)
            #expect(try ComposerQueuePersistence.load(using: drafts).isEmpty)
            #expect(chat.messages.filter { $0.role == .user }.map(\.content)
                == ["第一个问题", "从现在起用中文回答"])
            let persisted = try #require(store.loadSession(id: sessionID.uuidString))
            #expect(persisted.messages.filter { $0.role == .user }.map(\.content)
                == ["第一个问题", "从现在起用中文回答"])
        }
    }

    @Test(arguments: ["failed", "cancelled", "succeeded"])
    func dequeuedPreparationPreservesCanonicalInputAndFailedRetryDoesNotDuplicate(outcome: String) async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("s01-queue-preparation") { root async throws -> Void in
            let suite = "s01-queue-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SessionStore(directory: root.appendingPathComponent("sessions"))
            let drafts = root.appendingPathComponent("drafts")
            let chat = ChatStore(preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("logs")))
            defer { chat.stopAllStreamingForSafety() }
            try #require(chat.attachPersistence(store))
            chat.attachDraftStore(DraftStore(directory: drafts))
            let sessionID = try #require(chat.activeSessionID)
            let text = "S01 owned queued payload"
            chat.draftText = text
            try #require(chat.enqueueComposer())
            try #require(chat.queuePersistenceNotice == nil)
            let queued = try #require(chat.activeQueuedComposerMessages.first)
            let beforeReopen = ChatStore(preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("before-reopen-logs")))
            try #require(beforeReopen.attachPersistence(store))
            beforeReopen.attachDraftStore(DraftStore(directory: drafts))
            #expect(beforeReopen.queuedComposerMessages.contains { $0.id == queued.id && $0.text == text })

            let engine = CapturingChatEngine()
            enum PreparationFailure: Error { case unavailable }
            if outcome == "failed" { engine.preparationFailure = PreparationFailure.unavailable }
            if outcome == "cancelled" { engine.preparationFailure = CancellationError() }
            chat.agentEngine = engine
            chat.streamingProviderOverride = MockProvider()
            try #require(chat.sendNextQueuedComposer())
            let turn = try #require(chat.turnTaskForTests(sessionID: sessionID))
            await turn.value
            let terminal = try #require(chat.executionSnapshot(forSessionID: sessionID))
            if outcome == "failed" { #expect(terminal.state == .failed) }
            if outcome != "failed" { #expect(terminal.state == .idle) }
            let identity = try #require(terminal.executionIdentity)
            let receipt = try #require(chat.terminalReceipt(for: identity))
            if outcome == "failed" { #expect(receipt.outcome == .failed) }
            if outcome == "cancelled" { #expect(receipt.outcome == .cancelled) }
            if outcome == "succeeded" { #expect(receipt.outcome == .succeeded) }
            #expect(engine.calls.count == (outcome == "succeeded" ? 1 : 0))
            // Characterize the current ownership transfer, not S01 acceptance:
            // queue identity is gone, while its exact user input is durable.
            #expect(!chat.queuedComposerMessages.contains { $0.id == queued.id })
            let canonical = try #require(store.loadSession(id: sessionID.uuidString))
            let originalUsers = canonical.messages.filter { $0.role == .user && $0.content == text }
            try #require(originalUsers.count == 1)
            let originalUserIDs = chat.messages.filter { $0.role == .user && $0.content == text }.map(\.id)
            try #require(originalUserIDs.count == 1)
            let afterReopen = ChatStore(preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("after-reopen-logs")))
            try #require(afterReopen.attachPersistence(store))
            afterReopen.attachDraftStore(DraftStore(directory: drafts))
            afterReopen.switchSession(id: sessionID)
            #expect(!afterReopen.queuedComposerMessages.contains { $0.id == queued.id })
            #expect(afterReopen.messages.filter { $0.role == .user && $0.content == text }.count == 1)
            if outcome == "failed" {
                engine.preparationFailure = nil
                try #require(chat.retryFailedSession(terminal.retryIdentity))
                let retry = try #require(chat.turnTaskForTests(sessionID: sessionID))
                await retry.value
                #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
                #expect(engine.calls.count == 1)
                let retried = try #require(store.loadSession(id: sessionID.uuidString))
                #expect(retried.messages.filter { $0.role == .user && $0.content == text } == originalUsers)
                #expect(chat.messages.filter { $0.role == .user && $0.content == text }.map(\.id) == originalUserIDs)
            }
        }
    }

    @Test func steerSystemPromptFormatMatchesEngine() {
        let base = "你是助手"
        let injected = ChatStore.systemPrompt(
            withSteers: base,
            steers: ["用中文回答", "先计划再执行"]
        )
        #expect(injected.hasPrefix(base))
        #expect(injected.contains("[转向指令] 用中文回答"))
        #expect(injected.contains("[转向指令] 先计划再执行"))
        // 空列表 → 原样返回
        #expect(ChatStore.systemPrompt(withSteers: base, steers: []) == base)
    }

    // O-06 supersedes the old system-steer oracle; two queued inputs retain FIFO.
    @Test func multipleQueuedInputsPersistFIFOAndAutoSendWithoutCancelling() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("o06-multiple-queue") { root async throws -> Void in
            let suite = "o06-multiple-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SessionStore(directory: root.appendingPathComponent("sessions"))
            let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
            let chat = ChatStore(preferencesDefaults: defaults,
                logManager: LogManager(directory: root.appendingPathComponent("logs")))
            defer { chat.stopAllStreamingForSafety() }
            try #require(chat.attachPersistence(store))
            chat.attachDraftStore(drafts)
            chat.newMessageInterruptsGeneration = { false }
            let engine = CapturingChatEngine()
            chat.agentEngine = engine
            chat.streamingProviderOverride = MockProvider()
            chat.draftText = "第一个问题"
            chat.sendDraft()
            try await Task.sleep(for: .milliseconds(50))
            try #require(chat.isStreaming && engine.calls.count == 1)
            let sessionID = try #require(chat.activeSessionID)
            let firstIdentity = try #require(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
            let userCountBefore = chat.messages.filter { $0.role == .user }.count

            chat.draftText = "先说中文"
            chat.sendDraft()
            chat.draftText = "再简洁一点"
            chat.sendDraft()
            #expect(chat.isStreaming && engine.calls.count == 1)
            #expect(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity == firstIdentity)
            #expect(chat.draftText.isEmpty)
            #expect(chat.messages.filter { $0.role == .user }.count == userCountBefore)
            let queued = chat.activeQueuedComposerMessages
            try #require(queued.count == 2)
            #expect(queued.map(\.sessionID) == [sessionID, sessionID])
            #expect(queued.map(\.text) == ["先说中文", "再简洁一点"])
            #expect(Set(queued.map(\.id)).count == 2)
            #expect(chat.queuePersistenceNotice == nil)
            #expect(try ComposerQueuePersistence.load(using: drafts) == queued)
            #expect(chat.pendingSteers.isEmpty)
            #expect(!chat.messages.contains { $0.role == .system && $0.content.hasPrefix("↗ 转向：") })

            // O-06 auto-consumes the queue; no extra user submission starts it.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && (engine.calls.count < 3 || chat.isStreaming
                || !chat.activeQueuedComposerMessages.isEmpty || chat.turnTaskForTests(sessionID: sessionID) != nil) {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!chat.isStreaming && chat.turnTaskForTests(sessionID: sessionID) == nil)
            #expect(engine.calls.count == 3)
            #expect(engine.snapshots.count == 3 && Set(engine.snapshots.map(\.taskID)).count == 3)
            #expect(engine.calls.map { $0.history.last(where: { $0.role == .user })?.content }
                == ["第一个问题", "先说中文", "再简洁一点"])
            #expect(engine.calls.allSatisfy { !$0.systemPrompt.contains("[转向指令]") })
            #expect(chat.terminalReceipt(for: firstIdentity)?.outcome == .succeeded)
            let lastIdentity = try #require(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
            #expect(lastIdentity != firstIdentity)
            #expect(chat.terminalReceipt(for: lastIdentity)?.outcome == .succeeded)
            #expect(chat.activeQueuedComposerMessages.isEmpty && chat.pendingSteers.isEmpty)
            #expect(try ComposerQueuePersistence.load(using: drafts).isEmpty)
            #expect(chat.messages.filter { $0.role == .user }.map(\.content)
                == ["第一个问题", "先说中文", "再简洁一点"])
            let persisted = try #require(store.loadSession(id: sessionID.uuidString))
            #expect(persisted.messages.filter { $0.role == .user }.map(\.content)
                == ["第一个问题", "先说中文", "再简洁一点"])
        }
    }

}

// MARK: - 编辑旧消息 → 新建一轮重发（D-CHAT-09）

@Suite("C4-2 编辑消息（转录编辑 → 新建一轮重发，原历史保留）")
@MainActor
struct EditMessageTests {
    private func waitForStreamEnd(_ chat: ChatStore) async throws {
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(!chat.isStreaming)
    }

    @Test func beginEditFillsComposer() async throws {
        let chat = ChatStore()
        chat.agentEngine = CapturingChatEngine()
        chat.draftText = "待编辑的消息"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        let userMessage = chat.messages.first { $0.role == .user }!
        chat.beginEdit(messageID: userMessage.id)

        #expect(chat.isEditingMessage)
        #expect(chat.draftText == "待编辑的消息")
        #expect(chat.editingMessageID == userMessage.id)
    }

    /// D-CHAT-09 核心回归：编辑旧消息后回车 = 新建一轮（新 messageID +
    /// 新回合 identity 追加重发），原消息与其后全部历史（含 provider
    /// 请求上下文）不覆盖、不截断。
    @Test func resendStartsNewRoundAndKeepsOriginalHistory() async throws {
        let chat = ChatStore()
        let engine = CapturingChatEngine()
        chat.agentEngine = engine

        // 两条完整对话轮
        chat.draftText = "第一条"
        chat.sendDraft()
        try await waitForStreamEnd(chat)
        chat.draftText = "第二条"
        chat.sendDraft()
        try await waitForStreamEnd(chat)
        let countBefore = chat.messages.count
        #expect(countBefore == 5) // 欢迎语 + 用户×2 + 助手×2

        let firstUser = chat.messages.first { $0.role == .user }!
        let lastTurnIDBefore = engine.snapshots.last?.turnID

        // 编辑第一条：内容填回输入框 → 修改 → 回车 = 新建一轮重发
        chat.beginEdit(messageID: firstUser.id)
        chat.draftText = "第一条（改）"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        // 原消息与后续历史原样保留；编辑文本以新 id 的消息追加在末尾
        let usersAfter = chat.messages.filter { $0.role == .user }
        #expect(usersAfter.count == 3)
        #expect(usersAfter[0].id == firstUser.id)
        #expect(usersAfter[0].content == "第一条")
        #expect(usersAfter[1].content == "第二条")
        #expect(usersAfter[2].content == "第一条（改）")
        #expect(usersAfter[2].id != firstUser.id)
        #expect(chat.messages.count == countBefore + 2) // 新用户消息 + 新助手回复
        #expect(!chat.isEditingMessage)

        // provider 请求上下文 = 完整历史（含被编辑的原文与新消息结尾）
        #expect(engine.calls.count == 3)
        let lastHistory = engine.calls[2].history
        #expect(lastHistory.contains { $0.role == .user && $0.content == "第一条" })
        #expect(lastHistory.contains { $0.role == .user && $0.content == "第二条" })
        #expect(lastHistory.last?.role == .user)
        #expect(lastHistory.last?.content == "第一条（改）")

        // 回合 identity：编辑重发铸造全新 turnID / messageID（不复用编辑目标）
        #expect(engine.snapshots.count == 3)
        let editSnapshot = engine.snapshots.last!
        #expect(editSnapshot.messageID != firstUser.id.uuidString)
        if let lastTurnIDBefore {
            #expect(editSnapshot.turnID > lastTurnIDBefore)
        }
    }

    @Test func cancelEditKeepsMessageUntouched() async throws {
        let chat = ChatStore()
        chat.agentEngine = CapturingChatEngine()
        chat.draftText = "保持原样"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        let userMessage = chat.messages.first { $0.role == .user }!
        let countBefore = chat.messages.count

        chat.beginEdit(messageID: userMessage.id)
        chat.cancelEdit()

        #expect(!chat.isEditingMessage)
        #expect(chat.messages.count == countBefore)
        #expect(chat.messages.first { $0.role == .user }?.content == "保持原样")
    }

    /// D-CHAT-09「不损坏上一轮流」：生成中点「编辑」→ 旧流停止并被定格，
    /// 重发新轮不得改写停止后已定格的转录前缀。
    @Test func editDuringStreamingStopsPriorStreamAndResendDoesNotCorruptIt() async throws {
        let chat = ChatStore()
        let engine = CapturingChatEngine()
        chat.agentEngine = engine

        chat.draftText = "第一条"
        chat.sendDraft()
        try await waitForStreamEnd(chat)
        chat.draftText = "第二条"
        chat.sendDraft()
        try await Task.sleep(for: .milliseconds(50))
        #expect(chat.isStreaming)

        // 生成中「编辑」：beginEdit 停流（编辑即停流语义）
        let firstUser = chat.messages.first { $0.role == .user }!
        chat.beginEdit(messageID: firstUser.id)
        try await waitForStreamEnd(chat)
        // 停止后转录定格：作为不可改写前缀
        let frozen = chat.messages

        chat.draftText = "第一条（改）"
        chat.sendDraft()
        try await waitForStreamEnd(chat)

        // 前缀逐位一致（id/内容/流式标记均未被新轮破坏）
        #expect(Array(chat.messages.prefix(frozen.count)) == frozen)
        // 新轮只追加：编辑后的新用户消息 + 新助手回复
        #expect(chat.messages.count == frozen.count + 2)
        #expect(chat.messages.dropFirst(frozen.count).first?.role == .user)
        #expect(chat.messages.dropFirst(frozen.count).first?.content == "第一条（改）")
        // 重发走完整历史，编辑文本是 provider 上下文末条
        #expect(engine.calls.count == 3)
        #expect(engine.calls[2].history.last?.content == "第一条（改）")
    }
}
