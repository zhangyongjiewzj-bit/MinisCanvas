import Foundation
import Testing
@testable import MinisCore

@Suite("D-H2A durable child result parent read")
struct ChildEnvelopeParentReadRestart2323Tests {
    @Test func productionChildTerminalReopensForExactParentWithoutForeignWriteback() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent(
            "child2323-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let provider = H2AParentReadProvider()
        let parentID = "child2323-parent"
        let childID = "child2323-child"
        let conversationID = "child2323-conversation"
        let binding = ParentContextSnapshotV1(
            providerID: provider.name, modelID: provider.model.id,
            configurationFingerprint: "child2323-frozen",
            conversationID: conversationID
        )
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: H2AParentReadExecutor(),
            currentConversationID: conversationID,
            taskStore: store, parentID: parentID, parentBinding: binding,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "child2323-session",
                conversationID: conversationID,
                turnID: "turn-handle:\(turn.turnID)", taskID: parentID, actorID: "test"
            ),
            parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []
            ),
            parentCapabilities: provider.capabilities
        )
        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: childID, title: "owned child", instructions: "complete")],
            strategy: .sequential
        )
        #expect(reports.count == 1 && reports.first?.result.isSuccess == true)
        let receipt = try #require(store.allReceipts().first)
        let envelope = try #require(receipt.childResultEnvelope)
        #expect(envelope.taskID == childID)
        #expect(envelope.taskID == receipt.taskID)
        #expect(envelope.runID == receipt.runID)
        #expect(envelope.attemptID == receipt.attemptID)
        #expect(envelope.parentContextSnapshotID == receipt.parentContextSnapshotID)

        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reopened.allReceipts() == [receipt])
        #expect(reopened.childResultEnvelope(
            taskID: childID, parentID: parentID, runID: receipt.runID
        ) == envelope)
        #expect(reopened.childResultEnvelope(
            taskID: "foreign-child", parentID: parentID, runID: receipt.runID
        ) == nil)
        #expect(reopened.childResultEnvelope(
            taskID: childID, parentID: "foreign-parent", runID: receipt.runID
        ) == nil)
        #expect(reopened.childResultEnvelope(
            taskID: childID, parentID: parentID, runID: "foreign-run"
        ) == nil)
        let before = try Data(contentsOf: ledgerURL)
        for (taskID, runID, attemptID) in [
            ("foreign-child", envelope.runID, envelope.attemptID),
            (envelope.taskID, "foreign-run", envelope.attemptID),
            (envelope.taskID, envelope.runID, envelope.attemptID + "-stale")
        ] {
            let foreign = ChildResultEnvelope(
                taskID: taskID, runID: runID, attemptID: attemptID,
                parentContextSnapshotID: envelope.parentContextSnapshotID,
                childExecutionID: envelope.childExecutionID,
                outcome: envelope.outcome, resultDigest: envelope.resultDigest
            )
            #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
                try reopened.settleChildResult(foreign)
            }
        }
        #expect(try reopened.settleChildResult(envelope) == receipt)
        #expect(try Data(contentsOf: ledgerURL) == before)
        #expect(reopened.allReceipts() == [receipt])
    }
}

private struct H2AParentReadExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String { "ok" }
}

private struct H2AParentReadProvider: LLMProvider {
    let name = "child2323-provider"
    var model = LLMModel(
        id: "child2323-model", displayName: "Owned H2A model", provider: "child2323-provider"
    )
    let capabilities: Set<ProviderCapability> = [.streaming]

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "child complete", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
