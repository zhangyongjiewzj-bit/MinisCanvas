import Foundation
import Testing
@testable import MinisCore

private actor DoubleClickApprovalDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private actor DoubleClickReceiptStore {
    private(set) var receipts: [ApprovalReceipt] = []

    func append(_ receipt: ApprovalReceipt) {
        receipts.append(receipt)
    }
}

@Suite("D-TOOL-09 repeated approval identity")
struct P3AcceptanceM07ApprovalDoubleClickTests {
    @Test func sameApprovalIDHasOneExecutorEffectAndOneReceipt() async throws {
        let root = try minisCoreToolContractRoot("approval-double-click")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try minisCoreToolContractLedger(at: root)
        let callID = "call:\(UUID().uuidString)"
        let input: [String: Any] = ["path": "/synthetic/no-write", "content": "sample"]
        let envelopeData = try JSONSerialization.data(withJSONObject: [
            "tool_calls": [["id": callID, "name": "file_write", "input": input]]
        ])
        let envelope = try #require(String(data: envelopeData, encoding: .utf8))
        // Separate model turns retain the same approval ID. A single envelope
        // rejects duplicate tool IDs earlier, so it would not exercise replay.
        let provider = ToolApprovalMockLLMProvider(responses: [envelope, envelope, "done"])
        let delegate = DoubleClickApprovalDelegate()
        let receiptStore = DoubleClickReceiptStore()
        let gate = ApprovalGate(
            delegate: delegate,
            onApprovalReceipt: { receipt in await receiptStore.append(receipt) }
        )
        let executor = RecordingToolExecutor() // records names; never writes the path
        let identity = minisCoreToolContractIdentity("double-click-\(UUID().uuidString)")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            turnController: TurnController(),
            loopDetector: nil, // isolate the approval/receipt replay fence
            timeout: 30,
            toolExecutionFactLedger: ledger
        )

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_write"]),
            maxTokens: 1024,
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:double-click",
                actorID: "test"
            ),
            executionIdentity: identity
        )

        #expect(executor.executedNames == ["file_write"])
        #expect(result.toolCallsExecuted == 1)
        let receipts = await receiptStore.receipts
        #expect(receipts.count == 1)
        #expect(receipts.first?.requestID == callID)
        #expect(receipts.first?.identityDigest != nil)
        let requests = await delegate.requests
        #expect(requests.first?.binding != nil)
        #expect(requests.allSatisfy { $0.requestID == callID })

        let outcomes = result.messages.flatMap { $0.toAgentContentParts() }.compactMap { part -> Bool? in
            guard case .toolResult(let id, _, _, let isError, _, _, _, _) = part,
                  id == callID else { return nil }
            return isError
        }
        #expect(outcomes == [false, true])
    }
}
