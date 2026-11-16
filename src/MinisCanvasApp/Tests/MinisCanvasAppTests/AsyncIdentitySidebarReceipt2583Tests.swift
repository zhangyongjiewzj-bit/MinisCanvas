import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-ASYNC1 sidebar receipt ownership")
@MainActor
struct AsyncIdentitySidebarReceipt2583Tests {
    @Test("a queued failure cannot borrow another session's same-ID receipt after restart")
    func queuedFailureDoesNotBorrowForeignReceiptAfterReopen() throws {
        let profile = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = profile.rootDirectory.appendingPathComponent("async2583-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDirectory = root.appendingPathComponent("chat")
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let defaultsName = "com.miniscanvas.test.async2583.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(
            SessionStore(directory: chatDirectory),
            badgeStore: SessionBadgeStore(directory: chatDirectory)
        ))
        let firstSessionID = try #require(chat.activeSessionID)
        chat.appendUser("first request")
        chat.newSession()
        let secondSessionID = try #require(chat.activeSessionID)
        chat.appendUser("second request")

        let taskStore = try AgentTaskStore(persistenceURL: ledgerURL)
        let first = try taskStore.enqueue(
            taskID: "shared-task", parentID: firstSessionID.uuidString,
            providerID: "synthetic", modelID: "synthetic"
        )
        let firstRun = try taskStore.startRun(
            taskID: first.taskID, parentID: first.parentID, runID: "run-first"
        )
        _ = try taskStore.finish(runID: firstRun.runID, outcome: .failed(reason: "first failure"))
        let second = try taskStore.enqueue(
            taskID: "shared-task", parentID: secondSessionID.uuidString,
            providerID: "synthetic", modelID: "synthetic"
        )
        try taskStore.abortQueued(taskID: second.taskID, parentID: second.parentID)
        #expect(taskStore.allReceipts().count == 1)
        #expect(taskStore.snapshot(taskID: second.taskID, parentID: second.parentID)?.status == .failed)

        func checkRows(_ consumer: ChatStore) throws {
            let rows = Dictionary(uniqueKeysWithValues: consumer.sessionList.map { ($0.id, $0) })
            #expect(rows[firstSessionID]?.indicator == .failed(reason: "execution-failed"))
            #expect(rows[secondSessionID]?.indicator == .failed(reason: nil))
            #expect(rows[firstSessionID]?.retryIdentity?.sessionID == firstSessionID)
            #expect(rows[secondSessionID]?.retryIdentity?.sessionID == secondSessionID)
        }

        chat.attachAgentTaskStore(taskStore)
        try checkRows(chat)

        let reopenedTasks = try AgentTaskStore(persistenceURL: ledgerURL)
        let reopenedChat = ChatStore(preferencesDefaults: defaults)
        #expect(reopenedChat.attachPersistence(
            SessionStore(directory: chatDirectory),
            badgeStore: SessionBadgeStore(directory: chatDirectory)
        ))
        reopenedChat.attachAgentTaskStore(reopenedTasks)
        try checkRows(reopenedChat)
    }
}
