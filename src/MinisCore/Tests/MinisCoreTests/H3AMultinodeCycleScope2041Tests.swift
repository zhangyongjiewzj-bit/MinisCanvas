import Foundation
import Testing
@testable import MinisCore

@Suite("H3A durable graph cycle and root boundary")
struct H3AMultinodeCycleScope2041Tests {
    private func ledger(_ name: String) throws -> (AgentTaskStore, URL) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("h3a-2041-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tasks.json")
        return (try AgentTaskStore(persistenceURL: url), url)
    }

    @Test("a second generic task cannot close a non-self parent cycle")
    func twoNodeCycleCannotBeEnqueued() throws {
        let (store, url) = try ledger("write-cycle")
        _ = try store.enqueue(taskID: "cycle-A", parentID: "cycle-B",
            providerID: nil, modelID: nil)
        let before = try Data(contentsOf: url)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueue(taskID: "cycle-B", parentID: "cycle-A",
                providerID: nil, modelID: nil)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(store.snapshot(taskID: "cycle-B", parentID: "cycle-A") == nil)
        #expect(try AgentTaskStore(persistenceURL: url)
            .snapshot(taskID: "cycle-A", parentID: "cycle-B") != nil)
    }

    @Test("a third task cannot close an indirect parent cycle")
    func threeNodeCycleCannotBeEnqueued() throws {
        let (store, url) = try ledger("three-node-cycle")
        _ = try store.enqueue(taskID: "cycle-A", parentID: "cycle-B",
            providerID: nil, modelID: nil)
        _ = try store.enqueue(taskID: "cycle-B", parentID: "cycle-C",
            providerID: nil, modelID: nil)
        let before = try Data(contentsOf: url)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueue(taskID: "cycle-C", parentID: "cycle-A",
                providerID: nil, modelID: nil)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(store.snapshot(taskID: "cycle-C", parentID: "cycle-A") == nil)
    }

    @Test("a parseable non-self cycle cannot survive a fresh Store reopen")
    func twoNodeCycleCannotBeRecovered() throws {
        let (store, url) = try ledger("reopen-cycle")
        _ = try store.enqueue(taskID: "cycle-A", parentID: "root",
            providerID: nil, modelID: nil)
        _ = try store.enqueue(taskID: "cycle-B", parentID: "cycle-A",
            providerID: nil, modelID: nil)
        #expect(try AgentTaskStore(persistenceURL: url)
            .snapshot(taskID: "cycle-B", parentID: "cycle-A") != nil)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var state = try #require(document["state"] as? [String: Any])
        var tasks = try #require(state["tasks"] as? [String: [String: Any]])
        var controls = try #require(state["controlByTaskKey"] as? [String: [String: Any]])
        let oldKey = "root\u{1F}cycle-A"
        let newKey = "cycle-B\u{1F}cycle-A"
        var changedTask = try #require(tasks[oldKey])
        tasks.removeValue(forKey: oldKey)
        changedTask["parentID"] = "cycle-B"
        tasks[newKey] = changedTask
        var changedControl = try #require(controls[oldKey])
        controls.removeValue(forKey: oldKey)
        changedControl["parentID"] = "cycle-B"
        controls[newKey] = changedControl
        state["tasks"] = tasks
        state["controlByTaskKey"] = controls
        document["state"] = state
        let invalid = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try invalid.write(to: url)
        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test("same child IDs under a foreign root or Goal cannot replace a durable child")
    func foreignRootAndGoalCannotClaimSameChildIDs() async throws {
        let (store, url) = try ledger("foreign-root")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let turnID = "turn-handle:\(handle.turnID)"
        let root = ParentRuntimeIdentity(sessionID: "h3a-2041-root-A",
            conversationID: "h3a-2041-conversation-A", turnID: turnID,
            taskID: "h3a-2041-parent", actorID: "app")
        let foreign = ParentRuntimeIdentity(sessionID: "h3a-2041-root-B",
            conversationID: "h3a-2041-conversation-B", turnID: turnID,
            taskID: root.taskID, actorID: "app")
        let goal = GoalEnvelope(scopeID: "h3a-2041-scope-A",
            allowedCapabilities: ["orchestrate"], budget: 10,
            deadline: Date().addingTimeInterval(60))
        let foreignGoal = GoalEnvelope(goalID: goal.goalID, scopeID: "h3a-2041-scope-B",
            allowedCapabilities: ["orchestrate"], budget: 10,
            deadline: Date().addingTimeInterval(60))
        let binding = ParentContextSnapshotV1(providerID: "h3a-provider",
            modelID: "h3a-model", configurationFingerprint: "h3a-fingerprint",
            conversationID: root.conversationID)
        let request = SubAgentTask(id: "h3a-2041-child", title: "child",
            instructions: "synthetic", executionID: "h3a-2041-execution")
        let producer = AgentOrchestrator(currentConversationID: root.conversationID,
            taskStore: store, parentID: root.taskID, parentBinding: binding,
            parentRuntimeIdentity: root, parentGoal: goal, parentTurnHandle: handle,
            runtimeMode: .production)
        let child = try producer.makeChildRuntimeIdentity(for: request)
        let admitted = try store.enqueue(taskID: request.id, parentID: root.taskID,
            providerID: binding.providerID, modelID: binding.modelID,
            parentRuntimeIdentity: root, childRuntimeIdentity: child, parentGoal: goal)
        let before = try Data(contentsOf: url)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueue(taskID: request.id, parentID: root.taskID,
                providerID: binding.providerID, modelID: binding.modelID,
                parentRuntimeIdentity: root, childRuntimeIdentity: child,
                parentGoal: foreignGoal)
        }
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueue(taskID: request.id, parentID: root.taskID,
                providerID: binding.providerID, modelID: binding.modelID,
                parentRuntimeIdentity: foreign, childRuntimeIdentity: child,
                parentGoal: goal)
        }
        #expect(try Data(contentsOf: url) == before)
        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.snapshot(taskID: request.id, parentID: root.taskID) == admitted)
        #expect(reopened.snapshot(taskID: request.id, parentID: root.taskID)?.childRuntimeIdentity == child)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try reopened.enqueue(taskID: request.id, parentID: root.taskID,
                providerID: binding.providerID, modelID: binding.modelID,
                parentRuntimeIdentity: root, childRuntimeIdentity: child,
                parentGoal: foreignGoal)
        }
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try reopened.enqueue(taskID: request.id, parentID: root.taskID,
                providerID: binding.providerID, modelID: binding.modelID,
                parentRuntimeIdentity: foreign, childRuntimeIdentity: child,
                parentGoal: goal)
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
