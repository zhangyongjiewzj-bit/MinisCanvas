import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center observation receipt snapshot")
struct TaskCenterObservationSnapshotTests {
    @Test func productionConsumerProjectsTaskRunAttemptAndEffectStates() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "receipt-task",
            parentID: "session-a",
            providerID: "offline",
            modelID: "gpt-5.6-luna"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "receipt-run"
        )

        let consumer = TaskCenterControlConsumer(store: store)
        let running = try #require(
            consumer.receiptRows(now: observationNow).first
        )
        #expect(running.taskState == .running)
        #expect(running.runState == .running)
        #expect(running.attemptState == .running)
        #expect(running.effectState == .running)
        #expect(running.runID == run.runID)
        #expect(running.attemptID == "\(run.runID):attempt:1")

        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "api_key=should-not-escape"))
        let failed = try #require(
            consumer.receiptRows(now: observationNow).first
        )
        #expect(failed.taskState == .failed)
        #expect(failed.runState == .failed)
        #expect(failed.attemptState == .failed)
        #expect(failed.effectState == .failed)
        #expect(failed.failureReason == "execution-failed")
        #expect(failed.failureReason?.contains("api_key") == false)
        #expect(failed.receiptID == run.runID)
    }

    @Test func retryAndCancelRemainVisibleAsStableReceiptStates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try store.enqueue(
            taskID: "retry-task",
            parentID: "session-a",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "retry-run"
        )
        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "private failure"))

        _ = try store.enqueue(
            taskID: task.taskID, parentID: "session-z", providerID: "offline", modelID: "test"
        )
        _ = try store.startRun(
            taskID: task.taskID, parentID: "session-z", runID: "foreign-parent-run"
        )
        let consumer = makeConsumer(store: store)
        let failed = try #require(consumer.receiptRows(now: observationNow).first)
        #expect(failed.retryAvailable)
        let failedFact = try #require(
            consumer.project(now: observationNow).fact(
                taskID: task.taskID,
                parentID: task.parentID
            )
        )

        let retryRequest = TaskCenterControlRequest(
            taskID: task.taskID,
            parentID: task.parentID,
            revision: failedFact.revision,
            scopeID: failedFact.scopeID!,
            actorID: "task-center-test",
            idempotencyKey: "retry-receipt",
            action: .retry,
            runID: run.runID
        )
        _ = try consumer.execute(retryRequest, now: observationNow)
        let retrying = try #require(consumer.receiptRows(now: observationNow).first)
        #expect(retrying.taskState == .retrying)
        #expect(retrying.runState == .retrying)
        #expect(retrying.attemptState == .retrying)
        #expect(retrying.effectState == .retrying)
        #expect(retrying.cancelAvailable)
        #expect(retrying.runID != run.runID)
        #expect(retrying.runID == store.controlSnapshot(
            taskID: task.taskID, parentID: task.parentID
        )?.runID)
        #expect(retrying.receiptID == retrying.runID)
        #expect(retrying.observationIdentity.runID == retrying.runID)
        #expect(retrying.attemptID == retrying.runID.map { "\($0):attempt:1" })
        #expect(retrying.observationState == .running)
        #expect(retrying.failureReason == nil)
        #expect(retrying.childResultEnvelope == nil)
        #expect(retrying.succeededBacklink == nil)
        #expect(store.taskSnapshot(runID: run.runID) == nil)
        #expect(consumer.orphanReceiptRunIDs().isEmpty)
        let foreign = try #require(consumer.receiptRows(now: observationNow).first {
            $0.parentID == "session-z"
        })
        #expect(foreign.taskState == .running)
        #expect(foreign.runID == "foreign-parent-run")
        let reloaded = try AgentTaskStore(persistenceURL: ledgerURL)
        let restartedConsumer = makeConsumer(store: reloaded)
        let restored = try #require(restartedConsumer.receiptRows(now: observationNow).first {
            $0.parentID == task.parentID
        })
        #expect(restored.taskState == .retrying)
        #expect(restored.runState == .retrying)
        #expect(restored.attemptState == .retrying)
        #expect(restored.effectState == .retrying)
        #expect(restored.runID == retrying.runID)
        #expect(restored.attemptID == retrying.attemptID)
        #expect(restored.recoveryState == .needsUserReview)
        #expect(!restored.cancelAvailable)
        #expect(restartedConsumer.orphanReceiptRunIDs().isEmpty)
        #expect(reloaded.receipt(runID: run.runID)?.outcome == .failed(reason: "execution-failed"))

        let retryFact = try #require(
            consumer.project(now: observationNow).fact(
                taskID: task.taskID,
                parentID: task.parentID
            )
        )
        let cancelRequest = TaskCenterControlRequest(
            taskID: task.taskID,
            parentID: task.parentID,
            revision: retryFact.revision,
            scopeID: retryFact.scopeID!,
            actorID: "task-center-test",
            idempotencyKey: "cancel-receipt",
            action: .cancel,
            runID: retrying.runID
        )
        _ = try consumer.execute(cancelRequest, now: observationNow)
        let cancelled = try #require(consumer.receiptRows(now: observationNow).first)
        #expect(cancelled.taskState == .cancelled)
        #expect(cancelled.runState == .cancelled)
        #expect(cancelled.attemptState == .cancelled)
        #expect(cancelled.effectState == .cancelled)
        #expect(cancelled.retryAvailable)
    }

    @Test func persistedReceiptIsVisibleAfterConsumerAndStoreRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-receipt-\(UUID().uuidString)", isDirectory: true)
        let ledgerURL = directory.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = try AgentTaskStore(persistenceURL: ledgerURL)
            let task = try store.enqueue(
                taskID: "restart-task",
                parentID: "session-b",
                providerID: "offline",
                modelID: "test"
            )
            let run = try store.startRun(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: "restart-run"
            )
            _ = try store.finish(runID: run.runID, outcome: .succeeded)
        }

        let reloaded = try AgentTaskStore(persistenceURL: ledgerURL)
        let rows = TaskCenterControlConsumer(store: reloaded)
            .receiptRows(now: observationNow)
        let row = try #require(rows.first)
        #expect(row.taskState == .completed)
        #expect(row.runState == .completed)
        #expect(row.effectState == .completed)
        #expect(row.receiptID == "restart-run")
        #expect(row.sessionID == "session-b")
    }

    @Test func persistedProductionBindingRehydratesControlConsumerAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-binding-\(UUID().uuidString)", isDirectory: true)
        let ledgerURL = directory.appendingPathComponent("tasks.json")
        let bindingURL = directory.appendingPathComponent("goal-lease.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try store.enqueue(
            taskID: "restart-control-task",
            parentID: "session-control",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "restart-control-run"
        )
        let goalID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let goal = GoalEnvelope(
            goalID: goalID,
            scopeID: "scope:task-center-restart",
            allowedCapabilities: ["task.control"],
            budget: 10,
            deadline: Date(timeIntervalSince1970: 1_900_000_000),
            createdAt: issuedAt
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: issuedAt,
            expiresAt: goal.deadline
        )

        let firstConsumer = TaskCenterControlConsumer(
            store: store,
            bindingPersistenceURL: bindingURL
        )
        firstConsumer.installProductionGoal(goal: goal, lease: lease)

        let restartedConsumer = TaskCenterControlConsumer(
            store: store,
            bindingPersistenceURL: bindingURL
        )
        #expect(restartedConsumer.isAvailable)
        let running = try #require(
            restartedConsumer.project(now: observationNow).fact(
                taskID: task.taskID,
                parentID: task.parentID
            )
        )
        let stop = try restartedConsumer.execute(
            TaskCenterControlRequest(
                taskID: task.taskID,
                parentID: task.parentID,
                revision: running.revision,
                scopeID: goal.scopeID,
                actorID: "task-center-ui",
                idempotencyKey: "restart-control-stop",
                action: .stop,
                runID: run.runID
            ),
            now: observationNow
        )

        #expect(stop.afterFact.status == .cancelled)
        #expect(store.receipt(runID: run.runID)?.outcome == .cancelled)
    }

    @Test func receiptRowsDoNotMergeTasksFromDifferentSessions() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "same-task-id",
            parentID: "session-a",
            providerID: "offline",
            modelID: "test"
        )
        _ = try store.enqueue(
            taskID: "same-task-id",
            parentID: "session-b",
            providerID: "offline",
            modelID: "test"
        )

        let rows = TaskCenterControlConsumer(store: store)
            .receiptRows(now: observationNow)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.sessionID)) == ["session-a", "session-b"])
        #expect(Set(rows.map(\.stableID)).count == 2)
    }

    private var observationNow: Date {
        Date(timeIntervalSince1970: 1_850_000_000)
    }

    private func makeConsumer(store: AgentTaskStore) -> TaskCenterControlConsumer {
        let goalID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let leaseID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = Date(timeIntervalSince1970: 1_900_000_000)
        let consumer = TaskCenterControlConsumer(
            store: store,
            bindingProvider: { snapshot in
                let goal = GoalEnvelope(
                    goalID: goalID,
                    scopeID: "scope:task-center",
                    allowedCapabilities: ["task.control"],
                    budget: 10,
                    deadline: deadline,
                    createdAt: issuedAt
                )
                let lease = AutonomyLease(
                    leaseID: leaseID,
                    goalID: goalID,
                    scopeID: goal.scopeID,
                    issuedAt: issuedAt,
                    expiresAt: deadline
                )
                return GoalTaskCenterBinding(
                    taskID: snapshot.taskID,
                    parentID: snapshot.parentID,
                    goal: goal,
                    lease: lease
                )
            }
        )
        return consumer
    }
}
