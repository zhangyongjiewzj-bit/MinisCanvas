import Foundation
import Testing
@testable import MinisCore

@Suite("D-POLICY-03 plan result is not an execution success")
struct P3AcceptanceM07DryRunTerminalTests {
    @Test func planToolCallReturnsErrorClassDryRunWithoutEffectOrFact() async throws {
        let identity = minisCoreToolContractIdentity("plan-terminal-\(UUID().uuidString)")
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .plan,
            approvalScope: .request,
            effort: .standard,
            sessionID: identity.turn.sessionID,
            turnID: identity.turn.turnID,
            taskID: "task:plan-terminal",
            messageID: identity.turn.messageID,
            workspaceID: "synthetic-workspace",
            createdAt: now,
            policyRevision: "facts-1",
            grantEpoch: "epoch-1",
            autonomyCeiling: .l0
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"],
            allowedWriteRoots: ["/synthetic"],
            workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision,
            grantEpoch: snapshot.grantEpoch,
            leaseID: "synthetic-lease",
            expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l0
        )
        let base = RecordingToolExecutor() // records names; never writes the path
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: base,
            controller: ComposerAuthorizationController(
                snapshot: snapshot,
                facts: facts,
                now: { now }
            )
        )
        let callID = "call:\(UUID().uuidString)"
        let callData = try JSONSerialization.data(withJSONObject: [
            "tool_calls": [[
                "id": callID,
                "name": "file_write",
                "input": ["path": "/synthetic/plan.txt", "content": "sample"]
            ]]
        ])
        let envelope = try #require(String(data: callData, encoding: .utf8))
        let ledger = ToolExecutionFactLedger()
        let result = try await AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(),
            toolExecutionFactLedger: ledger
        ).run(
            messages: [],
            systemPrompt: "test",
            provider: ToolApprovalMockLLMProvider(responses: [envelope, "done"]),
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_write"]),
            maxTokens: 1024,
            composerSnapshot: snapshot,
            executionIdentity: identity
        )

        let terminal = result.messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> (String, Bool)? in
            guard case .toolResult(let id, _, let content, let isError, _, _, _, _) = part,
                  id == callID else { return nil }
            return (content, isError)
        }
        #expect(terminal.count == 1)
        #expect(terminal.first?.0.contains("dry-run") == true)
        #expect(terminal.first?.1 == true)
        #expect(base.executedNames.isEmpty)
        #expect(result.toolCallsExecuted == 0)
        #expect(result.toolExecutionFacts.isEmpty)
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
    }
}
