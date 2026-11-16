import Foundation
import Testing
@testable import MinisCore

@Suite("H3A verified one-level child execution binding")
struct H3ASingleLevelExecutionBinding2013Tests {
    private struct Fixture {
        let store: AgentTaskStore
        let ledgerURL: URL
        let task: AgentTaskSnapshot
        let run: AgentRunSnapshot
        let attemptID: String
        let child: ChildRuntimeIdentity
        let handle: TurnController.TurnHandle

        func envelope(executionID: String) -> ChildResultEnvelope {
            ChildResultEnvelope(taskID: task.taskID, runID: run.runID,
                attemptID: attemptID, parentContextSnapshotID: task.parentContextSnapshotID,
                childExecutionID: executionID, outcome: .succeeded,
                resultDigest: "sha256:h3a-owned-result")
        }
    }

    private func makeFixture(_ name: String) async throws -> Fixture {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("h3a-execution-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parent = ParentRuntimeIdentity(sessionID: "h3a-root-session",
            conversationID: "h3a-root-conversation", turnID: "turn-handle:\(handle.turnID)",
            taskID: "h3a-root-task", actorID: "app")
        let goal = GoalEnvelope(scopeID: "h3a-parent-authority",
            allowedCapabilities: ["orchestrate"], budget: 10,
            deadline: Date().addingTimeInterval(60))
        let binding = ParentContextSnapshotV1(providerID: "h3a-provider", modelID: "h3a-model",
            configurationFingerprint: "h3a-fingerprint", conversationID: parent.conversationID)
        let request = SubAgentTask(id: "h3a-child", title: "one child",
            instructions: "finish synthetic work", executionID: "h3a-owned-execution",
            parentContextSnapshotID: "h3a-parent-context")
        let orchestrator = AgentOrchestrator(currentConversationID: parent.conversationID,
            taskStore: store, parentID: parent.taskID, parentBinding: binding,
            parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: handle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []),
            parentCapabilities: [.streaming])
        let child = try orchestrator.makeChildRuntimeIdentity(for: request)
        #expect(child.rootParentIdentity == parent)
        #expect(child.parentGoalID == goal.goalID)
        #expect(child.parentGoalScopeID == goal.scopeID)
        #expect(child.scopeID != goal.scopeID)
        let task = try store.enqueue(taskID: request.id, parentID: parent.taskID,
            providerID: binding.providerID, modelID: binding.modelID,
            configurationFingerprint: binding.configurationFingerprint,
            parentContextSnapshotID: request.parentContextSnapshotID,
            parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID,
            runID: "h3a-child-run")
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        return Fixture(store: store, ledgerURL: ledgerURL, task: task,
            run: run, attemptID: attemptID, child: child, handle: handle)
    }

    @Test("foreign execution cannot claim the same child run and attempt")
    func foreignExecutionCannotSettleOwnedChild() async throws {
        let fixture = try await makeFixture("foreign")
        defer { Task { await fixture.handle.finish() } }
        let before = try Data(contentsOf: fixture.ledgerURL)
        let wrong = fixture.envelope(executionID: "h3a-foreign-execution")
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try fixture.store.settleChildResult(wrong)
        }
        #expect(fixture.store.receipt(runID: fixture.run.runID) == nil)
        #expect(try Data(contentsOf: fixture.ledgerURL) == before)
        let reopened = try AgentTaskStore(persistenceURL: fixture.ledgerURL)
        #expect(reopened.taskSnapshot(runID: fixture.run.runID)?.childRuntimeIdentity == fixture.child)
        #expect(reopened.allReceipts().isEmpty)
    }

    @Test("the original execution settles once and survives a fresh reopen")
    func originalExecutionSettlesAndReopens() async throws {
        let fixture = try await makeFixture("owned")
        defer { Task { await fixture.handle.finish() } }
        let owned = fixture.envelope(executionID: "h3a-owned-execution")
        let receipt = try fixture.store.settleChildResult(owned)
        let reopened = try AgentTaskStore(persistenceURL: fixture.ledgerURL)
        #expect(reopened.allReceipts() == [receipt])
        #expect(reopened.childResultEnvelope(runID: fixture.run.runID) == owned)
        #expect(reopened.taskSnapshot(runID: fixture.run.runID)?.childRuntimeIdentity == fixture.child)

        let originalData = try Data(contentsOf: fixture.ledgerURL)
        var durable = try #require(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        var state = try #require(durable["state"] as? [String: Any])
        var receipts = try #require(state["receiptByRunID"] as? [String: Any])
        var forgedReceipt = try #require(receipts[fixture.run.runID] as? [String: Any])
        var forgedEnvelope = try #require(forgedReceipt["childResultEnvelope"] as? [String: Any])
        forgedEnvelope["childExecutionID"] = "h3a-foreign-execution"
        forgedReceipt["childResultEnvelope"] = forgedEnvelope
        receipts[fixture.run.runID] = forgedReceipt
        state["receiptByRunID"] = receipts
        durable["state"] = state
        let forgedURL = fixture.ledgerURL.deletingLastPathComponent()
            .appendingPathComponent("foreign-receipt.json")
        try JSONSerialization.data(withJSONObject: durable).write(to: forgedURL)
        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: forgedURL)
        }
        #expect(try Data(contentsOf: fixture.ledgerURL) == originalData)
    }
}
