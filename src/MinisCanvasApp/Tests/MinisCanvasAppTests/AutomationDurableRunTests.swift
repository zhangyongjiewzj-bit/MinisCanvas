import Foundation
import Testing
@testable import MinisCanvasApp

// GAP_CLASSIFICATION: DOMAIN_STATE_GAP (current Store had no durable ledger).
// P3-SCHED-01/P3-TASK-01/P3-EVENT-01/P3-REC-01 durable lifecycle contract.
// These tests exercise the production SchedulerTaskStore state machine with
// isolated defaults/ledger files; no App, network, or Keychain is involved.

@Suite("P3 Automation durable run")
@MainActor
struct AutomationDurableRunTests {

    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "automation-durable-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeLedgerURL() -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-durable-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("occurrences.json")
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    private func makeTargetedStore(
        defaults: UserDefaults,
        ledgerURL: URL,
        command: String = "执行自动化"
    ) -> (SchedulerTaskStore, SchedulerTask) {
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        let sessionID = UUID()
        store.add(
            name: "自动化任务",
            cronExpression: "* * * * *",
            command: command,
            targetSessionID: sessionID,
            targetProjectID: "project-automation",
            targetTurnID: 1
        )
        return (store, store.allTasks()[0])
    }

    private func moveToDispatched(
        _ store: SchedulerTaskStore,
        occurrenceID: UUID,
        revision: Int
    ) {
        #expect(store.compareAndSwapOccurrence(id: occurrenceID, expected: .triggered, next: .authorized, expectedControlRevision: revision))
        #expect(store.compareAndSwapOccurrence(id: occurrenceID, expected: .authorized, next: .admitted, expectedControlRevision: revision))
        #expect(store.compareAndSwapOccurrence(id: occurrenceID, expected: .admitted, next: .dispatched, expectedControlRevision: revision))
    }

    @Test func occurrenceCASLeaseReceiptAndRestartAreDurable() {
        let (defaults, cleanupDefaults) = makeDefaults()
        let (ledgerURL, cleanupLedger) = makeLedgerURL()
        defer { cleanupDefaults(); cleanupLedger() }
        let (store, task) = makeTargetedStore(defaults: defaults, ledgerURL: ledgerURL)
        #expect(store.authorize(task.id))

        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = store.reserveOccurrence(taskID: task.id, at: date)!
        moveToDispatched(store, occurrenceID: occurrence.id, revision: task.version)
        let token = store.claimLease(id: occurrence.id, owner: "worker-a", now: date, ttl: 30)!
        #expect(store.heartbeat(id: occurrence.id, owner: "worker-a", token: token, now: date, ttl: 30))
        #expect(store.recordDelivery(
            id: occurrence.id,
            owner: "worker-a",
            token: token,
            status: .delivered,
            now: date,
            expectedTaskVersion: task.version,
            expectedControlRevision: task.version
        ))
        #expect(store.occurrence(id: occurrence.id)?.state == .succeeded)
        #expect(store.occurrence(id: occurrence.id)?.deliveryReceipt?.status == .delivered)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        #expect(reopened.occurrence(id: occurrence.id)?.state == .succeeded)
        #expect(reopened.occurrenceJournal.map(\.state) == [.triggered, .authorized, .admitted, .dispatched, .leased, .running, .succeeded])
    }

    @Test func staleCASLeaseAndLateReceiptFailClosed() {
        let (defaults, cleanupDefaults) = makeDefaults()
        let (ledgerURL, cleanupLedger) = makeLedgerURL()
        defer { cleanupDefaults(); cleanupLedger() }
        let (store, task) = makeTargetedStore(defaults: defaults, ledgerURL: ledgerURL)
        #expect(store.authorize(task.id))
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = store.reserveOccurrence(taskID: task.id, at: date)!
        #expect(!store.compareAndSwapOccurrence(id: occurrence.id, expected: .authorized, next: .admitted, expectedControlRevision: task.version))
        moveToDispatched(store, occurrenceID: occurrence.id, revision: task.version)
        let token = store.claimLease(id: occurrence.id, owner: "worker-a", now: date, ttl: 1)!
        #expect(store.reconcileExpiredOccurrences(now: date.addingTimeInterval(1)) == 1)
        #expect(store.occurrence(id: occurrence.id)?.state == .unknown)
        #expect(!store.recordDelivery(
            id: occurrence.id,
            owner: "worker-a",
            token: token,
            status: .delivered,
            now: date.addingTimeInterval(1),
            expectedTaskVersion: task.version,
            expectedControlRevision: task.version
        ))
        #expect(store.inspectUnknownOccurrence(id: occurrence.id) != nil)
    }

    @Test func unknownRequiresPersistedReconcileBeforeRetry() {
        let (defaults, cleanupDefaults) = makeDefaults()
        let (ledgerURL, cleanupLedger) = makeLedgerURL()
        defer { cleanupDefaults(); cleanupLedger() }
        let (store, task) = makeTargetedStore(defaults: defaults, ledgerURL: ledgerURL)
        #expect(store.authorize(task.id))
        let date = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = store.reserveOccurrence(taskID: task.id, at: date)!
        moveToDispatched(store, occurrenceID: occurrence.id, revision: task.version)
        let token = store.claimLease(id: occurrence.id, owner: "worker-a", now: date, ttl: 30)!
        #expect(store.heartbeat(id: occurrence.id, owner: "worker-a", token: token, now: date, ttl: 30))
        #expect(store.recordDelivery(
            id: occurrence.id,
            owner: "worker-a",
            token: token,
            status: .unknown,
            now: date,
            expectedTaskVersion: task.version,
            expectedControlRevision: task.version
        ))
        #expect(store.retryUnknownOccurrence(
            id: occurrence.id,
            expectedControlRevision: task.version,
            proofToken: "missing-proof",
            now: date
        ) == nil)
        #expect(store.reconcileUnknownOccurrence(id: occurrence.id, now: date))
        let proof = store.occurrence(id: occurrence.id)!.reconciliationProof!
        let retry = store.retryUnknownOccurrence(
            id: occurrence.id,
            expectedControlRevision: task.version,
            proofToken: proof,
            now: date
        )!
        #expect(retry.retryOfOccurrenceID == occurrence.id)
        #expect(store.occurrence(id: occurrence.id)?.state == .retryRequested)
        #expect(store.occurrence(id: retry.id)?.state == .triggered)
    }

    @Test func corruptLedgerIsQuarantinedAndStoreFailsClosed() {
        let (defaults, cleanupDefaults) = makeDefaults()
        let (ledgerURL, cleanupLedger) = makeLedgerURL()
        defer { cleanupDefaults(); cleanupLedger() }
        try! FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("{\"schemaVersion\":1".utf8).write(to: ledgerURL)

        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        guard case .corruptLedger(let quarantinePath) = store.persistenceError else {
            #expect(Bool(false), "损坏 ledger 必须转为 typed error")
            return
        }
        #expect(FileManager.default.fileExists(atPath: quarantinePath))
        #expect(store.reserveOccurrence(taskID: UUID(), at: Date()) == nil)
    }
}
