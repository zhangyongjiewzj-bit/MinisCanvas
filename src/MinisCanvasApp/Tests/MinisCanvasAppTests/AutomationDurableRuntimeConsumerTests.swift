import Foundation
import Testing
@testable import MinisCanvasApp

// Production-consumer continuation for P3-SCHED-01.
// The runtime must use the Store ledger for admission, lease fencing,
// delivery receipts, and restart reconciliation; no direct-submit bypass is
// considered a valid production path.

private final class RuntimeRequestSpy: @unchecked Sendable {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("P3 Automation durable runtime consumer")
@MainActor
struct AutomationDurableRuntimeConsumerTests {

    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "automation-runtime-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeLedgerURL() -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        return (directory.appendingPathComponent("occurrences.json"), {
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func makeTargetedStore(defaults: UserDefaults, ledgerURL: URL) -> (SchedulerTaskStore, SchedulerTask) {
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        store.add(
            name: "运行时自动化",
            cronExpression: "* * * * *",
            command: "提交运行时任务",
            targetSessionID: UUID(),
            targetProjectID: "runtime-project",
            targetTurnID: 1
        )
        return (store, store.allTasks()[0])
    }

    private func moveToDispatched(_ store: SchedulerTaskStore, occurrenceID: UUID, revision: Int) {
        #expect(store.compareAndSwapOccurrence(id: occurrenceID, expected: .triggered, next: .authorized, expectedControlRevision: revision))
        #expect(store.compareAndSwapOccurrence(id: occurrenceID, expected: .authorized, next: .admitted, expectedControlRevision: revision))
        #expect(store.compareAndSwapOccurrence(id: occurrenceID, expected: .admitted, next: .dispatched, expectedControlRevision: revision))
    }

    @Test func runtimeConsumesLedgerAndRestartDoesNotRedispatchTerminalRun() {
        let (defaults, cleanupDefaults) = makeDefaults()
        let (ledgerURL, cleanupLedger) = makeLedgerURL()
        defer { cleanupDefaults(); cleanupLedger() }
        let (store, task) = makeTargetedStore(defaults: defaults, ledgerURL: ledgerURL)
        #expect(store.authorize(task.id))

        let spy = RuntimeRequestSpy()
        let runtime = SchedulerTaskRuntime(
            store: store,
            submitOccurrenceResult: { request in
                spy.requests.append(request)
                return .delivered
            }
        )
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        runtime.pollNow(at: date)
        #expect(spy.requests.count == 1)
        #expect(store.occurrences.count == 1)
        #expect(store.occurrences[0].state == .succeeded)
        #expect(store.occurrences[0].submissionReceipt?.request == spy.requests[0])

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        let restartSpy = RuntimeRequestSpy()
        SchedulerTaskRuntime(
            store: reopened,
            submitOccurrenceResult: { request in
                restartSpy.requests.append(request)
                return .delivered
            }
        ).pollNow(at: date)
        #expect(restartSpy.requests.isEmpty, "重启后 terminal occurrence 不得重复提交")
        #expect(reopened.occurrence(id: store.occurrences[0].id)?.state == .succeeded)
    }

    @Test func runtimeRestartReconcilesExpiredLeaseAndRejectsLateResult() {
        let (defaults, cleanupDefaults) = makeDefaults()
        let (ledgerURL, cleanupLedger) = makeLedgerURL()
        defer { cleanupDefaults(); cleanupLedger() }
        let (store, task) = makeTargetedStore(defaults: defaults, ledgerURL: ledgerURL)
        #expect(store.authorize(task.id))
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = store.reserveOccurrence(taskID: task.id, at: date)!
        moveToDispatched(store, occurrenceID: occurrence.id, revision: task.version)
        let token = store.claimLease(id: occurrence.id, owner: "worker-a", now: date, ttl: 1)!
        #expect(store.heartbeat(id: occurrence.id, owner: "worker-a", token: token, now: date, ttl: 1))

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        #expect(reopened.reconcileExpiredOccurrences(now: date.addingTimeInterval(1)) == 1)
        #expect(reopened.occurrence(id: occurrence.id)?.state == .unknown)
        #expect(!reopened.recordDelivery(
            id: occurrence.id,
            owner: "worker-a",
            token: token,
            status: .delivered,
            now: date.addingTimeInterval(1),
            expectedTaskVersion: task.version,
            expectedControlRevision: task.version
        ), "过期 lease 的晚到结果必须被 fence 拒绝")

        let runtimeSpy = RuntimeRequestSpy()
        SchedulerTaskRuntime(
            store: reopened,
            submitOccurrenceResult: { request in
                runtimeSpy.requests.append(request)
                return .delivered
            }
        ).pollNow(at: date)
        #expect(runtimeSpy.requests.isEmpty, "UNKNOWN 必须等待显式 reconcile，不得自动重发")
    }
}
