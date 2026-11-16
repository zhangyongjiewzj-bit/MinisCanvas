import Foundation
import Testing
@testable import MinisCore

/// D-RECOVERY-10 consumer evidence: a session created or mutated after a
/// recovery admission must never be overwritten by the stale recovery
/// write-back, and every refused write-back must be observable through the
/// production entry point (`SyncManager.importSnapshot`) as a typed, per-item
/// failure — silent drop is forbidden. The fence itself (generation +
/// sessionRecoveryIdentity) is delivered in SessionRecoveryCoordinator.swift;
/// these tests pin the consumer contract at the SyncManager boundary, which
/// DEV05's coordinator-level suite (SessionRecoveryCoordinatorTests) does not
/// exercise.
@Suite("Session recovery consumer fence", .serialized)
struct SessionRecoveryConsumerTests {
    /// Acceptance (a): the recovery admitted a stale snapshot entry while the
    /// destination was absent; the app then created that session through a
    /// second SessionStore instance for the same canonical directory (the
    /// production shape: importer store and runtime store are distinct
    /// instances sharing the per-directory `SessionPersistenceLock`). The
    /// stale apply must be refused and the newer session content must survive.
    @Test("a session created after recovery admission survives a stale write-back")
    func createdDuringRecoverySurvivesStaleWriteBack() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recoveryStore = SessionStore(directory: directory)
        let appStore = SessionStore(directory: directory)
        let coordinator = SessionRecoveryCoordinator(store: recoveryStore)
        let snapshotCreatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let stale = ChatSession(
            id: "late-s2",
            title: "stale snapshot title",
            createdAt: snapshotCreatedAt,
            updatedAt: snapshotCreatedAt.addingTimeInterval(1)
        )

        // Recovery begins: identity captured while the destination is absent.
        let token = try #require(coordinator.begin([stale])[stale.id])
        #expect(token.expectedIdentity == nil)

        // The user creates the same session while the recovery is in flight.
        let created = try appStore.createSession(id: stale.id, title: "created during recovery")

        #expect(try coordinator.apply(stale, token: token) == false)
        // Neither store instance may observe the stale content.
        #expect(appStore.loadSession(id: stale.id) == created)
        #expect(recoveryStore.loadSession(id: stale.id)?.title == "created during recovery")
    }

    /// Acceptance (b): the ordinary restore path must keep working. Importing
    /// a snapshot into a fresh store creates the session, and re-importing
    /// the same snapshot while nothing changed since admission still applies
    /// (documented import semantics: the restored domain follows the
    /// snapshot). A guard that refused every write-back would fail here.
    @Test("a normal restore of an unchanged session still applies through importSnapshot")
    func normalRestoreOfUnchangedSessionApplies() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let targetDir = root.appendingPathComponent("target", isDirectory: true)

        let source = try makeManager(at: sourceDir)
        let original = try source.sessionStore.createSession(id: "s-1", title: "snapshot session")
        let data = try source.exportSnapshot(scopes: [.sessions])

        let target = try makeManager(at: targetDir)
        #expect(target.sessionStore.listSessions().isEmpty)

        let first = try target.importSnapshot(data, restoring: [.sessions])
        #expect(first.allSucceeded)
        #expect(first.failedScopes.isEmpty)
        #expect(target.sessionStore.loadSession(id: "s-1") == original)

        // Second import of the same snapshot: the destination is unchanged
        // since admission, so the fenced write-back must apply, not skip.
        let second = try target.importSnapshot(data, restoring: [.sessions])
        #expect(second.allSucceeded)
        #expect(second.failedScopes.isEmpty)
        #expect(target.sessionStore.loadSession(id: "s-1") == original)
    }

    /// Silent-drop ban at the production consumer: when the fenced apply
    /// refuses a write-back, `importSnapshot` must surface a typed
    /// per-session failure (`SyncImportError.result.scopeResults` carrying
    /// `SyncScopeFailure(item:, reason: "stale recovery ignored")`) and must
    /// leave the destination bytes untouched. A recoverable preimage that
    /// cannot be decoded exercises the fail-closed arm deterministically;
    /// cross-thread staleness takes the same `applyRecoveredSession == false`
    /// path proven in the first test.
    @Test("a refused recovery write-back is reported, never silently dropped")
    func refusedWriteBackIsObservable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let targetDir = root.appendingPathComponent("target", isDirectory: true)

        let source = try makeManager(at: sourceDir)
        _ = try source.sessionStore.createSession(id: "s-1", title: "snapshot session")
        let data = try source.exportSnapshot(scopes: [.sessions])

        // Destination has an unreadable preimage for the same session id.
        let target = try makeManager(at: targetDir)
        let sessionsDirectory = target.sessionStore.sessionsDirectory
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let preimagePath = sessionsDirectory.appendingPathComponent("s-1.json")
        let malformed = Data("{not-json".utf8)
        try malformed.write(to: preimagePath)

        var observedFailure: SyncScopeFailure?
        do {
            _ = try target.importSnapshot(data, restoring: [.sessions])
            Issue.record("importSnapshot must throw SyncImportError for a refused write-back")
        } catch let error as SyncImportError {
            let sessionResults = error.result.scopeResults.filter { $0.scope == .sessions }
            #expect(sessionResults.count == 1)
            let scopeResult = try #require(sessionResults.first)
            #expect(scopeResult.succeeded == false)
            observedFailure = scopeResult.failures.first { $0.item == "s-1" }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        let failure = try #require(observedFailure)
        #expect(failure.reason.contains("stale recovery ignored"))
        // Fail-closed: the unreadable bytes were not replaced.
        #expect(try Data(contentsOf: preimagePath) == malformed)
    }

    private func makeManager(at directory: URL) throws -> SyncManager {
        let chat = directory.appendingPathComponent("chat", isDirectory: true)
        let core = directory.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        return SyncManager(
            sessionStore: SessionStore(directory: chat),
            memoryStore: MemoryStore(directory: chat),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: core),
            deviceName: "RecoveryConsumerTestMac"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "MinisCore-SessionRecoveryConsumer-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
