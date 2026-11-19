import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - QODER-DEV-256-SESSION01 — P3-SESSION-01 会话生命周期重启存活证明
//
// Canonical 总表 :294 的验收列要求「全生命周期和重启恢复同一 App SHA 通过」，
// 当前事实列点名「重命名、归档恢复和重启仍有问题/未测」。本套件不引入新断言
// 口径，只把既有四个入口（renameSession / archiveSession / restoreSession /
// deleteArchivedSession）串成「真实落盘 → 全新 ChatStore 重挂载同一 SessionStore
// 目录」的重启链；重挂载即重启语义的最小可执行代理（attachPersistence 重读磁盘
// 会话与 _archive 目录，内存态不跨实例传递），不以任何静态 fixture 代证。

@Suite("P3-SESSION-01 会话生命周期重启存活")
@MainActor
struct ChatStoreSessionLifecycle256Tests {

    @Test("session list records the task projection version used for its read")
    func sessionListCachesTaskProjectionVersion() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "sidebar-projection-cache", canvasRuntimeState: .disabled
        )
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(),
            logManager: profile.makeLogManager()
        )
        let taskStore = AgentTaskStore()
        chat.attachAgentTaskStore(taskStore)
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.testAgentTaskProjectionCacheVersion == nil)

        _ = chat.executionSnapshot(forSessionID: sessionID)
        let cachedVersion = try #require(chat.testAgentTaskProjectionCacheVersion)
        #expect(cachedVersion == taskStore.taskCenterReadVersion())
        _ = chat.sessionList
        #expect(chat.testAgentTaskProjectionCacheVersion == cachedVersion)
        _ = chat.sessionList
        #expect(chat.testAgentTaskProjectionCacheVersion == cachedVersion)
        _ = chat.executionSnapshot(forSessionID: sessionID)
        #expect(chat.testAgentTaskProjectionCacheVersion == cachedVersion)

        _ = try taskStore.enqueue(
            taskID: "sidebar-cache-task",
            parentID: sessionID.uuidString,
            providerID: "synthetic",
            modelID: "synthetic",
            parentContextSnapshotID: "sidebar-cache-context"
        )
        #expect(taskStore.taskCenterReadVersion() != cachedVersion)
        _ = chat.sessionList
        #expect(chat.testAgentTaskProjectionCacheVersion == taskStore.taskCenterReadVersion())

        _ = try taskStore.startRun(taskID: "sidebar-cache-task", runID: "sidebar-cache-run")
        let versionBeforeReceipt = taskStore.taskCenterReadVersion()
        _ = try taskStore.finish(runID: "sidebar-cache-run", outcome: .succeeded)
        #expect(taskStore.taskCenterReadVersion() > versionBeforeReceipt)
        _ = chat.sessionList
        #expect(chat.testAgentTaskProjectionCacheVersion == taskStore.taskCenterReadVersion())
    }

    /// 临时目录：所有 SessionStore 落临时目录，不碰 Application Support（口径同 E7Tests）。
    private func makeStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLifecycle256-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionStore(directory: dir), dir)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("MOVE TO TRASH")
    }

    /// 重命名后的会话在重启后仍是该标题，且后续追加消息不会把标题冲回自动标题。
    @Test func renamedTitleSurvivesRemountAndKeepsAutoTitleSuppressed() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let id = try #require(chat.activeSessionID)
        chat.appendUser("持久化重命名验证")
        chat.renameSession(id: id, title: "自定义持久标题")

        let chat2 = ChatStore()
        #expect(chat2.attachPersistence(store))
        let restored = try #require(chat2.sessions.first { $0.id == id })
        #expect(restored.title == "自定义持久标题")

        // 重命名过的会话（标题≠"新会话"）追加新消息不得再被自动标题覆盖。
        chat2.switchSession(id: id)
        chat2.appendUser("重启后追加的消息")
        #expect(try #require(chat2.sessions.first { $0.id == id }).title == "自定义持久标题")

        let chat3 = ChatStore()
        #expect(chat3.attachPersistence(store))
        let survivor = try #require(chat3.sessions.first { $0.id == id })
        #expect(survivor.title == "自定义持久标题")
        #expect(survivor.messages.contains { $0.content == "持久化重命名验证" })
        #expect(survivor.messages.contains { $0.content == "重启后追加的消息" })
    }

    /// 全生命周期链：重命名 → 归档 → 重启 → 恢复 → 再重启，标题与消息全程存活。
    @Test func renamedArchiveRestoreChainSurvivesTwoRemounts() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let id = try #require(chat.activeSessionID)
        chat.appendUser("全生命周期链内容")
        chat.renameSession(id: id, title: "归档前重命名")
        chat.archiveSession(id: id)

        let chat2 = ChatStore()
        #expect(chat2.attachPersistence(store))
        let archived = try #require(chat2.archivedList.first { $0.session.id == id })
        #expect(archived.session.title == "归档前重命名")

        chat2.restoreSession(id: id)
        #expect(try #require(chat2.sessions.first { $0.id == id }).title == "归档前重命名")
        #expect(chat2.activeSessionID == id)

        let chat3 = ChatStore()
        #expect(chat3.attachPersistence(store))
        let survivor = try #require(chat3.sessions.first { $0.id == id })
        #expect(survivor.title == "归档前重命名")
        #expect(survivor.messages.contains { $0.content == "全生命周期链内容" })
        #expect(chat3.archivedList.first { $0.session.id == id } == nil)
    }

    /// 两步确认删除归档会话后，重启不复活。
    @Test func deletedArchivedSessionStaysGoneAfterRemount() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let doomedID = try #require(chat.activeSessionID)
        chat.appendUser("将被删除的归档会话")
        chat.newSession()
        let keptID = try #require(chat.activeSessionID)
        chat.appendUser("保留的活跃会话")

        chat.archiveSession(id: doomedID)
        #expect(chat.archivedList.first { $0.session.id == doomedID } != nil)

        let intent = try chat.previewDeletion(id: doomedID, archived: true)
        _ = try chat.deleteArchivedSession(id: doomedID, intent: confirmed(intent))
        #expect(chat.archivedList.isEmpty)

        let chat2 = ChatStore()
        #expect(chat2.attachPersistence(store))
        #expect(chat2.archivedList.first { $0.session.id == doomedID } == nil)
        #expect(chat2.sessions.first { $0.id == doomedID } == nil)
        #expect(try #require(chat2.sessions.first { $0.id == keptID }).messages
            .contains { $0.content == "保留的活跃会话" })
    }

    /// 重启前重命名归档会话不可见生效（UI 归档行仅提供恢复/删除）；恢复后的重命名
    /// 必须落盘并在再次重启后仍成立。
    @Test func renameAfterRestoreAcrossRemountPersistsAgain() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let id = try #require(chat.activeSessionID)
        chat.appendUser("恢复后再重命名")
        chat.renameSession(id: id, title: "初始重命名")
        chat.archiveSession(id: id)
        chat.newSession()

        let chat2 = ChatStore()
        #expect(chat2.attachPersistence(store))
        // 归档集合内重命名不生效：sessions 不含该 ID，applyRenameSession 拒绝。
        #expect(chat2.sessions.first { $0.id == id } == nil)
        #expect(!chat2.applyRenameSession(id: id, title: "非法归档重命名"))
        #expect(try #require(chat2.archivedList.first { $0.session.id == id })
            .session.title == "初始重命名")

        chat2.restoreSession(id: id)
        chat2.renameSession(id: id, title: "重命名后标题")

        let chat3 = ChatStore()
        #expect(chat3.attachPersistence(store))
        let survivor = try #require(chat3.sessions.first { $0.id == id })
        #expect(survivor.title == "重命名后标题")
    }
}

@Suite("会话归档遇到后台生成（D-1）")
@MainActor
struct ChatStoreArchiveWhileGeneratingTests {
    @Test("手动归档正在后台生成的非活动会话被拒绝，会话留在活动列表")
    func manualArchiveRefusesBackgroundGeneratingSession() throws {
        let chat = ChatStore()
        chat.newSession()
        let busy = try #require(chat.activeSessionID)
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: nil)
        chat.newSession()
        let other = try #require(chat.activeSessionID)
        #expect(other != busy)
        #expect(chat.isSessionGenerating(busy))
        #expect(chat.archiveSession(id: busy) == false)
        #expect(chat.sessions.contains { $0.id == busy })
        #expect(!chat.archivedSessions.contains { $0.id == busy })
    }

    /// MC4-027：侧栏手动归档当前正在生成的会话，要在停止回复之前拦下并提示先停止。
    @Test("侧栏归档当前正在生成的会话：给出先停止的提示，不动回复")
    func sidebarArchiveBlocksActiveGeneratingSessionBeforeStopping() throws {
        let chat = ChatStore()
        chat.newSession()
        let active = try #require(chat.activeSessionID)
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: nil)
        #expect(chat.isSessionGenerating(active))
        let message = try #require(SessionSidebarArchiveConsumer.generatingBlockMessage(for: active, in: chat))
        #expect(message.contains("先点停止"))
        #expect(chat.isSessionGenerating(active))
        chat.newSession()
        #expect(SessionSidebarArchiveConsumer.generatingBlockMessage(for: chat.activeSessionID!, in: chat) == nil)
    }

    @Test("超过 50 个会话时自动归档跳过正在生成的会话")
    func autoArchiveSkipsGeneratingSession() throws {
        let chat = ChatStore()
        chat.newSession()
        let busy = try #require(chat.activeSessionID)
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: nil)
        for _ in 0..<(ChatStore.maxSessionListCount + 2) { chat.newSession() }
        #expect(chat.sessions.contains { $0.id == busy })
        #expect(!chat.archivedSessions.contains { $0.id == busy })
    }

    /// S-05：定时任务回合只登记 scheduledSessionBusy、不登记 streamingTasks；手动归档和自动归档都要认它。
    @Test("正在跑定时任务回合的会话：手动归档被拒，自动归档也跳过（即使排在候选最前）")
    func scheduledTurnSessionIsNeitherManuallyNorAutomaticallyArchived() throws {
        let chat = ChatStore()
        chat.newSession()
        let busy = try #require(chat.activeSessionID)
        chat.installScheduledSessionBusyForTests(sessionID: busy)
        chat.newSession()
        #expect(chat.isSessionGenerating(busy))
        #expect(chat.archiveSession(id: busy) == false)
        #expect(chat.sessions.contains { $0.id == busy })
        for _ in 0..<(ChatStore.maxSessionListCount + 2) { chat.newSession() }
        #expect(chat.sessions.contains { $0.id == busy })
        #expect(!chat.archivedSessions.contains { $0.id == busy })
    }

    /// S-06：对话里恢复（不激活）的归档会话，活动会话已满时不能刚恢复就被自动归档回去。
    @Test("活动会话已满时对话里恢复归档会话：恢复的会话留在活动列表")
    func restoreWithoutActivatingSurvivesTheSessionLimit() throws {
        let chat = ChatStore()
        let oldest = try #require(chat.activeSessionID)
        chat.appendUser("最旧的会话")
        chat.newSession()
        #expect(chat.archiveSession(id: oldest))
        #expect(chat.archivedSessions.contains { $0.id == oldest })
        while chat.sessions.count < ChatStore.maxSessionListCount { chat.newSession() }
        let current = try #require(chat.activeSessionID)
        chat.restoreSession(id: oldest, activating: false)
        #expect(chat.activeSessionID == current)
        #expect(chat.sessions.contains { $0.id == oldest })
        #expect(!chat.archivedSessions.contains { $0.id == oldest })
    }

    /// S-09：复制 / 分叉正在生成的会话被拒时要说明原因，不能点了没反应。
    @Test("复制或分叉正在生成的会话被拒时有说明；空闲会话没有")
    func refusedDuplicateOrForkExplainsWhy() throws {
        let chat = ChatStore()
        chat.newSession()
        let busy = try #require(chat.activeSessionID)
        chat.appendUser("一个问题")
        let messageID = try #require(chat.messages.last?.id)
        #expect(chat.duplicateRefusalNotice(sessionID: busy) == nil)
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: nil)
        #expect(chat.duplicateRefusalNotice(sessionID: busy) == ChatStore.duplicateWhileGeneratingNotice)
        #expect(chat.forkSession(id: busy, atMessageID: messageID, inclusive: true) == nil)
        #expect(chat.pastedTextActionFeedback == ChatStore.duplicateWhileGeneratingNotice)
    }

    @Test("复制正在生成的会话被拒绝")
    func duplicateRefusesGeneratingSession() throws {
        let chat = ChatStore()
        chat.newSession()
        let busy = try #require(chat.activeSessionID)
        chat.installLegacySafetyDrainStateForTests(writebackMessageID: nil)
        let before = chat.sessions.count
        #expect(chat.applyDuplicateSession(id: busy) == nil)
        #expect(chat.sessions.count == before)
    }
}
