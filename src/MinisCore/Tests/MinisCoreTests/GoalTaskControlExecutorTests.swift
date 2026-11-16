import Foundation
import Testing
@testable import MinisCore

private final class CancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func load() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("P3 UX-05 Goal Task Control Executor", .serialized)
struct GoalTaskControlExecutorTests {
    @Test func pauseAndResumeMigrateControlStateWithoutChangingQueuedLifecycle() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "ux05-pause",
            parentID: "root",
            providerID: "provider",
            modelID: "model"
        )
        let executor = try makeExecutor(store: store, snapshots: [task])

        let queued = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        let paused = try executor.execute(
            request(for: queued, command: .pause, key: "ux05-pause-key"),
            now: now
        )
        #expect(paused.afterFact.controlState == .paused)
        #expect(paused.afterFact.controlRevision == queued.controlRevision + 1)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .queued)

        let resumed = try executor.execute(
            request(for: paused.afterFact, command: .resume, key: "ux05-resume-key"),
            now: now
        )
        #expect(resumed.afterFact.controlState == .active)
        #expect(resumed.afterFact.controlRevision == paused.afterFact.controlRevision + 1)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .queued)
    }

    @Test func stopSettlesRunningTaskAndLateSuccessCannotOverwriteTerminalState() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "ux05-stop", parentID: "root", providerID: "p", modelID: "m")
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "ux05-stop-run")
        let executor = try makeExecutor(store: store, snapshots: [task])
        let running = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))

        let stopped = try executor.execute(
            request(for: running, command: .stop, key: "ux05-stop-key", runID: run.runID),
            now: now
        )
        #expect(stopped.beforeAttemptID == "ux05-stop-run:attempt:1")
        #expect(stopped.resultingAttemptID == nil)
        #expect(stopped.afterFact.status == .cancelled)
        #expect(stopped.afterFact.controlState == .stopped)
        #expect(store.events(runID: run.runID).map(\.kind) == [.cancelled])

        let late = try store.finish(runID: run.runID, outcome: .succeeded)
        #expect(late.outcome == .cancelled)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .cancelled)
        #expect(store.events(runID: run.runID).map(\.kind) == [.cancelled])
    }

    @Test func stopInvokesRegisteredCancellationHandleAfterDurableSettlement() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "ux05-stop-handle", parentID: "root", providerID: "p", modelID: "m")
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "ux05-stop-handle-run")
        let cancellationCount = CancellationCount()
        let handle = try store.registerCancellationHandle(runID: run.runID) {
            cancellationCount.increment()
        }
        let executor = try makeExecutor(store: store, snapshots: [task])
        let running = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))

        _ = try executor.execute(
            request(for: running, command: .stop, key: "ux05-stop-handle-key", runID: run.runID),
            now: now
        )

        #expect(handle.isCancelled)
        #expect(cancellationCount.load() == 1)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .cancelled)
    }

    @Test func stopReceiptIsIdempotentAcrossReloadWithoutDuplicateTerminalEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UX05-stop-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = try AgentTaskStore(persistenceURL: persistenceURL)
        let task = try firstStore.enqueue(taskID: "ux05-stop-reload", parentID: "root", providerID: "p", modelID: "m")
        let run = try firstStore.startRun(taskID: task.taskID, parentID: task.parentID, runID: "ux05-stop-reload-run")
        let firstExecutor = try makeExecutor(store: firstStore, snapshots: [task])
        let running = try #require(firstExecutor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        let request = request(for: running, command: .stop, key: "ux05-stop-reload-key", runID: run.runID)

        let firstReceipt = try firstExecutor.execute(request, now: now)
        let reloadedStore = try AgentTaskStore(persistenceURL: persistenceURL)
        let reloadedExecutor = try makeExecutor(store: reloadedStore, snapshots: [task])
        let secondReceipt = try reloadedExecutor.execute(request, now: now)

        #expect(secondReceipt == firstReceipt)
        #expect(reloadedStore.events(runID: run.runID).map(\.kind) == [.cancelled])
        #expect(reloadedStore.allReceipts().map(\.runID) == [run.runID])
    }

    @Test func runningPauseAndResumeRequireTheOwnedRunAndPreserveLifecycleStatus() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "ux05-running-pause", parentID: "root", providerID: "p", modelID: "m")
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "ux05-running-pause-run")
        let executor = try makeExecutor(store: store, snapshots: [task])
        let running = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))

        #expect(throws: GoalTaskControlExecutorError.unknownRun) {
            _ = try executor.execute(
                request(for: running, command: .pause, key: "ux05-running-pause-missing"),
                now: now
            )
        }
        let paused = try executor.execute(
            request(for: running, command: .pause, key: "ux05-running-pause-key", runID: run.runID),
            now: now
        )
        #expect(paused.afterFact.controlState == .paused)
        #expect(paused.afterFact.status == .running)

        let resumed = try executor.execute(
            request(for: paused.afterFact, command: .resume, key: "ux05-running-resume-key", runID: run.runID),
            now: now
        )
        #expect(resumed.afterFact.controlState == .active)
        #expect(resumed.afterFact.status == .running)
    }

    @Test func retryCreatesFreshRunAndPersistsIdempotentReceiptAcrossReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UX05-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = try AgentTaskStore(persistenceURL: persistenceURL)
        let task = try firstStore.enqueue(taskID: "ux05-retry", parentID: "root", providerID: "p", modelID: "m")
        let firstRun = try firstStore.startRun(taskID: task.taskID, parentID: task.parentID, runID: "ux05-retry-run-1")
        _ = try firstStore.finish(runID: firstRun.runID, outcome: .failed(reason: "redacted"))
        let firstExecutor = try makeExecutor(store: firstStore, snapshots: [task])
        let failed = try #require(firstExecutor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        let retryRequest = request(for: failed, command: .retry, key: "ux05-retry-key", runID: firstRun.runID)

        let firstReceipt = try firstExecutor.execute(retryRequest, now: now)
        #expect(firstReceipt.afterFact.status == .running)
        #expect(firstReceipt.afterFact.controlState == .active)
        #expect(firstReceipt.resultingRunID == "ux05-retry:retry:ux05-retry-key")
        #expect(firstStore.historicalAttempt(
            runID: firstRun.runID,
            taskID: task.taskID,
            parentID: task.parentID
        )?.attemptID == "ux05-retry-run-1:attempt:1")
        #expect(firstStore.historicalAttempt(
            runID: "unknown-run",
            taskID: task.taskID,
            parentID: task.parentID
        ) == nil)
        #expect(firstStore.historicalAttempt(
            runID: firstRun.runID,
            taskID: "other-task",
            parentID: task.parentID
        ) == nil)
        #expect(firstStore.historicalAttempt(
            runID: firstRun.runID,
            taskID: task.taskID,
            parentID: "other-parent"
        ) == nil)

        let historical = try #require(firstStore.historicalRunIdentity(
            runID: firstRun.runID, taskID: task.taskID, parentID: task.parentID
        ))
        #expect(historical.taskID == task.taskID)
        #expect(historical.parentID == task.parentID)
        #expect(historical.runID == firstRun.runID)
        #expect(historical.attemptID == firstReceipt.beforeAttemptID)
        #expect(historical.parentContextSnapshotID == task.parentContextSnapshotID)
        #expect(firstStore.taskSnapshot(runID: firstRun.runID) == nil)
        #expect(firstStore.canonicalAttemptID(runID: firstRun.runID) == nil)
        #expect(firstStore.attempt(runID: firstRun.runID, attemptID: historical.attemptID) == nil)
        #expect(firstStore.historicalRunIdentity(
            runID: "missing", taskID: task.taskID, parentID: task.parentID
        ) == nil)
        #expect(firstStore.historicalRunIdentity(
            runID: firstRun.runID, taskID: "other-task", parentID: task.parentID
        ) == nil)
        let sameIDOtherParent = try firstStore.enqueue(
            taskID: task.taskID, parentID: "other-parent", providerID: "p", modelID: "m"
        )
        _ = try firstStore.startRun(
            taskID: sameIDOtherParent.taskID, parentID: sameIDOtherParent.parentID,
            runID: "other-parent-run"
        )
        #expect(firstStore.historicalRunIdentity(
            runID: firstRun.runID, taskID: task.taskID, parentID: sameIDOtherParent.parentID
        ) == nil)
        #expect(firstStore.historicalRunIdentity(
            runID: "other-parent-run", taskID: task.taskID, parentID: task.parentID
        ) == nil)

        let reloadedStore = try AgentTaskStore(persistenceURL: persistenceURL)
        #expect(reloadedStore.historicalRunIdentity(
            runID: firstRun.runID, taskID: task.taskID, parentID: task.parentID
        ) == historical)
        #expect(reloadedStore.taskSnapshot(runID: firstRun.runID) == nil)
        #expect(reloadedStore.receipt(runID: firstRun.runID)?.attemptID == historical.attemptID)
        let reloadedExecutor = try makeExecutor(store: reloadedStore, snapshots: [task])
        let secondReceipt = try reloadedExecutor.execute(retryRequest, now: now)
        #expect(secondReceipt == firstReceipt)
        #expect(firstReceipt.beforeAttemptID == "ux05-retry-run-1:attempt:1")
        #expect(firstReceipt.resultingAttemptID == "ux05-retry:retry:ux05-retry-key:attempt:1")

        _ = try reloadedStore.finish(
            runID: try #require(firstReceipt.resultingRunID),
            outcome: .succeeded
        )
        let thirdReceipt = try reloadedExecutor.execute(retryRequest, now: now)
        #expect(thirdReceipt == firstReceipt)
        #expect(thirdReceipt.resultingAttemptID == firstReceipt.resultingAttemptID)

        let conflictingRequest = request(for: failed, command: .stop, key: "ux05-retry-key", runID: firstRun.runID)
        #expect(throws: GoalTaskControlExecutorError.idempotencyKeyConflict) {
            _ = try reloadedExecutor.execute(conflictingRequest, now: now)
        }
        let wrongOwnerRequest = GoalTaskCenterCommandRequest(
            taskID: retryRequest.taskID,
            parentID: "other-parent",
            revision: retryRequest.revision,
            scopeID: retryRequest.scopeID,
            actorID: retryRequest.actorID,
            idempotencyKey: retryRequest.idempotencyKey,
            command: .retry,
            runID: retryRequest.runID
        )
        #expect(throws: GoalTaskControlExecutorError.idempotencyKeyConflict) {
            _ = try reloadedExecutor.execute(wrongOwnerRequest, now: now)
        }
        let differentKeyRequest = request(
            for: failed,
            command: .retry,
            key: "ux05-retry-other-key",
            runID: firstRun.runID
        )
        #expect(throws: GoalTaskCenterFacadeError.revisionMismatch) {
            _ = try reloadedExecutor.execute(differentKeyRequest, now: now)
        }
    }

    @Test func abortedQueuedTaskBecomesRetryableTerminalControl() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "ux05-abort-queued",
            parentID: "root",
            providerID: "p",
            modelID: "m"
        )
        try store.abortQueued(taskID: task.taskID, parentID: task.parentID)
        let executor = try makeExecutor(store: store, snapshots: [task])
        let failed = try #require(
            executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID)
        )
        #expect(failed.status == .failed)
        #expect(failed.controlState == .terminal)

        let receipt = try executor.execute(
            request(for: failed, command: .retry, key: "ux05-abort-retry"),
            now: now
        )
        #expect(receipt.afterFact.status == .running)
        #expect(receipt.afterFact.controlState == .active)
    }

    @Test func staleRevisionWrongScopeAndInactiveLeaseFailClosedBeforeMutation() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "ux05-identity", parentID: "root", providerID: nil, modelID: nil)
        let executor = try makeExecutor(store: store, snapshots: [task])
        let fact = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))

        #expect(throws: GoalTaskCenterFacadeError.revisionMismatch) {
            _ = try executor.execute(
                request(for: fact, revision: "stale", command: .pause, key: "ux05-stale"),
                now: now
            )
        }
        #expect(throws: GoalTaskCenterFacadeError.scopeMismatch) {
            _ = try executor.execute(
                request(for: fact, scopeID: "wrong-scope", command: .pause, key: "ux05-scope"),
                now: now
            )
        }
        let expiredExecutor = try makeExecutor(
            store: store,
            snapshots: [task],
            leaseExpiresAt: Date(timeIntervalSince1970: 1_840_000_000)
        )
        let expiredFact = try #require(expiredExecutor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        #expect(throws: GoalTaskCenterFacadeError.leaseNotActive(.expired)) {
            _ = try expiredExecutor.execute(
                request(for: expiredFact, command: .pause, key: "ux05-expired"),
                now: now
            )
        }
        #expect(store.controlSnapshot(taskID: task.taskID, parentID: task.parentID)?.controlRevision == 0)
    }

    @Test func stoppingParentPropagatesToChildrenAsOneDurableControlOperation() throws {
        let store = AgentTaskStore()
        let parent = try store.enqueue(taskID: "ux05-parent", parentID: "root", providerID: nil, modelID: nil)
        let child = try store.enqueue(taskID: "ux05-child", parentID: parent.taskID, providerID: nil, modelID: nil)
        let executor = try makeExecutor(store: store, snapshots: [parent, child])
        let parentFact = try #require(executor.project(now: now).fact(taskID: parent.taskID, parentID: parent.parentID))

        let receipt = try executor.execute(
            request(for: parentFact, command: .stop, key: "ux05-parent-stop"),
            now: now
        )

        #expect(receipt.cancelledTaskIDs == [parent.taskID, child.taskID])
        #expect(store.snapshot(taskID: parent.taskID, parentID: parent.parentID)?.status == .cancelled)
        #expect(store.snapshot(taskID: child.taskID, parentID: child.parentID)?.status == .cancelled)
        #expect(store.controlSnapshot(taskID: child.taskID, parentID: child.parentID)?.state == .stopped)
    }

    @Test func recoveredOrUnknownExternalSubmissionCannotBeControlledAutomatically() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(taskID: "ux05-review", parentID: "root", providerID: nil, modelID: nil)
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "ux05-review-run")
        try store.markExternalSubmissionUnknown(runID: run.runID)
        let executor = try makeExecutor(store: store, snapshots: [task])
        let fact = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))

        #expect(throws: GoalTaskControlExecutorError.needsUserReview(.externalSubmissionUnknown)) {
            _ = try executor.execute(
                request(for: fact, command: .stop, key: "ux05-review-stop", runID: run.runID),
                now: now
            )
        }
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .running)
        #expect(store.controlSnapshot(taskID: task.taskID, parentID: task.parentID)?.state == .active)
    }

    @Test func malformedHistoricalAttemptEvidenceFailsClosed() throws {
        for mutation in ["missing-attempt", "wrong-context", "wrong-run"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("historical-run-invalid-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("ledger.json")
            let store = try AgentTaskStore(persistenceURL: url)
            _ = try store.enqueue(
                taskID: "identity-task", parentID: "identity-parent",
                providerID: nil, modelID: nil, parentContextSnapshotID: "identity-context"
            )
            _ = try store.startRun(
                taskID: "identity-task", parentID: "identity-parent", runID: "identity-run"
            )
            _ = try store.finish(runID: "identity-run", outcome: .failed(reason: "redacted"))
            var envelope = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            var state = try #require(envelope["state"] as? [String: Any])
            var attempts = try #require(state["attempts"] as? [String: Any])
            let attemptID = "identity-run:attempt:1"
            var attempt = try #require(attempts[attemptID] as? [String: Any])
            switch mutation {
            case "missing-attempt": attempts.removeValue(forKey: attemptID)
            case "wrong-context":
                attempt["parentContextSnapshotID"] = "foreign-context"
                attempts[attemptID] = attempt
            default:
                attempt["runID"] = "foreign-run"
                attempts[attemptID] = attempt
            }
            state["attempts"] = attempts
            envelope["state"] = state
            try JSONSerialization.data(withJSONObject: envelope).write(to: url)
            if mutation == "wrong-context" {
                // Legacy plain receipts may load despite absent context
                // validation; historical observation still fails closed.
                let reloaded = try AgentTaskStore(persistenceURL: url)
                #expect(reloaded.historicalRunIdentity(
                    runID: "identity-run", taskID: "identity-task", parentID: "identity-parent"
                ) == nil)
            } else {
                #expect(throws: AgentTaskStoreError.persistenceFailed) {
                    _ = try AgentTaskStore(persistenceURL: url)
                }
            }
        }
    }

    private let now = Date(timeIntervalSince1970: 1_850_000_000)

    private func makeExecutor(
        store: AgentTaskStore,
        snapshots: [AgentTaskSnapshot],
        leaseExpiresAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) throws -> GoalTaskControlExecutor {
        try GoalTaskControlExecutor(
            store: store,
            bindings: snapshots.map { snapshot in
                let goal = GoalEnvelope(
                    goalID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    scopeID: "scope:\(snapshot.taskID)",
                    allowedCapabilities: ["task.read"],
                    budget: 10,
                    deadline: Date(timeIntervalSince1970: 1_900_000_000),
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
                return GoalTaskCenterBinding(
                    taskID: snapshot.taskID,
                    parentID: snapshot.parentID,
                    goal: goal,
                    lease: AutonomyLease(
                        leaseID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                        goalID: goal.goalID,
                        scopeID: goal.scopeID,
                        issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        expiresAt: leaseExpiresAt
                    )
                )
            }
        )
    }

    private func request(
        for fact: GoalTaskCenterTaskFact,
        revision: String? = nil,
        scopeID: String? = nil,
        command: GoalTaskCenterCommand,
        key: String,
        runID: String? = nil
    ) -> GoalTaskCenterCommandRequest {
        GoalTaskCenterCommandRequest(
            taskID: fact.taskID,
            parentID: fact.parentID,
            revision: revision ?? fact.revision,
            scopeID: scopeID ?? fact.scopeID ?? "",
            actorID: "ux05-test",
            idempotencyKey: key,
            command: command,
            runID: runID
        )
    }
}
