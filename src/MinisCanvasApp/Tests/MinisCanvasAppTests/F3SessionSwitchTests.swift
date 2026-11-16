import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - F3 对话互不干扰（问题②回归测试）
//
// 用户实测：A 会话生成中，切到 B 会话发任务 → A 的回复被中断（自断）。
// 根因（2026-08-07 调查实锤）：
//   1) switchSession(945) 无条件 `stopStreamingForSwitch()` → `streamingTask?.cancel()`
//      取消 A 流（切走即杀）；
//   2) sendDraft(~1772) 全局 `if isStreaming` 判打断 → 在 B 发消息也会取消 A 流；
//   3) 程序性停止调用 `agentEngine.interrupt()` → TurnController 把停止信号排队给
//      下一 turn → 后续对话首轮必「已中断」（用户实测全灭）。
// 修复（F3 per-session 流跟踪，2026-08-07 第三轮升级为流任务字典）：
//   · streamingTasks: [UUID?: Task] —— 每会话独立流，支持 A/B 并发：
//     A 生成中切到 B 发任务 → A/B 各占一项，互不干扰；
//   · streamReply 按「启动时会话」key 注册任务，流结束只移除自己；
//   · switchSession / newSession / restoreSession 一律不取消旧流（旧流后台按
//     sessionID 写回原会话）；
//   · sendDraft 只打断「当前活跃会话自己的流」（isActiveSessionStreaming）；
//   · finishStoppingStreaming 守卫 `streamingTasks[activeSessionID] != nil`；
//   · 程序性停止只走 streamingTask?.cancel()，绝不调 agentEngine.interrupt()。

@Suite("F3 会话切换不杀旧流（问题②）")
@MainActor
struct F3SessionSwitchTests {

    final class NamedProvider: LLMProvider, @unchecked Sendable {
        let name: String
        var model: LLMModel

        init(_ name: String) {
            self.name = name
            self.model = LLMModel(id: name.lowercased(), displayName: name, provider: name)
        }

        var capabilities: Set<ProviderCapability> { [.streaming] }

        func sendMessage(
            messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
        ) async throws -> LLMResponse {
            LLMResponse(text: name, stopReason: "end_turn", usage: nil)
        }

        func sendMessage(
            messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
            maxTokens: Int, temperature: Double?
        ) async throws -> LLMResponse {
            try await sendMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }

        func streamMessage(
            messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
        ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    final class ProviderCaptureEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
        var isAvailable: Bool { true }

        private let lock = NSLock()
        private var _providerNames: [String] = []
        var providerNames: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _providerNames
        }

        private func recordProviderName(_ name: String) {
            lock.lock()
            _providerNames.append(name)
            lock.unlock()
        }

        func streamReply(
            provider: any LLMProvider,
            history: [ChatMessageUI],
            systemPrompt: String,
            maxTokens: Int
        ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
            recordProviderName(provider.name)
            return AsyncThrowingStream { continuation in
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
            }
        }

        func interrupt() {}

        func compactContext(
            provider: any LLMProvider,
            history: [ChatMessageUI],
            systemPrompt: String,
            keepRecent: Int
        ) async -> CompactionResult {
            CompactionResult(messages: [], summary: nil, compactedCount: 0)
        }
    }

    // 复用 C4-1 的挂起流引擎：产出「部分输出」后挂起直到流被取消。
    // interrupt() 计数 → 断言程序性操作未触发引擎级中断。
    final class HangingEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
        var isAvailable: Bool { true }

        private let lock = NSLock()
        private var _interruptCount = 0
        var interruptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _interruptCount
        }

        func interrupt() {
            lock.lock()
            _interruptCount += 1
            lock.unlock()
        }

        func streamReply(
            provider: any LLMProvider,
            history: [ChatMessageUI],
            systemPrompt: String,
            maxTokens: Int
        ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.textDelta("部分输出"))
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func makePersistentChat() throws -> (ChatStore, SessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("F3-stop-persistence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = SessionStore(directory: directory)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        chat.agentEngine = HangingEngine()
        return (chat, store, directory)
    }

    private func sessionBytes(_ store: SessionStore, _ id: UUID) throws -> Data {
        try Data(contentsOf: store.sessionsDirectory.appendingPathComponent(id.uuidString + ".json"))
    }

    private func waitForPartialOutput(_ chat: ChatStore) async throws {
        var waited: TimeInterval = 0
        while !(chat.messages.last?.content.contains("部分输出") ?? false) && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(chat.messages.last?.content.contains("部分输出") == true)
    }

    // MARK: 核心：切到 B 会话（newSession）不取消 A 的流

    @Test func newSessionDoesNotCancelActiveStream() async throws {
        let chat = ChatStore()
        defer { chat.stopAllStreamingForSafety() }
        let mock = HangingEngine()
        chat.agentEngine = mock

        // A（默认会话）开始生成
        chat.draftText = "A 的任务"
        chat.sendDraft()
        #expect(chat.isStreaming)
        #expect(chat.isActiveSessionStreaming)
        try await waitForPartialOutput(chat)

        let sessionA = chat.activeSessionID
        #expect(sessionA != nil)

        // 切到新会话 B —— 不得取消 A 流、不得调引擎 interrupt
        chat.newSession()
        #expect(mock.interruptCount == 0, "newSession 不得调用引擎 interrupt")
        #expect(chat.activeSessionID != sessionA, "应已切到新会话")
        #expect(!chat.isActiveSessionStreaming, "B 会话自己没有流")
        // 旧流仍在跑：B 无流但全局 isStreaming 仍 true → A 的流任务仍挂在表里
        #expect(chat.isStreaming, "A 的旧流应仍在后台运行（isStreaming 唯一来源是 A）")
    }

    // MARK: 切到 B 发任务：只打断 B 自己的流，A 不受影响

    @Test func sendDraftInSessionBDoesNotCancelSessionAStream() async throws {
        let chat = ChatStore()
        defer { chat.stopAllStreamingForSafety() }
        let mock = HangingEngine()
        chat.agentEngine = mock

        // A 生成中
        chat.draftText = "A 的任务"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let sessionA = chat.activeSessionID

        // 切到 B
        chat.newSession()
        let sessionB = chat.activeSessionID
        #expect(sessionB != sessionA)

        // B 发任务：全局 isStreaming 仍 true（A 还在跑），但 per-session 判定
        // isActiveSessionStreaming=false → 不进入打断分支，A 流不受影响。
        // B 的流正常启动（流任务字典支持并发双流）。
        chat.draftText = "B 的任务"
        chat.sendDraft()
        #expect(chat.isStreaming)
        #expect(chat.isActiveSessionStreaming, "B 自己的流应被跟踪")
        try await waitForPartialOutput(chat)

        // 引擎 interrupt 一次都没被调（两轮都是正常发送，无打断）
        #expect(mock.interruptCount == 0)

        // A 流未被取消：切回 A，isActiveSessionStreaming 应为 true（A 流仍在跑）
        chat.switchSession(id: sessionA!)
        #expect(chat.isActiveSessionStreaming, "A 的旧流应仍在后台运行")
        #expect(chat.isStreaming, "A 与 B 双流并发，全局 isStreaming 仍 true")
    }

    // MARK: 停止按钮守卫：在 B 停止不杀 A 的流；切回 A 停止才停 A

    @Test func stopStreamingInSessionBDoesNotCancelSessionA() async throws {
        let (chat, _, directory) = try makePersistentChat()
        defer {
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        let mock = HangingEngine()
        chat.agentEngine = mock

        // A 生成中
        chat.draftText = "A 的任务"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let sessionA = chat.activeSessionID

        // 切到 B（A 流继续后台跑）
        chat.newSession()
        let _ = chat.activeSessionID
        #expect(chat.isActiveSessionStreaming == false)

        // 在 B 点停止：B 无流 → 必须完全 no-op，A 流不被取消，也不能触发
        // 共享 Agent 引擎的 interrupt。
        chat.stopStreaming()
        #expect(chat.isStreaming, "A 的流仍在后台运行（B 的停止未清流任务表）")
        #expect(mock.interruptCount == 0, "当前会话无流时不得中断其他会话")

        // 切回 A：A 流仍在（停止被守卫拦下，未误杀）
        chat.switchSession(id: sessionA!)
        #expect(chat.isActiveSessionStreaming, "A 的流应仍在运行（B 的停止未误杀）")

        // 在 A 点停止：守卫通过 → 真正停掉 A 流 + 「已中断」提示
        chat.stopStreaming()
        #expect(!chat.isStreaming)
        #expect(!chat.isActiveSessionStreaming)
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: directory)))
        let stopped = try #require(reopened.sessions.first(where: { $0.id == sessionA })?.messages.last)
        #expect(stopped.content == "部分输出" && !stopped.content.contains("**错误**"))
        #expect(stopped.wasInterrupted && !stopped.isStreaming)
        #expect(ChatTranscriptFormatter.accessibilityText([stopped]).contains("已中断"))
    }

    // MARK: 程序性停止（switchSession 不再调用）绝不向引擎发 interrupt

    @Test func switchSessionDoesNotInterruptEngine() async throws {
        let chat = ChatStore()
        defer { chat.stopAllStreamingForSafety() }
        let mock = HangingEngine()
        chat.agentEngine = mock

        chat.draftText = "A 的任务"
        chat.sendDraft()
        try await waitForPartialOutput(chat)

        // 直接 switchSession 到新会话（模拟 UI 切换）
        chat.newSession()
        let sessionB = chat.activeSessionID

        // 再切回 A：全程不得调引擎 interrupt
        let sessionA2 = chat.sessions.first(where: { $0.id != sessionB })?.id
        #expect(sessionA2 != nil)
        chat.switchSession(id: sessionA2!)
        #expect(mock.interruptCount == 0, "switchSession 全程不得调用引擎 interrupt")
    }

    // MARK: deleteSession 删除当前会话仍停当前流（守卫内）

    @Test func deleteActiveSessionStopsItsOwnStream() async throws {
        let chat = ChatStore()
        let mock = HangingEngine()
        chat.agentEngine = mock

        chat.draftText = "A 的任务"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let sessionA = chat.activeSessionID

        // 先建第二个会话（deleteSession 要求 sessions.count > 1）
        chat.newSession()
        let sessionB = chat.activeSessionID
        #expect(sessionB != sessionA)
        #expect(chat.isStreaming, "A 的流仍在后台（切走不杀）")

        // 切回 A 再删除当前会话：它自己的流应被程序性停止（守卫 streamingTasks[activeSessionID] 通过）
        chat.switchSession(id: sessionA!)
        let intent = try chat.previewDeletion(id: sessionA!)
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try chat.deleteSession(id: sessionA!, intent: intent)
        #expect(!chat.isStreaming, "删除当前会话后其流被程序性停止，全局无流")
        #expect(!chat.isActiveSessionStreaming)
        #expect(mock.interruptCount == 0, "程序性停止（删除会话）不得调引擎 interrupt")
    }

    @Test func deleteBackgroundSessionWhileBActiveCancelsOnlyA() async throws {
        let chat = ChatStore()
        let mock = HangingEngine()
        chat.agentEngine = mock

        chat.draftText = "A 的任务"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let sessionA = try #require(chat.activeSessionID)
        let writebackA = try #require(chat.activeWritebackIdentity(for: sessionA))
        let executionA = try #require(chat.activeExecutionIdentity(for: sessionA))
        #expect(chat.activeWritebackIdentity(for: sessionA) == writebackA)
        #expect(chat.activeExecutionIdentity(for: sessionA) == executionA)
        #expect(chat.executionSnapshot(forSessionID: sessionA)?.taskID != nil)

        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        #expect(sessionB != sessionA)
        chat.draftText = "B 的任务"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let writebackB = try #require(chat.activeWritebackIdentity(for: sessionB))
        let executionB = try #require(chat.activeExecutionIdentity(for: sessionB))
        let taskB = try #require(chat.executionSnapshot(forSessionID: sessionB)?.taskID)

        // B is active while A remains a background stream. Deleting A must
        // remove only A's stream and runtime identity/task projection.
        let intent = try chat.previewDeletion(id: sessionA)
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try chat.deleteSession(id: sessionA, intent: intent)

        #expect(!chat.hasSession(sessionA))
        #expect(chat.activeSessionID == sessionB)
        #expect(chat.activeWritebackIdentity(for: sessionA) == nil)
        #expect(chat.activeExecutionIdentity(for: sessionA) == nil)
        #expect(chat.executionSnapshot(forSessionID: sessionA) == nil)
        #expect(chat.activeWritebackIdentity(for: sessionB) == writebackB)
        #expect(chat.activeExecutionIdentity(for: sessionB) == executionB)
        #expect(chat.executionSnapshot(forSessionID: sessionB)?.taskID == taskB)
        #expect(chat.isActiveSessionStreaming)
        #expect(chat.isStreaming)
        #expect(mock.interruptCount == 0)

        // Keep the surviving B fixture bounded and clean.
        chat.stopStreaming()
    }

    @Test func staleTurnIdentityCannotWriteAfterStopOrNewTurn() async throws {
        let chat = ChatStore()
        let mock = HangingEngine()
        chat.agentEngine = mock
        let sessionID = try #require(chat.activeSessionID)

        chat.draftText = "第一回合"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let firstAssistant = try #require(chat.messages.last)
        let firstIdentity = try #require(
            chat.activeWritebackIdentity(for: sessionID)
        )

        chat.stopStreaming()
        chat.draftText = "第二回合"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let secondAssistant = try #require(chat.messages.last)

        #expect(
            chat.updateMessageContent(
                sessionID: sessionID,
                messageID: firstAssistant.id,
                identity: firstIdentity,
                append: "迟到写回"
            ) == false,
            "旧回合身份不能写入已停止的消息"
        )
        #expect(!secondAssistant.content.contains("迟到写回"))

        chat.stopStreaming()
    }

    @Test func staleTurnIdentityCannotReplaceOrFinalizeAfterStopOrNewTurn() async throws {
        let chat = ChatStore()
        let mock = HangingEngine()
        chat.agentEngine = mock
        let sessionID = try #require(chat.activeSessionID)

        chat.draftText = "第一回合"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let firstAssistant = try #require(chat.messages.last)
        let firstIdentity = try #require(
            chat.activeWritebackIdentity(for: sessionID)
        )

        chat.stopStreaming()
        chat.draftText = "第二回合"
        chat.sendDraft()
        try await waitForPartialOutput(chat)

        #expect(
            chat.replaceMessageContent(
                sessionID: sessionID,
                messageID: firstAssistant.id,
                identity: firstIdentity,
                with: "迟到整体替换"
            ) == false
        )
        #expect(
            chat.finalizeStreamingMessage(
                sessionID: sessionID,
                messageID: firstAssistant.id,
                identity: firstIdentity,
                suffix: "迟到结束"
            ) == false
        )
        #expect(chat.messages.last?.content.contains("迟到") == false)
        #expect(chat.messages.last?.isStreaming == true)

        chat.stopStreaming()
    }

    @Test func turnCapturesProviderBeforeSessionSwitch() async throws {
        let chat = ChatStore()
        let engine = ProviderCaptureEngine()
        chat.agentEngine = engine
        let providerA = NamedProvider("Provider-A")
        let providerB = NamedProvider("Provider-B")
        chat.streamingProviderOverride = providerA

        chat.draftText = "A 的任务"
        chat.sendDraft()
        chat.newSession()
        chat.streamingProviderOverride = providerB
        var waited = 0
        while engine.providerNames.isEmpty && waited < 100 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        #expect(engine.providerNames == ["Provider-A"], "A 回合不能读取切换后的 B Provider")
    }
    @Test func stoppedTerminalIsDurableBeforeAnotherUIActionAndRejectsLateWrites() async throws {
        let (chat, store, directory) = try makePersistentChat()
        defer {
            chat.onStreamingStopped = nil
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        let sessionID = try #require(chat.activeSessionID)
        chat.draftText = "取消后立即重启"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let assistant = try #require(chat.messages.last)
        let identity = try #require(chat.activeWritebackIdentity(for: sessionID))

        chat.stopStreaming()
        let expected = try #require(chat.messages.last?.content)
        #expect(expected == "部分输出")
        #expect(!expected.contains("**错误**"))
        let durable = try #require(store.loadSession(id: sessionID.uuidString))
        #expect(durable.messages.last?.role == .assistant)
        #expect(durable.messages.last?.content == expected)
        let savedBytes = try sessionBytes(store, sessionID)

        chat.stopStreaming()
        #expect(!chat.updateMessageContent(sessionID: sessionID, messageID: assistant.id,
                                          identity: identity, append: "迟到追加"))
        #expect(!chat.replaceMessageContent(sessionID: sessionID, messageID: assistant.id,
                                           identity: identity, with: "迟到替换"))
        #expect(!chat.finalizeStreamingMessage(sessionID: sessionID, messageID: assistant.id,
                                              identity: identity, suffix: "迟到结束"))
        #expect(try sessionBytes(store, sessionID) == savedBytes)

        let reopenedStore = SessionStore(directory: directory)
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(reopenedStore))
        #expect(reopened.activeSessionID == sessionID)
        #expect(reopened.messages.last?.content == expected)
        #expect(reopened.messages.last?.isStreaming == false)
        #expect(!reopened.isStreaming)
        let stopped = try #require(reopened.messages.last)
        #expect(stopped.wasInterrupted)
        #expect(ChatTranscriptFormatter.accessibilityText([stopped]).contains("已中断"))
    }

    @Test func cancelledOldTurnCannotChangeTheNextDurableTurn() async throws {
        let (chat, _, directory) = try makePersistentChat()
        defer {
            chat.onStreamingStopped = nil
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        let sessionID = try #require(chat.activeSessionID)
        chat.draftText = "旧回合"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let oldAssistant = try #require(chat.messages.last)
        let oldIdentity = try #require(chat.activeWritebackIdentity(for: sessionID))
        chat.stopStreaming()
        let cancelledContent = try #require(chat.messages.last?.content)

        chat.draftText = "新回合"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let newAssistantID = try #require(chat.messages.last?.id)
        #expect(!chat.updateMessageContent(sessionID: sessionID, messageID: oldAssistant.id,
                                          identity: oldIdentity, append: "旧回合迟到"))
        #expect(!chat.finalizeStreamingMessage(sessionID: sessionID, messageID: oldAssistant.id,
                                              identity: oldIdentity, suffix: "重复取消"))
        #expect(chat.messages.last?.id == newAssistantID)
        #expect(chat.messages.last?.isStreaming == true)
        chat.stopStreaming()

        let reopened = try #require(SessionStore(directory: directory).loadSession(id: sessionID.uuidString))
        let assistants = reopened.messages.filter { $0.role == .assistant }
        #expect(cancelledContent == "部分输出")
        #expect(assistants.suffix(2).map(\.content) == [cancelledContent, "部分输出"])
        #expect(reopened.messages.allSatisfy { !$0.content.contains("迟到") && !$0.content.contains("重复取消") })
        let restoredChat = ChatStore()
        #expect(restoredChat.attachPersistence(SessionStore(directory: directory)))
        let restoredSession = try #require(restoredChat.sessions.first(where: { $0.id == sessionID }))
        let stopped = Array(restoredSession.messages.filter { $0.role == .assistant }.suffix(2))
        #expect(stopped.count == 2)
        for message in stopped {
            #expect(message.wasInterrupted && !message.isStreaming)
            #expect(!message.content.contains("**错误**"))
            #expect(ChatTranscriptFormatter.accessibilityText([message]).contains("已中断"))
        }
    }

    @Test func stopPersistsCapturedSessionWhenCallbackChangesActiveSession() async throws {
        let (chat, store, directory) = try makePersistentChat()
        defer {
            chat.onStreamingStopped = nil
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        let sessionA = try #require(chat.activeSessionID)
        chat.draftText = "A 的流"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        chat.draftText = "B 的流"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        chat.switchSession(id: sessionA)
        chat.onStreamingStopped = { chat.switchSession(id: sessionB) }
        chat.stopStreaming()
        chat.onStreamingStopped = nil

        #expect(chat.activeSessionID == sessionB)
        #expect(chat.isActiveSessionStreaming)
        #expect(chat.messages.last?.isStreaming == true)
        #expect(chat.messages.last?.content == "部分输出")
        let restoredA = try #require(store.loadSession(id: sessionA.uuidString))
        #expect(restoredA.messages.last?.content == "部分输出")
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: directory)))
        let stoppedA = try #require(reopened.sessions.first(where: { $0.id == sessionA })?.messages.last)
        #expect(stoppedA.content == restoredA.messages.last?.content)
        #expect(stoppedA.wasInterrupted && !stoppedA.isStreaming)
        #expect(!stoppedA.content.contains("**错误**"))
        #expect(ChatTranscriptFormatter.accessibilityText([stoppedA]).contains("已中断"))
        chat.stopStreaming()
    }

    @Test func programmaticStopPersistsWithoutUserInterruptedHint() async throws {
        let (chat, _, directory) = try makePersistentChat()
        defer {
            chat.onStreamingStopped = nil
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        let sessionID = try #require(chat.activeSessionID)
        chat.draftText = "程序性停止"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        chat.stopStreamingForSwitch()
        #expect(!chat.isStreaming)
        let reopened = try #require(SessionStore(directory: directory).loadSession(id: sessionID.uuidString))
        #expect(reopened.messages.last?.content == "部分输出")
        #expect(reopened.messages.last?.content.contains("已中断") == false)
    }

    // MARK: D-RECOVERY-10：Kill Switch 全停必须持久化每个被终止的会话

    @Test func safetyStopAllPersistsEveryTerminatedSession() async throws {
        let (chat, store, directory) = try makePersistentChat()
        defer {
            chat.onStreamingStopped = nil
            chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: directory)
        }
        // A 会话生成中切到新建的 B 会话（A 的流按 F3 保留在后台），
        // 然后安全锁全停：两个会话的「已由安全锁终止」终态都不能只留在内存。
        let sessionA = try #require(chat.activeSessionID)
        chat.draftText = "A 的流"
        chat.sendDraft()
        try await waitForPartialOutput(chat)
        let aUpdatedAtBeforeStop = try #require(
            store.loadSession(id: sessionA.uuidString)
        ).updatedAt
        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        chat.draftText = "B 的流"
        chat.sendDraft()
        try await waitForPartialOutput(chat)

        chat.stopAllStreamingForSafety()

        #expect(!chat.isStreaming)
        // 每个被终止的会话（含已切走的 A）都必须被 touchSession 持久化：
        // 缺 touchSession 时终态只存内存，重启后恢复状态过期（D-RECOVERY-10）。
        for id in [sessionA, sessionB] {
            let durable = try #require(store.loadSession(id: id.uuidString))
            #expect(durable.messages.last?.role == .assistant)
            #expect(durable.messages.last?.content == "部分输出\n\n*⏹ 已由安全锁终止*")
            // isStreaming 是 UI 层专属标记，持久化模型 LLMMessage 从不落盘该字段
            // （口径同 ChatSessionBridge.swift 的 ChatThread↔ChatSession 边界注释）。
            // 持久层校验终态内容/排序键，流式标记复位在 UI 层校验。
            let live = try #require(chat.sessions.first { $0.id == id })
            #expect(live.messages.allSatisfy { !$0.isStreaming })
        }
        let durableA = try #require(store.loadSession(id: sessionA.uuidString))
        #expect(durableA.updatedAt > aUpdatedAtBeforeStop, "全停必须刷新被终止会话的 updatedAt/排序键")

        // 重新打开同一目录：看到的是终止终态，而不是仍在流式的旧状态。
        let reopenedStore = SessionStore(directory: directory)
        let reopenedA = try #require(reopenedStore.loadSession(id: sessionA.uuidString))
        let reopenedB = try #require(reopenedStore.loadSession(id: sessionB.uuidString))
        #expect(reopenedA.messages.last?.content == "部分输出\n\n*⏹ 已由安全锁终止*")
        #expect(reopenedB.messages.last?.content == "部分输出\n\n*⏹ 已由安全锁终止*")
        // 「重启后不再显示仍在流式」是 UI 恢复层契约（持久 schema 无 isStreaming 字段，
        // 口径同本文件 cancelThenImmediateRestart 的 reopened ChatStore 检查）。
        let reopenedChat = ChatStore()
        #expect(reopenedChat.attachPersistence(reopenedStore))
        #expect(!reopenedChat.isStreaming)
        for id in [sessionA, sessionB] {
            let restored = try #require(reopenedChat.sessions.first { $0.id == id })
            #expect(restored.messages.allSatisfy { !$0.isStreaming })
        }
    }

}
