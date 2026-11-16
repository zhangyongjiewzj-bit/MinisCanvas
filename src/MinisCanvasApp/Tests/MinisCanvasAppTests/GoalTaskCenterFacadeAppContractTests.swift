import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Goal Task Center App contract")
@MainActor
struct GoalTaskCenterFacadeAppContractTests {
    @Test func productionGoalLeaseBindingSurvivesBridgeRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-goal-lease-\(UUID().uuidString)", isDirectory: true)
        let ledgerURL = directory.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstProjection: GoalTaskCenterProjection
        do {
            let bridge = try BridgeStore(taskStorePersistenceURL: ledgerURL)
            _ = try bridge.agentTaskStore.enqueue(
                taskID: "durable-goal-task",
                parentID: "durable-goal-parent",
                providerID: "offline",
                modelID: "test"
            )
            bridge.attachProductionServices(
                fileAccessAllowedRoot: directory,
                sessionDirectory: directory,
                policyDefaults: ProductionPolicyDefaults(
                    deadlineHorizon: 10 * 365 * 24 * 60 * 60
                )
            )
            firstProjection = bridge.taskCenterGoalProjection(now: observationNow)
        }

        let restarted = try BridgeStore(taskStorePersistenceURL: ledgerURL)
        restarted.attachProductionServices(
            fileAccessAllowedRoot: directory,
            sessionDirectory: directory,
            policyDefaults: ProductionPolicyDefaults(
                deadlineHorizon: 10 * 365 * 24 * 60 * 60
            )
        )
        let secondProjection = restarted.taskCenterGoalProjection(now: observationNow)

        let firstGoal = try #require(firstProjection.goals.first)
        let secondGoal = try #require(secondProjection.goals.first)
        #expect(secondGoal.goalID == firstGoal.goalID)
        #expect(secondGoal.leaseID == firstGoal.leaseID)
        #expect(secondGoal.leaseExpiresAt == firstGoal.leaseExpiresAt)
        #expect(
            secondProjection.fact(
                taskID: "durable-goal-task",
                parentID: "durable-goal-parent"
            )?.leaseState == firstProjection.fact(
                taskID: "durable-goal-task",
                parentID: "durable-goal-parent"
            )?.leaseState
        )
    }

    @Test func taskCenterLeaseStatesHaveDistinctAccessibilityLabels() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for label in ["授权有效", "授权过期", "授权撤销", "授权无效"] {
            #expect(source.contains(label))
        }
        #expect(source.contains("accessibilityLabel(leaseAccessibilityLabel"))
        #expect(source.contains("task-center-lease-state"))
    }

    @Test func taskCenterViewProjectsTheBridgeCanonicalStoreWithoutMutation() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        _ = try store.enqueue(
            taskID: "app-goal-task",
            parentID: "app-goal-parent",
            providerID: "offline",
            modelID: "test",
            routeReceiptID: "route-receipt"
        )
        let before = store.taskCenterSnapshots()

        let facade = GoalTaskCenterFacade(store: bridge.agentTaskStore)
        let projection = facade.project(now: Date(timeIntervalSince1970: 1_850_000_000))
        let fact = try #require(
            projection.fact(taskID: "app-goal-task", parentID: "app-goal-parent")
        )

        #expect(bridge.agentTaskStore === store)
        #expect(fact.providerID == "offline")
        #expect(fact.modelID == "test")
        #expect(fact.routeReceiptID == "route-receipt")
        #expect(facade.controlMode == .readOnlyProjection)

        // Constructing the real App view is the wiring check; its body is read-only.
        let view = TaskCenterObservationView(bridge: bridge)
        _ = view.body
        #expect(store.taskCenterSnapshots() == before)
    }

    @Test func bridgeControlConsumerExecutesAValidatedPauseInsteadOfReturningReadOnlyAdmission() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "app-control-task",
            parentID: "app-control-parent",
            providerID: "offline",
            modelID: "test"
        )
        let bridge = BridgeStore(agentTaskStore: store)
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-production-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        bridge.attachProductionServices(
            fileAccessAllowedRoot: sessionDirectory,
            sessionDirectory: sessionDirectory,
            policyDefaults: ProductionPolicyDefaults(
                deadlineHorizon: 10 * 365 * 24 * 60 * 60
            )
        )
        let projection = bridge.taskCenterGoalProjection(now: observationNow)
        let fact = try #require(
            projection.fact(taskID: task.taskID, parentID: task.parentID)
        )
        let request = TaskCenterControlRequest(
            taskID: fact.taskID,
            parentID: fact.parentID,
            revision: fact.revision,
            scopeID: "production:agent",
            actorID: "task-center-ui",
            idempotencyKey: "app-control-pause",
            action: .pause
        )

        let receipt = try bridge.executeTaskCenterControl(request, now: observationNow)

        #expect(receipt.request == request)
        #expect(receipt.afterFact.controlState == .paused)
        #expect(receipt.afterFact.status == .queued)
        #expect(store.controlReceipt(idempotencyKey: receipt.durableIdempotencyKey) != nil)
    }

    @Test func controlConsumerExecutesPauseResumeStopRetryAndCancelWithReceipts() throws {
        let pauseStore = AgentTaskStore()
        let pauseTask = try pauseStore.enqueue(
            taskID: "app-five-pause",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let pauseConsumer = makeConsumer(store: pauseStore)
        let queued = try #require(
            pauseConsumer.project(now: observationNow).fact(
                taskID: pauseTask.taskID,
                parentID: pauseTask.parentID
            )
        )
        let paused = try pauseConsumer.execute(
            request(for: queued, action: .pause, key: "app-five-pause"),
            now: observationNow
        )
        #expect(paused.afterFact.controlState == .paused)
        #expect(paused.afterFact.status == .queued)

        let resumed = try pauseConsumer.execute(
            request(for: paused.afterFact, action: .resume, key: "app-five-resume"),
            now: observationNow
        )
        #expect(resumed.afterFact.controlState == .active)
        #expect(resumed.afterFact.status == .queued)

        let stopStore = AgentTaskStore()
        let stopTask = try stopStore.enqueue(
            taskID: "app-five-stop",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let stopRun = try stopStore.startRun(
            taskID: stopTask.taskID,
            parentID: stopTask.parentID,
            runID: "app-five-stop-run"
        )
        let stopConsumer = makeConsumer(store: stopStore)
        let running = try #require(
            stopConsumer.project(now: observationNow).fact(
                taskID: stopTask.taskID,
                parentID: stopTask.parentID
            )
        )
        let stopped = try stopConsumer.execute(
            request(for: running, action: .stop, key: "app-five-stop", runID: stopRun.runID),
            now: observationNow
        )
        #expect(stopped.afterFact.status == .cancelled)
        #expect(stopped.afterFact.controlState == .stopped)
        #expect(stopStore.events(runID: stopRun.runID).map(\.kind) == [.cancelled])

        let retryStore = AgentTaskStore()
        let retryTask = try retryStore.enqueue(
            taskID: "app-five-retry",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let retryRun = try retryStore.startRun(
            taskID: retryTask.taskID,
            parentID: retryTask.parentID,
            runID: "app-five-retry-run"
        )
        _ = try retryStore.finish(
            runID: retryRun.runID,
            outcome: .failed(reason: "redacted")
        )
        let retryConsumer = makeConsumer(store: retryStore)
        let failed = try #require(
            retryConsumer.project(now: observationNow).fact(
                taskID: retryTask.taskID,
                parentID: retryTask.parentID
            )
        )
        let retried = try retryConsumer.execute(
            request(for: failed, action: .retry, key: "app-five-retry", runID: retryRun.runID),
            now: observationNow
        )
        #expect(retried.afterFact.status == .running)
        #expect(
            retried.resultingRunID
                == "\(retried.afterFact.taskID):retry:\(retried.durableIdempotencyKey)"
        )

        let cancelStore = AgentTaskStore()
        let cancelTask = try cancelStore.enqueue(
            taskID: "app-five-cancel",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let cancelConsumer = makeConsumer(store: cancelStore)
        let cancelFact = try #require(
            cancelConsumer.project(now: observationNow).fact(
                taskID: cancelTask.taskID,
                parentID: cancelTask.parentID
            )
        )
        let cancelled = try cancelConsumer.execute(
            request(for: cancelFact, action: .cancel, key: "app-five-cancel"),
            now: observationNow
        )
        #expect(cancelled.afterFact.status == .cancelled)
        #expect(cancelled.afterFact.controlState == .stopped)
        #expect(
            cancelStore.controlReceipt(idempotencyKey: cancelled.durableIdempotencyKey)?.command == .stop
        )
        #expect(
            [paused, resumed, stopped, retried, cancelled].allSatisfy {
                $0.durableIdempotencyKey.isEmpty == false
            }
        )
    }

    @Test func controlConsumerFailsClosedForIdentityLeaseReceiptAndUnknownSubmission() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "app-negative",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let consumer = makeConsumer(store: store)
        let fact = try #require(
            consumer.project(now: observationNow).fact(
                taskID: task.taskID,
                parentID: task.parentID
            )
        )

        #expect(throws: TaskCenterControlConsumerError.unavailable) {
            _ = try consumer.execute(
                TaskCenterControlRequest(
                    taskID: fact.taskID,
                    parentID: "wrong-parent",
                    revision: fact.revision,
                    scopeID: fact.scopeID ?? "",
                    actorID: "task-center-ui",
                    idempotencyKey: "app-negative-identity",
                    action: .pause
                ),
                now: observationNow
            )
        }
        #expect(store.controlSnapshot(taskID: task.taskID, parentID: task.parentID)?.controlRevision == 0)
        #expect(
            throws: TaskCenterControlConsumerError.facade(
                .invalidRequest(.blankActorID)
            )
        ) {
            _ = try consumer.execute(
                request(
                    for: fact,
                    actorID: "",
                    action: .pause,
                    key: "app-negative-actor"
                ),
                now: observationNow
            )
        }

        #expect(throws: TaskCenterControlConsumerError.facade(.revisionMismatch)) {
            _ = try consumer.execute(
                request(
                    for: fact,
                    revision: "stale-revision",
                    action: .pause,
                    key: "app-negative-revision"
                ),
                now: observationNow
            )
        }
        #expect(throws: TaskCenterControlConsumerError.facade(.scopeMismatch)) {
            _ = try consumer.execute(
                request(
                    for: fact,
                    scopeID: "wrong-scope",
                    action: .pause,
                    key: "app-negative-scope"
                ),
                now: observationNow
            )
        }

        let first = try consumer.execute(
            request(for: fact, action: .pause, key: "app-negative-receipt"),
            now: observationNow
        )
        #expect(
            try consumer.execute(
                request(for: fact, action: .pause, key: "app-negative-receipt"),
                now: observationNow
            ) == first
        )
        #expect(store.controlSnapshot(taskID: task.taskID, parentID: task.parentID)?.controlRevision == 1)
        #expect(throws: TaskCenterControlConsumerError.executor(.idempotencyKeyConflict)) {
            _ = try consumer.execute(
                request(for: fact, action: .stop, key: "app-negative-receipt"),
                now: observationNow
            )
        }

        let expiredStore = AgentTaskStore()
        let expiredTask = try expiredStore.enqueue(
            taskID: "app-negative-expired",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let expiredConsumer = makeConsumer(
            store: expiredStore,
            leaseExpiresAt: Date(timeIntervalSince1970: 1_840_000_000)
        )
        let expiredFact = try #require(
            expiredConsumer.project(now: observationNow).fact(
                taskID: expiredTask.taskID,
                parentID: expiredTask.parentID
            )
        )
        #expect(throws: TaskCenterControlConsumerError.facade(.leaseNotActive(.expired))) {
            _ = try expiredConsumer.execute(
                request(for: expiredFact, action: .pause, key: "app-negative-expired"),
                now: observationNow
            )
        }
        #expect(
            expiredStore.controlSnapshot(
                taskID: expiredTask.taskID,
                parentID: expiredTask.parentID
            )?.controlRevision == 0
        )

        let unknownStore = AgentTaskStore()
        let unknownTask = try unknownStore.enqueue(
            taskID: "app-negative-unknown",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let unknownRun = try unknownStore.startRun(
            taskID: unknownTask.taskID,
            parentID: unknownTask.parentID,
            runID: "app-negative-unknown-run"
        )
        try unknownStore.markExternalSubmissionUnknown(runID: unknownRun.runID)
        let unknownConsumer = makeConsumer(store: unknownStore)
        let unknownFact = try #require(
            unknownConsumer.project(now: observationNow).fact(
                taskID: unknownTask.taskID,
                parentID: unknownTask.parentID
            )
        )
        #expect(
            throws: TaskCenterControlConsumerError.executor(
                .needsUserReview(.externalSubmissionUnknown)
            )
        ) {
            _ = try unknownConsumer.execute(
                request(
                    for: unknownFact,
                    action: .stop,
                    key: "app-negative-unknown",
                    runID: unknownRun.runID
                ),
                now: observationNow
            )
        }
        #expect(
            unknownStore.snapshot(
                taskID: unknownTask.taskID,
                parentID: unknownTask.parentID
            )?.status == .running
        )
    }

    @Test func unconfiguredControlConsumerFailsClosedWhileObservationRemainsReadOnly() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "app-unconfigured",
            parentID: "root",
            providerID: "offline",
            modelID: "test"
        )
        let bridge = BridgeStore(agentTaskStore: store)
        let fact = try #require(
            bridge.taskCenterGoalProjection(now: observationNow).fact(
                taskID: task.taskID,
                parentID: task.parentID
            )
        )
        let before = store.taskCenterSnapshots()

        #expect(!bridge.taskCenterControlConsumer.isAvailable)
        #expect(throws: TaskCenterControlConsumerError.unavailable) {
            _ = try bridge.executeTaskCenterControl(
                request(for: fact, action: .pause, key: "app-unconfigured"),
                now: observationNow
            )
        }
        #expect(bridge.taskCenterObservation.taskSnapshots == before)
        #expect(fact.leaseState == .invalid)
    }

    private func makeConsumer(
        store: AgentTaskStore,
        leaseExpiresAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) -> TaskCenterControlConsumer {
        let goalID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let leaseID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let deadline = Date(timeIntervalSince1970: 1_900_000_000)
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return TaskCenterControlConsumer(
            store: store,
            bindingProvider: { snapshot in
                let goal = GoalEnvelope(
                    goalID: goalID,
                    scopeID: "scope:app-task-center",
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
                    expiresAt: leaseExpiresAt
                )
                return GoalTaskCenterBinding(
                    taskID: snapshot.taskID,
                    parentID: snapshot.parentID,
                    goal: goal,
                    lease: lease
                )
            }
        )
    }

    private func request(
        for fact: GoalTaskCenterTaskFact,
        revision: String? = nil,
        scopeID: String? = nil,
        actorID: String = "task-center-ui",
        action: TaskCenterControlAction,
        key: String,
        runID: String? = nil
    ) -> TaskCenterControlRequest {
        TaskCenterControlRequest(
            taskID: fact.taskID,
            parentID: fact.parentID,
            revision: revision ?? fact.revision,
            scopeID: scopeID ?? fact.scopeID ?? "",
            actorID: actorID,
            idempotencyKey: key,
            action: action,
            runID: runID
        )
    }

    private var observationNow: Date {
        Date(timeIntervalSince1970: 1_850_000_000)
    }
}
