import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SESSION-18 deletion intent binds the selected session")
@MainActor
struct Session18DeleteIntentIdentity2718Tests {
    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("已核对精准预览")
            .withSecondConfirmation("移入回收站")
    }

    @Test("an active row cannot consume a sibling's valid deletion intent")
    func activeRowRejectsSiblingIntentWithoutMovingEitherFile() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "SESSION18-active-2718")
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let suite = "session18-active-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(directory: root)
        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root)))
        let selectedID = try #require(chat.activeSessionID)
        let intendedID = chat.applyNewSession(title: "intended sibling")
        let keeperID = chat.applyNewSession(title: "active keeper")
        let selectedURL = store.sessionsDirectory.appendingPathComponent("\(selectedID.uuidString).json")
        let intendedURL = store.sessionsDirectory.appendingPathComponent("\(intendedID.uuidString).json")
        let selectedBefore = try Data(contentsOf: selectedURL)
        let intendedBefore = try Data(contentsOf: intendedURL)
        let sessionIDsBefore = chat.sessions.map(\.id)
        let preview = try chat.previewCurrentDeletion(id: intendedID)
        #expect(!preview.archived)
        let intent = confirmed(preview.intent)
        let trashURL = store.sessionsDirectory.appendingPathComponent("_trash")
            .appendingPathComponent("\(intent.operationID.uuidString).json")

        #expect(throws: DeletionGateError.invalidIntent) {
            try chat.deleteSession(id: selectedID, intent: intent)
        }
        #expect(try Data(contentsOf: selectedURL) == selectedBefore)
        #expect(try Data(contentsOf: intendedURL) == intendedBefore)
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
        #expect(chat.sessions.map(\.id) == sessionIDsBefore)
        #expect(chat.activeSessionID == keeperID)

        let receipt = try chat.deleteSession(id: intendedID, intent: intent)
        #expect(receipt.targetID == intendedID.uuidString)
        #expect(try Data(contentsOf: trashURL) == intendedBefore)
        #expect(try Data(contentsOf: selectedURL) == selectedBefore)
        #expect(chat.sessions.map(\.id) == sessionIDsBefore.filter { $0 != intendedID })
        #expect(chat.activeSessionID == keeperID)
    }

    @Test("an archived row cannot consume another archived session's valid intent")
    func archivedRowRejectsSiblingIntentWithoutMovingEitherFile() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "SESSION18-archive-2718")
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let suite = "session18-archive-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(directory: root)
        let chat = ChatStore(preferencesDefaults: defaults)
        #expect(chat.attachPersistence(store, badgeStore: SessionBadgeStore(directory: root)))
        let selectedID = try #require(chat.activeSessionID)
        let intendedID = chat.applyNewSession(title: "intended archive")
        let keeperID = chat.applyNewSession(title: "active keeper")
        chat.archiveSession(id: selectedID)
        chat.archiveSession(id: intendedID)
        let manager = try #require(chat.sessionManager)
        let selectedURL = manager.archiveDirectory.appendingPathComponent("\(selectedID.uuidString).json")
        let intendedURL = manager.archiveDirectory.appendingPathComponent("\(intendedID.uuidString).json")
        let selectedBefore = try Data(contentsOf: selectedURL)
        let intendedBefore = try Data(contentsOf: intendedURL)
        let archivedIDsBefore = chat.archivedSessions.map(\.id)
        let preview = try chat.previewCurrentDeletion(id: intendedID)
        #expect(preview.archived)
        let intent = confirmed(preview.intent)
        let trashURL = store.sessionsDirectory.appendingPathComponent("_trash")
            .appendingPathComponent("\(intent.operationID.uuidString).json")

        #expect(throws: DeletionGateError.invalidIntent) {
            try chat.deleteArchivedSession(id: selectedID, intent: intent)
        }
        #expect(try Data(contentsOf: selectedURL) == selectedBefore)
        #expect(try Data(contentsOf: intendedURL) == intendedBefore)
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
        #expect(chat.archivedSessions.map(\.id) == archivedIDsBefore)
        #expect(chat.activeSessionID == keeperID)

        let receipt = try chat.deleteArchivedSession(id: intendedID, intent: intent)
        #expect(receipt.targetID == intendedID.uuidString)
        #expect(try Data(contentsOf: trashURL) == intendedBefore)
        #expect(try Data(contentsOf: selectedURL) == selectedBefore)
        #expect(chat.archivedSessions.map(\.id) == archivedIDsBefore.filter { $0 != intendedID })
        #expect(chat.activeSessionID == keeperID)
    }
}
