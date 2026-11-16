import Foundation
import Testing
@testable import MinisCore

@Suite("Session recovery generation fence", .serialized)
struct SessionRecoveryCoordinatorTests {
    @Test("late recovery cannot replace a recreated session")
    func lateRecoveryCannotReplaceRecreatedSession() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let coordinator = SessionRecoveryCoordinator(store: store)
        let old = try store.createSession(id: "recovery-target", title: "old session")
        let token = try #require(coordinator.begin([old])[old.id])

        try store.deleteSessionForMaintenance(id: old.id)
        let replacement = try store.createSession(id: old.id, title: "new session")

        #expect(try coordinator.apply(old, token: token) == false)
        #expect(store.loadSession(id: old.id) == replacement)
    }

    @Test("a recovery token can create an absent session")
    func recoveryCanCreateAbsentSession() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let coordinator = SessionRecoveryCoordinator(store: store)
        let payload = ChatSession(
            id: "recovery-new",
            title: "restored session",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let token = try #require(coordinator.begin([payload])[payload.id])

        #expect(token.expectedIdentity == nil)
        #expect(try coordinator.apply(payload, token: token))
        #expect(store.loadSession(id: payload.id) == payload)
    }

    @Test("a mutation invalidates an in-flight recovery with the same identity")
    func mutationInvalidatesInFlightRecovery() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let coordinator = SessionRecoveryCoordinator(store: store)
        let old = try store.createSession(id: "recovery-mutated", title: "before")
        let token = try #require(coordinator.begin([old])[old.id])

        var newer = old
        newer.title = "after"
        newer.updatedAt = old.updatedAt.addingTimeInterval(1)
        try store.updateSession(newer)

        #expect(try coordinator.apply(old, token: token) == false)
        #expect(store.loadSession(id: old.id)?.title == "after")
    }

    @Test("an unreadable preimage cannot be replaced")
    func unreadablePreimageFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let coordinator = SessionRecoveryCoordinator(store: store)
        try FileManager.default.createDirectory(
            at: store.sessionsDirectory,
            withIntermediateDirectories: true
        )
        let path = store.sessionsDirectory.appendingPathComponent("unreadable.json")
        let malformed = Data("{not-json".utf8)
        try malformed.write(to: path)
        let incoming = ChatSession(id: "unreadable", title: "must not replace")
        let token = try #require(coordinator.begin([incoming])[incoming.id])

        #expect(token.baselineReadable == false)
        #expect(try coordinator.apply(incoming, token: token) == false)
        #expect(try Data(contentsOf: path) == malformed)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCore-SessionRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
