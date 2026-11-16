import Foundation
import Testing
@testable import MinisCore

@Suite("AgentDurableEffectJournal", .serialized)
struct AgentDurableEffectJournalTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func makeJournal(_ name: String = #function) throws -> (AgentDurableEffectJournal, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDurableEffectJournalTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("journal.json")
        return (try AgentDurableEffectJournal(persistenceURL: persistenceURL), persistenceURL)
    }

    private func identity(
        taskID: String = "task-1",
        runID: String = "run-1",
        attemptID: String = "attempt-1",
        effectID: String = "effect-1"
    ) -> AgentDurableEffectIdentity {
        AgentDurableEffectIdentity(
            taskID: taskID,
            runID: runID,
            attemptID: attemptID,
            effectID: effectID
        )
    }

    private func lease(_ leaseID: String = "lease-1") -> AgentDurableEffectLease {
        AgentDurableEffectLease(
            leaseID: leaseID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
    }

    private func request(
        identity: AgentDurableEffectIdentity = AgentDurableEffectIdentity(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            effectID: "effect-1"
        ),
        leaseID: String = "lease-1",
        idempotencyKey: String = "idem-1"
    ) -> AgentDurableEffectRequest {
        AgentDurableEffectRequest(
            identity: identity,
            lease: AgentDurableEffectLease(
                leaseID: leaseID,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            idempotencyKey: idempotencyKey,
            inputDigest: "sha256-input-1"
        )
    }

    @Test func identityAndAttemptLineageAreImmutable() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }

        let first = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        #expect(first.attemptNumber == 1)
        #expect(first.supersedesAttemptID == nil)

        _ = try journal.reserveEffect(request())
        #expect(throws: AgentDurableEffectJournalError.identityMismatch) {
            _ = try journal.submitEffect(
                identity(
                    taskID: "other-task",
                    runID: "run-1",
                    attemptID: "attempt-1",
                    effectID: "effect-1"
                ),
                leaseID: "lease-1",
                now: now
            )
        }
        #expect(throws: AgentDurableEffectJournalError.identityMismatch) {
            _ = try journal.beginAttempt(
                taskID: "other-task",
                runID: "run-1",
                attemptID: "attempt-1",
                now: now
            )
        }
    }

    @Test func sequenceAndChecksumChainSurviveReload() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }

        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        _ = try journal.reserveEffect(request())
        _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now.addingTimeInterval(1))
        _ = try journal.completeEffect(
            identity(),
            leaseID: "lease-1",
            status: .succeeded,
            redactedOutcome: "ok",
            now: now.addingTimeInterval(2)
        )

        let entries = journal.journalEntries()
        #expect(entries.map(\.sequence) == [1, 2, 3, 4])
        #expect(entries.allSatisfy { $0.checksum.count == 64 })
        #expect(entries.dropFirst().enumerated().allSatisfy { offset, entry in
            entry.previousChecksum == entries[offset].checksum
        })

        let reloaded = try AgentDurableEffectJournal(persistenceURL: directoryURL)
        #expect(reloaded.journalEntries() == entries)
        #expect(reloaded.record(for: identity())?.status == .succeeded)
        #expect(reloaded.record(for: identity())?.lease.isReleased == true)
    }

    @Test func corruptedLedgerFailsClosed() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )

        let marker = "\"checksum\":\""
        var text = try String(contentsOf: directoryURL, encoding: .utf8)
        let start = try #require(text.range(of: marker)?.upperBound)
        let end = try #require(text.range(of: "\"", range: start..<text.endIndex)?.lowerBound)
        text.replaceSubrange(start..<end, with: String(repeating: "0", count: 64))
        try text.write(to: directoryURL, atomically: true, encoding: .utf8)

        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: directoryURL)
        }
    }

    @Test func corruptedProjectionFailsClosed() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )

        let marker = "\"snapshotChecksum\":\""
        var text = try String(contentsOf: directoryURL, encoding: .utf8)
        let start = try #require(text.range(of: marker)?.upperBound)
        let end = try #require(text.range(of: "\"", range: start..<text.endIndex)?.lowerBound)
        text.replaceSubrange(start..<end, with: String(repeating: "0", count: 64))
        try text.write(to: directoryURL, atomically: true, encoding: String.Encoding.utf8)

        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: directoryURL)
        }
    }

    @Test func failedAtomicWriteDoesNotPublishInMemoryMutation() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )

        try FileManager.default.removeItem(at: directoryURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        #expect(throws: AgentDurableEffectJournalError.persistenceFailed) {
            _ = try journal.reserveEffect(request())
        }
        #expect(journal.record(for: identity()) == nil)
        #expect(journal.attempt(attemptID: "attempt-1") != nil)

        try FileManager.default.removeItem(at: directoryURL)
        _ = try journal.reserveEffect(request())
        let recovered = try AgentDurableEffectJournal(persistenceURL: directoryURL)
        #expect(recovered.attempt(attemptID: "attempt-1") != nil)
        #expect(recovered.record(for: identity()) != nil)
    }

    @Test func idempotencyDigestAndRedactedOutcomeAreDurableWithoutRawInput() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )

        let first = try journal.reserveEffect(request())
        let replay = try journal.reserveEffect(request())
        #expect(replay == first)
        #expect(journal.journalEntries().count == 2)
        #expect(first.idempotencyKey == "idem-1")
        #expect(first.inputDigest == "sha256-input-1")

        #expect(throws: AgentDurableEffectJournalError.idempotencyConflict) {
            _ = try journal.reserveEffect(
                request(
                    identity: identity(effectID: "effect-2"),
                    idempotencyKey: "idem-1"
                )
            )
        }

        _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now.addingTimeInterval(1))
        _ = try journal.completeEffect(
            identity(),
            leaseID: "lease-1",
            status: .failed,
            redactedOutcome: "provider unavailable",
            now: now.addingTimeInterval(2)
        )
        let persistedText = try String(contentsOf: directoryURL, encoding: .utf8)
        #expect(!persistedText.contains("raw-secret-input"))
        #expect(journal.record(for: identity())?.redactedOutcome == "provider unavailable")
    }

    @Test func cancelProducesTerminalEffectAndReleasesLease() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        _ = try journal.reserveEffect(request())

        let cancelled = try journal.cancelEffect(
            identity(),
            leaseID: "lease-1",
            redactedOutcome: "cancelled by user",
            now: now.addingTimeInterval(1)
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.lease.isReleased)
        #expect(cancelled.redactedOutcome == "cancelled by user")
    }

    @Test func retrySupersedesAttemptClosesLeaseAndRejectsLateWriteback() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        _ = try journal.reserveEffect(request())

        let retried = try journal.retryAttempt(
            taskID: "task-1",
            runID: "run-1",
            previousAttemptID: "attempt-1",
            nextAttemptID: "attempt-2",
            now: now.addingTimeInterval(1)
        )
        #expect(retried.attemptNumber == 2)
        #expect(retried.supersedesAttemptID == "attempt-1")
        #expect(journal.record(for: identity())?.status == .cancelled)
        #expect(journal.record(for: identity())?.lease.isReleased == true)
        #expect(throws: AgentDurableEffectJournalError.staleAttempt) {
            _ = try journal.submitEffect(
                identity(),
                leaseID: "lease-1",
                now: now.addingTimeInterval(2)
            )
        }
    }

    @Test func submittedReplayNeedsReviewAndNeverAutoReexecutes() throws {
        let (journal, directoryURL) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent()) }
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        _ = try journal.reserveEffect(request())
        _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now.addingTimeInterval(1))

        #expect(
            try journal.replayDecision(for: identity()) == .submittedNeedsReview
        )
        let before = journal.journalEntries()
        let replay = try journal.reserveEffect(request())
        #expect(replay.status == .submitted)
        #expect(journal.journalEntries() == before)
        #expect(journal.record(for: identity())?.status == .submitted)
    }
}
