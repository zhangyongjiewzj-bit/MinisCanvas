import Foundation
import Testing
@testable import MinisCore

/// Recovery is an explicit producer event; ordinary render priority stays
/// unchanged. Synthetic archive mutations below are negative controls only.
@Suite("D-SESSION-05 interrupted badge recovery guards 359")
struct DSession05InterruptedRecoveryBadgeTests {
    private let sourceTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() throws -> URL {
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        let isolation = try #require(resolved)
        let directory = isolation.temporaryDirectory.appendingPathComponent(
            "interrupted-badge359-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("RECOVERY359_ISOLATED_DIRECTORY=" + directory.path)
        return directory
    }

    private func identity(
        turn: Int = 3, task: String = "interrupted", provider: String = "synthetic-provider",
        owner: String = "synthetic-owner", revision: UInt64 = 9
    ) -> SessionBadgeStore.SessionIdentity {
        .init(sessionID: "synthetic-recovery-359", turnID: turn, taskID: task,
              providerID: provider, lineageOwner: owner, transcriptRevision: revision)
    }

    private func archive(at directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("badges.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeArchive(_ archive: [String: Any], at directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("badges.json"), options: .atomic)
    }

    private func recoveryRecords(at directory: URL) throws -> [String: Any] {
        try #require(archive(at: directory)["recoveredRunning"] as? [String: Any])
    }

    @Test func explicitRecoveryPersistsWithoutRelaxingOrdinaryRenderPriority() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        let running = try #require(badges.project(
            identity: source, source: .running, updatedAt: sourceTime
        ))
        #expect(badges.project(identity: source, source: .idle, updatedAt: sourceTime) == nil)
        #expect(badges.snapshot(for: source.sessionID) == running)
        let idle = try #require(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: false
        ))
        #expect(idle.status == .idle)
        #expect(idle.identity == source && idle.updatedAt == sourceTime)
        #expect(try recoveryRecords(at: directory).count == 1)

        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.snapshot(for: source.sessionID) == idle)
        #expect(reopened.project(identity: source, source: .running, updatedAt: sourceTime) == nil)
        #expect(reopened.project(
            identity: source, source: .running, updatedAt: sourceTime.addingTimeInterval(-1)
        ) == nil)
        #expect(reopened.project(identity: source, source: .idle, unread: true,
                                 updatedAt: sourceTime)?.status == .unread)
        #expect(reopened.project(identity: source, source: .idle, unread: false,
                                 updatedAt: sourceTime)?.status == .idle)
        #expect(reopened.project(
            identity: source, source: .failed, failureReason: "synthetic failure",
            updatedAt: sourceTime
        )?.status == .failed)
        #expect(reopened.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: true
        ) == nil)
        #expect(reopened.status(for: source.sessionID) == .failed)
    }

    @Test func everyCompleteIdentityFieldAndSourceClockMustMatch() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        let running = try #require(badges.project(
            identity: source, source: .running, updatedAt: sourceTime
        ))
        let foreignSources = [identity(turn: 2), identity(task: "another-task"),
                              identity(provider: "another-provider"),
                              identity(owner: "another-owner"), identity(revision: 8)]
        for foreign in foreignSources {
            #expect(badges.recoverInterruptedRunning(
                identity: foreign, updatedAt: sourceTime, unread: true
            ) == nil)
            #expect(badges.snapshot(for: source.sessionID) == running)
        }
        #expect(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime.addingTimeInterval(-1), unread: true
        ) == nil)
        #expect(badges.snapshot(for: source.sessionID) == running)
        #expect(try recoveryRecords(at: directory).isEmpty)
        #expect(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: true
        )?.status == .unread)
    }

    @Test func newerSourcesClearOnlyTheirPreviousRecoveryBoundary() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        _ = try #require(badges.project(identity: source, source: .running, updatedAt: sourceTime))
        _ = try #require(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: false
        ))
        let later = sourceTime.addingTimeInterval(1)
        _ = try #require(badges.project(identity: source, source: .running, updatedAt: later))
        #expect(try recoveryRecords(at: directory).isEmpty)
        #expect(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: true
        ) == nil)
        #expect(badges.snapshot(for: source.sessionID)?.updatedAt == later)
        _ = try #require(badges.recoverInterruptedRunning(
            identity: source, updatedAt: later, unread: false
        ))
        let next = identity(turn: 4, task: "next-task", revision: 10)
        _ = try #require(badges.project(identity: next, source: .running, updatedAt: later))
        #expect(try recoveryRecords(at: directory).isEmpty)
        #expect(badges.recoverInterruptedRunning(
            identity: source, updatedAt: later, unread: true
        ) == nil)
        #expect(badges.snapshot(for: source.sessionID)?.identity == next)
    }

    @Test func resetAndResetAllCannotResurrectRecoveredSources() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        _ = try #require(badges.project(identity: source, source: .running, updatedAt: sourceTime))
        _ = try #require(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: false
        ))
        badges.reset(for: source.sessionID)
        #expect(try recoveryRecords(at: directory).isEmpty)
        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.snapshot(for: source.sessionID) == nil)
        #expect(reopened.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: true
        ) == nil)
        #expect(reopened.project(identity: source, source: .running, updatedAt: sourceTime) == nil)

        let otherDirectory = try makeDirectory()
        let other = SessionBadgeStore(directory: otherDirectory)
        _ = try #require(other.project(identity: source, source: .running, updatedAt: sourceTime))
        _ = try #require(other.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: true
        ))
        other.resetAll()
        #expect(try recoveryRecords(at: otherDirectory).isEmpty)
        let reloaded = SessionBadgeStore(directory: otherDirectory)
        #expect(reloaded.project(identity: source, source: .running, updatedAt: sourceTime) == nil)
        #expect(reloaded.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: false
        ) == nil)
    }

    @Test func retirementFloorStillRejectsAnExactRunningRecovery() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        let original = try #require(badges.project(
            identity: source, source: .running, updatedAt: sourceTime
        ))
        // Synthetic persisted-floor negative control; not a natural product RED.
        var persisted = try archive(at: directory)
        persisted["retirementFloor"] = sourceTime.timeIntervalSinceReferenceDate
        try writeArchive(persisted, at: directory)
        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: true
        ) == nil)
        #expect(reopened.snapshot(for: source.sessionID) == original)
        #expect(reopened.project(identity: source, source: .running, updatedAt: sourceTime) == nil)
    }

    @Test(arguments: ["undecodable", "foreignIdentity", "newClock", "runningCurrent",
                      "wrongStatus", "wrongKey", "foreignCurrent", "newCurrentClock"])
    func invalidPersistedRecoveryMarkersDoNotBlockLegitimateRunning(_ damage: String) throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        _ = try #require(badges.project(identity: source, source: .running, updatedAt: sourceTime))
        _ = try #require(badges.recoverInterruptedRunning(
            identity: source, updatedAt: sourceTime, unread: false
        ))
        // Start with production-written bytes, then damage only this explicit
        // synthetic archive. Valid canonical snapshots must survive bad metadata.
        var persisted = try archive(at: directory)
        var markers = try #require(persisted["recoveredRunning"] as? [String: Any])
        var marker = try #require(markers[source.sessionID] as? [String: Any])
        var snapshots = try #require(persisted["snapshots"] as? [String: Any])
        var current = try #require(snapshots[source.sessionID] as? [String: Any])
        switch damage {
        case "undecodable": marker = ["status": "running"]
        case "foreignIdentity":
            var owner = try #require(marker["identity"] as? [String: Any])
            owner["providerID"] = "foreign-provider"
            marker["identity"] = owner
        case "newClock": marker["updatedAt"] = sourceTime.addingTimeInterval(1).timeIntervalSinceReferenceDate
        case "runningCurrent": current["status"] = "running"
        case "wrongStatus": marker["status"] = "failed"
        case "wrongKey": markers.removeValue(forKey: source.sessionID)
        case "foreignCurrent":
            var owner = try #require(current["identity"] as? [String: Any])
            owner["taskID"] = "another-task"
            current["identity"] = owner
        case "newCurrentClock": current["updatedAt"] = sourceTime.addingTimeInterval(1).timeIntervalSinceReferenceDate
        default: Issue.record("unknown synthetic archive case")
        }
        markers[damage == "wrongKey" ? "another-session" : source.sessionID] = marker
        snapshots[source.sessionID] = current
        persisted["recoveredRunning"] = markers
        persisted["snapshots"] = snapshots
        try writeArchive(persisted, at: directory)
        let expected = try JSONDecoder().decode(
            SessionBadgeStore.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: current)
        )
        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.snapshot(for: source.sessionID) == expected)
        // This existing count producer persists the loaded state without
        // changing the canonical projection, exposing discarded metadata.
        #expect(reopened.increment(for: source.sessionID) == 1)
        #expect(try recoveryRecords(at: directory).isEmpty)
        #expect(reopened.project(identity: expected.identity, source: .running,
                                 updatedAt: expected.updatedAt)?.status == .running)
    }

    @Test func legacyArchiveWithoutRecoveryMetadataKeepsItsExistingBehavior() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        let idle = try #require(badges.project(identity: source, source: .idle, updatedAt: sourceTime))
        var persisted = try archive(at: directory)
        persisted.removeValue(forKey: "recoveredRunning")
        try writeArchive(persisted, at: directory)
        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.snapshot(for: source.sessionID) == idle)
        #expect(reopened.project(identity: source, source: .running, updatedAt: sourceTime)?.status == .running)
    }

    @Test func oneCorruptRecordDoesNotDiscardAnotherSessionsValidRecoveryFence() throws {
        let directory = try makeDirectory()
        let badges = SessionBadgeStore(directory: directory)
        let source = identity()
        let keeper = SessionBadgeStore.SessionIdentity(
            sessionID: "synthetic-keeper-359", turnID: 3, taskID: "keeper",
            providerID: "synthetic-provider", lineageOwner: "synthetic-owner", transcriptRevision: 9
        )
        for item in [source, keeper] {
            _ = try #require(badges.project(identity: item, source: .running, updatedAt: sourceTime))
            _ = try #require(badges.recoverInterruptedRunning(
                identity: item, updatedAt: sourceTime, unread: false
            ))
        }
        var persisted = try archive(at: directory)
        var markers = try #require(persisted["recoveredRunning"] as? [String: Any])
        markers[source.sessionID] = ["status": "running"]
        persisted["recoveredRunning"] = markers
        try writeArchive(persisted, at: directory)
        let reopened = SessionBadgeStore(directory: directory)
        #expect(reopened.increment(for: keeper.sessionID) == 1)
        #expect(try recoveryRecords(at: directory).count == 1)
        #expect(reopened.project(identity: keeper, source: .running, updatedAt: sourceTime) == nil)
        #expect(reopened.status(for: keeper.sessionID) == .idle)
        #expect(reopened.project(identity: source, source: .running, updatedAt: sourceTime)?.status == .running)
    }
}
