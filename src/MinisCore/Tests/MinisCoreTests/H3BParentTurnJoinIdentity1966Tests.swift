import Foundation
import Testing
@testable import MinisCore

@Suite("H3B durable parent turn join identity")
struct H3BParentTurnJoinIdentity1966Tests {
    @Test("Composer's durable turn binds a different local cancellation handle without accepting a foreign operation")
    func composerTurnAndLocalHandleStayBoundAfterReopen() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("h3b-composer-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let sessionID = "h3b-composer-session"
        let attemptID = "123E4567-E89B-12D3-A456-426614174000"
        let messageID = "123E4567-E89B-12D3-A456-426614174001"
        let parent = ParentRuntimeIdentity(sessionID: sessionID, conversationID: sessionID,
            turnID: "turn-handle:\(turn.turnID)",
            taskID: "chat:\(sessionID):0:\(attemptID)", actorID: "app")
        let binding = ParentContextSnapshotV1(providerID: "owned-provider", modelID: "owned-model",
            configurationFingerprint: "owned-fingerprint", conversationID: sessionID)
        let goal = GoalEnvelope(scopeID: "h3b-composer-parent-scope",
            allowedCapabilities: ["orchestrate"], budget: 10,
            deadline: Date().addingTimeInterval(60))
        let child = try ChildRuntimeIdentity.derive(parent: parent,
            childSessionID: "h3b-composer-child-session", childTaskID: "h3b-composer-child",
            scopeID: "h3b-composer-child-scope", requestedCapabilities: [.streaming],
            parentCapabilities: [.streaming], policyCapabilities: [.streaming],
            providerSnapshot: binding, memoryScopeID: "h3b-composer-memory",
            workingDirectory: root.path, cancelGeneration: turn.turnID,
            evidenceRoot: "h3b-composer-evidence", parentTurnHandle: turn,
            childExecutionID: "h3b-composer-child-execution", parentGoal: goal)
        _ = try store.enqueue(taskID: child.childTaskID, parentID: parent.taskID,
            providerID: binding.providerID, modelID: binding.modelID,
            parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
        _ = try store.startRun(taskID: child.childTaskID, parentID: parent.taskID,
            runID: "h3b-composer-child-run")
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: sessionID, turnID: 0, messageID: messageID),
            operationID: "chat:\(sessionID):0:\(messageID)", attempt: 1)
        let foreign = AgentExecutionIdentity(turn: execution.turn,
            operationID: "chat:\(sessionID):0:123E4567-E89B-12D3-A456-426614174002", attempt: 1)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.recordParentTurnTerminal(parent: parent, execution: foreign,
                outcome: .succeeded)
        }
        // Even an execution whose durable turn number happens to equal the
        // local handle cannot claim this Composer turn by that coincidence.
        let coincidentHandle = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: sessionID, turnID: turn.turnID,
            messageID: "123E4567-E89B-12D3-A456-426614174003"),
            operationID: "chat:\(sessionID):\(turn.turnID):123E4567-E89B-12D3-A456-426614174003",
            attempt: 1)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.recordParentTurnTerminal(parent: parent,
                execution: coincidentHandle, outcome: .succeeded)
        }
        let recorded = try #require(try store.recordParentTurnTerminal(
            parent: parent, execution: execution, outcome: .succeeded))
        #expect(recorded.children.count == 1)
        #expect(recorded.children.first?.outcome == .needsUserReview)
        let secondMessage = "123E4567-E89B-12D3-A456-426614174004"
        let secondExecution = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: sessionID, turnID: 0, messageID: secondMessage),
            operationID: "chat:\(sessionID):0:\(secondMessage)", attempt: 1)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.recordParentTurnTerminal(parent: parent,
                execution: secondExecution, outcome: .succeeded)
        }
        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.parentTurnTerminalFact(parent: parent, execution: execution) == recorded)
        #expect(reopened.recoveryState(runID: "h3b-composer-child-run") == .needsUserReview)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any])
        var state = try #require(envelope["state"] as? [String: Any])
        var facts = try #require(state["parentTurnTerminalFacts"] as? [[String: Any]])
        var fact = try #require(facts.first)
        var claimedExecution = try #require(fact["execution"] as? [String: Any])
        claimedExecution["operationID"] = foreign.operationID
        fact["execution"] = claimedExecution
        facts[0] = fact
        state["parentTurnTerminalFacts"] = facts
        envelope["state"] = state
        let tamperedURL = root.appendingPathComponent("foreign-operation.json")
        try JSONSerialization.data(withJSONObject: envelope).write(to: tamperedURL)
        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: tamperedURL)
        }
    }

    @Test("a child join belongs to its exact parent turn at write and recovery")
    func foreignTurnCannotClaimPersistedChildJoin() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("h3b-turn-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = ParentRuntimeIdentity(sessionID: "h3b-1966-session",
            conversationID: "h3b-1966-session", turnID: "turn-handle:\(turn.turnID)",
            taskID: "h3b-1966-parent", actorID: "owned-test")
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: parent.sessionID, turnID: turn.turnID,
            messageID: "h3b-1966-message"), operationID: "h3b-1966-operation", attempt: 1)
        let binding = ParentContextSnapshotV1(providerID: "owned-provider", modelID: "owned-model",
            configurationFingerprint: "owned-fingerprint", conversationID: parent.conversationID)
        let goal = GoalEnvelope(scopeID: "h3b-1966-parent-scope",
            allowedCapabilities: ["orchestrate"], budget: 10,
            deadline: Date().addingTimeInterval(60))
        let child = try ChildRuntimeIdentity.derive(parent: parent,
            childSessionID: "h3b-1966-child-session", childTaskID: "h3b-1966-child",
            scopeID: "h3b-1966-child-scope", requestedCapabilities: [.streaming],
            parentCapabilities: [.streaming], policyCapabilities: [.streaming],
            providerSnapshot: binding, memoryScopeID: "h3b-1966-memory",
            workingDirectory: root.path, cancelGeneration: turn.turnID,
            evidenceRoot: "h3b-1966-evidence", parentTurnHandle: turn,
            childExecutionID: "h3b-1966-child-execution", parentGoal: goal)
        _ = try store.enqueue(taskID: child.childTaskID, parentID: parent.taskID,
            providerID: binding.providerID, modelID: binding.modelID,
            parentRuntimeIdentity: parent, childRuntimeIdentity: child, parentGoal: goal)
        _ = try store.startRun(taskID: child.childTaskID, parentID: parent.taskID,
            runID: "h3b-1966-child-run")
        let recorded = try store.recordParentTurnTerminal(
            parent: parent, execution: execution, outcome: .cancelled)
        let joined = try #require(recorded)
        #expect(joined.children.count == 1)
        #expect(joined.children.first?.outcome == .needsUserReview)
        #expect(store.receipt(runID: "h3b-1966-child-run") == nil)
        let bytes = try Data(contentsOf: url)
        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.parentTurnTerminalFact(parent: parent, execution: execution) == joined)
        #expect(reopened.recoveryState(runID: "h3b-1966-child-run") == .needsUserReview)

        // The same session and child run do not authorize a different parent
        // turn to claim this join, even if its execution identity is well formed.
        let foreign = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: parent.sessionID, turnID: turn.turnID + 1,
            messageID: "h3b-1966-foreign-message"),
            operationID: "h3b-1966-foreign-operation", attempt: 1)
        let foreignURL = root.appendingPathComponent("foreign-writer.json")
        try bytes.write(to: foreignURL)
        let foreignStore = try AgentTaskStore(persistenceURL: foreignURL)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try foreignStore.recordParentTurnTerminal(
                parent: parent, execution: foreign, outcome: .succeeded)
        }
        #expect(try Data(contentsOf: foreignURL) == bytes)

        // Recovery must reject the same cross-turn substitution in a durable
        // fact rather than displaying an UNKNOWN child under the wrong turn.
        var envelope = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var state = try #require(envelope["state"] as? [String: Any])
        var facts = try #require(state["parentTurnTerminalFacts"] as? [[String: Any]])
        var fact = try #require(facts.first)
        var claimedExecution = try #require(fact["execution"] as? [String: Any])
        var claimedTurn = try #require(claimedExecution["turn"] as? [String: Any])
        claimedTurn["turnID"] = turn.turnID + 1
        claimedExecution["turn"] = claimedTurn
        fact["execution"] = claimedExecution
        facts[0] = fact
        state["parentTurnTerminalFacts"] = facts
        envelope["state"] = state
        let tamperedURL = root.appendingPathComponent("foreign-recovery.json")
        try JSONSerialization.data(withJSONObject: envelope).write(to: tamperedURL)
        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: tamperedURL)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
