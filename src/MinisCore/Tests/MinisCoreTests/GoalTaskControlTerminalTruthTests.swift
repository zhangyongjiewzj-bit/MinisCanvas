import Foundation
import Testing
@testable import MinisCore

@Suite("Goal/Task control terminal truth")
struct GoalTaskControlTerminalTruthTests {
    @Test("running cancellation projects one durable terminal receipt")
    func runningCancellationProjectsTerminalReceipt() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "terminal-cancel-task",
            parentID: "terminal-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "terminal-cancel-run"
        )
        _ = try store.finish(runID: run.runID, outcome: .cancelled)

        let facade = try GoalTaskCenterFacade(
            store: store,
            bindings: [binding(for: task)]
        )
        let projection = try #require(
            facade.verticalSliceProjection(
                taskID: task.taskID,
                parentID: task.parentID,
                route: .chat,
                now: observationNow
            )
        )

        #expect(projection.terminalState == .cancelled)
        #expect(projection.terminalReceipt?.runID == run.runID)
        #expect(projection.terminalReceipt?.attemptID == "\(run.runID):attempt:1")
        #expect(projection.terminalReceipt?.eventKind == .cancelled)
        #expect(projection.cancellation.state == .settled)
        #expect(projection.cancellation.runID == run.runID)
        #expect(projection.validationIssues.isEmpty)
    }

    @Test("queued stop exposes cancellation truth without claiming success")
    func queuedStopProjectsCancellationTruth() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "queued-cancel-task",
            parentID: "queued-parent",
            providerID: nil,
            modelID: nil
        )
        let executor = try GoalTaskControlExecutor(
            store: store,
            bindings: [binding(for: task)]
        )
        let before = try #require(
            executor.project(now: observationNow).fact(
                taskID: task.taskID,
                parentID: task.parentID
            )
        )
        let request = GoalTaskCenterCommandRequest(
            taskID: task.taskID,
            parentID: task.parentID,
            revision: before.revision,
            scopeID: before.scopeID ?? "",
            actorID: "terminal-truth-test",
            idempotencyKey: "queued-cancel-key",
            command: .stop
        )

        let execution = try executor.execute(request, now: observationNow)
        let truth = try #require(execution.terminalTruth)

        #expect(truth.taskID == task.taskID)
        #expect(truth.parentID == task.parentID)
        #expect(truth.runID == nil)
        #expect(truth.outcome == .cancelled)
        #expect(!truth.isSuccess)
        #expect(execution.afterFact.status == .cancelled)
        #expect(execution.afterFact.controlState == .stopped)

        let facade = try GoalTaskCenterFacade(
            store: store,
            bindings: [binding(for: task)]
        )
        let projection = try #require(
            facade.verticalSliceProjection(
                taskID: task.taskID,
                parentID: task.parentID,
                route: .chat,
                now: observationNow
            )
        )
        #expect(projection.terminalState == .cancelled)
        #expect(projection.terminalReceipt == nil)
        #expect(projection.cancellation.state == .settled)
        #expect(projection.cancellation.runID == nil)
        #expect(projection.cancellation.terminalEventKind == .cancelled)
        #expect(projection.validationIssues.isEmpty)
    }

    @Test("review refusal maps to policy refusal and cannot project success")
    func reviewRefusalIsNotSuccess() throws {
        let request = GoalTaskCenterCommandRequest(
            taskID: "review-task",
            parentID: "review-parent",
            revision: "revision",
            scopeID: "scope:review",
            actorID: "terminal-truth-test",
            idempotencyKey: "review-key",
            command: .stop,
            runID: "review-run"
        )

        let truth = GoalTaskControlExecutorError
            .needsUserReview(.externalSubmissionUnknown)
            .terminalTruth(for: request)

        #expect(truth.outcome == .policyRefused)
        #expect(truth.reason == GoalTaskCenterReviewReason.externalSubmissionUnknown.rawValue)
        #expect(!truth.isSuccess)
    }

    private let observationNow = Date(timeIntervalSince1970: 1_850_000_000)

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
}
