import Testing
@testable import MinisCore

@Suite("Agent context receipt ledger")
struct AgentContextReceiptLedgerTests {
    @Test("attempt IDs are canonicalized and same identity cannot reuse the current attempt")
    func canonicalAttemptIDAndRecoveryFence() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }
        let identity = try makeIdentity(parentTurn: parentTurn, execution: "canonical")
        let ledger = AgentChildReceiptLedger()

        #expect(await ledger.begin(identity: identity, attemptID: "  attempt-1  "))
        #expect(await ledger.snapshot()?.attemptID == "attempt-1")
        #expect(await ledger.settle(
            identity: identity,
            attemptID: "attempt-1",
            outcome: .failed,
            detail: "failed"
        ))
        #expect(await ledger.recover(from: identity, nextAttemptID: " attempt-1 ") == false)
    }

    @Test("retired attempt IDs are scoped to the child identity")
    func sameAttemptIDCanBelongToAnotherChild() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }
        let first = try makeIdentity(parentTurn: parentTurn, execution: "first")
        let second = try makeIdentity(parentTurn: parentTurn, execution: "second")
        let ledger = AgentChildReceiptLedger()

        #expect(await ledger.begin(identity: first, attemptID: "shared-attempt"))
        #expect(await ledger.cancel(identity: first, attemptID: "shared-attempt"))
        #expect(await ledger.recover(from: first, nextAttemptID: "next-attempt"))
        #expect(await ledger.begin(identity: second, attemptID: "shared-attempt"))
        #expect(await ledger.settle(
            identity: second,
            attemptID: "shared-attempt",
            outcome: .succeeded
        ))
    }

    private func makeIdentity(
        parentTurn: TurnController.TurnHandle,
        execution: String
    ) throws -> ChildRuntimeIdentity {
        try ChildRuntimeIdentity.derive(
            parent: ParentRuntimeIdentity(
                sessionID: "receipt-parent-session",
                conversationID: "receipt-parent-conversation",
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "receipt-parent-task",
                actorID: "receipt-test"
            ),
            childSessionID: "receipt-child-session-\(execution)",
            childTaskID: "receipt-child-task-\(execution)",
            scopeID: "receipt-scope-\(execution)",
            requestedCapabilities: [.tools],
            parentCapabilities: [.streaming, .tools],
            policyCapabilities: [.streaming, .tools],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "receipt-provider",
                modelID: "receipt-model",
                configurationFingerprint: "receipt-fingerprint",
                conversationID: "receipt-parent-conversation"
            ),
            memoryScopeID: "receipt-memory-\(execution)",
            workingDirectory: "/tmp/receipt-ledger",
            cancelGeneration: parentTurn.turnID,
            evidenceRoot: "receipt-evidence-\(execution)",
            parentTurnHandle: parentTurn,
            childExecutionID: execution
        )
    }
}
