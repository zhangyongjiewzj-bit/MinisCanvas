import CryptoKit
import Foundation
import Testing
@testable import MinisCore

private actor ArtifactEvidenceApproveFileWrite: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true, confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

/// D-ARTIFACTA: the file write and its terminal tool fact must share the
/// actual receipt. These fixtures use a temporary user-workspace analogue.
struct ChatFileArtifactEvidenceTests {
    private func receipt(session: String = "chat-session", call: String = "call-1", attempt: String = "attempt-1") -> ToolExecutionReceipt {
        let key = ToolExecutionCompositeKey(
            sessionID: session, turnID: 1, messageID: "message-1",
            operationID: "operation-1", attemptID: attempt,
            attemptNumber: 1, toolCallID: call
        )
        return ToolExecutionReceipt(
            toolCallID: call, receiptID: "receipt-\(call)",
            toolName: "file_write", attemptID: attempt, attemptNumber: 1,
            compositeKey: key
        )
    }

    private func fact(_ receipt: ToolExecutionReceipt, status: ToolExecutionStatus) -> ToolExecutionFact {
        ToolExecutionFact(
            toolCallID: receipt.toolCallID, receiptID: receipt.receiptID,
            toolName: receipt.toolName, status: status,
            attemptID: receipt.attemptID, attemptNumber: receipt.attemptNumber,
            compositeKey: receipt.compositeKey
        )
    }

    private func fixture() throws -> (BuiltinToolExecutor, FileChangeLedger, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatFileArtifactEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeLedger = ledger
        executor.fileChangeSessionID = "chat-session"
        return (executor, ledger, root)
    }

    @Test func agentLoopToBuiltinWriteToTerminalFactProjectsOneArtifact() async throws {
        let (executor, ledger, root) = try fixture()
        let identity = minisCoreToolContractIdentity(
            "artifact-evidence", sessionID: "chat-session"
        )
        let factLedger = try minisCoreToolContractLedger(at: root)
        let output = root.appendingPathComponent("from-loop.txt")
        let envelope = try JSONSerialization.data(withJSONObject: [
            "tool_calls": [[
                "id": "actual-call", "name": "file_write",
                "input": ["path": output.path, "content": "from actual loop\n"]
            ]]
        ])
        let provider = MockLLMProvider(responses: [
            String(decoding: envelope, as: UTF8.self), "done"
        ])
        let loop = AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(delegate: ArtifactEvidenceApproveFileWrite()),
            turnController: TurnController(),
            timeout: 30,
            toolExecutionFactLedger: factLedger
        )
        let result = try await loop.run(
            messages: [], systemPrompt: "test", provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_write"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "task:\(identity.operationID)", actorID: "test"
            ),
            executionIdentity: identity
        )
        let records = ledger.records(sessionID: "chat-session")
        if records.isEmpty {
            Issue.record("No file record; terminal facts: \(factLedger.facts); messages: \(result.messages)")
        }
        let record = try #require(records.first)
        let fact = try #require(factLedger.facts.first { $0.toolCallID == "actual-call" })
        #expect(fact.status == .succeeded)
        #expect(record.producerReceiptID == fact.receiptID)
        #expect(record.producerCompositeKey == fact.compositeKey)
        let evidence = try #require(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session", fact: fact
        ))
        #expect(evidence.outputSHA256 == SHA256.hash(data: Data("from actual loop\n".utf8))
            .map { String(format: "%02x", $0) }.joined())
    }

    @Test func successfulWriteProjectsOnlyItsExactTerminalFact() async throws {
        let (executor, ledger, root) = try fixture()
        let output = root.appendingPathComponent("note.txt")
        let producer = receipt()
        _ = try await ToolExecutionReceiptContext.$current.withValue(producer) {
            try await executor.execute(
                name: "file_write", input: ["path": output.path, "content": "hello\n"]
            )
        }
        let record = try #require(ledger.records(sessionID: "chat-session").first)
        let evidence = try #require(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(producer, status: .succeeded)
        ))
        let expectedHash = SHA256.hash(data: Data("hello\n".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(evidence.outputSHA256 == expectedHash)
        #expect(evidence.producerAttemptID == producer.attemptID)
        #expect(evidence.producerReceiptID == producer.receiptID)
        #expect(evidence.status == .succeeded)
        #expect(evidence.nextStep == .reviewDiff)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(producer, status: .failed)
        ) == nil)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(producer, status: .cancelled)
        ) == nil)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "other-session",
            fact: fact(producer, status: .succeeded)
        ) == nil)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(receipt(call: "call-2"), status: .succeeded)
        ) == nil)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(receipt(attempt: "attempt-2"), status: .succeeded)
        ) == nil)
    }

    @Test func failedWriteDoesNotRegisterAnArtifact() async throws {
        let (executor, ledger, root) = try fixture()
        let producer = receipt()
        // 缺失的父目录现在会自动创建；父路径是普通文件时写入才会失败。
        try "plain file".write(to: root.appendingPathComponent("not-a-dir"), atomically: true, encoding: .utf8)
        do {
            _ = try await ToolExecutionReceiptContext.$current.withValue(producer) {
                try await executor.execute(
                    name: "file_write",
                    input: ["path": root.appendingPathComponent("not-a-dir/note.txt").path,
                            "content": "never-written"]
                )
            }
            Issue.record("Expected a write failure")
        } catch {
            #expect(ledger.records(sessionID: "chat-session").isEmpty)
        }
    }

    @Test func appendKeepsDiffButCannotClaimRacyOutputHash() async throws {
        let (executor, ledger, root) = try fixture()
        let output = root.appendingPathComponent("binary.dat")
        try Data([0, 1, 2]).write(to: output)
        let producer = receipt()
        _ = try await ToolExecutionReceiptContext.$current.withValue(producer) {
            try await executor.execute(
                name: "file_write",
                input: ["path": output.path, "content": "tail", "append": true]
            )
        }
        let record = try #require(ledger.records(sessionID: "chat-session").first)
        #expect(record.outputSHA256 == nil)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(producer, status: .succeeded)
        ) == nil)
    }

    @Test func sessionSelectionSwitchDoesNotReattributeProducer() async throws {
        let (executor, ledger, root) = try fixture()
        executor.fileChangeSessionID = "other-session"
        let producer = receipt(session: "chat-session")
        _ = try await ToolExecutionReceiptContext.$current.withValue(producer) {
            try await executor.execute(
                name: "file_write",
                input: ["path": root.appendingPathComponent("owned.txt").path,
                        "content": "owned"]
            )
        }
        #expect(ledger.records(sessionID: "other-session").isEmpty)
        let record = try #require(ledger.records(sessionID: "chat-session").first)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(producer, status: .succeeded)
        ) != nil)
    }

    @Test func repeatedSameContentCannotBorrowEarlierAttempt() async throws {
        let (executor, ledger, root) = try fixture()
        let output = root.appendingPathComponent("same.txt")
        let first = receipt(call: "call-1")
        let second = receipt(call: "call-2")
        for producer in [first, second] {
            _ = try await ToolExecutionReceiptContext.$current.withValue(producer) {
                try await executor.execute(
                    name: "file_write", input: ["path": output.path, "content": "same"]
                )
            }
        }
        let record = try #require(ledger.records(sessionID: "chat-session").first)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(first, status: .succeeded)
        ) == nil)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID, sessionID: "chat-session",
            fact: fact(second, status: .succeeded)
        ) != nil)
    }
}
