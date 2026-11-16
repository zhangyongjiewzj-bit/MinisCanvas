import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class Scheduler2031Capture {
    private(set) var requests: [SchedulerSubmissionRequest] = []

    func submit(_ request: SchedulerSubmissionRequest) -> SchedulerDeliveryReceipt.Status {
        requests.append(request)
        return .delivered
    }
}

@MainActor
private final class Scheduler2031PausedEffect {
    private(set) var contexts: [SchedulerExecutionContext] = []
    private var continuation: CheckedContinuation<SchedulerEffectOutcome, Error>?

    func submit(_ context: SchedulerExecutionContext) async throws -> SchedulerEffectOutcome {
        contexts.append(context)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while contexts.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        continuation?.resume(returning: SchedulerEffectOutcome(status: .delivered))
        continuation = nil
    }
}

@Suite("D-SCHEDD scheduler recovery consumer")
@MainActor
struct SchedulerRecoveryConsumer2031Tests {
    private func fixture(_ label: String) throws -> (SchedulerTaskStore, UserDefaults, URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("schedD-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "schedD-\(UUID().uuidString)"))
        let ledger = root.appendingPathComponent("occurrences.json")
        return (SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger), defaults, ledger)
    }

    private func addAuthorizedTask(to store: SchedulerTaskStore, name: String) throws -> SchedulerTask {
        #expect(store.add(name: name, cronExpression: "* * * * *", command: name,
            targetSessionID: UUID(), targetProjectID: "schedD-owned-project", targetTurnID: 1) == nil)
        let task = try #require(store.allTasks().first { $0.name == name })
        #expect(store.authorize(task.id, actorID: "schedD-user", scopeID: "schedD-owned-project",
            policyRevision: "schedD-policy"))
        return try #require(store.task(id: task.id))
    }

    @Test("fresh runtime marks a persisted running lease UNKNOWN and dispatches only queued work")
    func crashLeaseNeverResubmitsWhileQueuedWorkResumes() throws {
        let (first, defaults, ledger) = try fixture("crash")
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let runningTask = try addAuthorizedTask(to: first, name: "old running")
        let queuedTask = try addAuthorizedTask(to: first, name: "allowed queued")
        #expect(first.reconcileExpiredOccurrences(now: now) == 0)
        let running = try #require(first.reserveOccurrence(taskID: runningTask.id, at: now))
        let queued = try #require(first.reserveOccurrence(taskID: queuedTask.id, at: now))
        #expect(first.compareAndSwapOccurrence(id: running.id, expected: .triggered,
            next: .authorized, expectedControlRevision: runningTask.version, now: now))
        #expect(first.compareAndSwapOccurrence(id: running.id, expected: .authorized,
            next: .admitted, expectedControlRevision: runningTask.version, now: now))
        #expect(first.compareAndSwapOccurrence(id: running.id, expected: .admitted,
            next: .dispatched, expectedControlRevision: runningTask.version, now: now))
        let oldToken = try #require(first.claimLease(id: running.id, owner: "prior-process",
            expectedControlRevision: runningTask.version, now: now, ttl: 300))
        #expect(first.heartbeat(id: running.id, owner: "prior-process", token: oldToken,
            now: now, ttl: 300))
        #expect(first.occurrence(id: running.id)?.state == .running)
        #expect(first.occurrence(id: queued.id)?.state == .triggered)

        // A fresh Store/Runtime consumes persisted rows as a restart would.
        // The old process is represented only by its durable lease; no real
        // process or external automation is touched.
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let capture = Scheduler2031Capture()
        let runtime = SchedulerTaskRuntime(store: reopened,
            submitOccurrenceResult: { capture.submit($0) })
        runtime.pollNow(at: now.addingTimeInterval(1))
        #expect(capture.requests.map(\.occurrenceID) == [queued.id])
        #expect(reopened.occurrence(id: running.id)?.state == .unknown)
        #expect(reopened.occurrence(id: queued.id)?.state == .succeeded)
        #expect(reopened.occurrence(id: running.id)?.leaseToken == nil)
        #expect(reopened.occurrence(id: running.id)?.deliveryReceipt?.status == .unknown)
        #expect(!reopened.recordDelivery(id: running.id, owner: "prior-process", token: oldToken,
            status: .delivered, now: now.addingTimeInterval(1),
            expectedTaskVersion: runningTask.version,
            expectedControlRevision: runningTask.version))
        #expect(runtime.retryReconciledOccurrence(id: running.id,
            expectedControlRevision: runningTask.version, proofToken: "not-persisted",
            now: now.addingTimeInterval(2)) == nil)
        let journal = reopened.occurrenceJournal
        runtime.pollNow(at: now.addingTimeInterval(2))
        #expect(capture.requests.map(\.occurrenceID) == [queued.id])
        #expect(reopened.occurrenceJournal == journal)
        let secondReopen = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(secondReopen.occurrence(id: running.id)?.state == .unknown)
        #expect(secondReopen.occurrence(id: queued.id)?.state == .succeeded)

        // Only an explicit persisted review proof may create a new attempt.
        #expect(runtime.reconcileUnknownOccurrence(id: running.id,
            now: now.addingTimeInterval(3)))
        let reviewed = try #require(reopened.occurrence(id: running.id))
        let proof = try #require(reviewed.reconciliationProof)
        let retry = try #require(runtime.retryReconciledOccurrence(id: running.id,
            expectedControlRevision: runningTask.version, proofToken: proof,
            now: now.addingTimeInterval(4)))
        #expect(retry.retryOfOccurrenceID == running.id)
        #expect(retry.id != running.id)
        runtime.pollNow(at: now.addingTimeInterval(5))
        #expect(capture.requests.map(\.occurrenceID) == [queued.id, retry.id])
        #expect(reopened.occurrence(id: running.id)?.state == .retryRequested)
        #expect(reopened.occurrence(id: retry.id)?.state == .succeeded)
    }

    @Test("a healthy in-flight effect is observed without a second dispatch")
    func healthyRunningIsNotRedispatchedByAnotherRuntime() async throws {
        let (store, _, _) = try fixture("healthy")
        _ = try addAuthorizedTask(to: store, name: "healthy running")
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let paused = Scheduler2031PausedEffect()
        defer { paused.release() }
        let first = SchedulerTaskRuntime(store: store, now: { now },
            submitEffect: { try await paused.submit($0) })
        first.pollNow(at: now)
        try await paused.waitUntilStarted()
        let execution = try #require(paused.contexts.first)
        #expect(store.occurrence(id: execution.request.occurrenceID)?.state == .running)
        let observer = Scheduler2031Capture()
        SchedulerTaskRuntime(store: store,
            submitOccurrenceResult: { observer.submit($0) })
            .pollNow(at: now.addingTimeInterval(299))
        // The cron fires every minute. At +299s a new occurrence is due;
        // this observer must not redispatch the still-running old effect.
        let laterRequest = try #require(observer.requests.first)
        #expect(observer.requests.count == 1)
        #expect(laterRequest.occurrenceID != execution.request.occurrenceID)
        #expect(laterRequest.effectID != execution.request.effectID)
        #expect(laterRequest.idempotencyKey != execution.request.idempotencyKey)
        #expect(store.occurrence(id: laterRequest.occurrenceID)?.state == .succeeded)
        #expect(paused.contexts.count == 1)
        #expect(store.occurrence(id: execution.request.occurrenceID)?.state == .running)
        paused.release()
        for _ in 0..<100 {
            if store.occurrence(id: execution.request.occurrenceID)?.state == .succeeded { break }
            await Task.yield()
        }
        #expect(store.occurrence(id: execution.request.occurrenceID)?.state == .succeeded)
    }
}
