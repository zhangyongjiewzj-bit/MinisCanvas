import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// D-ARTIFACTA: the ordinary Chat producer is the existing
/// FileChangeRecord + ToolExecutionFact join. This test deliberately reads
/// session/turn from the canonical composite key instead of introducing a
/// second artifact identity record.
struct ArtifactAOrdinaryChatJoinContractTests {
    private func receipt(
        sessionID: String = "artifacta-session",
        turnID: Int = 7,
        callID: String = "artifacta-call",
        attemptID: String = "artifacta-attempt"
    ) -> ToolExecutionReceipt {
        ToolExecutionReceipt(
            toolCallID: callID,
            receiptID: "receipt-\(callID)",
            toolName: "file_write",
            attemptID: attemptID,
            attemptNumber: 1,
            compositeKey: ToolExecutionCompositeKey(
                sessionID: sessionID,
                turnID: turnID,
                messageID: "artifacta-message",
                operationID: "artifacta-operation",
                attemptID: attemptID,
                attemptNumber: 1,
                toolCallID: callID
            )
        )
    }

    private func fact(
        receipt: ToolExecutionReceipt,
        status: ToolExecutionStatus
    ) -> ToolExecutionFact {
        ToolExecutionFact(
            toolCallID: receipt.toolCallID,
            receiptID: receipt.receiptID,
            toolName: receipt.toolName,
            status: status,
            attemptID: receipt.attemptID,
            attemptNumber: receipt.attemptNumber,
            compositeKey: receipt.compositeKey
        )
    }

    @Test("successful ordinary Chat join exposes canonical provenance without a second identity")
    func successfulJoinProjectsSessionTurnAndNextStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacta-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let content = "artifacta success\n"
        let producer = receipt()
        let record = try ledger.register(
            sessionID: "artifacta-session",
            path: root.appendingPathComponent("result.txt").path,
            kind: .created,
            oldContent: nil,
            newContent: content,
            producerReceipt: producer,
            verifiedOutputContent: content
        )
        let terminal = fact(receipt: producer, status: .succeeded)
        let projected = AgentOutputLedgerCardAdapter.fileArtifacts(
            sessionID: "artifacta-session",
            ledger: ledger,
            facts: [terminal],
            limit: 10
        )
        let artifact = try #require(projected.first)
        #expect(projected.count == 1)
        #expect(record.producerCompositeKey?.sessionID == "artifacta-session")
        #expect(record.producerCompositeKey?.turnID == 7)
        #expect(artifact.producerReceiptID == producer.receiptID)
        #expect(artifact.producerAttemptID == producer.attemptID)
        #expect(artifact.producerToolCallID == producer.toolCallID)
        #expect(artifact.status == .succeeded)
        #expect(artifact.nextStep == .reviewDiff)
        #expect(ledger.record(diffID: record.diffID, sessionID: "other-session") == nil)
    }

    @Test("failed terminal fact and failed write with no record produce no ordinary Chat artifact")
    func failedJoinNeverProjectsArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacta-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let content = "artifacta failed\n"
        let producer = receipt(callID: "artifacta-failed-call")
        let record = try ledger.register(
            sessionID: "artifacta-session",
            path: root.appendingPathComponent("failed.txt").path,
            kind: .created,
            oldContent: nil,
            newContent: content,
            producerReceipt: producer,
            verifiedOutputContent: content
        )
        let failed = fact(receipt: producer, status: .failed)
        #expect(ledger.artifactEvidence(
            diffID: record.diffID,
            sessionID: "artifacta-session",
            fact: failed
        ) == nil)
        #expect(AgentOutputLedgerCardAdapter.fileArtifacts(
            sessionID: "artifacta-session",
            ledger: ledger,
            facts: [failed],
            limit: 10
        ).isEmpty)
        #expect(AgentOutputLedgerCardAdapter.fileArtifacts(
            sessionID: "artifacta-session",
            ledger: ledger,
            facts: [],
            limit: 10
        ).isEmpty)
    }
}
