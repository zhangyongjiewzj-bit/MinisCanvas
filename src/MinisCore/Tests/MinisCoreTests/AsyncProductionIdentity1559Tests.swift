import Foundation
import Testing
@testable import MinisCore

@Suite("D-ASYNC1/3 production identity and late diagnostic")
struct AsyncProductionIdentity1559Tests {
    @Test("one production request retains Session Turn Run Task Attempt Effect identity")
    func productionRequestIdentityReachesToolFactAndReopen() async throws {
        actor Approval: ApprovalDelegate {
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                ApprovalDecision(approved: true, confirmed: true,
                    requestID: request.requestID, bindingDigest: request.identityDigest)
            }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("async1559-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "1559-source")
        let taskURL = root.appendingPathComponent("tasks.json")
        let factURL = root.appendingPathComponent("facts.json")
        let tasks = try AgentTaskStore(persistenceURL: taskURL)
        let ledger = try ToolExecutionFactLedger(persistenceURL: factURL)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id,
            conversationID: source.id, taskID: "1559-parent", actorID: "test")
            .makeIdentity(using: turn)
        let input = root.appendingPathComponent("input.txt")
        try "async1559 effect\n".write(to: input, atomically: true, encoding: .utf8)
        let callData = try JSONSerialization.data(withJSONObject: [
            "tool_calls": [["id": "1559-effect", "name": "file_read", "input": ["path": input.path]]]
        ])
        let provider = ScriptedChildProvider(responses: [String(decoding: callData, as: UTF8.self), "done"])
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let reader = ScopedForwardingExecutor(base: builtin)
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3,
            provider: provider, toolExecutor: reader,
            approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: Approval()),
            turnController: controller, makeLoopDetector: { nil }, currentConversationID: source.id,
            taskStore: tasks, sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_read"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: builtin),
            concreteBuiltinToolExecutorOwner: builtin)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "1559-child",
            title: "read", instructions: "read input", requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"],
                allowedReadRoots: [root.path]))], strategy: .sequential)
        #expect(reports.first?.result.isSuccess == true)
        #expect(reader.invokedNames == ["file_read"])

        let receipt = try #require(tasks.allReceipts().first)
        let envelope = try #require(receipt.childResultEnvelope)
        let locator = try #require(envelope.childTranscriptLocator)
        let task = try #require(tasks.taskSnapshot(runID: receipt.runID))
        let run = try #require(tasks.historicalRunIdentity(
            runID: receipt.runID, taskID: receipt.taskID, parentID: parent.taskID))
        let attempt = try #require(tasks.attempt(runID: receipt.runID, attemptID: receipt.attemptID))
        let fact = try #require(ledger.facts.first)
        let effect = try #require(fact.executionIdentity)
        let key = try #require(fact.compositeKey)
        #expect(tasks.allReceipts().count == 1 && ledger.facts.count == 1)
        #expect(parent.sessionID == source.id && parent.turnID == "turn-handle:\(turn.turnID)")
        #expect(task.parentRuntimeIdentity == parent && task.sourceSessionID == source.id)
        #expect(task.taskID == locator.taskID && task.parentID == parent.taskID)
        #expect(run.runID == locator.runID && run.taskID == task.taskID)
        #expect(attempt.runID == run.runID && attempt.attemptID == locator.attemptID)
        #expect(receipt.runID == run.runID && receipt.attemptID == attempt.attemptID)
        #expect(envelope.runID == run.runID && envelope.attemptID == attempt.attemptID)
        #expect(envelope.childExecutionID == locator.childExecutionID)
        #expect(locator.parentSessionID == source.id && locator.childSessionID != source.id)
        #expect(fact.parentRuntimeIdentity == parent && fact.childTranscriptLocator == locator)
        #expect(effect.turn.sessionID == locator.childSessionID)
        #expect(key.sessionID == effect.turn.sessionID && key.turnID == effect.turn.turnID)
        #expect(key.messageID == effect.turn.messageID && key.messageID == task.taskID)
        #expect(key.operationID == effect.operationID)
        #expect(key.attemptID == fact.attemptID && key.attemptNumber == effect.attempt)
        #expect(key.toolCallID == fact.toolCallID && fact.toolCallID == "1559-effect")
        #expect(fact.attemptID != attempt.attemptID)

        let reopenedTasks = try AgentTaskStore(persistenceURL: taskURL)
        let reopenedFacts = try ToolExecutionFactLedger(persistenceURL: factURL)
        #expect(reopenedTasks.receipt(runID: run.runID) == receipt)
        #expect(reopenedTasks.taskSnapshot(runID: run.runID)?.parentRuntimeIdentity == parent)
        #expect(reopenedFacts.facts == [fact])
    }

    @Test("late result after production turn cancellation or revoke enters diagnostics only", arguments: [false, true])
    func stoppedProductionTurnKeepsTerminalReceiptAndRecordsLateIdentity(revoke: Bool) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("async1559-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let taskURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: taskURL)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: "1559-cancel-source",
            conversationID: "1559-cancel-source", taskID: "1559-cancel-parent", actorID: "test")
            .makeIdentity(using: turn)
        if revoke { await turn.revoke() } else { await turn.interrupt() }
        let provider = ScriptedChildProvider(responses: ["unreachable"])
        let orchestrator = AgentOrchestrator(provider: provider,
            toolExecutor: NoopToolExecutor(), currentConversationID: parent.conversationID,
            taskStore: store, parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name,
                modelID: provider.model.id, configurationFingerprint: "1559-frozen",
                conversationID: parent.conversationID),
            parentRuntimeIdentity: parent, parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools],
                allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: provider.capabilities)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "1559-cancel-child",
            title: "cancelled", instructions: "must not run")], strategy: .sequential)
        #expect(reports.first?.result.isSuccess == false)
        #expect(provider.receivedRequests.isEmpty)
        let receipt = try #require(store.allReceipts().first)
        #expect(receipt.outcome == .cancelled)
        let terminalEvents = store.events(runID: receipt.runID)
        let late = ChildResultEnvelope(taskID: receipt.taskID, runID: receipt.runID,
            attemptID: receipt.attemptID, parentContextSnapshotID: receipt.parentContextSnapshotID,
            childExecutionID: "1559-late-execution", outcome: .succeeded,
            resultDigest: "secret-result-must-not-enter-diagnostics")
        #expect(throws: AgentTaskStoreError.childResultCancelled) {
            try store.settleChildResult(late)
        }
        let diagnostic = try #require(store.rejectedChildResultDiagnostics(runID: receipt.runID).first)
        #expect(diagnostic.taskID == receipt.taskID && diagnostic.runID == receipt.runID)
        #expect(diagnostic.attemptID == receipt.attemptID)
        #expect(diagnostic.childExecutionID == late.childExecutionID)
        #expect(diagnostic.reason == .cancelled)
        #expect(store.receipt(runID: receipt.runID) == receipt)
        #expect(store.events(runID: receipt.runID) == terminalEvents)
        #expect(store.taskSnapshot(runID: receipt.runID)?.status == .cancelled)

        let reopened = try AgentTaskStore(persistenceURL: taskURL)
        #expect(reopened.receipt(runID: receipt.runID) == receipt)
        #expect(reopened.events(runID: receipt.runID) == terminalEvents)
        #expect(reopened.rejectedChildResultDiagnostics(runID: receipt.runID) == [diagnostic])
        let persisted = try String(contentsOf: taskURL, encoding: .utf8)
        #expect(!persisted.contains("secret-result-must-not-enter-diagnostics"))
    }
}
