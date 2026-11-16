import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center task/child recovery consumer")
struct TaskCenterControlConsumerTests {
    @Test
    func terminalChildResultProjectionPreservesTaskRunAttemptAndBacklink() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "child-task",
            parentID: "parent-a",
            providerID: "offline",
            modelID: "test",
            parentContextSnapshotID: "session-a"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "child-run"
        )
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: "\(run.runID):attempt:1",
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "child-execution",
            outcome: .succeeded,
            outputDigest: "digest-child-result",
            evidenceRefs: ["receipt://child-result/evidence"],
            idempotencyKey: "child-result-idempotency",
            agentType: "codex",
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 165)
        )
        _ = try store.settleChildResult(envelope)

        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first)
        #expect(row.taskState == .completed)
        #expect(row.runID == run.runID)
        #expect(row.attemptID == envelope.attemptID)
        #expect(row.childResultEnvelope == envelope)
        #expect(row.durationTitle() == "1分5秒")
        #expect(row.resultSummaryTitle == "已完成 · 有证据")
        #expect(row.recoveryState == .none)
        #expect(
            consumer.childResult(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: run.runID
            ) == envelope
        )
        #expect(
            consumer.childResult(
                taskID: task.taskID,
                parentID: "foreign-parent",
                runID: run.runID
            ) == nil
        )
        #expect(consumer.orphanReceiptRunIDs().isEmpty)
    }

    @Test
    func recoveredRunningTaskProjectsReviewRequiredAndDisablesCancel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-center-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let ledgerURL = root.appendingPathComponent("agent-tasks.json")
        do {
            let store = try AgentTaskStore(persistenceURL: ledgerURL)
            let task = try store.enqueue(
                taskID: "recovered-task",
                parentID: "parent-recovery",
                providerID: "offline",
                modelID: "test"
            )
            _ = try store.startRun(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: "recovered-run"
            )
        }

        let reloaded = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reloaded.recoveryState(runID: "recovered-run") == .needsUserReview)
        let row = try #require(
            TaskCenterControlConsumer(store: reloaded).receiptRows().first
        )
        #expect(row.taskState == .running)
        #expect(row.recoveryState == .needsUserReview)
        #expect(!row.needsChildTerminalReview)
        #expect(TaskCenterRecoveryRowText.visibleTitle(for: row) == "恢复：需要人工复核")
        #expect(!row.cancelAvailable)
        #expect(!row.retryAvailable)
        #expect(
            row.accessibilityLabel.contains("需要人工复核")
        )
        #expect(
            TaskCenterControlConsumer(store: reloaded).orphanReceiptRunIDs().isEmpty
        )
    }

    @Test("reopened production child shows missing terminal truth without creating a receipt",
          arguments: [AgentParentTurnTerminalFact.Outcome?.none, .succeeded, .cancelled, .timedOut])
    func recoveredChildShowsParentAndMissingTerminal(_ parentOutcome: AgentParentTurnTerminalFact.Outcome?) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("agent-tasks.json")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = ParentRuntimeIdentity(
            sessionID: "parent-session", conversationID: "parent-conversation",
            turnID: "turn-handle:\(handle.turnID)", taskID: "parent-task", actorID: "app"
        )
        let goal = GoalEnvelope(scopeID: "parent-authority", allowedCapabilities: ["orchestrate"],
            budget: 10, deadline: Date().addingTimeInterval(60))
        let provider = ParentContextSnapshotV1(providerID: "offline", modelID: "test",
            configurationFingerprint: "synthetic", conversationID: parent.conversationID)
        let child = try ChildRuntimeIdentity.derive(parent: parent,
            childSessionID: "child-session", childTaskID: "child-task",
            scopeID: "private-child-scope", requestedCapabilities: [.streaming],
            parentCapabilities: [.streaming], policyCapabilities: [.streaming],
            providerSnapshot: provider, memoryScopeID: "synthetic-memory",
            workingDirectory: root.path, cancelGeneration: handle.turnID,
            evidenceRoot: "synthetic-evidence", parentTurnHandle: handle,
            childExecutionID: "child-execution", parentGoal: goal)
        do {
            let store = try AgentTaskStore(persistenceURL: ledgerURL)
            _ = try store.enqueue(taskID: child.childTaskID, parentID: parent.taskID,
                providerID: provider.providerID, modelID: provider.modelID,
                parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
            _ = try store.startRun(taskID: child.childTaskID, parentID: parent.taskID,
                runID: "child-run")
            #expect(store.recoveryState(runID: "child-run") == nil)
            #expect(TaskCenterControlConsumer(store: store).receiptRows().first?.needsChildTerminalReview == false)
            let execution = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: parent.sessionID,
                    turnID: handle.turnID, messageID: "parent-message"),
                operationID: "parent-run", attempt: 1)
            if let parentOutcome {
                let recorded = try store.recordParentTurnTerminal(
                    parent: parent, execution: execution, outcome: parentOutcome)
                let terminal = try #require(recorded)
                #expect(terminal.outcome == parentOutcome)
                #expect(terminal.children.count == 1)
                #expect(terminal.children.first?.outcome == .needsUserReview)
                #expect(terminal.children.first?.cancellationReason ==
                    (parentOutcome == .cancelled ? "parent-cancelled" :
                        parentOutcome == .timedOut ? "parent-timeout" : nil))
                #expect(store.recoveryState(runID: "child-run") == .needsUserReview)
                let liveRow = try #require(TaskCenterControlConsumer(store: store).receiptRows().first)
                #expect(liveRow.needsChildTerminalReview && !liveRow.retryAvailable)
            } else {
                // Crash before the parent can write a terminal fact: only a
                // fresh durable consumer may classify the running child.
                #expect(store.parentTurnTerminalFact(parent: parent, execution: execution) == nil)
                #expect(store.recoveryState(runID: "child-run") == nil)
            }
        }

        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        let row = try #require(TaskCenterControlConsumer(store: reopened).receiptRows().first)
        #expect(row.needsChildTerminalReview)
        #expect(row.recoveryState == .needsUserReview)
        #expect(row.taskID == child.childTaskID && row.parentID == parent.taskID)
        #expect(row.runID == "child-run" && row.childResultEnvelope == nil)
        #expect(row.resultSummaryTitle == "子任务真实终态未记录")
        let recoveryTitle = try #require(TaskCenterRecoveryRowText.visibleTitle(for: row))
        #expect(recoveryTitle.contains("子任务 child-task"))
        #expect(recoveryTitle.contains("父任务 parent-task"))
        #expect(recoveryTitle.contains("Run child-run"))
        #expect(recoveryTitle.contains("真实终态未记录"))
        #expect(row.accessibilityLabel.contains("父任务 parent-task"))
        #expect(!row.cancelAvailable && !row.retryAvailable)
        #expect(reopened.attempts(runID: "child-run").count == 1)
        #expect(reopened.allReceipts().isEmpty)
        #expect(TaskCenterControlConsumer(store: reopened).orphanReceiptRunIDs().isEmpty)

        // Exercise the actual control entry with a valid current Goal/Lease.
        // A disabled row alone does not prove that stale/manual requests stop.
        let consumer = TaskCenterControlConsumer(store: reopened)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: goal.createdAt, expiresAt: goal.deadline)
        consumer.installProductionGoal(goal: goal, lease: lease)
        #expect(consumer.installTopLevelTaskGoal(taskID: parent.taskID, goal: goal, lease: lease))
        let fact = try #require(consumer.project().fact(taskID: child.childTaskID, parentID: parent.taskID))
        #expect(fact.isGoalBound)
        let beforeDeniedControl = try Data(contentsOf: ledgerURL)
        for action in [TaskCenterControlAction.cancel, .retry] {
            let request = TaskCenterControlRequest(taskID: child.childTaskID, parentID: parent.taskID,
                revision: fact.revision, scopeID: goal.scopeID, actorID: "app",
                idempotencyKey: "orphan-denied:\(action.rawValue)", action: action, runID: "child-run")
            let expected: TaskCenterControlConsumerError = action == .cancel
                ? .executor(.needsUserReview(.recoveredRunningTask))
                : .facade(.commandNotApplicable(.retry, .running))
            #expect(throws: expected) { _ = try consumer.execute(request) }
        }
        #expect(try Data(contentsOf: ledgerURL) == beforeDeniedControl)
        #expect(reopened.attempts(runID: "child-run").count == 1)
        #expect(reopened.allReceipts().isEmpty)

        _ = try reopened.finish(runID: "child-run", outcome: .succeeded)
        let settled = try #require(TaskCenterControlConsumer(store: reopened).receiptRows().first)
        #expect(!settled.needsChildTerminalReview)
        #expect(TaskCenterRecoveryRowText.visibleTitle(for: settled) == nil)
        #expect(reopened.allReceipts().count == 1)
    }

    @Test
    func missingOrForeignChildResultFailsClosedWithoutOrphanProjection() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "unsettled-child",
            parentID: "parent-c",
            providerID: "offline",
            modelID: "test",
            parentContextSnapshotID: "session-c"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "unsettled-run"
        )
        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first)
        #expect(row.childResultEnvelope == nil)
        #expect(row.durationTitle() == "未记录")
        #expect(row.resultSummaryTitle == "尚无结果")
        #expect(
            consumer.childResult(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: run.runID
            ) == nil
        )
        #expect(consumer.orphanReceiptRunIDs().isEmpty)
    }

    @Test("reopened child uses its exact parent task Goal, never the process binding")
    func childGoalBindingSurvivesRestartWithoutLegacyFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-goal-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = ParentRuntimeIdentity(
            sessionID: "session", conversationID: "conversation",
            turnID: "turn-handle:\(handle.turnID)", taskID: "parent-task", actorID: "app"
        )
        let oldGoal = GoalEnvelope(
            scopeID: "production:agent", allowedCapabilities: ["orchestrate"],
            budget: 1, deadline: Date().addingTimeInterval(60)
        )
        let newGoal = GoalEnvelope(
            scopeID: "production:agent", allowedCapabilities: ["orchestrate"],
            budget: 9, deadline: Date().addingTimeInterval(120)
        )
        let oldLease = AutonomyLease(
            goalID: oldGoal.goalID, scopeID: oldGoal.scopeID,
            issuedAt: oldGoal.createdAt, expiresAt: oldGoal.deadline
        )
        let newLease = AutonomyLease(
            goalID: newGoal.goalID, scopeID: newGoal.scopeID,
            issuedAt: newGoal.createdAt, expiresAt: newGoal.deadline
        )
        let provider = ParentContextSnapshotV1(
            providerID: "offline", modelID: "test",
            configurationFingerprint: "synthetic", conversationID: parent.conversationID
        )
        let child = try ChildRuntimeIdentity.derive(
            parent: parent, childSessionID: "child-session", childTaskID: "child-task",
            scopeID: "private-child-scope", requestedCapabilities: [.streaming],
            parentCapabilities: [.streaming], policyCapabilities: [.streaming],
            providerSnapshot: provider, memoryScopeID: "memory:synthetic",
            workingDirectory: root.path, cancelGeneration: handle.turnID,
            evidenceRoot: "evidence:synthetic", parentTurnHandle: handle,
            childExecutionID: "child-execution", parentGoal: newGoal
        )
        _ = try store.enqueue(
            taskID: child.childTaskID, parentID: parent.taskID,
            providerID: "offline", modelID: "test",
            parentRuntimeIdentity: parent, childRuntimeIdentity: child,
            parentGoal: newGoal
        )

        let legacyURL = root.appendingPathComponent("legacy-binding.json")
        let legacy = TaskCenterControlConsumer(store: store, bindingPersistenceURL: legacyURL)
        legacy.installProductionGoal(goal: oldGoal, lease: oldLease)
        #expect(legacy.project().fact(taskID: child.childTaskID, parentID: parent.taskID)?.isGoalBound == false)

        let bindingURL = root.appendingPathComponent("task-bindings.json")
        let first = TaskCenterControlConsumer(store: store, bindingPersistenceURL: bindingURL)
        first.installProductionGoal(goal: oldGoal, lease: oldLease)
        #expect(first.installTopLevelTaskGoal(
            taskID: parent.taskID, goal: newGoal, lease: newLease
        ))
        let reopenedStore = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let reopened = TaskCenterControlConsumer(
            store: reopenedStore, bindingPersistenceURL: bindingURL
        )
        let fact = try #require(reopened.project().fact(
            taskID: child.childTaskID, parentID: parent.taskID
        ))
        #expect(fact.goalID == newGoal.goalID)
        #expect(fact.budget == 9)
        #expect(fact.leaseID == newLease.leaseID)
        #expect(fact.goalID != oldGoal.goalID)
    }
}
