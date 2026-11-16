import CryptoKit
import Foundation
import Testing
@testable import MinisCore

/// P3-EVENT-01 contract suite for the single durable event fact source
/// (`AgentDurableEffectJournal`): closed replay vocabulary, authenticated
/// ignorable compatibility, monotonic sequence, unknown-required fail-closed, replay without side
/// effects, durable effect order, and bounded torn-tail recovery.
@Suite("P3Event01DurableEventReplayContract", .serialized)
struct P3Event01DurableEventReplayContractTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func makeJournalURL(_ name: String = #function) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3Event01Tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("journal.json")
    }

    private func identity() -> AgentDurableEffectIdentity {
        AgentDurableEffectIdentity(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            effectID: "effect-1"
        )
    }

    private func request() -> AgentDurableEffectRequest {
        AgentDurableEffectRequest(
            identity: identity(),
            lease: AgentDurableEffectLease(
                leaseID: "lease-1",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            idempotencyKey: "idem-1",
            inputDigest: "sha256-input-1"
        )
    }

    /// Opens a journal that has run one full lease→submit→complete lifecycle
    /// (four durable entries).
    private func makePopulatedJournal(_ url: URL) throws -> AgentDurableEffectJournal {
        let journal = try AgentDurableEffectJournal(persistenceURL: url)
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        _ = try journal.reserveEffect(request(), now: now)
        _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now.addingTimeInterval(1))
        _ = try journal.completeEffect(
            identity(),
            leaseID: "lease-1",
            status: .succeeded,
            redactedOutcome: "ok",
            now: now.addingTimeInterval(2)
        )
        return journal
    }

    /// Replaces the payload of the `occurrence`-th `"checksum":"` field in
    /// the persisted JSON. Occurrences are counted from 1 in file order:
    /// the effect-record bindings sort before the append-only entries.
    private enum FixtureError: Error {
        case missingField
    }

    private func replacingChecksum(in url: URL, occurrence: Int, with replacement: String) throws {
        let marker = "\"checksum\":\""
        var text = try String(contentsOf: url, encoding: .utf8)
        var searchStart = text.startIndex
        for _ in 1..<occurrence {
            guard let found = text.range(of: marker, range: searchStart..<text.endIndex) else {
                throw FixtureError.missingField
            }
            searchStart = found.upperBound
        }
        guard let found = text.range(of: marker, range: searchStart..<text.endIndex),
              let end = text.range(of: "\"", range: found.upperBound..<text.endIndex) else {
            throw FixtureError.missingField
        }
        text.replaceSubrange(found.upperBound..<end.lowerBound, with: replacement)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replaces the value of the last `"kind":"` field in the persisted JSON.
    private func replacingLastKind(in url: URL, with replacement: String) throws {
        let marker = "\"kind\":\""
        var text = try String(contentsOf: url, encoding: .utf8)
        guard let found = text.range(of: marker, options: .backwards),
              let end = text.range(of: "\"", range: found.upperBound..<text.endIndex) else {
            throw FixtureError.missingField
        }
        text.replaceSubrange(found.upperBound..<end.lowerBound, with: replacement)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Clause: append-only closed event vocabulary (frozen, all required)

    @Test func vocabularyIsFrozenAndEveryMemberIsRequired() throws {
        let vocabulary = AgentDurableEffectJournalEventKind.frozenVocabulary
        #expect(vocabulary.count == 5)
        #expect(Set(vocabulary).count == 5)
        #expect(vocabulary.contains(.attemptStarted))
        #expect(vocabulary.contains(.effectLeased))
        #expect(vocabulary.contains(.effectSubmitted))
        #expect(vocabulary.contains(.effectCompleted))
        #expect(vocabulary.contains(.effectCancelled))
        for kind in vocabulary {
            #expect(kind.replayRequirement == .required)
        }
    }

    @Test func unknownEventKindCannotBeDecoded() throws {
        let data = Data("\"effectScheduledElsewhere\"".utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AgentDurableEffectJournalEventKind.self, from: data)
        }
    }

    @Test func lifecycleAppendsOnlyFrozenVocabularyWithContiguousSequences() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try makePopulatedJournal(url)

        let entries = journal.journalEntries()
        #expect(entries.map(\.sequence) == [1, 2, 3, 4])
        let frozen = Set(AgentDurableEffectJournalEventKind.frozenVocabulary)
        #expect(entries.allSatisfy { frozen.contains($0.kind) })
        #expect(entries.map(\.kind) == [
            .attemptStarted,
            .effectLeased,
            .effectSubmitted,
            .effectCompleted,
        ])
        #expect(entries.dropFirst().enumerated().allSatisfy { offset, entry in
            entry.previousChecksum == entries[offset].checksum
        })
    }

    // MARK: - Clause: unknown required event fails closed

    @Test func unknownRequiredKindInPersistedLedgerFailsClosed() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try makePopulatedJournal(url)
        try replacingLastKind(in: url, with: "effectScheduledElsewhere")
        let tornText = try String(contentsOf: url, encoding: .utf8)

        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
        // Fail-closed means no silent repair: the file is left untouched.
        #expect(try String(contentsOf: url, encoding: .utf8) == tornText)
    }

    // Version 2 fixes the common envelope and reserves opaque string metadata
    // for future non-replay facts. This fixture models a newer writer, without
    // replacing the production decoder, integrity checks, or persistence path.
    private func authenticatedDocument(_ document: [String: Any], to url: URL) throws {
        var document = document
        document.removeValue(forKey: "snapshotChecksum")
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        document["snapshotChecksum"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func appendFutureEvent(
        to url: URL, requirement: String? = "ignorable", schema: Int = 2,
        kind: String = "futureDisplayAnnotation", effectID: String? = nil
    ) throws {
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(document["entries"] as? [[String: Any]])
        var event: [String: Any] = [
            "kind": kind, "taskID": "task-1", "runID": "run-1", "attemptID": "attempt-1",
            "timestamp": now.timeIntervalSinceReferenceDate,
            "opaquePayload": ["label": "future annotation", "revision": "2"],
        ]
        if AgentDurableEffectJournalEventKind(rawValue: kind) != nil {
            event.removeValue(forKey: "opaquePayload")
        }
        if let requirement { event["replayRequirement"] = requirement }
        if let effectID { event["effectID"] = effectID }
        var entry: [String: Any] = ["sequence": entries.count + 1, "event": event]
        entry["previousChecksum"] = entries.last?["checksum"]
        let material = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        entry["checksum"] = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        entries.append(entry)
        document["schemaVersion"] = schema
        document["entries"] = entries
        try authenticatedDocument(document, to: url)
    }

    @Test func unknownIgnorableEventSurvivesReopenReplayAndLaterAppend() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let known = try makePopulatedJournal(url).journalEntries()
        try appendFutureEvent(to: url)
        let bytes = try Data(contentsOf: url)
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let originalEntries = try #require(original["entries"] as? [[String: Any]])
        let futureBytes = try JSONSerialization.data(withJSONObject: originalEntries[4], options: [.sortedKeys])

        let reloaded = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(reloaded.recoveredTornTailEntryCount == 0)
        #expect(reloaded.journalEntries() == known)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try reloaded.replayDecision(for: identity()) == .terminal)
        #expect(try reloaded.reserveEffect(request(), now: now.addingTimeInterval(3)).status == .succeeded)
        #expect(try Data(contentsOf: url) == bytes)

        // A normal production write must retain the future fact and chain from
        // it, rather than silently overwrite or truncate it during reopening.
        _ = try reloaded.beginAttempt(taskID: "task-2", runID: "run-2", attemptID: "attempt-2", now: now)
        let persisted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(persisted["entries"] as? [[String: Any]])
        #expect(entries.count == 6)
        #expect(try JSONSerialization.data(withJSONObject: entries[4], options: [.sortedKeys]) == futureBytes)
        #expect(entries[5]["previousChecksum"] as? String == entries[4]["checksum"] as? String)
        let reopenedAgain = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(reopenedAgain.journalEntries().map(\.sequence) == [1, 2, 3, 4, 6])
        #expect(reopenedAgain.attempt(attemptID: "attempt-2")?.taskID == "task-2")
        #expect(try reopenedAgain.replayDecision(for: identity()) == .terminal)
    }

    @Test(arguments: ["required", "missing", "invalid", "legacy", "unsupported", "downgrade", "effect"])
    func incompatibleFutureEventFailsClosedEvenWithValidChecksums(_ scenario: String) throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try makePopulatedJournal(url)
        try appendFutureEvent(
            to: url,
            requirement: scenario == "missing" ? nil : scenario == "required" ? "required" : scenario == "invalid" ? "optional" : "ignorable",
            schema: scenario == "legacy" ? 1 : scenario == "unsupported" ? 3 : 2,
            kind: scenario == "downgrade" ? "effectCompleted" : "futureDisplayAnnotation",
            effectID: scenario == "effect" ? "effect-1" : nil
        )
        let bytes = try Data(contentsOf: url)
        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func ignorableMetadataTamperingIsNotSkippedOrRepaired() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try makePopulatedJournal(url)
        try appendFutureEvent(to: url)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "future annotation", with: "tampered annotation")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let bytes = try Data(contentsOf: url)
        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func legacyVersionOneBytesReopenWithoutRewriteAndRemainUsable() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try makePopulatedJournal(url).journalEntries()
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["schemaVersion"] = 1
        // Known-event wire bytes and entry checksums are unchanged from v1.
        let entries = try #require(document["entries"] as? [[String: Any]])
        for entry in entries {
            let event = try #require(entry["event"] as? [String: Any])
            #expect(event["replayRequirement"] == nil)
            #expect(event["opaquePayload"] == nil)
        }
        try authenticatedDocument(document, to: url)
        let bytes = try Data(contentsOf: url)
        let old = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(old.journalEntries() == before)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try old.replayDecision(for: identity()) == .terminal)
        _ = try old.beginAttempt(taskID: "task-2", runID: "run-2", attemptID: "attempt-2", now: now)
        let reopened = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(reopened.journalEntries().map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(reopened.record(for: identity())?.status == .succeeded)
        let persisted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(persisted["schemaVersion"] as? Int == 1)
    }

    // MARK: - Clause: replay does not execute side effects

    @Test func reloadAndReplayDecisionNeverExecuteEffects() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try makePopulatedJournal(url)
        let before = journal.journalEntries()

        let reloaded = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(reloaded.journalEntries() == before)
        #expect(reloaded.recoveredTornTailEntryCount == 0)
        #expect(try reloaded.replayDecision(for: identity()) == .terminal)
        // Re-reserving the same idempotency key replays the stored fact;
        // it appends nothing and executes nothing.
        let replayed = try reloaded.reserveEffect(request(), now: now.addingTimeInterval(3))
        #expect(replayed.status == .succeeded)
        #expect(reloaded.journalEntries().count == before.count)
    }

    // MARK: - Clause: durable effect order is enforced

    @Test func durableEffectOrderIsEnforced() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try AgentDurableEffectJournal(persistenceURL: url)
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )

        #expect(throws: AgentDurableEffectJournalError.unknownEffect) {
            _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now)
        }
        _ = try journal.reserveEffect(request(), now: now)
        // A leased effect cannot complete before it is submitted.
        #expect(throws: AgentDurableEffectJournalError.invalidTransition) {
            _ = try journal.completeEffect(
                identity(),
                leaseID: "lease-1",
                status: .succeeded,
                redactedOutcome: "too early",
                now: now.addingTimeInterval(1)
            )
        }
        _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now.addingTimeInterval(1))
        #expect(throws: AgentDurableEffectJournalError.submittedEffectRequiresReview) {
            _ = try journal.cancelEffect(
                identity(),
                leaseID: "lease-1",
                redactedOutcome: "late cancel",
                now: now.addingTimeInterval(2)
            )
        }
    }

    // MARK: - Clause: torn-tail bounded recovery

    @Test func tornTailDropsOnlyTheFinalEntryAndKeepsTheLedgerUsable() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try makePopulatedJournal(url)
        let intactPrefix = Array(journal.journalEntries().dropLast())

        // Damage exactly one trailing field: the last entry's stored checksum.
        _ = try replacingChecksum(in: url, occurrence: 5, with: String(repeating: "f", count: 64))

        let recovered = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(recovered.recoveredTornTailEntryCount == 1)
        // Recovery replays the surviving events into pure projections without
        // side effects: the visible log is exactly the verified prefix.
        #expect(recovered.journalEntries() == intactPrefix)
        #expect(recovered.journalEntries().map(\.sequence) == [1, 2, 3])
        // The attempt and the verified submitted entry survive. The damaged
        // completion is unknown, so recovery must retain the effect identity
        // and require reconciliation instead of making it executable again.
        #expect(recovered.attempt(attemptID: "attempt-1") != nil)
        #expect(recovered.record(for: identity())?.status == .submitted)
        #expect(recovered.record(for: identity())?.sequence == 3)
        #expect(try recovered.replayDecision(for: identity()) == .submittedNeedsReview)

        // Re-reserving the same key cannot create another submission. A new
        // effect with that key and an attempt retry are also fenced.
        let replayed = try recovered.reserveEffect(request(), now: now.addingTimeInterval(3))
        #expect(replayed.status == .submitted)
        #expect(recovered.journalEntries().count == 3)
        let conflicting = AgentDurableEffectRequest(
            identity: AgentDurableEffectIdentity(
                taskID: "task-1", runID: "run-1", attemptID: "attempt-1", effectID: "effect-2"
            ),
            lease: request().lease,
            idempotencyKey: request().idempotencyKey,
            inputDigest: request().inputDigest
        )
        #expect(throws: AgentDurableEffectJournalError.idempotencyConflict) {
            _ = try recovered.reserveEffect(conflicting, now: now.addingTimeInterval(3))
        }
        #expect(throws: AgentDurableEffectJournalError.submittedEffectRequiresReview) {
            _ = try recovered.retryAttempt(
                taskID: "task-1", runID: "run-1",
                previousAttemptID: "attempt-1", nextAttemptID: "attempt-2",
                now: now.addingTimeInterval(3)
            )
        }
        // The repaired file reloads without a second discard and preserves
        // the unresolved submitted fact.
        let reloaded = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(reloaded.recoveredTornTailEntryCount == 0)
        #expect(reloaded.journalEntries().count == 3)
        #expect(reloaded.record(for: identity())?.status == .submitted)
    }

    @Test func recoveryBoundIsOneEntryMidLedgerBreakStillFailsClosed() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try makePopulatedJournal(url)

        // Entry 2's stored checksum breaks the chain in the middle; the
        // recovery bound only ever tolerates the final entry, so this must
        // fail closed rather than truncate the ledger down to entry 1.
        _ = try replacingChecksum(in: url, occurrence: 3, with: String(repeating: "0", count: 64))

        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
    }

    @Test func tornSubmittedCannotFallBackToExecutableLease() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try AgentDurableEffectJournal(persistenceURL: url)
        _ = try journal.beginAttempt(taskID: "task-1", runID: "run-1", attemptID: "attempt-1", now: now)
        _ = try journal.reserveEffect(request(), now: now)
        _ = try journal.submitEffect(identity(), leaseID: "lease-1", now: now.addingTimeInterval(1))

        // The valid prefix ends at effectLeased. That alone cannot prove the
        // external effect was never submitted, so recovery must fail closed.
        _ = try replacingChecksum(in: url, occurrence: 4, with: String(repeating: "a", count: 64))
        let damaged = try Data(contentsOf: url)
        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func tornCompletionWithUnverifiedLeaseProjectionFailsClosed() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try makePopulatedJournal(url)
        _ = try replacingChecksum(in: url, occurrence: 5, with: String(repeating: "f", count: 64))

        // A second mutation of the effect projection cannot be authenticated
        // by the surviving event prefix (which carries no lease dates).
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var effects = try #require(document["effectsByID"] as? [String: Any])
        var effect = try #require(effects["effect-1"] as? [String: Any])
        var lease = try #require(effect["lease"] as? [String: Any])
        lease["issuedAt"] = 1
        effect["lease"] = lease
        effects["effect-1"] = effect
        document["effectsByID"] = effects
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url, options: .atomic)
        let damaged = try Data(contentsOf: url)
        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func twoTrailingDamagedEntriesExceedTheBoundAndFailClosed() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try makePopulatedJournal(url)

        // Damage the last two entries: dropping only the final one still
        // leaves a broken tail, which is beyond the bounded recovery.
        _ = try replacingChecksum(in: url, occurrence: 5, with: String(repeating: "f", count: 64))
        _ = try replacingChecksum(in: url, occurrence: 4, with: String(repeating: "e", count: 64))

        #expect(throws: AgentDurableEffectJournalError.corruptLedger) {
            _ = try AgentDurableEffectJournal(persistenceURL: url)
        }
    }

    @Test func recoveryAfterRetryTailKeepsAttemptsDeterministic() throws {
        let url = try makeJournalURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try AgentDurableEffectJournal(persistenceURL: url)
        _ = try journal.beginAttempt(
            taskID: "task-1",
            runID: "run-1",
            attemptID: "attempt-1",
            now: now
        )
        _ = try journal.reserveEffect(request(), now: now)
        let retried = try journal.retryAttempt(
            taskID: "task-1",
            runID: "run-1",
            previousAttemptID: "attempt-1",
            nextAttemptID: "attempt-2",
            now: now.addingTimeInterval(1)
        )
        #expect(retried.attemptNumber == 2)
        // Entries: attemptStarted, effectLeased, effectCancelled, attemptStarted.
        let before = journal.journalEntries()
        #expect(before.map(\.sequence) == [1, 2, 3, 4])

        // The torn final entry is the retry's attemptStarted; recovery folds
        // attempts from surviving events, so the run reverts to attempt-1 and
        // the already-cancelled effect fact (entry 3) survives.
        _ = try replacingChecksum(in: url, occurrence: 5, with: String(repeating: "a", count: 64))

        let recovered = try AgentDurableEffectJournal(persistenceURL: url)
        #expect(recovered.recoveredTornTailEntryCount == 1)
        #expect(recovered.journalEntries() == Array(before.dropLast()))
        #expect(recovered.attempt(attemptID: "attempt-2") == nil)
        #expect(recovered.attempt(attemptID: "attempt-1")?.attemptNumber == 1)
        #expect(recovered.record(for: identity())?.status == .cancelled)

        // Deterministic continuation: replaying the same retry appends a
        // fresh attemptStarted bound to the surviving chain.
        let retriedAgain = try recovered.retryAttempt(
            taskID: "task-1",
            runID: "run-1",
            previousAttemptID: "attempt-1",
            nextAttemptID: "attempt-2",
            now: now.addingTimeInterval(2)
        )
        #expect(retriedAgain.attemptNumber == 2)
        #expect(recovered.journalEntries().count == 4)
    }
}
