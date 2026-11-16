import Foundation
import Testing
@testable import MinisCanvasApp

// W4-SCHED-CAS-RECEIPT-033 (wave-4, 2026-09-22): residual contract tests for
// the F16 scheduler family against the already-integrated donor units
// (PKG-INT-026A slots 1-2: intake-07 TaskScheduler/store side, intake-06
// SchedulerControlSettingsView/preview side). The capabilities for
// D-SCHEDA / D-SCHEDC / D-SCHEDF exist in this candidate; these suites pin
// only the sub-scenarios that had no direct contract proof yet:
//   1. D-SCHEDC: a CAS whose expected state matches but whose
//      expectedControlRevision is stale must fail closed without mutating the
//      ledger, and the row must remain observable as pending.
//   2. D-SCHEDC: cancel of a not-yet-leased row keeps zero dispatch across a
//      live poll, a lease claim, and a ledger reopen.
//   3. D-SCHEDF: a persisted delivery receipt must link back to its exact
//      task/occurrence identity across a store reopen without inventing
//      state, and the reopened runtime must not dispatch a second effect.
// Isolated UserDefaults suites and temp ledgers only; the submit seam is a
// pure in-memory capture, so no real external delivery can fire here.

@MainActor
private final class W4ReceiptLinkbackCapture: @unchecked Sendable {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("W4-033 scheduler CAS stale revision and cancel zero-dispatch")
@MainActor
struct W4SchedCASReceiptLinkbackContractTests {

    private func makeReopenableStore() -> (SchedulerTaskStore, UserDefaults, URL, () -> Void) {
        let suite = "w4-033-cas-receipt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("w4-033-cas-receipt-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, defaults, ledger, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func addAuthorizedTargetedTask(to store: SchedulerTaskStore) -> SchedulerTask {
        #expect(store.add(
            name: "W4-033 CAS 回链任务",
            cronExpression: "* * * * *",
            command: "w4-033 receipt linkback",
            targetSessionID: UUID(),
            targetProjectID: "w4-033-project",
            targetTurnID: 7
        ) == nil)
        let task = store.allTasks()[0]
        #expect(store.authorize(task.id, actorID: "w4-033-actor", scopeID: "w4-033-project", policyRevision: "policy-v1"))
        return task
    }

    private var utcMinuteCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// D-SCHEDC: CAS with a matching expected state but a stale
    /// expectedControlRevision fails closed, leaves the ledger byte-stable,
    /// and keeps the row observable as pending instead of half-advancing it.
    @Test func casWithStaleControlRevisionFailsClosedAndRowRemainsPending() throws {
        let (store, _, _, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let task = addAuthorizedTargetedTask(to: store)
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = try #require(store.reserveOccurrence(taskID: task.id, at: now, calendar: utcMinuteCalendar))
        #expect(occurrence.state == .triggered)
        #expect(occurrence.controlRevision == task.version)
        let journalCountBefore = store.occurrenceJournal.count

        // Correct expected state, deliberately stale revision (simulates a
        // second consumer that read an older ledger generation).
        #expect(!store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .triggered, next: .authorized,
            expectedControlRevision: task.version + 1, now: now
        ))
        let afterStale = try #require(store.occurrence(id: occurrence.id))
        #expect(afterStale.state == .triggered, "stale-revision CAS 不得推进状态")
        #expect(afterStale.controlRevision == task.version)
        #expect(store.occurrenceJournal.count == journalCountBefore, "stale-revision CAS 不得追加 journal")
        // The row remains a pending, resumable fact rather than vanishing or
        // half-committing: the user-visible queue keeps one waiting row.
        #expect(store.resumableOccurrences().map(\.id).contains(occurrence.id))

        // The same transition with the live revision still succeeds (the
        // failure above fenced the caller, not the state machine).
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .triggered, next: .authorized,
            expectedControlRevision: task.version, now: now
        ))
        #expect(store.occurrence(id: occurrence.id)?.state == .authorized)
        #expect(store.occurrenceJournal.count == journalCountBefore + 1)
    }

    /// D-SCHEDC: a cancelled not-yet-leased occurrence keeps zero dispatch —
    /// a same-minute poll never re-drives it, a lease claim fails, and the
    /// cancellation survives a reopen with still-zero effect submissions.
    @Test func cancelledOccurrenceBeforeLeaseDispatchesZeroAcrossPollAndReopen() async throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let task = addAuthorizedTargetedTask(to: store)
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = try #require(store.reserveOccurrence(taskID: task.id, at: now, calendar: utcMinuteCalendar))

        #expect(store.cancelOccurrence(
            id: occurrence.id,
            expectedTaskVersion: task.version,
            expectedControlRevision: occurrence.controlRevision,
            now: now
        ))
        #expect(store.occurrence(id: occurrence.id)?.state == .cancelled)
        // A fenced terminal row cannot be cancelled twice or CAS-revived.
        #expect(!store.cancelOccurrence(
            id: occurrence.id,
            expectedTaskVersion: task.version,
            expectedControlRevision: occurrence.controlRevision,
            now: now.addingTimeInterval(1)
        ))
        #expect(!store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .cancelled, next: .authorized,
            expectedControlRevision: task.version, now: now
        ))
        #expect(store.claimLease(
            id: occurrence.id, owner: "late-worker",
            expectedControlRevision: task.version, now: now
        ) == nil)

        let firstCapture = W4ReceiptLinkbackCapture()
        let firstRuntime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            firstCapture.requests.append(request)
            return .delivered
        })
        firstRuntime.pollNow(at: now, calendar: utcMinuteCalendar)
        firstRuntime.pollNow(at: now.addingTimeInterval(30), calendar: utcMinuteCalendar)
        #expect(firstCapture.requests.isEmpty, "取消后同分钟 poll 必须零派发")

        // Reopen: the cancelled row stays terminal history; a fresh runtime
        // still dispatches nothing for the same minute.
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let reopenedRow = try #require(reopened.occurrence(id: occurrence.id))
        #expect(reopenedRow.state == .cancelled)
        #expect(reopenedRow.deliveryReceipt == nil, "取消行不得被伪造成投递回执")
        #expect(reopenedRow.submissionReceipt == nil)
        #expect(!reopened.resumableOccurrences().map(\.id).contains(occurrence.id))
        let secondCapture = W4ReceiptLinkbackCapture()
        let secondRuntime = SchedulerTaskRuntime(store: reopened, submitOccurrenceResult: { request in
            secondCapture.requests.append(request)
            return .delivered
        })
        secondRuntime.pollNow(at: now, calendar: utcMinuteCalendar)
        #expect(secondCapture.requests.isEmpty, "重开后取消行仍须零派发")
        // Identity uniqueness: the same minute/version still maps to exactly
        // one ledger row (the cancelled one), not a respawned duplicate.
        #expect(reopened.occurrences.filter {
            $0.taskID == task.id && $0.taskVersion == task.version
        }.count == 1)
    }

    /// D-SCHEDF: after a real (captured) delivery, a store reopened from the
    /// persisted ledger must still link the receipt back to its exact
    /// occurrence/task identity and must not invent state or a second effect.
    @Test func deliveredReceiptLinksBackToTaskIdentityAcrossReopenWithoutSecondDispatch() async throws {
        let (store, defaults, ledger, cleanup) = makeReopenableStore()
        defer { cleanup() }
        let task = addAuthorizedTargetedTask(to: store)
        let now = Date(timeIntervalSince1970: 1_756_650_000)

        let capture = W4ReceiptLinkbackCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            capture.requests.append(request)
            return .delivered
        })
        runtime.pollNow(at: now, calendar: utcMinuteCalendar)
        let submitted = try #require(capture.requests.first)
        #expect(capture.requests.count == 1)
        let delivered = try #require(store.occurrence(id: submitted.occurrenceID))
        #expect(delivered.state == .succeeded)
        #expect(delivered.submissionReceipt?.request == submitted)

        // Reopen strictly from persisted facts — no in-memory handoff.
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let restored = try #require(reopened.occurrence(id: submitted.occurrenceID))
        #expect(restored.state == .succeeded, "重开不得改写终态")
        #expect(restored.deliveryReceipt?.status == .delivered)
        let receipt = try #require(restored.submissionReceipt)
        #expect(receipt.status == .delivered)
        // Link-back identity: every field must be traceable to the durable
        // occurrence/task, never to caller-supplied state.
        #expect(receipt.request.occurrenceID == restored.id)
        #expect(receipt.request.effectID == restored.effectID)
        #expect(receipt.request.taskID == task.id)
        #expect(receipt.request.taskVersion == restored.taskVersion)
        #expect(receipt.request.idempotencyKey == restored.idempotencyKey)
        #expect(receipt.request.command == restored.command)
        #expect(receipt.request.targetSessionID == restored.targetSessionID)
        #expect(receipt.request.targetProjectID == restored.targetProjectID)
        #expect(receipt.request.targetTurnID == restored.targetTurnID)
        #expect(receipt.request.sourceTaskID == task.id)
        #expect(receipt.request.hasValidTarget)

        // A restarted runtime consuming the same ledger cannot double-send:
        // the succeeded row is neither resumable nor re-dispatchable.
        #expect(!reopened.resumableOccurrences().map(\.id).contains(restored.id))
        let postReopenCapture = W4ReceiptLinkbackCapture()
        let secondRuntime = SchedulerTaskRuntime(store: reopened, submitOccurrenceResult: { request in
            postReopenCapture.requests.append(request)
            return .delivered
        })
        secondRuntime.pollNow(at: now, calendar: utcMinuteCalendar)
        secondRuntime.pollNow(at: now.addingTimeInterval(45), calendar: utcMinuteCalendar)
        #expect(postReopenCapture.requests.isEmpty, "已投递 occurrence 重开后不得二次派发")
        #expect(reopened.occurrences.count == 1)
    }
}
