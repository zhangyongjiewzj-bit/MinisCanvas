import Foundation
import Testing
@testable import MinisCore

private actor UnconfirmedApprovalDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: true,
            confirmed: false,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

@Suite("D-TOOL-06 second confirmation terminal")
struct P3AcceptanceM07SecondConfirmationTerminalTests {
    @Test func manualApprovalWithoutSecondConfirmationIsAnErrorBeforeEffect() async throws {
        let identity = minisCoreToolContractIdentity("second-confirmation-\(UUID().uuidString)")
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: identity.turn.sessionID,
            turnID: identity.turn.turnID,
            taskID: "task:second-confirmation",
            messageID: identity.turn.messageID,
            workspaceID: "synthetic-workspace",
            createdAt: now,
            policyRevision: "facts-1",
            grantEpoch: "epoch-1",
            bypassModeConfirmed: false,
            autonomyCeiling: .l3
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
            autonomyCeiling: .l3
        )
        let delegate = UnconfirmedApprovalDelegate()
        let gate = ApprovalGate(delegate: delegate)
        let base = RecordingToolExecutor() // no filesystem effect
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: base,
            controller: ComposerAuthorizationController(
                snapshot: snapshot,
                facts: facts,
                now: { now }
            ),
            approvalGate: gate
        )
        let callID = "call:\(UUID().uuidString)"
        let callData = try JSONSerialization.data(withJSONObject: [
            "tool_calls": [[
                "id": callID,
                "name": "file_write",
                "input": ["path": "/synthetic/unconfirmed.txt", "content": "sample"]
            ]]
        ])
        let envelope = try #require(String(data: callData, encoding: .utf8))
        let ledger = ToolExecutionFactLedger()
        let result = try await AgentLoop(
            maxIterations: 2,
            approvalGate: gate,
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

        let requests = await delegate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.requestID == callID)
        #expect(requests.first?.requiresSecondConfirmation == true)
        #expect(requests.first?.identityDigest != nil)
        let errors = result.messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> Bool? in
            guard case .toolResult(let id, _, _, let isError, _, _, _, _) = part,
                  id == callID else { return nil }
            return isError
        }
        #expect(errors == [true])
        #expect(base.executedNames.isEmpty)
        #expect(result.toolCallsExecuted == 0)
        #expect(result.toolExecutionFacts.isEmpty)
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
    }
}
