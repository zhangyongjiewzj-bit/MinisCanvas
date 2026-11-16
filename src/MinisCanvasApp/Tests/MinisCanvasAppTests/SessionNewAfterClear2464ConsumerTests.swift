import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-APP-09 new session after confirmed clear", .serialized)
@MainActor
struct SessionNewAfterClear2464ConsumerTests {
    @Test("confirmed last-session trash still permits a receipt-bound new session")
    func newAfterLastSessionClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app09-new-after-clear-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let tasks = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: tasks)
        #expect(bridge.chat.attachPersistence(sessions))
        let original = try #require(bridge.chat.activeSessionID)
        bridge.chat.appendUser("owned fixture session")
        #expect(sessions.loadSession(id: original.uuidString) != nil)

        // The same canonical reversible deletion producer used by the UI.
        let deletion = SessionDeletionService(manager: SessionManager(store: sessions))
        let preview = try deletion.preview(sessionID: original.uuidString)
        let intent = preview.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("移入回收站")
        let receipt = try deletion.delete(intent)
        #expect(receipt.targetID == original.uuidString)
        #expect(receipt.outcome == "deleted")
        bridge.chat.reconcileConfirmedExternalSessionDeletion([original.uuidString])
        #expect(bridge.chat.sessions.isEmpty)
        #expect(bridge.chat.activeSessionID == nil)

        let before = tasks.taskCenterSnapshots()
        for request in [
            SessionActionRequest.rename(sessionID: original.uuidString, title: "不能改名"),
            .switch(sessionID: original.uuidString),
            .fork(sessionID: original.uuidString),
        ] {
            #expect(throws: SessionActionError.invalidSource) {
                try bridge.performSessionAction(request)
            }
        }
        #expect(throws: SessionActionError.invalidTitle) {
            try bridge.performSessionAction(.new(title: "  "))
        }
        #expect(tasks.taskCenterSnapshots() == before)
        #expect(bridge.chat.sessions.isEmpty)

        // Sidebar, palette and menu ultimately call this attached ChatStore entry.
        bridge.chat.newSession()
        let restored = try #require(bridge.chat.activeSessionID)
        #expect(restored != original)
        #expect(bridge.chat.sessions.map(\.id) == [restored])
        #expect(sessions.loadSession(id: restored.uuidString) != nil)
        let created = tasks.taskCenterSnapshots().filter { task in
            !before.contains(where: { $0.taskID == task.taskID })
        }
        #expect(created.count == 1)
        let actionTask = try #require(created.first)
        #expect(actionTask.status == .succeeded)
        #expect(tasks.allReceipts().contains { $0.taskID == actionTask.taskID })
        #expect(actionTask.parentID != original.uuidString)

        let activeObservation = try bridge.performSessionAction(.new(title: "现存来源新建"))
        #expect(activeObservation.source.sessionID == restored.uuidString)
        let second = try #require(bridge.chat.activeSessionID)
        for id in [restored, second] {
            let preview = try deletion.preview(sessionID: id.uuidString)
            let intent = preview.withFirstConfirmation("已核对这份预览")
                .withSecondConfirmation("移入回收站")
            _ = try deletion.delete(intent)
            bridge.chat.reconcileConfirmedExternalSessionDeletion([id.uuidString])
        }
        #expect(bridge.chat.sessions.isEmpty)
        #expect(bridge.chat.activeSessionID == nil)

        let bootstrap = try bridge.performSessionAction(.new(title: "首会话恢复"))
        #expect(bootstrap.source.sessionID == "app:empty-session-new")
        #expect(bootstrap.receipt.sessionID == bridge.chat.activeSessionID?.uuidString)
        let afterBootstrap = tasks.taskCenterSnapshots()
        #expect(throws: SessionActionError.sourceTurnMismatch) {
            try bridge.performSessionAction(.new(title: "过期来源", source: bootstrap.source))
        }
        #expect(tasks.taskCenterSnapshots() == afterBootstrap)
        #expect(bridge.chat.sessions.count == 1)
    }

    @Test("failed durable task admission leaves the cleared session state untouched")
    func failedAdmissionDoesNotCreateAnUnreceiptedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app09-failed-new-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let tasks = try AgentTaskStore(
            persistenceURL: root.appendingPathComponent("agent-tasks.json"),
            persistenceFault: .diskFull
        )
        let bridge = BridgeStore(agentTaskStore: tasks)
        #expect(bridge.chat.attachPersistence(sessions))
        let original = try #require(bridge.chat.activeSessionID)
        bridge.chat.appendUser("owned fixture session")
        let deletion = SessionDeletionService(manager: SessionManager(store: sessions))
        let preview = try deletion.preview(sessionID: original.uuidString)
        _ = try deletion.delete(
            preview.withFirstConfirmation("已核对这份预览")
                .withSecondConfirmation("移入回收站")
        )
        bridge.chat.reconcileConfirmedExternalSessionDeletion([original.uuidString])
        #expect(bridge.chat.sessions.isEmpty)

        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            try bridge.performSessionAction(.new(title: "不得无回执新建"))
        }
        #expect(bridge.chat.sessions.isEmpty)
        #expect(bridge.chat.activeSessionID == nil)
        #expect(sessions.listSessions().isEmpty)
        #expect(tasks.taskCenterSnapshots().isEmpty)
        #expect(tasks.allReceipts().isEmpty)
    }
}
