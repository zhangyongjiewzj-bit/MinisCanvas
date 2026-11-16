import Foundation
import Testing
@testable import MinisCanvasApp

// QODER-DEV-W13-SCHEDC-176 (wave-4, 2026-09-23): residual D-SCHEDC contract
// tests for "暂停恢复取消CAS一致且取消后零dispatch". Prior accepted work in
// this chain already pins (cited, not re-tested here):
//   · W4SchedCASReceiptLinkbackContractTests.swift:67 — CAS with a stale
//     expectedControlRevision fails closed and the row remains pending.
//   · W4SchedCASReceiptLinkbackContractTests.swift:104 — cancel of a
//     not-yet-leased (.triggered) row keeps zero dispatch across same-minute
//     polls and a store reopen.
//   · SchedulerRuntimeConsumerTests.swift:236 — pause fences queued rows and
//     re-enable dispatches exactly one new occurrence (pause→resume).
//   · AutomationDurableRunTests.swift:84 — state-mismatch CAS losers and
//     stale-lease late receipts fail closed.
// The ledger row still flagged two open sub-scenarios, which this suite
// closes with executing tests that would fail if the pinned guard were
// removed:
//   1. cancelledOccurrenceStopsQueuedEffectContinuationBeforeDispatch:
//      between drive() launching the async effect continuation and the
//      continuation invoking submit, a user cancel lands on the leased/
//      running row. The queued continuation must re-check the durable
//      generation (SchedulerTaskRuntime.launchEffect `context.isCurrent()`
//      before dispatch) and produce ZERO effect invocations, and the
//      cancellation path after the failed guard must not revive or relabel
//      the already-terminal row. Removing the pre-dispatch guard makes the
//      probe non-empty and fails this test.
//   2. cancelledAdmittedRowDispatchesZeroWhileSiblingAdmittedRowStillDispatches:
//      rows already advanced to .admitted (the queue state poll would
//      genuinely drive next) cancel CAS-consistently and then dispatch
//      zero across repeated same-minute polls, while a non-cancelled sibling
//      in the identical state still dispatches exactly once — the zero is
//      produced by the cancel fence, not by an inert fixture.
//   3. cancelledWaitingApprovalRowSurvivesAuthorizationAndPollWithoutRevival:
//      a row parked at .waitingApproval by the approval fence cancels with
//      an observable result; later authorization plus polling may neither
//      revive it nor respawn a duplicate row for the same minute.
// Synthetic suites/ledgers and an injected clock only; no wall-clock sleeps,
// no real targets, no external side effects can fire.

@MainActor
private final class W176EffectProbe {
    private(set) var startedContexts: [SchedulerExecutionContext] = []
    func submit(_ context: SchedulerExecutionContext) async throws -> SchedulerEffectOutcome {
        startedContexts.append(context)
        return SchedulerEffectOutcome(status: .delivered)
    }
}

@MainActor
private final class W176RequestCapture: @unchecked Sendable {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("W13-176 D-SCHEDC cancel CAS consistency and post-cancel zero dispatch")
@MainActor
struct W13SchedC176CancelZeroDispatchTests {

    private func makeStore() -> (SchedulerTaskStore, () -> Void) {
        let suite = "w13-176-schedc-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("w13-176-schedc-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func addAuthorizedTargetedTask(
        to store: SchedulerTaskStore,
        name: String
    ) -> SchedulerTask {
        #expect(store.add(
            name: name,
            cronExpression: "* * * * *",
            command: "w13-176 \(name)",
            targetSessionID: UUID(),
            targetProjectID: "w13-176-project",
            targetTurnID: 7
        ) == nil)
        let task = try! #require(store.allTasks().first { $0.name == name })
        #expect(store.authorize(
            task.id,
            actorID: "w13-176-actor",
            scopeID: "w13-176-project",
            policyRevision: "policy-v1"
        ))
        return task
    }

    private var utcMinuteCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func advanceToAdmitted(
        _ store: SchedulerTaskStore,
        occurrenceID: UUID,
        revision: Int,
        now: Date
    ) throws {
        #expect(store.compareAndSwapOccurrence(
            id: occurrenceID, expected: .triggered, next: .authorized,
            expectedControlRevision: revision, now: now
        ))
        let authorized = try #require(store.occurrence(id: occurrenceID))
        #expect(store.compareAndSwapOccurrence(
            id: occurrenceID, expected: .authorized, next: .admitted,
            expectedControlRevision: authorized.controlRevision, now: now
        ))
        #expect(store.occurrence(id: occurrenceID)?.state == .admitted)
    }

    /// Open sub-scenario 1: zero dispatch across the async boundary. The
    /// effect continuation is queued by drive(); the cancel lands before the
    /// continuation runs; the pre-dispatch `context.isCurrent()` re-check
    /// must stop the effect and the cancelled row must stay terminal with no
    /// fabricated receipts.
    @Test func cancelledOccurrenceStopsQueuedEffectContinuationBeforeDispatch() async throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTargetedTask(to: store, name: "W176-async-boundary")
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let probe = W176EffectProbe()
        let runtime = SchedulerTaskRuntime(
            store: store,
            now: { date },
            submitEffect: { context in
                try await probe.submit(context)
            }
        )

        runtime.pollNow(at: date, calendar: utcMinuteCalendar)
        // pollNow drove the durable chain synchronously and returned while
        // the effect is still a queued MainActor continuation.
        let running = try #require(store.occurrences.first { $0.taskID == task.id })
        #expect(running.state == .running)
        #expect(running.leaseOwner != nil)
        #expect(running.leaseToken != nil)
        #expect(probe.startedContexts.isEmpty, "同一 MainActor turn 内 continuation 尚未启动")

        // User cancel with the durable lease credentials, before the
        // queued continuation could dispatch anything.
        #expect(runtime.cancelOccurrence(
            id: running.id,
            expectedTaskVersion: running.taskVersion,
            expectedControlRevision: running.controlRevision,
            owner: running.leaseOwner,
            token: running.leaseToken,
            now: date.addingTimeInterval(1)
        ))

        // Let the cancelled continuation run to completion. Yields only
        // schedule already-queued work; no wall-clock waiting.
        for _ in 0..<4 { await Task.yield() }

        let final = try #require(store.occurrence(id: running.id))
        #expect(probe.startedContexts.isEmpty, "取消后的 queued continuation 必须零 dispatch")
        #expect(final.state == .cancelled, "取消必须对 continuation 可见且保持终态")
        #expect(final.leaseOwner == nil && final.leaseToken == nil && final.leaseExpiresAt == nil)
        #expect(final.deliveryReceipt == nil, "取消行不得被伪造成投递回执")
        #expect(final.submissionReceipt == nil)
        // The failed-cancel catch path in the continuation must not downgrade
        // the already-terminal row into UNKNOWN.
        #expect(store.occurrences.filter { $0.taskID == task.id }.count == 1)
        #expect(store.occurrenceJournal.last { $0.occurrenceID == running.id }?.state == .cancelled)

        // Losing operations after the terminal transition are observable, not
        // silently overwritten: same-minute polls dispatch zero, a revival
        // CAS loses, and a second cancel reports the loss.
        runtime.pollNow(at: date.addingTimeInterval(30), calendar: utcMinuteCalendar)
        #expect(probe.startedContexts.isEmpty)
        #expect(!store.compareAndSwapOccurrence(
            id: running.id, expected: .cancelled, next: .authorized,
            expectedControlRevision: running.controlRevision, now: date
        ))
        #expect(!runtime.cancelOccurrence(
            id: running.id,
            expectedTaskVersion: running.taskVersion,
            expectedControlRevision: running.controlRevision,
            owner: running.leaseOwner,
            token: running.leaseToken,
            now: date.addingTimeInterval(2)
        ))
    }

    /// Open sub-scenario 2: cancel of an already .admitted row keeps zero
    /// dispatch across repeated polls while an identical non-cancelled sibling
    /// still dispatches exactly once — proving the queue state was live and
    /// the cancel fence, not fixture inertia, produced the zero.
    @Test func cancelledAdmittedRowDispatchesZeroWhileSiblingAdmittedRowStillDispatches() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let taskA = addAuthorizedTargetedTask(to: store, name: "W176-sibling-A")
        let taskB = addAuthorizedTargetedTask(to: store, name: "W176-cancelled-B")
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let rowA = try #require(store.reserveOccurrence(taskID: taskA.id, at: date, calendar: utcMinuteCalendar))
        let rowB = try #require(store.reserveOccurrence(taskID: taskB.id, at: date, calendar: utcMinuteCalendar))
        try advanceToAdmitted(store, occurrenceID: rowA.id, revision: rowA.controlRevision, now: date)
        try advanceToAdmitted(store, occurrenceID: rowB.id, revision: rowB.controlRevision, now: date)

        // Both admitted rows are live dispatch candidates before the cancel.
        let resumableIDs = Set(store.resumableOccurrences().map(\.id))
        #expect(resumableIDs.contains(rowA.id))
        #expect(resumableIDs.contains(rowB.id))

        let capture = W176RequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            capture.requests.append(request)
            return .delivered
        })
        #expect(runtime.cancelOccurrence(
            id: rowB.id,
            expectedTaskVersion: taskB.version,
            expectedControlRevision: rowB.controlRevision,
            now: date
        ))
        #expect(store.occurrence(id: rowB.id)?.state == .cancelled)
        #expect(!store.resumableOccurrences().map(\.id).contains(rowB.id))

        runtime.pollNow(at: date, calendar: utcMinuteCalendar)
        runtime.pollNow(at: date.addingTimeInterval(30), calendar: utcMinuteCalendar)

        #expect(capture.requests.map(\.occurrenceID) == [rowA.id],
                "取消的 admitted 行必须零派发，而同状态的兄弟行仍恰好派发一次")
        let doneA = try #require(store.occurrence(id: rowA.id))
        #expect(doneA.state == .succeeded)
        let doneB = try #require(store.occurrence(id: rowB.id))
        #expect(doneB.state == .cancelled)
        #expect(doneB.deliveryReceipt == nil)
        #expect(doneB.submissionReceipt == nil)
        // CAS-consistent loss observation: stale drivers that still believe
        // the row is .admitted are refused, not silently overwritten.
        #expect(!store.compareAndSwapOccurrence(
            id: rowB.id, expected: .admitted, next: .dispatched,
            expectedControlRevision: taskB.version, now: date
        ))
        #expect(store.claimLease(
            id: rowB.id, owner: "late-worker",
            expectedControlRevision: taskB.version, now: date
        ) == nil)
        #expect(!runtime.cancelOccurrence(
            id: rowB.id,
            expectedTaskVersion: taskB.version,
            expectedControlRevision: doneB.controlRevision,
            now: date.addingTimeInterval(1)
        ))
        // No duplicate row for the same minute/version was respawned.
        #expect(store.occurrences.filter {
            $0.taskID == taskB.id && $0.taskVersion == taskB.version
        }.count == 1)
    }

    /// Open sub-scenario 3: a row parked at .waitingApproval by the approval
    /// fence cancels with an observable result; later authorization plus
    /// polling may neither revive it nor spawn a duplicate row.
    @Test func cancelledWaitingApprovalRowSurvivesAuthorizationAndPollWithoutRevival() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let name = "W176-unauthorized-C"
        #expect(store.add(
            name: name,
            cronExpression: "* * * * *",
            command: "w13-176 \(name)",
            targetSessionID: UUID(),
            targetProjectID: "w13-176-project",
            targetTurnID: 7
        ) == nil)
        let task = try #require(store.allTasks().first { $0.name == name })
        let date = Date(timeIntervalSince1970: 1_756_650_000)

        let capture = W176RequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            capture.requests.append(request)
            return .delivered
        })
        runtime.pollNow(at: date, calendar: utcMinuteCalendar)
        let parked = try #require(store.occurrences.first { $0.taskID == task.id })
        #expect(parked.state == .waitingApproval, "未授权任务的 poll 必须停在审批栅栏")
        #expect(capture.requests.isEmpty)

        #expect(runtime.cancelOccurrence(
            id: parked.id,
            expectedTaskVersion: task.version,
            expectedControlRevision: parked.controlRevision,
            now: date
        ))
        #expect(store.occurrence(id: parked.id)?.state == .cancelled)
        // Losing transitions stay observable after the cancel.
        #expect(!store.compareAndSwapOccurrence(
            id: parked.id, expected: .waitingApproval, next: .authorized,
            expectedControlRevision: parked.controlRevision, now: date
        ))

        // A later authorization removes every other fence; the cancelled row
        // must still be terminal history with zero dispatch and no revival.
        #expect(store.authorize(
            task.id,
            actorID: "w13-176-actor",
            scopeID: "w13-176-project",
            policyRevision: "policy-v2"
        ))
        runtime.pollNow(at: date, calendar: utcMinuteCalendar)
        runtime.pollNow(at: date.addingTimeInterval(30), calendar: utcMinuteCalendar)
        #expect(capture.requests.isEmpty, "取消后的 waitingApproval 行在授权后仍须零派发")
        #expect(store.occurrence(id: parked.id)?.state == .cancelled)
        #expect(store.occurrences.filter { $0.taskID == task.id }.count == 1,
                "同分钟不得复活或复制已取消行")
    }
}
