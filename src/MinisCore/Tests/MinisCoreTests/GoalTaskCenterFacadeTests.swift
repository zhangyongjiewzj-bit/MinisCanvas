import Foundation
import Testing
@testable import MinisCore

@Suite("GoalTaskCenterFacade")
struct GoalTaskCenterFacadeTests {
    @Test func projectsGoalLeaseAndTaskIdentityIntoTheTaskCenterFact() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(
            taskID: "goal-task",
            parentID: "goal-parent",
            providerID: "provider",
            modelID: "model"
        )
        let goalID = UUID()
        let leaseID = UUID()
        let deadline = Date(timeIntervalSince1970: 1_900_000_000)
        let goal = GoalEnvelope(
            goalID: goalID,
            scopeID: "scope:goal-task",
            allowedCapabilities: ["task.read"],
            budget: 42,
            deadline: deadline
        )
        let lease = AutonomyLease(
            leaseID: leaseID,
            goalID: goalID,
            scopeID: goal.scopeID,
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: deadline
        )
        let facade = try GoalTaskCenterFacade(
            store: store,
            bindings: [
                GoalTaskCenterBinding(
                    taskID: snapshot.taskID,
                    parentID: snapshot.parentID,
                    goal: goal,
                    lease: lease
                )
            ]
        )

        let projection = facade.project(now: Date(timeIntervalSince1970: 1_850_000_000))
        let fact = try #require(projection.fact(taskID: snapshot.taskID, parentID: snapshot.parentID))

        #expect(fact.taskID == "goal-task")
        #expect(fact.parentID == "goal-parent")
        #expect(fact.scopeID == goal.scopeID)
        #expect(fact.goalID == goalID)
        #expect(fact.leaseID == leaseID)
        #expect(fact.providerID == "provider")
        #expect(fact.modelID == "model")
        #expect(fact.routeReceiptID == nil)
        #expect(fact.budget == 42)
        #expect(fact.deadline == deadline)
        #expect(fact.leaseState == .active)
        #expect(!fact.revision.isEmpty)
    }

    @Test func controlsFailClosedWithoutChangingTheCanonicalTaskFact() throws {
        let pauseStore = AgentTaskStore()
        let pauseSnapshot = try pauseStore.enqueue(
            taskID: "pause-task",
            parentID: "parent",
            providerID: nil,
            modelID: nil
        )
        let pauseFacade = try GoalTaskCenterFacade(
            store: pauseStore,
            bindings: [binding(for: pauseSnapshot)]
        )
        let pauseFact = try #require(
            pauseFacade.project(now: observationNow).fact(
                taskID: pauseSnapshot.taskID,
                parentID: pauseSnapshot.parentID
            )
        )
        let pauseReceipt = try pauseFacade.submit(
            request(for: pauseFact, command: .pause, key: "pause-key"),
            now: observationNow
        )
        #expect(pauseReceipt.decision == .needsProductionExecutor)
        #expect(pauseStore.snapshot(taskID: pauseSnapshot.taskID, parentID: pauseSnapshot.parentID) == pauseSnapshot)

        #expect(throws: GoalTaskCenterFacadeError.commandNotApplicable(.resume, .queued)) {
            _ = try pauseFacade.submit(
                request(for: pauseFact, command: .resume, key: "resume-key"),
                now: observationNow
            )
        }

        let stopReceipt = try pauseFacade.submit(
            request(for: pauseFact, command: .stop, key: "stop-key"),
            now: observationNow
        )
        #expect(stopReceipt.decision == .needsProductionExecutor)
        #expect(pauseStore.snapshot(taskID: pauseSnapshot.taskID, parentID: pauseSnapshot.parentID) == pauseSnapshot)

        let retryStore = AgentTaskStore()
        let retryQueued = try retryStore.enqueue(
            taskID: "retry-task",
            parentID: "parent",
            providerID: nil,
            modelID: nil
        )
        let retryRun = try retryStore.startRun(
            taskID: retryQueued.taskID,
            parentID: retryQueued.parentID,
            runID: "retry-run"
        )
        _ = try retryStore.finish(runID: retryRun.runID, outcome: .failed(reason: "redacted"))
        let retryFacade = try GoalTaskCenterFacade(
            store: retryStore,
            bindings: [binding(for: retryQueued)]
        )
        let retryFact = try #require(
            retryFacade.project(now: observationNow).fact(
                taskID: retryQueued.taskID,
                parentID: retryQueued.parentID
            )
        )
        let retryReceipt = try retryFacade.submit(
            request(for: retryFact, command: .retry, key: "retry-key", runID: retryRun.runID),
            now: observationNow
        )
        #expect(retryReceipt.decision == .needsProductionExecutor)
        #expect(retryStore.snapshot(taskID: retryQueued.taskID, parentID: retryQueued.parentID)?.status == .failed)
    }

    @Test func revisionScopeAndIdempotencyAreRequiredBeforeACommandDecision() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(
            taskID: "identity-task",
            parentID: "identity-parent",
            providerID: nil,
            modelID: nil
        )
        let facade = try GoalTaskCenterFacade(store: store, bindings: [binding(for: snapshot)])
        let fact = try #require(
            facade.project(now: observationNow).fact(
                taskID: snapshot.taskID,
                parentID: snapshot.parentID
            )
        )
        let firstRequest = request(for: fact, command: .pause, key: "same-key")
        let first = try facade.submit(firstRequest, now: observationNow)
        #expect(try facade.submit(firstRequest, now: observationNow) == first)

        #expect(throws: GoalTaskCenterFacadeError.idempotencyKeyConflict) {
            _ = try facade.submit(
                request(for: fact, command: .stop, key: "same-key"),
                now: observationNow
            )
        }
        #expect(throws: GoalTaskCenterFacadeError.revisionMismatch) {
            _ = try facade.submit(
                GoalTaskCenterCommandRequest(
                    taskID: fact.taskID,
                    parentID: fact.parentID,
                    revision: "stale-revision",
                    scopeID: fact.scopeID ?? "",
                    actorID: "task-center-ui",
                    idempotencyKey: "stale-revision-key",
                    command: .pause
                ),
                now: observationNow
            )
        }
        #expect(throws: GoalTaskCenterFacadeError.scopeMismatch) {
            _ = try facade.submit(
                GoalTaskCenterCommandRequest(
                    taskID: fact.taskID,
                    parentID: fact.parentID,
                    revision: fact.revision,
                    scopeID: "scope:wrong",
                    actorID: "task-center-ui",
                    idempotencyKey: "wrong-scope-key",
                    command: .pause
                ),
                now: observationNow
            )
        }
    }

    @Test func unboundProjectionIsExplicitlyReadOnly() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(
            taskID: "unbound-task",
            parentID: "parent",
            providerID: nil,
            modelID: nil
        )
        let facade = GoalTaskCenterFacade(store: store)
        let projection = facade.project(now: observationNow)
        let fact = try #require(
            projection.fact(taskID: snapshot.taskID, parentID: snapshot.parentID)
        )

        #expect(facade.controlMode == .readOnlyProjection)
        #expect(projection.goals.isEmpty)
        #expect(projection.boundTaskCount == 0)
        #expect(projection.unboundTaskCount == 1)
        #expect(!fact.isGoalBound)
        #expect(fact.leaseState == .invalid)
        #expect(throws: GoalTaskCenterFacadeError.unboundGoal) {
            _ = try facade.submit(
                request(for: fact, scopeID: "scope:unbound", command: .pause, key: "unbound-key"),
                now: observationNow
            )
        }
    }

    @Test func durableReceiptReplaySurvivesFacadeRestartAndRejectsChangedPayload() throws {
        let store = AgentTaskStore()
        let snapshot = try store.enqueue(
            taskID: "durable-receipt-task",
            parentID: "durable-receipt-parent",
            providerID: nil,
            modelID: nil
        )
        let binding = binding(for: snapshot)
        let firstFacade = try GoalTaskCenterFacade(store: store, bindings: [binding])
        let beforeFact = try #require(
            firstFacade.project(now: observationNow).fact(
                taskID: snapshot.taskID,
                parentID: snapshot.parentID
            )
        )
        let request = request(for: beforeFact, command: .pause, key: "durable-pause")
        let beforeControl = try #require(
            store.controlSnapshot(taskID: snapshot.taskID, parentID: snapshot.parentID)
        )
        _ = try store.applyControl(
            taskID: snapshot.taskID,
            parentID: snapshot.parentID,
            command: .pause,
            expectedControlRevision: beforeControl.controlRevision,
            runID: nil,
            resultingRunID: nil,
            receipt: AgentTaskControlReceipt(
                taskID: request.taskID,
                parentID: request.parentID,
                idempotencyKey: request.idempotencyKey,
                command: .pause,
                revision: request.revision,
                scopeID: request.scopeID,
                actorID: request.actorID,
                runID: nil,
                resultingRunID: nil,
                controlState: .paused,
                controlRevision: beforeControl.controlRevision + 1,
                cancelledTaskIDs: []
            )
        )

        let recoveredFacade = try GoalTaskCenterFacade(store: store, bindings: [binding])
        let replay = try recoveredFacade.submit(request, now: observationNow)
        #expect(replay.request == request)
        #expect(replay.decision == .needsProductionExecutor)
        #expect(replay.observedFact.controlState == .paused)

        #expect(throws: GoalTaskCenterFacadeError.idempotencyKeyConflict) {
            _ = try recoveredFacade.submit(
                self.request(for: beforeFact, command: .stop, key: request.idempotencyKey),
                now: observationNow
            )
        }
    }

    private var observationNow: Date {
        Date(timeIntervalSince1970: 1_850_000_000)
    }

    private func binding(for snapshot: AgentTaskSnapshot) -> GoalTaskCenterBinding {
        let goal = GoalEnvelope(
            goalID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            scopeID: "scope:\(snapshot.taskID)",
            allowedCapabilities: ["task.read"],
            budget: 10,
            deadline: Date(timeIntervalSince1970: 1_900_000_000)
        )
        return GoalTaskCenterBinding(
            taskID: snapshot.taskID,
            parentID: snapshot.parentID,
            goal: goal,
            lease: AutonomyLease(
                goalID: goal.goalID,
                scopeID: goal.scopeID,
                issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
                expiresAt: goal.deadline
            )
        )
    }

    private func request(
        for fact: GoalTaskCenterTaskFact,
        scopeID: String? = nil,
        command: GoalTaskCenterCommand,
        key: String,
        runID: String? = nil
    ) -> GoalTaskCenterCommandRequest {
        GoalTaskCenterCommandRequest(
            taskID: fact.taskID,
            parentID: fact.parentID,
            revision: fact.revision,
            scopeID: scopeID ?? fact.scopeID ?? "",
            actorID: "task-center-ui",
            idempotencyKey: key,
            command: command,
            runID: runID
        )
    }
}
