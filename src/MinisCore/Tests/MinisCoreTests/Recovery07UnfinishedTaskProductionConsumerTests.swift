import Foundation
import Testing
@testable import MinisCore

@Suite("Recovery07 unfinished task production consumer")
struct Recovery07UnfinishedTaskProductionConsumerTests {
    @Test("reopened running child with pending tool effect cannot resume or redispatch its original attempt")
    func pendingChildEffectNeedsReviewBeforeAnotherProductionDispatch() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("recovery07-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let taskURL = root.appendingPathComponent("tasks.json")
        let effectURL = root.appendingPathComponent("effects.json")
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let session = try sessions.createSession(id: "recovery07-session")
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: session.id,
            conversationID: session.id, taskID: "recovery07-parent", actorID: "owned-test")
            .makeIdentity(using: turn)
        let oldTaskID = "recovery07-unfinished-child"
        let oldRunID = "recovery07-old-run"
        let oldAttemptID = "\(oldRunID):attempt:1"
        let firstTasks = try AgentTaskStore(persistenceURL: taskURL)
        _ = try firstTasks.enqueue(taskID: oldTaskID, parentID: parent.taskID,
            providerID: "synthetic", modelID: "synthetic", parentRuntimeIdentity: parent)
        _ = try firstTasks.startRun(taskID: oldTaskID, parentID: parent.taskID, runID: oldRunID)
        _ = try firstTasks.appendEvent(runID: oldRunID, kind: .started, detail: "child-dispatched")

        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let goal = GoalEnvelope(scopeID: "recovery07-scope", allowedCapabilities: ["task.read"],
            budget: 10, deadline: Date(timeIntervalSince1970: 1_900_000_000),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let binding = GoalTaskCenterBinding(taskID: oldTaskID, parentID: parent.taskID,
            goal: goal, lease: AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)))
        let liveControl = try GoalTaskControlExecutor(store: firstTasks, bindings: [binding])
        let liveFact = try #require(liveControl.project(now: now).fact(taskID: oldTaskID, parentID: parent.taskID))
        _ = try liveControl.execute(GoalTaskCenterCommandRequest(taskID: oldTaskID,
            parentID: parent.taskID, revision: liveFact.revision, scopeID: goal.scopeID,
            actorID: "owned-test", idempotencyKey: "pause-before-restart", command: .pause,
            runID: oldRunID), now: now)

        let firstEffects = try ToolExecutionFactLedger(persistenceURL: effectURL)
        let turnNumber = try #require(Int(parent.turnID.split(separator: ":").last ?? ""))
        let locator = ChildTranscriptLocator(childSessionID: "recovery07-child-session",
            parentSessionID: session.id, taskID: oldTaskID, parentID: parent.taskID,
            runID: oldRunID, attemptID: oldAttemptID,
            childExecutionID: "recovery07-child-execution", parentContextSnapshotID: nil)
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: locator.childSessionID, turnID: turnNumber, messageID: oldTaskID),
            operationID: oldRunID, attempt: 1)
        let pending = try firstEffects.mint(toolCallID: "recovery07-pending-write",
            toolName: "file_write", attemptID: oldAttemptID, attemptNumber: 1,
            executionIdentity: execution, parentRuntimeIdentity: parent,
            childTranscriptLocator: locator)

        // A fresh process opens both durable stores. The pending receipt is an
        // unknown external outcome; neither a control resume nor replaying the
        // same child through the production orchestrator may call a provider/tool.
        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopenedEffects = try ToolExecutionFactLedger(persistenceURL: effectURL)
        #expect(reopenedTasks.recoveryState(runID: oldRunID) == .needsUserReview)
        #expect(reopenedEffects.recoveredPendingReceipts == [pending])
        let originalTasks = try Data(contentsOf: taskURL)
        let originalEffects = try Data(contentsOf: effectURL)
        let control = try GoalTaskControlExecutor(store: reopenedTasks, bindings: [binding])
        let fact = try #require(control.project(now: now).fact(taskID: oldTaskID, parentID: parent.taskID))
        #expect(throws: GoalTaskControlExecutorError.needsUserReview(.recoveredRunningTask)) {
            _ = try control.execute(GoalTaskCenterCommandRequest(taskID: oldTaskID,
                parentID: parent.taskID, revision: fact.revision, scopeID: goal.scopeID,
                actorID: "owned-test", idempotencyKey: "resume-after-restart", command: .resume,
                runID: oldRunID), now: now)
        }

        let input = root.appendingPathComponent("owned.txt")
        try "owned recovery07\n".write(to: input, atomically: true, encoding: .utf8)
        let call = try #require(String(data: JSONSerialization.data(withJSONObject: [
            "tool_calls": [["id": "recovery07-new-call", "name": "file_read",
                "input": ["path": input.path]]]
        ]), encoding: .utf8))
        let provider = ScriptedChildProvider(responses: [call, "done"])
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let reader = ScopedForwardingExecutor(base: builtin)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3, provider: provider,
            toolExecutor: reader, approvalGate: ApprovalGate(policyByTool: ["file_read": .autoApprove]),
            turnController: controller, makeLoopDetector: { nil },
            currentConversationID: session.id, taskStore: reopenedTasks,
            sessionStore: sessions, toolExecutionFactLedger: reopenedEffects,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools],
                allowedToolNames: ["file_read"]), parentCapabilities: [.tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: builtin),
            concreteBuiltinToolExecutorOwner: builtin)
        func child(_ id: String) -> SubAgentTask {
            SubAgentTask(id: id, title: id, instructions: "read owned file",
                requiredCapabilities: [.tools], resourceRequest: SubAgentResourceRequest(
                    allowedToolNames: ["file_read"], allowedReadRoots: [root.path]))
        }
        let replay = await orchestrator.orchestrate(tasks: [child(oldTaskID)], strategy: .sequential)
        #expect(replay.count == 1 && replay.first?.result.isSuccess == false)
        #expect(provider.receivedRequests.isEmpty)
        #expect(reader.invokedNames.isEmpty)
        #expect(reopenedTasks.attempts(runID: oldRunID).map(\.attemptID) == [oldAttemptID])
        #expect(reopenedEffects.pendingReceipts == [pending] && reopenedEffects.facts.isEmpty)
        #expect(try Data(contentsOf: taskURL) == originalTasks)
        #expect(try Data(contentsOf: effectURL) == originalEffects)

        // A distinct, newly admitted task can still run; old uncertainty does
        // not silently grant or suppress unrelated work.
        let fresh = await orchestrator.orchestrate(tasks: [child("recovery07-new-child")],
            strategy: .sequential)
        #expect(fresh.count == 1 && fresh.first?.result.isSuccess == true)
        #expect(provider.receivedRequests.count == 2)
        #expect(reader.invokedNames == ["file_read"])
        #expect(reopenedEffects.pendingReceipts == [pending])
    }
}
