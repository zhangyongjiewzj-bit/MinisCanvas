import Foundation
import Testing
@testable import MinisCore

@Suite("B2332 C0263 public reset clears count and execution projection")
struct SessionBadgeResetBothTablesC0263Tests {
    @Test func resetClearsUnreadCountAndExecutionSnapshotTogether() throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let directory = formal.rootDirectory.appendingPathComponent(
            "badge-reset-c0263-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = "owned-c0263-session"
        let identity = SessionBadgeStore.SessionIdentity(
            sessionID: sessionID, turnID: 1, taskID: "owned-c0263-task",
            providerID: "synthetic", lineageOwner: "owned-c0263-lineage",
            transcriptRevision: 1
        )
        let store = SessionBadgeStore(directory: directory)
        let projection = try #require(store.project(
            identity: identity, status: .running,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try #require(store.increment(for: sessionID) == 1)
        try #require(store.unreadCount(for: sessionID) == 1)
        try #require(store.snapshot(for: sessionID) == projection)

        let beforeReset = SessionBadgeStore(directory: directory)
        try #require(beforeReset.unreadCount(for: sessionID) == 1)
        try #require(beforeReset.snapshot(for: sessionID) == projection)

        store.reset(for: sessionID)

        #expect(store.unreadCount(for: sessionID) == 0)
        #expect(store.snapshot(for: sessionID) == nil)
        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.unreadCount(for: sessionID) == 0)
        #expect(reopened.snapshot(for: sessionID) == nil)
    }
}
