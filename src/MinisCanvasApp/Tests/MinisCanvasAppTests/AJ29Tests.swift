import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

private final class IF05RetryRecordingEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "if05.retry-recording-engine")
    private(set) var turnIDs: [Int?] = []
    private(set) var providerIDs: [String] = []

    var isAvailable: Bool { true }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        queue.sync {
            turnIDs.append(nil)
            providerIDs.append(provider.model.id)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        queue.sync {
            turnIDs.append(turnID)
            providerIDs.append(provider.model.id)
        }
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

// MARK: - AJ-29 会话菜单（置顶 / 未读 / 排序 / 深链）

@Suite("AJ-29 会话菜单")
@MainActor
struct AJ29SessionMenuTests {

    /// 临时目录：所有 SessionStore 落临时目录，不碰 Application Support。
    private func makeStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AJ29Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionStore(directory: dir), dir)
    }

    // MARK: 置顶排序

    @Test func pinMovesSessionToFront() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.appendUser("第一条")
        chat.newSession()
        let secondID = chat.activeSessionID!
        chat.appendUser("第二条")
        // 默认最近更新在前：second 在 first 前
        #expect(chat.sessionList.first?.session.id == secondID)

        // 置顶第一条 → 它跳到最前（尽管它更旧）
        chat.setPinned(true, sessionID: firstID)
        #expect(chat.sessionList.first?.session.id == firstID)
        #expect(chat.sessions.first { $0.id == firstID }?.pinned == true)

        // 取消置顶 → 恢复按时间排序
        chat.setPinned(false, sessionID: firstID)
        #expect(chat.sessionList.first?.session.id == secondID)
    }

    // MARK: 未读标记

    @Test func unreadMarkedAndClearedOnSwitch() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.appendUser("第一条")
        chat.newSession()
        _ = chat.activeSessionID!
        chat.appendUser("第二条")

        chat.setUnread(true, sessionID: firstID)
        #expect(chat.sessions.first { $0.id == firstID }?.unread == true)

        // 切到该会话 → 自动标记已读
        chat.switchSession(id: firstID)
        #expect(chat.sessions.first { $0.id == firstID }?.unread == false)
        #expect(chat.activeSessionID == firstID)
    }

    // MARK: 持久化（置顶 + 未读 经磁盘往返）

    @Test func pinnedUnreadPersistThroughReload() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let id = chat.activeSessionID!
        chat.appendUser("测试")
        chat.setPinned(true, sessionID: id)
        chat.setUnread(true, sessionID: id)

        // 重新装配：从磁盘恢复 pinned/unread
        let chat2 = ChatStore()
        chat2.attachPersistence(store)
        let restored = chat2.sessions.first { $0.id == id }
        #expect(restored?.pinned == true)
        #expect(restored?.unread == true)
    }

    @Test func onlyChangedSessionsReachDisk() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let firstID = chat.activeSessionID!
        chat.appendUser("第一会话内容")
        let secondID = chat.applyNewSession(title: "第二会话")
        chat.appendUser("第二会话内容")
        chat.flushPendingSessionPersistence()
        #expect(store.loadSession(id: firstID.uuidString)?.messages.isEmpty == false)
        #expect(store.loadSession(id: secondID.uuidString)?.messages.isEmpty == false)
        let firstCount = store.loadSession(id: firstID.uuidString)?.messages.count

        chat.renameSession(id: secondID, title: "改名后")
        chat.flushPendingSessionPersistence()
        #expect(store.loadSession(id: secondID.uuidString)?.title == "改名后")
        // 改名第二会话不应改动第一会话的落盘内容。
        #expect(store.loadSession(id: firstID.uuidString)?.messages.count == firstCount)
    }

    // MARK: 深链 / 文件 URL

    @Test func sessionDeepLinkFormat() {
        let id = UUID()
        let link = ChatStore.sessionDeepLink(for: id)
        #expect(link == "miniscanvas://session/\(id.uuidString)")
        #expect(link.hasPrefix("miniscanvas://session/"))
    }

    @Test func sessionFileURLNotNullWhenPersisted() {
        let (store, _) = makeStore()
        let chat = ChatStore()
        #expect(chat.sessionFileURL(UUID()) == nil) // 未装配 → nil

        chat.attachPersistence(store)
        let id = chat.activeSessionID!
        let url = chat.sessionFileURL(id)
        #expect(url != nil)
        #expect(url?.lastPathComponent == "\(id.uuidString).json")
    }

    // MARK: 会话行四态

    @Test func conversationIndicatorUsesFailedRunningUnreadIdlePriority() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 123)
        let running = ChatStore.ExecutionSnapshot(
            sessionID: id, turnID: 7, taskID: "chat-\(id.uuidString)-7",
            state: .running, updatedAt: now
        )
        #expect(ChatStore.ConversationListIndicator.derive(execution: running, unread: true) == .running)

        let failed = ChatStore.ExecutionSnapshot(
            sessionID: id, turnID: 7, taskID: "chat-\(id.uuidString)-7",
            state: .failed, updatedAt: now, failureReason: "请求失败"
        )
        #expect(ChatStore.ConversationListIndicator.derive(execution: failed, unread: true) == .failed(reason: "请求失败"))
        #expect(ChatStore.ConversationListIndicator.derive(execution: nil, unread: true) == .unread)
        #expect(ChatStore.ConversationListIndicator.derive(execution: nil, unread: false) == .idle)
    }

    @Test func conversationExecutionIsolatedAcrossSessionsAndRetainsIdentity() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.newSession()
        let secondID = chat.activeSessionID!
        let now = Date(timeIntervalSince1970: 456)

        chat.markExecutionRunning(
            sessionID: firstID, turnID: 11, taskID: "task-a", updatedAt: now
        )
        chat.markExecutionRunning(
            sessionID: secondID, turnID: 12, taskID: "task-b", updatedAt: now
        )

        #expect(chat.executionSnapshot(forSessionID: firstID)?.sessionID == firstID)
        #expect(chat.executionSnapshot(forSessionID: firstID)?.turnID == 11)
        #expect(chat.executionSnapshot(forSessionID: firstID)?.taskID == "task-a")
        #expect(chat.sessionList.first { $0.id == firstID }?.indicator == .running)
        #expect(chat.sessionList.first { $0.id == secondID }?.indicator == .running)

        chat.markExecutionFailed(
            sessionID: firstID, reason: "/Users/alice/private-token=secret\nnetwork failure",
            updatedAt: now
        )
        #expect(chat.sessionList.first { $0.id == firstID }?.indicator == .failed(reason: "network failure"))
        #expect(chat.sessionList.first { $0.id == secondID }?.indicator == .running)
    }

    @Test func conversationCancellationFallsBackToUnreadAndPersistsUnread() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let id = chat.activeSessionID!
        chat.markExecutionRunning(sessionID: id, turnID: 3, taskID: "task-c", updatedAt: Date())
        chat.setUnread(true, sessionID: id)
        chat.markExecutionCancelled(sessionID: id, updatedAt: Date())

        #expect(chat.executionSnapshot(forSessionID: id)?.state == .idle)
        #expect(chat.sessionList.first?.indicator == .unread)

        let restored = ChatStore()
        restored.attachPersistence(store)
        #expect(restored.sessions.first { $0.id == id }?.unread == true)
        #expect(restored.sessionList.first { $0.id == id }?.indicator == .unread)
    }

    @Test func agentTaskStoreProjectsRunningAndFailedStatesToSessionRow() throws {
        let chat = ChatStore()
        let sessionID = chat.activeSessionID!
        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(
            taskID: "task-session-row",
            parentID: sessionID.uuidString,
            providerID: "test-provider",
            modelID: "test-model"
        )
        _ = try taskStore.startRun(taskID: "task-session-row", runID: "run-session-row")
        chat.attachAgentTaskStore(taskStore)
        #expect(chat.sessionList.first?.indicator == .running)

        _ = try taskStore.finish(
            runID: "run-session-row",
            outcome: .failed(reason: "provider failure")
        )
        #expect(chat.sessionList.first?.indicator == .failed(reason: "execution-failed"))
    }

    @Test func agentTaskStoreFailureUsesTheSameRetryEntryPoint() throws {
        let chat = ChatStore()
        let sessionID = chat.activeSessionID!
        chat.appendUser("请重试这个请求")

        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(
            taskID: "task-session-row-retry",
            parentID: sessionID.uuidString,
            providerID: "test-provider",
            modelID: "test-model"
        )
        _ = try taskStore.startRun(taskID: "task-session-row-retry", runID: "run-session-row-retry")
        _ = try taskStore.finish(
            runID: "run-session-row-retry",
            outcome: .failed(reason: "/Users/alice/private-token=secret")
        )
        chat.attachAgentTaskStore(taskStore)

        #expect(chat.sessionList.first?.indicator == .failed(reason: "execution-failed"))
        let identity = try #require(chat.sessionList.first?.retryIdentity)
        #expect(chat.sessionList.first?.retryIdentity == identity)
        #expect(chat.retryFailedSession(identity))
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .running)
        chat.stopStreaming()
    }

    @Test func failedExecutionStatePersistsAndRestoresRetryIdentity() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("需要重试")
        chat.markExecutionRunning(
            sessionID: sessionID, turnID: 21, taskID: "task-old", updatedAt: Date(timeIntervalSince1970: 21)
        )
        chat.markExecutionFailed(
            sessionID: sessionID, reason: "provider failure", updatedAt: Date(timeIntervalSince1970: 22)
        )

        let restored = ChatStore()
        restored.attachPersistence(store)
        let restoredIdentity = try #require(restored.sessionList.first?.retryIdentity)
        #expect(restoredIdentity.sessionID == sessionID)
        #expect(restoredIdentity.taskID == "task-old")
        #expect(restored.executionSnapshot(forSessionID: sessionID)?.state == .failed)
    }

    /// a350e70e 起：生成中被杀、没有落盘回复的回合，重启后标成"中断，可重试"，不自动重发。
    @Test func runningExecutionBecomesRetryableFailureAfterReloadWithoutRedispatch() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("运行态恢复")
        chat.markExecutionRunning(
            sessionID: sessionID, turnID: 23, taskID: "task-running", updatedAt: Date(timeIntervalSince1970: 23)
        )

        let restored = ChatStore()
        restored.attachPersistence(store)
        #expect(restored.executionSnapshot(forSessionID: sessionID)?.state == .failed)
        #expect(restored.sessionList.first?.indicator == .failed(reason: "上次回复在生成中被中断，可重试"))
        #expect(restored.sessionList.first?.retryIdentity?.taskID == "task-running")
        #expect(!restored.isStreaming)
    }

    @Test func failedExternalProjectionWinsOverRunningProjection() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(
            taskID: "task-running-priority",
            parentID: sessionID.uuidString,
            providerID: "test-provider",
            modelID: "test-model"
        )
        _ = try taskStore.startRun(taskID: "task-running-priority", runID: "run-running-priority")
        _ = try taskStore.enqueue(
            taskID: "task-failed-priority",
            parentID: sessionID.uuidString,
            providerID: "test-provider",
            modelID: "test-model"
        )
        _ = try taskStore.startRun(taskID: "task-failed-priority", runID: "run-failed-priority")
        _ = try taskStore.finish(
            runID: "run-failed-priority", outcome: .failed(reason: "priority failure")
        )
        chat.attachAgentTaskStore(taskStore)
        #expect(chat.sessionList.first?.indicator == .failed(reason: "execution-failed"))
    }

    /// MC4-028：账本里更早的失败不能一直盖住之后新一轮的状态；新一轮开始后才失败的任务照常显示。
    @Test func earlierLedgerFailureDoesNotCoverALaterTurnButNewFailureStillShows() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("先失败后成功")
        let taskStore = AgentTaskStore()
        func addFailed(_ taskID: String) throws {
            _ = try taskStore.enqueue(taskID: taskID, parentID: sessionID.uuidString,
                                      providerID: "test-provider", modelID: "test-model")
            _ = try taskStore.startRun(taskID: taskID, runID: "run-\(taskID)")
            _ = try taskStore.finish(runID: "run-\(taskID)", outcome: .failed(reason: "failure"))
        }
        try addFailed("mc4-028-earlier")
        chat.attachAgentTaskStore(taskStore)
        #expect(chat.sessionList.first?.indicator == .failed(reason: "execution-failed"))

        chat.markExecutionRunning(sessionID: sessionID, turnID: 2, taskID: "chat-turn-2")
        chat.markExecutionSucceeded(sessionID: sessionID)
        #expect(chat.sessionList.first?.indicator == .idle)

        try addFailed("mc4-028-later-child")
        #expect(chat.sessionList.first?.indicator == .failed(reason: "execution-failed"))
    }

    @Test func ledgerSessionIDReadsBareAndPrefixedParents() {
        let id = UUID()
        #expect(ChatStore.ledgerSessionID(parentID: id.uuidString) == id)
        #expect(ChatStore.ledgerSessionID(parentID: "session:\(id.uuidString)") == id)
        #expect(ChatStore.ledgerSessionID(parentID: "child-task-1") == nil)
    }

    @Test func externalFailureRetryUsesImmutableIdentityAndSuppressesOldProjection() async throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("外部失败后重试")
        let engine = IF05RetryRecordingEngine()
        chat.agentEngine = engine

        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(
            taskID: "task-external-old",
            parentID: sessionID.uuidString,
            providerID: "test-provider",
            modelID: "test-model",
            routeReceiptID: "receipt-old"
        )
        _ = try taskStore.startRun(taskID: "task-external-old", runID: "run-external-old")
        _ = try taskStore.finish(
            runID: "run-external-old",
            outcome: .failed(reason: "provider failure")
        )
        chat.attachAgentTaskStore(taskStore)

        let oldIdentity = try #require(chat.sessionList.first?.retryIdentity)
        #expect(oldIdentity.taskID == "task-external-old")
        #expect(chat.retryFailedSession(oldIdentity))
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .running)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.taskID != oldIdentity.taskID)
        #expect(!chat.retryFailedSession(oldIdentity))

        for _ in 0..<50 where chat.sessionList.first?.indicator == .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.sessionList.first?.indicator == .idle)
        #expect(engine.turnIDs.compactMap { $0 }.count == 1)
    }

    @Test func sidebarBatchProjectionKeepsParentFormatsSortedPriorityAndSuppression() async throws {
        let suite = "sidebar-batch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = ChatStore(preferencesDefaults: defaults)
        let firstID = try #require(chat.activeSessionID)
        chat.newSession()
        let secondID = try #require(chat.activeSessionID)
        chat.newSession()
        let idleID = try #require(chat.activeSessionID)
        chat.switchSession(id: firstID)
        chat.appendUser("合成失败任务重试")
        chat.agentEngine = IF05RetryRecordingEngine()

        let taskStore = AgentTaskStore()
        func addFailed(_ taskID: String, parentID: String) throws {
            _ = try taskStore.enqueue(
                taskID: taskID, parentID: parentID,
                providerID: "synthetic-provider", modelID: "synthetic-model",
                routeReceiptID: "synthetic-route-\(taskID)"
            )
            let runID = "run-\(taskID)"
            _ = try taskStore.startRun(taskID: taskID, parentID: parentID, runID: runID)
            _ = try taskStore.finish(runID: runID, outcome: .failed(reason: "synthetic failure"))
        }
        try addFailed("a-first-failure", parentID: firstID.uuidString)
        try addFailed("b-next-failure", parentID: firstID.uuidString)
        try addFailed("c-prefixed-failure", parentID: "session:\(firstID.uuidString)")
        _ = try taskStore.enqueue(
            taskID: "z-later-queued", parentID: secondID.uuidString,
            providerID: "synthetic-provider", modelID: "synthetic-model"
        )
        _ = try taskStore.enqueue(
            taskID: "a-first-queued", parentID: secondID.uuidString,
            providerID: "synthetic-provider", modelID: "synthetic-model"
        )
        chat.attachAgentTaskStore(taskStore)

        let rows = Dictionary(uniqueKeysWithValues: chat.sessionList.map { ($0.id, $0) })
        #expect(rows[firstID]?.execution?.taskID == "a-first-failure")
        #expect(rows[firstID]?.indicator == .failed(reason: "execution-failed"))
        #expect(rows[secondID]?.execution?.taskID == "a-first-queued")
        #expect(rows[secondID]?.indicator == .running)
        #expect(rows[idleID]?.execution == nil)
        #expect(rows[firstID]?.execution?.taskID == chat.executionSnapshot(forSessionID: firstID)?.taskID)
        #expect(rows[secondID]?.execution?.taskID == chat.executionSnapshot(forSessionID: secondID)?.taskID)

        let firstFailure = try #require(rows[firstID]?.retryIdentity)
        #expect(chat.retryFailedSession(firstFailure))
        // MC4-028：重试开始新一轮后，本会话更早的账本失败不再盖住侧栏（任务中心里仍保留）。
        #expect(chat.executionSnapshot(forSessionID: firstID)?.state == .running)
        #expect(chat.sessionList.first(where: { $0.id == firstID })?.execution?.taskID
            == chat.executionSnapshot(forSessionID: firstID)?.taskID)
        #expect(chat.executionSnapshot(forSessionID: firstID)?.taskID != "b-next-failure")
        #expect(taskStore.snapshot(taskID: "b-next-failure")?.status == .failed)
        #expect(chat.sessionList.first(where: { $0.id == secondID })?.execution?.taskID == "a-first-queued")
        chat.stopStreaming()
    }

    @Test func completedExternalTaskCannotBeRetriedUsingStaleIdentity() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("已完成任务")
        let taskStore = AgentTaskStore()
        _ = try taskStore.enqueue(
            taskID: "task-completed",
            parentID: sessionID.uuidString,
            providerID: "test-provider",
            modelID: "test-model"
        )
        _ = try taskStore.startRun(taskID: "task-completed", runID: "run-completed")
        _ = try taskStore.finish(runID: "run-completed", outcome: .failed(reason: "first failure"))
        chat.attachAgentTaskStore(taskStore)
        let staleIdentity = try #require(chat.sessionList.first?.retryIdentity)
        // The external ledger is immutable after settlement. Once this row
        // has moved to a fresh terminal local state, the old identity is stale.
        chat.attachAgentTaskStore(AgentTaskStore())
        chat.markExecutionRunning(
            sessionID: sessionID, turnID: 40, taskID: "task-new", updatedAt: Date(timeIntervalSince1970: 40)
        )
        chat.markExecutionSucceeded(sessionID: sessionID, updatedAt: Date(timeIntervalSince1970: 41))
        #expect(!chat.retryFailedSession(staleIdentity))
    }

    @Test("exact search hit never follows a forked session") func exactSearchHitNeverFollowsForkedSession() async throws {
        let chat = ChatStore()
        let sourceID = try #require(chat.activeSessionID)
        chat.appendUser("AJ29搜索命中")
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("AJ29搜索命中")
        // `updateQuery` is cancellable and schedules its work asynchronously;
        // refresh provides a deterministic settled snapshot before the test
        // exercises the stable source-session identity after a fork.
        model.refresh()
        let hit = try #require(model.results.first)

        let forkID = try #require(chat.duplicateSession(id: sourceID))
        #expect(forkID != sourceID)
        #expect(chat.activeSessionID == forkID)
        #expect(chat.openSearchResult(hit))
        #expect(chat.activeSessionID == sourceID)
        #expect(chat.searchScrollTarget?.stableMessageID == hit.messageID)
    }

    @Test func oldTaskIdentityAndMissingUserMessageFailClosed() throws {
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.markExecutionRunning(
            sessionID: sessionID, turnID: 31, taskID: "task-first", updatedAt: Date(timeIntervalSince1970: 31)
        )
        chat.markExecutionFailed(sessionID: sessionID, reason: "first failure")
        let oldIdentity = try #require(chat.sessionList.first?.retryIdentity)
        chat.markExecutionRunning(
            sessionID: sessionID, turnID: 32, taskID: "task-second", updatedAt: Date(timeIntervalSince1970: 32)
        )
        chat.markExecutionFailed(sessionID: sessionID, reason: "second failure")
        #expect(!chat.retryFailedSession(oldIdentity))

        let noUser = ChatStore()
        let noUserID = try #require(noUser.activeSessionID)
        noUser.markExecutionRunning(sessionID: noUserID, turnID: 33, taskID: "task-no-user")
        noUser.markExecutionFailed(sessionID: noUserID, reason: "failure")
        let noUserIdentity = try #require(noUser.sessionList.first?.retryIdentity)
        #expect(!noUser.retryFailedSession(noUserIdentity))
    }
}
