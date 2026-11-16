import Foundation
import Testing
@testable import MinisCore

@Suite("Recovery306 reopened running task control consumer")
struct Recovery306TaskControlConsumerTests {
    @Test("persisted paused-running recovery rejects resume without a new run or receipt")
    func reopenedRunningTaskCannotCreateAnotherEffectIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery306-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ledger.json")
        let first = try AgentTaskStore(persistenceURL: url)
        let task = try first.enqueue(taskID: "recovery306-task", parentID: "root", providerID: "fake", modelID: "fake")
        let run = try first.startRun(taskID: task.taskID, parentID: task.parentID, runID: "previous-run")
        let goal = GoalEnvelope(scopeID: "recovery306", allowedCapabilities: ["task.read"], budget: 10,
            deadline: Date(timeIntervalSince1970: 1_900_000_000), createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let binding = GoalTaskCenterBinding(taskID: task.taskID, parentID: task.parentID, goal: goal,
            lease: AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_900_000_000)))
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let liveExecutor = try GoalTaskControlExecutor(store: first, bindings: [binding])
        let liveFact = try #require(liveExecutor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        _ = try liveExecutor.execute(GoalTaskCenterCommandRequest(taskID: task.taskID, parentID: task.parentID,
            revision: liveFact.revision, scopeID: goal.scopeID, actorID: "synthetic-test",
            idempotencyKey: "pause-before-reopen", command: .pause, runID: run.runID), now: now)
        let bytes = try Data(contentsOf: url)
        let reopened = try AgentTaskStore(persistenceURL: url)
        let executor = try GoalTaskControlExecutor(store: reopened, bindings: [binding])
        let fact = try #require(executor.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        #expect(reopened.recoveryState(runID: run.runID) == .needsUserReview)
        #expect(fact.controlState == .paused)
        let request = GoalTaskCenterCommandRequest(taskID: task.taskID, parentID: task.parentID,
            revision: fact.revision, scopeID: goal.scopeID, actorID: "synthetic-test",
            idempotencyKey: "recovery306-resume", command: .resume, runID: run.runID)
        #expect(throws: GoalTaskControlExecutorError.needsUserReview(.recoveredRunningTask)) {
            _ = try executor.execute(request, now: now)
        }
        #expect(throws: AgentTaskStoreError.taskAlreadyRunning) {
            _ = try reopened.startRun(taskID: task.taskID, parentID: task.parentID, runID: "forbidden-second-run")
        }
        #expect(reopened.attempts(runID: run.runID).count == 1)
        #expect(reopened.allReceipts().isEmpty)
        #expect(reopened.events(runID: run.runID).isEmpty)
        #expect(reopened.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .running)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
