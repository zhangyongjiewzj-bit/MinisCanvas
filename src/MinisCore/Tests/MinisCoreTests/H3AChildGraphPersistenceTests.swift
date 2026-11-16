import Foundation
import Testing
@testable import MinisCore

@Suite("H3A one-level child graph persistence")
struct H3AChildGraphPersistenceTests {
    private func ledger(_ name: String) throws -> (AgentTaskStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("h3a-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tasks.json")
        return (try AgentTaskStore(persistenceURL: url), url, root)
    }

    private func typedParent(_ store: AgentTaskStore) throws {
        let root = ParentRuntimeIdentity(sessionID: "root-session", conversationID: "root-session",
            turnID: "turn-handle:1", taskID: "root", actorID: "app")
        _ = try store.enqueue(taskID: "first-child", parentID: "root",
            providerID: nil, modelID: nil, parentRuntimeIdentity: root)
    }

    @Test func recursiveProductionRequestPersistsExplicitFailureReasonWithoutLaunchingChild() async throws {
        let (store, url, root) = try ledger("recursive-reason")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = ParentRuntimeIdentity(sessionID: "root-session",
            conversationID: "root-session", turnID: "turn-handle:\(turn.turnID)",
            taskID: "root", actorID: "app")
        let goal = GoalEnvelope(scopeID: "parent-scope", allowedCapabilities: ["orchestrate"],
            budget: 1, deadline: Date().addingTimeInterval(60))
        let orchestrator = AgentOrchestrator(
            currentConversationID: "root-session", taskStore: store, parentID: "root",
            parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: turn,
            runtimeMode: .production, childDepth: 1, maxChildDepth: 1
        )
        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(id: "refused-recursive", title: "recursive", instructions: "not launched")
        ], strategy: .sequential)
        #expect(reports.count == 1)
        #expect(reports.first?.result == .failed(error: "MAX_DEPTH_EXCEEDED"))
        #expect(store.snapshot(taskID: "refused-recursive", parentID: "root")?.status == .failed)
        let receipt = try #require(store.allReceipts().first)
        #expect(receipt.childResultEnvelope?.outcome == .failed(reason: "MAX_DEPTH_EXCEEDED"))
        #expect(receipt.childResultEnvelope?.error == "MAX_DEPTH_EXCEEDED")
        #expect(receipt.outcome == .failed(reason: "execution-failed"))
        #expect(store.events(runID: receipt.runID).last?.detail == "execution-failed")
        let reopened = try AgentTaskStore(persistenceURL: url)
        #expect(reopened.allReceipts() == [receipt])
        #expect(reopened.allReceipts().first?.childResultEnvelope?.error == "MAX_DEPTH_EXCEEDED")
        #expect(reopened.snapshot(taskID: "refused-recursive", parentID: "root")?.status == .failed)
    }

    @Test func enqueueRejectsSelfParentAndChildAsParentWithoutChangingLedger() throws {
        let (store, url, root) = try ledger("enqueue")
        defer { try? FileManager.default.removeItem(at: root) }
        try typedParent(store)
        let before = try Data(contentsOf: url)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueue(taskID: "self", parentID: "self", providerID: nil, modelID: nil)
        }
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueue(taskID: "grandchild", parentID: "first-child",
                providerID: nil, modelID: nil)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(store.snapshot(taskID: "grandchild", parentID: "first-child") == nil)
    }

    @Test func lateParentAdmissionCannotTurnAnExistingTaskIntoSecondLevel() throws {
        let (store, url, root) = try ledger("late-parent")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.enqueue(taskID: "descendant", parentID: "first-child",
            providerID: nil, modelID: nil)
        let before = try Data(contentsOf: url)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            try typedParent(store)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func idempotentEnqueueRejectsSelfParentWithoutPersistingCreation() throws {
        let (store, url, root) = try ledger("idempotent-self")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ParentRuntimeIdentity(sessionID: "source-session",
            conversationID: "source-session", turnID: "turn-handle:1",
            taskID: "root", actorID: "app")
        let creation = SessionActionCreationMetadata(scopeID: "source-scope",
            idempotencyKey: "self-creation",
            action: .new(title: "synthetic", source: source))
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            _ = try store.enqueueIdempotent(taskID: "self", parentID: "self",
                providerID: nil, modelID: nil, creation: creation)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func genericTaskCenterControlParentIsNotMistakenForAnAgentChild() throws {
        let (store, url, root) = try ledger("generic-control")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.enqueue(taskID: "control-parent", parentID: "root",
            providerID: nil, modelID: nil)
        _ = try store.enqueue(taskID: "control-child", parentID: "control-parent",
            providerID: nil, modelID: nil)
        #expect(try AgentTaskStore(persistenceURL: url)
            .snapshot(taskID: "control-child", parentID: "control-parent") != nil)
    }

    @Test(arguments: ["self", "child-parent"])
    func reopeningRejectsParseableIllegalGraphWithoutChangingEvidence(_ shape: String) throws {
        let (store, url, root) = try ledger("reopen-\(shape)")
        defer { try? FileManager.default.removeItem(at: root) }
        try typedParent(store)
        _ = try store.enqueue(taskID: "candidate", parentID: "other-root",
            providerID: nil, modelID: nil)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var state = try #require(envelope["state"] as? [String: Any])
        var tasks = try #require(state["tasks"] as? [String: [String: Any]])
        var controls = try #require(state["controlByTaskKey"] as? [String: [String: Any]])
        let oldKey = "other-root\u{1F}candidate"
        let newParent = shape == "self" ? "candidate" : "first-child"
        let newKey = "\(newParent)\u{1F}candidate"
        let removedCandidate = tasks.removeValue(forKey: oldKey)
        var candidate = try #require(removedCandidate)
        candidate["parentID"] = newParent
        tasks[newKey] = candidate
        let removedControl = controls.removeValue(forKey: oldKey)
        var control = try #require(removedControl)
        control["parentID"] = newParent
        controls[newKey] = control
        state["tasks"] = tasks
        state["controlByTaskKey"] = controls
        envelope["state"] = state
        let invalid = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try invalid.write(to: url)

        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == invalid)
    }
}
