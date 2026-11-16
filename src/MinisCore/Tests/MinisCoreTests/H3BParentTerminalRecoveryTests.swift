import Foundation
import Testing
@testable import MinisCore

private final class H3BUnsettledChildExecutor: ToolExecutor, @unchecked Sendable {
    let store: AgentTaskStore
    let workingDirectory: String
    private(set) var parent: ParentRuntimeIdentity?

    init(store: AgentTaskStore, workingDirectory: String) {
        self.store = store
        self.workingDirectory = workingDirectory
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let context = AgentExecutionContext.current,
              let parent = context.parentRuntimeIdentity,
              let handle = context.parentTurnHandle,
              let binding = context.parentBinding else {
            throw H3BFixtureError.missingParent
        }
        self.parent = parent
        let goal = GoalEnvelope(scopeID: "h3b-parent-scope", allowedCapabilities: ["orchestrate"],
            budget: 10, deadline: Date().addingTimeInterval(60))
        let child = try ChildRuntimeIdentity.derive(parent: parent,
            childSessionID: "h3b-child-session", childTaskID: "h3b-child",
            scopeID: "h3b-private-child", requestedCapabilities: [.streaming],
            parentCapabilities: [.streaming], policyCapabilities: [.streaming],
            providerSnapshot: binding, memoryScopeID: "h3b-memory",
            workingDirectory: workingDirectory, cancelGeneration: handle.turnID,
            evidenceRoot: "h3b-evidence", parentTurnHandle: handle,
            childExecutionID: "h3b-child-execution", parentGoal: goal)
        _ = try store.enqueue(taskID: child.childTaskID, parentID: parent.taskID,
            providerID: binding.providerID, modelID: binding.modelID,
            parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
        _ = try store.startRun(taskID: child.childTaskID, parentID: parent.taskID,
            runID: "h3b-child-run")
        return "child dispatched; settlement interrupted"
    }
}

private enum H3BFixtureError: Error { case missingParent }

private actor H3BApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("D-H3B parent terminal and child recovery")
struct H3BParentTerminalRecoveryTests {
    @Test("a parent without dispatched children needs no child join fact")
    func parentWithoutChildrenRemainsNoop() throws {
        let store = AgentTaskStore()
        let parent = ParentRuntimeIdentity(sessionID: "h3b-empty",
            conversationID: "h3b-empty", turnID: "turn-handle:1",
            taskID: "h3b-empty-parent", actorID: "app")
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: parent.sessionID, turnID: 1, messageID: "h3b-empty-message"),
            operationID: "h3b-empty-run", attempt: 0)
        let fact = try store.recordParentTurnTerminal(
            parent: parent, execution: execution, outcome: .succeeded)
        #expect(fact == nil)
    }

    @Test("parent cancellation lists settled and UNKNOWN children without inventing receipts")
    func parentCancellationPreservesChildOutcomes() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let directory = profile.rootDirectory.appendingPathComponent("h3b-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledger)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let parent = ParentRuntimeIdentity(sessionID: "h3b-cancel-session",
            conversationID: "h3b-cancel-session", turnID: "turn-handle:\(handle.turnID)",
            taskID: "h3b-cancel-parent", actorID: "app")
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: parent.sessionID, turnID: handle.turnID, messageID: "h3b-cancel-message"),
            operationID: "h3b-cancel-run", attempt: 1)
        let binding = ParentContextSnapshotV1(providerID: "offline", modelID: "test",
            configurationFingerprint: "h3b-test", conversationID: parent.conversationID)
        let goal = GoalEnvelope(scopeID: "h3b-cancel-scope",
            allowedCapabilities: ["orchestrate"], budget: 10,
            deadline: Date().addingTimeInterval(60))
        for taskID in ["h3b-unsettled", "h3b-settled"] {
            let child = try ChildRuntimeIdentity.derive(parent: parent,
                childSessionID: "\(taskID)-session", childTaskID: taskID,
                scopeID: "\(taskID)-scope", requestedCapabilities: [.streaming],
                parentCapabilities: [.streaming], policyCapabilities: [.streaming],
                providerSnapshot: binding, memoryScopeID: "h3b-memory",
                workingDirectory: directory.path, cancelGeneration: handle.turnID,
                evidenceRoot: "h3b-evidence", parentTurnHandle: handle,
                childExecutionID: "\(taskID)-execution", parentGoal: goal)
            _ = try store.enqueue(taskID: taskID, parentID: parent.taskID,
                providerID: binding.providerID, modelID: binding.modelID,
                parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
            _ = try store.startRun(taskID: taskID, parentID: parent.taskID,
                runID: "\(taskID)-run")
        }
        try store.markExternalSubmissionUnknown(runID: "h3b-unsettled-run")
        _ = try store.finish(runID: "h3b-settled-run", outcome: .succeeded)
        // A disk-full failure must roll back a valid first parent terminal
        // write. Once that terminal exists, a different execution for the
        // same parent is rejected by identity before persistence is attempted.
        let faulted = try AgentTaskStore(persistenceURL: ledger, persistenceFault: .diskFull)
        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try faulted.recordParentTurnTerminal(
                parent: parent, execution: execution, outcome: .cancelled)
        }
        #expect(faulted.parentTurnTerminalFact(parent: parent, execution: execution) == nil)
        #expect(try AgentTaskStore(persistenceURL: ledger)
            .parentTurnTerminalFact(parent: parent, execution: execution) == nil)
        let recorded = try store.recordParentTurnTerminal(
            parent: parent, execution: execution, outcome: .cancelled)
        let fact = try #require(recorded)
        #expect(fact.children.map(\.taskID) == ["h3b-settled", "h3b-unsettled"])
        #expect(fact.children.map(\.outcome) == [.succeeded, .needsUserReview])
        #expect(fact.children.last?.cancellationReason == "parent-cancelled")
        #expect(store.receipt(runID: "h3b-unsettled-run") == nil)
        #expect(store.recoveryState(runID: "h3b-unsettled-run") == .needsUserReview)
        #expect(store.recoveryState(runID: "h3b-settled-run") == nil)
        let reopened = try AgentTaskStore(persistenceURL: ledger)
        #expect(reopened.parentTurnTerminalFact(parent: parent, execution: execution) == fact)
        #expect(reopened.recoveryState(runID: "h3b-unsettled-run") == .needsUserReview)
        #expect(reopened.receipt(runID: "h3b-unsettled-run") == nil)
        let settledBytes = try Data(contentsOf: ledger)
        let settledObject = try JSONSerialization.jsonObject(with: settledBytes)
        for claimedOutcome in ["failed", "cancelled"] {
            var forgedEnvelope = try #require(settledObject as? [String: Any])
            var forgedState = try #require(forgedEnvelope["state"] as? [String: Any])
            var facts = try #require(forgedState["parentTurnTerminalFacts"] as? [[String: Any]])
            var forgedFact = try #require(facts.first)
            var children = try #require(forgedFact["children"] as? [[String: Any]])
            var settledChild = try #require(children.first)
            #expect(settledChild["taskID"] as? String == "h3b-settled")
            settledChild["outcome"] = claimedOutcome
            children[0] = settledChild
            forgedFact["children"] = children
            facts[0] = forgedFact
            forgedState["parentTurnTerminalFacts"] = facts
            forgedEnvelope["state"] = forgedState
            let forgedURL = directory.appendingPathComponent("wrong-settled-\(claimedOutcome).json")
            try JSONSerialization.data(withJSONObject: forgedEnvelope).write(to: forgedURL)
            #expect(throws: AgentTaskStoreError.persistenceFailed) {
                _ = try AgentTaskStore(persistenceURL: forgedURL)
            }
        }
        #expect(try Data(contentsOf: ledger) == settledBytes)
        let anotherAttempt = AgentExecutionIdentity(turn: execution.turn,
            operationID: "h3b-cancel-retry", attempt: 2)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.recordParentTurnTerminal(
                parent: parent, execution: anotherAttempt, outcome: .timedOut)
        }
        #expect(store.parentTurnTerminalFact(parent: parent, execution: anotherAttempt) == nil)
        let afterFailedWrite = try AgentTaskStore(persistenceURL: ledger)
        #expect(afterFailedWrite.parentTurnTerminalFact(parent: parent, execution: anotherAttempt) == nil)
        #expect(afterFailedWrite.recoveryState(runID: "h3b-unsettled-run") == .needsUserReview)
    }

    @Test("actual parent terminal makes an unclosed child review-only before and after restart")
    func parentTerminalFencesUnsettledChild() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let directory = profile.rootDirectory.appendingPathComponent("h3b-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledger)
        let toolLedger = try ToolExecutionFactLedger(
            persistenceURL: directory.appendingPathComponent("tool-facts.json"))
        let executor = H3BUnsettledChildExecutor(store: store, workingDirectory: directory.path)
        let call = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "h3b-call", "name": OrchestrationToolExecutor.toolName, "input": [:],
        ]]])
        let provider = MockLLMProvider(responses: [String(decoding: call, as: UTF8.self), "parent complete"])
        let controller = TurnController()
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "h3b-parent-conversation", turnID: 1, messageID: "h3b-parent-message"),
            operationID: "h3b-parent-operation", attempt: 1)
        let loop = AgentLoop(maxIterations: 3, approvalGate: ApprovalGate(delegate: H3BApproval()),
            turnController: controller, timeout: 30, taskStore: store,
            toolExecutionFactLedger: toolLedger)
        let result = try await loop.run(messages: [LLMMessage(role: .user, content: "spawn")],
            systemPrompt: nil, provider: provider, toolExecutor: executor,
            tools: [OrchestrationToolExecutor.makeDefinition()],
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                taskID: "h3b-parent-task", actorID: "app"),
            executionIdentity: identity)
        let parent = try #require(executor.parent, "tool messages: \(result.messages.map(\.content))")
        #expect(parent.turnID == "turn-handle:1")
        #expect(store.allReceipts().isEmpty)
        let fact = try #require(store.parentTurnTerminalFact(parent: parent, execution: identity))
        // The accepted orchestration tool fact failed while its child was
        // unsettled. A later plain-text parent message cannot claim success.
        #expect(fact.outcome == .failed)
        #expect(fact.children.count == 1)
        #expect(fact.children.first?.taskID == "h3b-child")
        #expect(fact.children.first?.runID == "h3b-child-run")
        #expect(fact.children.first?.outcome == .needsUserReview)
        #expect(store.recoveryState(runID: "h3b-child-run") == .needsUserReview)
        let reopened = try AgentTaskStore(persistenceURL: ledger)
        #expect(reopened.parentTurnTerminalFact(parent: parent, execution: identity) == fact)
        #expect(reopened.recoveryState(runID: "h3b-child-run") == .needsUserReview)
        #expect(reopened.attempts(runID: "h3b-child-run").count == 1)
        #expect(reopened.allReceipts().isEmpty)
        let originalData = try Data(contentsOf: ledger)
        let originalObject = try JSONSerialization.jsonObject(with: originalData)
        // The real parent producer recorded an unsettled child. A damaged
        // durable join cannot claim a terminal child without its receipt.
        for claimedOutcome in ["succeeded", "failed", "cancelled"] {
            var forgedEnvelope = try #require(originalObject as? [String: Any])
            var forgedState = try #require(forgedEnvelope["state"] as? [String: Any])
            var facts = try #require(forgedState["parentTurnTerminalFacts"] as? [[String: Any]])
            var forgedFact = try #require(facts.first)
            var children = try #require(forgedFact["children"] as? [[String: Any]])
            var forgedChild = try #require(children.first)
            forgedChild["outcome"] = claimedOutcome
            children[0] = forgedChild
            forgedFact["children"] = children
            facts[0] = forgedFact
            forgedState["parentTurnTerminalFacts"] = facts
            forgedEnvelope["state"] = forgedState
            let forgedURL = directory.appendingPathComponent("forged-\(claimedOutcome).json")
            try JSONSerialization.data(withJSONObject: forgedEnvelope).write(to: forgedURL)
            #expect(throws: AgentTaskStoreError.persistenceFailed) {
                _ = try AgentTaskStore(persistenceURL: forgedURL)
            }
        }
        #expect(try Data(contentsOf: ledger) == originalData)
        var legacyEnvelope = try #require(originalObject as? [String: Any])
        var legacyState = try #require(legacyEnvelope["state"] as? [String: Any])
        legacyState.removeValue(forKey: "parentTurnTerminalFacts")
        legacyEnvelope["state"] = legacyState
        let legacyURL = directory.appendingPathComponent("legacy-tasks.json")
        try JSONSerialization.data(withJSONObject: legacyEnvelope).write(to: legacyURL)
        let legacy = try AgentTaskStore(persistenceURL: legacyURL)
        #expect(legacy.parentTurnTerminalFact(parent: parent, execution: identity) == nil)
        #expect(legacy.recoveryState(runID: "h3b-child-run") == .needsUserReview)
    }
}
