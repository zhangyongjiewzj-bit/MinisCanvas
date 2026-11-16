import Foundation
import Testing
@testable import MinisCore

private struct NestedReceiptNoEffectExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.toolNotConfigured("synthetic-no-effect")
    }
}

private struct NestedReceiptFixture: Sendable {
    let directory: URL
    let snapshot: ComposerSubmissionSnapshot
    let ledger: ToolExecutionFactLedger
    let receipt: ToolExecutionReceipt

    init(tool: String = OrchestrationToolExecutor.toolName) throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nested-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshot = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task",
            messageID: "synthetic-message", workspaceID: "synthetic-workspace",
            createdAt: Date(), policyRevision: "v1", autonomyCeiling: .l3)
        ledger = try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json"))
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: snapshot.sessionID,
            turnID: snapshot.turnID, messageID: snapshot.messageID), operationID: "synthetic-operation", attempt: 1)
        receipt = try ledger.mint(toolCallID: "parent", toolName: tool,
            attemptID: try #require(AgentToolExecutionAttemptID.canonical(executionIdentity: identity,
                composerSnapshot: snapshot, childBoundary: nil)),
            attemptNumber: 1, executionIdentity: identity)
    }
}

@Suite("Nested shell durable receipt bridge synthetic contract")
struct NestedShellReceiptBridgeTests {
    @Test func nestedReceiptIsFreshSettledAndParentContextRestoredWithReplayDenied() async throws {
        let f = try NestedReceiptFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let input = try ComposerToolInput(["command": "git status --short", "cwd": f.directory.path])
        try await ToolExecutionReceiptContext.$current.withValue(f.receipt) {
        try await ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
            let parent = try NestedShellReceiptBridge.captureParent(snapshot: f.snapshot, callID: "nested")
            let result = try await NestedShellReceiptBridge.execute(parent: parent, callID: "nested",
                input: input, executor: NestedReceiptNoEffectExecutor()) {
                let nested = try #require(ToolExecutionReceiptContext.current)
                #expect(nested.toolName == "shell_execute")
                #expect(nested.toolCallID == "nested")
                #expect(nested.receiptID != f.receipt.receiptID)
                #expect(nested.executionIdentity == f.receipt.executionIdentity)
                #expect(nested.attemptID == f.receipt.attemptID)
                #expect(ToolExecutionReceiptContext.ledger === f.ledger)
                return "synthetic-result"
            }
            #expect(result == "synthetic-result")
            #expect(ToolExecutionReceiptContext.current == f.receipt)
            #expect(f.ledger.pendingReceipts == [f.receipt])
            #expect(f.ledger.facts.filter { $0.toolCallID == "nested" }.first?.status == .succeeded)
            await #expect(throws: ToolExecutionFactLedgerError.self) {
                _ = try await NestedShellReceiptBridge.execute(parent: parent, callID: "nested",
                    input: input, executor: NestedReceiptNoEffectExecutor()) {
                    Issue.record("duplicate nested call must not execute")
                    return "unexpected"
                }
            }
        }
        }
        #expect(ToolExecutionReceiptContext.current == nil)
    }

    @Test func missingForeignOrSettledParentCannotMintNestedReceipt() async throws {
        let f = try NestedReceiptFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(throws: ToolExecutionFactLedgerError.self) {
            try NestedShellReceiptBridge.captureParent(snapshot: f.snapshot, callID: "nested")
        }
        try ToolExecutionReceiptContext.$current.withValue(f.receipt) {
        try ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
            let foreign = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
                sessionID: "foreign", turnID: 1, taskID: "task", messageID: "message",
                workspaceID: "workspace", createdAt: Date(), policyRevision: "v1", autonomyCeiling: .l3)
            #expect(throws: ComposerAuthorizationError.self) {
                try NestedShellReceiptBridge.captureParent(snapshot: foreign, callID: "nested")
            }
            _ = try f.ledger.settle(f.receipt, status: .succeeded)
            #expect(throws: ToolExecutionFactLedgerError.self) {
                try NestedShellReceiptBridge.captureParent(snapshot: f.snapshot, callID: "nested")
            }
        }
        }
        #expect(f.ledger.facts.count == 1)
    }

    @Test func wrongToolOrNondurableLedgerCannotBorrowParentAuthority() throws {
        let f = try NestedReceiptFixture(tool: "file_read")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        ToolExecutionReceiptContext.$current.withValue(f.receipt) {
        ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
            #expect(throws: ToolExecutionFactLedgerError.self) {
                try NestedShellReceiptBridge.captureParent(snapshot: f.snapshot, callID: "nested")
            }
        }
        }
        #expect(f.ledger.facts.isEmpty)
        let memory = ToolExecutionFactLedger()
        // Nondurable authority now fails at mint, before a parent receipt can
        // exist for captureParent. Keep this ledger in memory as the negative control.
        #expect(throws: ToolExecutionFactLedgerError.durableAuthorityRequired) {
            _ = try memory.mint(toolCallID: "parent", toolName: OrchestrationToolExecutor.toolName,
                attemptID: f.receipt.attemptID, attemptNumber: f.receipt.attemptNumber,
                executionIdentity: f.receipt.executionIdentity)
        }
        #expect(memory.pendingReceipts.isEmpty)
        #expect(memory.facts.isEmpty)
    }

    @Test func cancellationSettlesOnlyNestedReceiptAndRestoresParent() async throws {
        let f = try NestedReceiptFixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await ToolExecutionReceiptContext.$current.withValue(f.receipt) {
        try await ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
            let parent = try NestedShellReceiptBridge.captureParent(snapshot: f.snapshot, callID: "cancelled")
            await #expect(throws: CancellationError.self) {
                _ = try await NestedShellReceiptBridge.execute(parent: parent, callID: "cancelled",
                    input: ComposerToolInput(["command": "git status", "cwd": f.directory.path]),
                    executor: NestedReceiptNoEffectExecutor()) { throw CancellationError() }
            }
            #expect(f.ledger.facts.first?.status == .cancelled)
            #expect(f.ledger.pendingReceipts == [f.receipt])
            #expect(ToolExecutionReceiptContext.current == f.receipt)
        }
        }
    }
}
