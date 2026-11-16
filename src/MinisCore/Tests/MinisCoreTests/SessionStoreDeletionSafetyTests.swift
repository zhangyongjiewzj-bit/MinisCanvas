import Foundation
import Testing
@testable import MinisCore

struct SessionStoreDeletionSafetyTests {
    private let now = Date(timeIntervalSince1970: 2_000)

    private func makeStore() throws -> (SessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreDeletionSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (SessionStore(directory: root), root)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("I reviewed this exact session")
            .withSecondConfirmation("永久删除")
    }

    @Test func legacyDeleteEntryFailsClosedWithoutUserIntent() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try store.createSession(id: "session-1")
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            try store.deleteSession(id: session.id)
        }
        #expect(store.loadSession(id: session.id) == session)
    }

    @Test func confirmedDeleteUsesPreviewAndReturnsReceipt() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try store.createSession(id: "session-2", title: "A")
        let intent = try store.previewDeletion(id: session.id, now: now, ttl: 60)
        let receipt = try store.deleteSession(id: session.id, intent: confirmed(intent), now: now)
        #expect(receipt.operationID == intent.operationID)
        #expect(receipt.targetID == session.id)
        #expect(store.loadSession(id: session.id) == nil)
    }

    @Test func changedSessionRejectsOriginalIntentAndPreservesFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try store.createSession(id: "session-3", title: "A")
        let intent = try store.previewDeletion(id: session.id, now: now, ttl: 60)
        var changed = session
        changed.title = "Changed"
        changed.updatedAt = now.addingTimeInterval(1)
        try store.updateSession(changed)
        #expect(throws: DeletionGateError.targetChanged) {
            try store.deleteSession(id: session.id, intent: confirmed(intent), now: now)
        }
        #expect(store.loadSession(id: session.id)?.title == "Changed")
    }
}
