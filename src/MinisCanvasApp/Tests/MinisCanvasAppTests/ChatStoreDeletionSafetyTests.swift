import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("ChatStore deletion safety")
@MainActor
struct ChatStoreDeletionSafetyTests {
    @Test func archiveAndRecoverableDeletionNeverRenewTheSameSessionQuota() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: root)))
        if chat.activeSessionID == nil { chat.newSession() }
        let a = try #require(chat.activeSessionID)
        chat.appendUser("owned quota restore A")
        let trackerA = chat.budgetTracker
        let leaseA = try await trackerA.beginRequest()
        _ = await trackerA.completeRequest(leaseA, usage: LLMUsage(inputTokens: 70, outputTokens: 3))
        await chat.syncBudgetStatus(for: a)
        chat.newSession()
        let b = try #require(chat.activeSessionID)
        let trackerB = chat.budgetTracker
        chat.appendUser("owned quota restore B")
        let leaseB = try await trackerB.beginRequest()
        _ = await trackerB.completeRequest(leaseB, usage: LLMUsage(inputTokens: 7, outputTokens: 0))
        await chat.syncBudgetStatus(for: b)
        #expect(chat.applySwitchSession(id: a))
        chat.archiveSession(id: a)
        #expect(chat.activeSessionID == b && chat.budgetTracker === trackerB)
        chat.restoreSession(id: a)
        await chat.syncBudgetStatus(for: a)
        #expect(chat.budgetTracker === trackerA && chat.budgetUsedTokens == 73)
        let preview = try chat.previewCurrentDeletion(id: a)
        let confirmed = preview.intent.withFirstConfirmation("已核对这份预览").withSecondConfirmation("移入回收站")
        let receipt = try chat.deleteSession(id: a, intent: confirmed)
        #expect(chat.activeSessionID == b && chat.budgetTracker === trackerB)
        #expect(chat.budgetUsedTokens == 7)
        #expect(chat.restoreTrashedSession(receipt))
        await chat.syncBudgetStatus(for: a)
        #expect(chat.activeSessionID == a && chat.budgetTracker === trackerA)
        #expect(chat.budgetUsedTokens == 73 && chat.budgetRequestCount == 1)
        #expect(await trackerB.budget.usedTokens == 7)
    }

    @Test("canonical archive preview drives reversible deletion and exact-byte restore")
    func archivedPreviewUsesCanonicalLocationAndRestoresBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        chat.newSession()
        let id = try #require(chat.activeSessionID)
        chat.appendUser("归档后保留的原始消息")
        chat.archiveSession(id: id)
        let manager = SessionManager(store: store)
        let archivedURL = manager.archiveDirectory.appendingPathComponent("\(id.uuidString).json")
        let original = try Data(contentsOf: archivedURL)
        let preview = try chat.previewCurrentDeletion(id: id)
        #expect(preview.archived)
        #expect(preview.intent.reversible)
        #expect(preview.intent.scopeID == "session:\(id.uuidString):archive")
        let confirmed = preview.intent.withFirstConfirmation("已核对这份预览").withSecondConfirmation("移入回收站")
        let receipt = try chat.deleteArchivedSession(id: id, intent: confirmed)
        #expect(!FileManager.default.fileExists(atPath: archivedURL.path))
        try SessionDeletionService(manager: manager).restore(receipt)
        #expect(try Data(contentsOf: archivedURL) == original)
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(store))
        let activeURL = store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        try original.write(to: activeURL)
        #expect(throws: Error.self) { _ = try reopened.previewCurrentDeletion(id: id) }
        #expect(try Data(contentsOf: archivedURL) == original)
        #expect(try Data(contentsOf: activeURL) == original)
    }

    /// MC4-027：归档会在停回复之前先检查磁盘；一定会失败的情形（归档目录被文件占住、已有同名文件）
    /// 返回原因，archiveSession 不停止回复、会话保持原状。
    @Test func archivePreflightRejectsBlockedArchiveDirectoryBeforeStoppingAnything() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        chat.newSession()
        let id = try #require(chat.activeSessionID)
        chat.appendUser("归档预检")
        #expect(chat.archiveDiskPreflightFailure(id: id) == nil)

        let manager = SessionManager(store: store)
        // 归档目录位置被一个普通文件占住：目录建不出来。
        try Data("blocker".utf8).write(to: manager.archiveDirectory)
        #expect(chat.archiveDiskPreflightFailure(id: id) != nil)
        #expect(!chat.archiveSession(id: id))
        #expect(chat.sessions.contains { $0.id == id })
        #expect(chat.activeSessionID == id)
        try FileManager.default.removeItem(at: manager.archiveDirectory)

        // 归档目录里已有同名文件。
        try FileManager.default.createDirectory(at: manager.archiveDirectory, withIntermediateDirectories: true)
        try Data("dup".utf8).write(to: manager.archiveDirectory.appendingPathComponent("\(id.uuidString).json"))
        #expect(chat.archiveDiskPreflightFailure(id: id) != nil)
        #expect(!chat.archiveSession(id: id))
        #expect(chat.sessions.contains { $0.id == id })
    }

    private let now = Date(timeIntervalSince1970: 3_000)
    private let expiredAt = Date(timeIntervalSince1970: 1)
    private let unexpiredAt = Date(timeIntervalSince1970: 4_000_000_000)

    private func confirmed(
        _ intent: OperationIntent,
        secondConfirmation: String = "永久删除",
        expiresAt: Date? = nil
    ) -> OperationIntent {
        let confirmed = intent.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation(secondConfirmation)
        guard let expiresAt else { return confirmed }
        return OperationIntent(
            operationID: confirmed.operationID,
            operationType: confirmed.operationType,
            targetID: confirmed.targetID,
            targetType: confirmed.targetType,
            targetName: confirmed.targetName,
            affectedCount: confirmed.affectedCount,
            impactSummary: confirmed.impactSummary,
            reversible: confirmed.reversible,
            scopeID: confirmed.scopeID,
            revision: confirmed.revision,
            fingerprint: confirmed.fingerprint,
            firstConfirmation: confirmed.firstConfirmation,
            secondConfirmation: confirmed.secondConfirmation,
            expiresAt: expiresAt
        )
    }

    @Test func legacyActiveDeleteFailsClosedAndConfirmedDeleteIsOneShot() throws {
        let chat = ChatStore()
        chat.newSession()
        let id = try #require(chat.activeSessionID)
        let count = chat.sessions.count
        chat.deleteSession(id: id)
        #expect(chat.sessions.count == count)
        let intent = try chat.previewDeletion(id: id, now: now, ttl: 60)
        let receipt = try chat.deleteSession(id: id, intent: confirmed(intent), now: now)
        #expect(receipt.targetID == id.uuidString)
        #expect(chat.sessions.contains { $0.id == id } == false)
        #expect(throws: DeletionGateError.alreadyConsumed) {
            try chat.deleteSession(id: id, intent: confirmed(intent), now: now)
        }
    }

    @Test func archivedDeleteRequiresIntent() throws {
        let chat = ChatStore()
        chat.newSession()
        let id = try #require(chat.activeSessionID)
        chat.archiveSession(id: id)
        #expect(chat.archivedSessions.contains { $0.id == id })
        chat.deleteArchivedSession(id: id)
        #expect(chat.archivedSessions.contains { $0.id == id })
        let intent = try chat.previewDeletion(id: id, archived: true, now: now, ttl: 60)
        _ = try chat.deleteArchivedSession(id: id, intent: confirmed(intent), now: now)
        #expect(chat.archivedSessions.contains { $0.id == id } == false)
    }

    @Test("manager-backed active expired deletion leaves files, trash, and UI state unchanged")
    func expiredActiveSessionTicketFailsBeforeFileOrUIMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-active-expired-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        #expect(chat.sessionManager != nil)

        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("待过期的活动会话")
        let siblingID = chat.applyNewSession(title: "保留活动会话")
        chat.appendUser("保留会话内容")
        #expect(chat.sessions.count == 2)

        let targetURL = store.sessionsDirectory
            .appendingPathComponent("\(targetID.uuidString).json")
        let siblingURL = store.sessionsDirectory
            .appendingPathComponent("\(siblingID.uuidString).json")
        let targetBefore = try Data(contentsOf: targetURL)
        let siblingBefore = try Data(contentsOf: siblingURL)
        let activeIDsBefore = chat.sessions.map { $0.id }
        let archivedIDsBefore = chat.archivedSessions.map { $0.id }
        let activeSessionBefore = chat.activeSessionID

        let preview = try chat.previewCurrentDeletion(id: targetID)
        #expect(!preview.archived)
        let intent = confirmed(
            preview.intent,
            secondConfirmation: "移入回收站",
            expiresAt: expiredAt
        )
        #expect(intent.firstConfirmation == "已核对这份预览")
        #expect(intent.secondConfirmation == "移入回收站")
        let trashURL = store.sessionsDirectory
            .appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent("\(intent.operationID.uuidString).json")

        #expect(throws: DeletionGateError.expired) {
            try chat.deleteSession(id: targetID, intent: intent, now: now)
        }

        #expect(try Data(contentsOf: targetURL) == targetBefore)
        #expect(try Data(contentsOf: siblingURL) == siblingBefore)
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
        #expect(chat.sessions.map { $0.id } == activeIDsBefore)
        #expect(chat.archivedSessions.map { $0.id } == archivedIDsBefore)
        #expect(chat.activeSessionID == activeSessionBefore)
    }

    @Test("manager-backed archived expired deletion leaves files, trash, and UI state unchanged")
    func expiredArchivedSessionTicketFailsBeforeFileOrUIMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-archived-expired-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        #expect(chat.sessionManager != nil)

        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("待过期的归档会话")
        let siblingID = chat.applyNewSession(title: "保留活动会话")
        chat.appendUser("保留会话内容")
        chat.archiveSession(id: targetID)
        #expect(chat.archivedSessions.contains { $0.id == targetID })

        let manager = try #require(chat.sessionManager)
        let archivedURL = manager.archiveDirectory
            .appendingPathComponent("\(targetID.uuidString).json")
        let siblingURL = store.sessionsDirectory
            .appendingPathComponent("\(siblingID.uuidString).json")
        let archivedBefore = try Data(contentsOf: archivedURL)
        let siblingBefore = try Data(contentsOf: siblingURL)
        let activeIDsBefore = chat.sessions.map { $0.id }
        let archivedIDsBefore = chat.archivedSessions.map { $0.id }
        let activeSessionBefore = chat.activeSessionID

        let preview = try chat.previewCurrentDeletion(id: targetID)
        #expect(preview.archived)
        let intent = confirmed(
            preview.intent,
            secondConfirmation: "移入回收站",
            expiresAt: expiredAt
        )
        #expect(intent.firstConfirmation == "已核对这份预览")
        #expect(intent.secondConfirmation == "移入回收站")
        let trashURL = store.sessionsDirectory
            .appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent("\(intent.operationID.uuidString).json")

        #expect(throws: DeletionGateError.expired) {
            try chat.deleteArchivedSession(id: targetID, intent: intent, now: now)
        }

        #expect(try Data(contentsOf: archivedURL) == archivedBefore)
        #expect(try Data(contentsOf: siblingURL) == siblingBefore)
        #expect(FileManager.default.fileExists(atPath: archivedURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
        #expect(chat.sessions.map { $0.id } == activeIDsBefore)
        #expect(chat.archivedSessions.map { $0.id } == archivedIDsBefore)
        #expect(chat.activeSessionID == activeSessionBefore)
    }

    @Test("manager-backed modified session rejects an old ticket before delete")
    func managerBackedModifiedSessionRejectsOldTicketBeforeDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-modified-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        #expect(chat.sessionManager != nil)

        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("修改前的活动会话")
        let siblingID = chat.applyNewSession(title: "保留活动会话")
        chat.appendUser("保留会话内容")

        let preview = try chat.previewCurrentDeletion(id: targetID)
        #expect(!preview.archived)
        let oldIntent = confirmed(
            preview.intent,
            secondConfirmation: "移入回收站",
            expiresAt: unexpiredAt
        )
        #expect(oldIntent.firstConfirmation == "已核对这份预览")
        #expect(oldIntent.secondConfirmation == "移入回收站")

        let targetURL = store.sessionsDirectory
            .appendingPathComponent("\(targetID.uuidString).json")
        let siblingURL = store.sessionsDirectory
            .appendingPathComponent("\(siblingID.uuidString).json")
        let targetBefore = try Data(contentsOf: targetURL)
        let siblingBefore = try Data(contentsOf: siblingURL)
        #expect(chat.applySwitchSession(id: targetID))
        chat.appendUser("修改后的活动会话")
        let targetAfter = try Data(contentsOf: targetURL)
        #expect(targetAfter != targetBefore)

        let rebuilt = ChatStore()
        #expect(rebuilt.attachPersistence(store))
        #expect(rebuilt.sessionManager != nil)
        let activeIDsBefore = rebuilt.sessions.map { $0.id }
        let archivedIDsBefore = rebuilt.archivedSessions.map { $0.id }
        let activeSessionBefore = rebuilt.activeSessionID
        let trashURL = store.sessionsDirectory
            .appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent("\(oldIntent.operationID.uuidString).json")

        #expect(throws: DeletionGateError.targetChanged) {
            try rebuilt.deleteSession(id: targetID, intent: oldIntent, now: now)
        }

        #expect(try Data(contentsOf: targetURL) == targetAfter)
        #expect(try Data(contentsOf: siblingURL) == siblingBefore)
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
        #expect(rebuilt.sessions.map { $0.id } == activeIDsBefore)
        #expect(rebuilt.archivedSessions.map { $0.id } == archivedIDsBefore)
        #expect(rebuilt.activeSessionID == activeSessionBefore)
    }

    @Test("manager-backed confirmed deletion is a positive control")
    func managerBackedConfirmedActiveDeleteIsPositiveControl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manager-confirmed-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        #expect(chat.sessionManager != nil)

        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("确认后应移入回收站")
        let siblingID = chat.applyNewSession(title: "保留活动会话")
        chat.appendUser("保留会话内容")
        let targetURL = store.sessionsDirectory
            .appendingPathComponent("\(targetID.uuidString).json")
        let siblingURL = store.sessionsDirectory
            .appendingPathComponent("\(siblingID.uuidString).json")
        let targetBefore = try Data(contentsOf: targetURL)
        let siblingBefore = try Data(contentsOf: siblingURL)
        let preview = try chat.previewCurrentDeletion(id: targetID)
        let intent = confirmed(
            preview.intent,
            secondConfirmation: "移入回收站",
            expiresAt: unexpiredAt
        )
        #expect(intent.firstConfirmation == "已核对这份预览")
        #expect(intent.secondConfirmation == "移入回收站")

        let receipt = try chat.deleteSession(id: targetID, intent: intent, now: now)
        let trashURL = store.sessionsDirectory
            .appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent("\(intent.operationID.uuidString).json")
        #expect(receipt.operationID == intent.operationID)
        #expect(receipt.targetID == targetID.uuidString)
        #expect(!chat.sessions.contains { $0.id == targetID })
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        #expect(try Data(contentsOf: trashURL) == targetBefore)
        #expect(try Data(contentsOf: siblingURL) == siblingBefore)
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    @Test("unchanged session upsert preserves original bytes while a real change persists")
    func unchangedSessionUpsertPreservesBytesAndRealChangesPersist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unchanged-upsert-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        chat.appendUser("保留原会话字节")
        let id = try #require(chat.activeSessionID)
        let session = try #require(store.loadSession(id: id.uuidString))
        let url = store.sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        // Valid JSON whitespace distinguishes preservation from re-encoding.
        var original = try Data(contentsOf: url)
        original.append(contentsOf: [10, 32, 10])
        try original.write(to: url, options: .atomic)
        try store.updateSession(session)
        #expect(try Data(contentsOf: url) == original)
        var changed = session
        changed.title = "实际修改必须持久化"
        try store.updateSession(changed)
        #expect(store.loadSession(id: id.uuidString)?.title == changed.title)
        #expect(try Data(contentsOf: url) != original)
    }
}

@MainActor
struct CCRound2ChatQueueConsumerTests {
    @Test func queuedPayloadSurvivesReconstructionAndRequiresEmptyDraftForEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc2-queue-consumer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        let chat = ChatStore()
        #expect(chat.attachPersistence(sessions))
        chat.newSession()
        let sessionID = try #require(chat.activeSessionID)
        chat.attachDraftStore(drafts)
        chat.draftText = "synthetic queue payload"
        #expect(chat.enqueueComposer())
        let item = try #require(chat.activeQueuedComposerMessages.first)
        #expect(chat.queuePersistenceNotice == nil)
        let restored = ChatStore()
        #expect(restored.attachPersistence(sessions))
        restored.switchSession(id: sessionID)
        restored.attachDraftStore(DraftStore(directory: drafts.directory))
        #expect(restored.activeQueuedComposerMessages.first?.id == item.id)
        #expect(!restored.canContinueAfterIterationLimit(sessionID: sessionID))
        restored.draftText = "keep existing draft"
        #expect(!restored.editQueuedComposer(id: item.id))
        #expect(restored.activeQueuedComposerMessages.count == 1)
        restored.draftText = ""
        #expect(restored.editQueuedComposer(id: item.id))
        #expect(restored.draftText == "synthetic queue payload")
        #expect(restored.activeQueuedComposerMessages.isEmpty)
    }
}

@MainActor
struct CCRound2ContinuationEligibilityTests {
    @Test func iterationPauseIsDistinctFromBudgetPauseAndSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc2-pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        chat.newSession()
        let id = try #require(chat.activeSessionID)
        chat.appendUser("synthetic continuation")
        chat.markExecutionFailed(sessionID: id, reason: "budget", failureKind: .budgetPause)
        #expect(!chat.canContinueAfterIterationLimit(sessionID: id))
        chat.markExecutionFailed(sessionID: id, reason: "iteration", failureKind: .iterationLimit)
        #expect(chat.canContinueAfterIterationLimit(sessionID: id))
        let restored = ChatStore()
        #expect(restored.attachPersistence(store))
        #expect(restored.canContinueAfterIterationLimit(sessionID: id))
        restored.markExecutionIdle(sessionID: id)
        #expect(!restored.canContinueAfterIterationLimit(sessionID: id))
    }

    @Test func changingCurrentBudgetNeverClearsCommittedUsage() async throws {
        let chat = ChatStore()
        _ = await chat.budgetTracker.record(requestTokens: 1234)
        await chat.syncBudgetStatus(for: chat.activeSessionID)
        chat.setTokenBudgetLimit(240000, unlimited: false)
        for _ in 0..<200 {
            if chat.budgetCapTokens == 240000 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(chat.budgetUsedTokens == 1234)
        #expect(chat.budgetCapTokens == 240000)
        chat.newSession()
        #expect(chat.budgetUsedTokens == 0)
        #expect(chat.budgetCapTokens == 240000)
    }
}
