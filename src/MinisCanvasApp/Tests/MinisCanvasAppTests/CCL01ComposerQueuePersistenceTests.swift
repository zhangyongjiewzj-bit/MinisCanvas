import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("L01 composer queue persistence")
@MainActor struct CCL01ComposerQueuePersistenceTests {
    @Test func restartRetainsIdentityOrderAndPerSessionPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CCL01-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PersistedComposerQueueItem(sessionID: UUID(), text: "first draft", attachments: [], pastedDrafts: [])
        let second = PersistedComposerQueueItem(sessionID: UUID(), text: "second draft", attachments: [], pastedDrafts: [])
        try ComposerQueuePersistence.save([first, second], using: DraftStore(directory: root))
        let restored = try ComposerQueuePersistence.load(using: DraftStore(directory: root))
        #expect(restored == [first, second])
        try ComposerQueuePersistence.save([second], using: DraftStore(directory: root))
        #expect(try ComposerQueuePersistence.load(using: DraftStore(directory: root)) == [second])
        try ComposerQueuePersistence.save([], using: DraftStore(directory: root))
        #expect(try ComposerQueuePersistence.load(using: DraftStore(directory: root)).isEmpty)
    }

    @Test func restorationBeforeSessionArrivalRetainsUnmatchedEntriesAcrossAssemblies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CCL01-unloaded-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = PersistedComposerQueueItem(sessionID: UUID(), text: "awaiting session", attachments: [], pastedDrafts: [])
        try ComposerQueuePersistence.save([item], using: DraftStore(directory: root))
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: root.appendingPathComponent("sessions"))))
        #expect(!chat.sessions.contains { $0.id == item.sessionID })
        chat.attachDraftStore(DraftStore(directory: root))
        #expect(chat.queuedComposerMessages == [item])
        // A second assembly neither duplicates nor removes an unmatched item.
        chat.attachDraftStore(DraftStore(directory: root))
        #expect(chat.queuedComposerMessages == [item])
        #expect(try ComposerQueuePersistence.load(using: DraftStore(directory: root)) == [item])
    }

    @Test func unsupportedAndCorruptQueueAreNotReportedAsAnEmptyQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CCL01-invalid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(directory: root)
        store.scheduleSave(key: ComposerQueuePersistence.key, payload: Data("{\"version\":2,\"items\":[]}".utf8))
        #expect(store.flushNow(key: ComposerQueuePersistence.key))
        #expect(throws: ComposerQueuePersistence.Failure.unsupportedVersion(2)) {
            try ComposerQueuePersistence.load(using: DraftStore(directory: root))
        }
        store.scheduleSave(key: ComposerQueuePersistence.key, payload: Data("corrupt queue".utf8))
        #expect(store.flushNow(key: ComposerQueuePersistence.key))
        #expect(throws: (any Error).self) {
            try ComposerQueuePersistence.load(using: DraftStore(directory: root))
        }
    }
}
