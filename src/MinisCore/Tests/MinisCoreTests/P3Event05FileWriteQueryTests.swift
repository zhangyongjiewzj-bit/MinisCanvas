import CryptoKit
import Foundation
import Testing
@testable import MinisCore

struct P3Event05FileWriteQueryTests {
    private func fixture(_ name: String) throws -> (URL, URL, ToolExecutionFactLedger, BuiltinToolExecutor) {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("event5-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("facts.json")
        return (root, journal, try ToolExecutionFactLedger(persistenceURL: journal),
            BuiltinToolExecutor(allowedRoot: root, deniedRoots: []))
    }

    private func mint(_ ledger: ToolExecutionFactLedger, _ call: String) throws -> ToolExecutionReceipt {
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "event5-session", turnID: 1, messageID: "event5-message"),
            operationID: "event5-operation", attempt: 1)
        return try ledger.mint(toolCallID: call, toolName: "file_write", attemptID: "event5-attempt",
            attemptNumber: 1, executionIdentity: identity)
    }

    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Only receipt-bound completion can settle recovered file_write")
    func completedReceipt() async throws {
        let (root, journal, original, executor) = try fixture("completed")
        let target = root.appendingPathComponent("owned.txt")
        let receipt = try mint(original, "A")
        _ = try await executeToolWithTimeout(name: "file_write", timeout: nil,
            receipt: receipt, ledger: original) {
            try await executor.execute(name: "file_write", input: ["path": target.path, "content": "exact A"])
        }
        // Stop before AgentLoop's ordinary settle, then reopen the persisted
        // receipt as a different writer after a simulated process crash.
        let recovered = try ToolExecutionFactLedger(persistenceURL: journal)
        #expect(recovered.recoveredPendingReceipts == [receipt])
        guard case .succeeded(let fact) = executor.queryRecoveredFileWrite(receipt, ledger: recovered) else {
            Issue.record("completed receipt did not reconcile to a fact")
            return
        }
        #expect(fact.receiptID == receipt.receiptID && fact.status == .succeeded)
        #expect(recovered.pendingReceipts.isEmpty && recovered.facts == [fact])
        #expect(try String(contentsOf: target, encoding: .utf8) == "exact A")
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("A")) {
            try mint(recovered, "A")
        }
        #expect(executor.queryRecoveredFileWrite(receipt, ledger: recovered) == .unknown)
    }

    @Test("A dispatch marker and matching bytes from B or an external writer stay UNKNOWN")
    func matchingBytesAreNotAttribution() async throws {
        let (root, journal, original, executor) = try fixture("other-writer")
        let target = root.appendingPathComponent("shared.txt")
        let receiptA = try mint(original, "A")
        try original.prepareFileWrite(receiptA)
        try original.beginFileWrite(receiptA, targetPath: target.path,
            expectedSHA256: hash("same bytes"), beforeSHA256: nil)
        // A never enters its executor. B writes the same target through the real
        // built-in executor under a different durable receipt.
        let receiptB = try mint(original, "B")
        _ = try await executeToolWithTimeout(name: "file_write", timeout: nil,
            receipt: receiptB, ledger: original) {
            try await executor.execute(name: "file_write",
                input: ["path": target.path, "content": "same bytes"])
        }
        _ = try original.settle(receiptB, status: .succeeded)
        let recovered = try ToolExecutionFactLedger(persistenceURL: journal)
        #expect(recovered.recoveredPendingReceipts == [receiptA])
        #expect(executor.queryRecoveredFileWrite(receiptA, ledger: recovered) == .unknown)
        #expect(recovered.pendingReceipts == [receiptA])
        #expect(recovered.facts.first?.receiptID == receiptB.receiptID)
        #expect(try String(contentsOf: target, encoding: .utf8) == "same bytes")

        let external = root.appendingPathComponent("external.txt")
        let receiptC = try mint(recovered, "C")
        try recovered.prepareFileWrite(receiptC)
        try recovered.beginFileWrite(receiptC, targetPath: external.path,
            expectedSHA256: hash("external bytes"), beforeSHA256: nil)
        try "external bytes".write(to: external, atomically: true, encoding: .utf8)
        let next = try ToolExecutionFactLedger(persistenceURL: journal)
        #expect(executor.queryRecoveredFileWrite(receiptC, ledger: next) == .unknown)
        #expect(next.pendingReceipts.contains(receiptC))
    }

    @Test("No dispatch marker is visibly not executed; marker without completion remains UNKNOWN")
    func missingAndIncompleteMarkers() async throws {
        let (root, journal, original, executor) = try fixture("no-effect")
        let neverStarted = try mint(original, "never-started")
        let started = try mint(original, "started")
        let mintedOnly = try mint(original, "minted-only")
        let target = root.appendingPathComponent("untouched.txt")
        // The real built-in enters and durably records no physical dispatch,
        // then its path policy refuses the target before touching a file.
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        await #expect(throws: ToolExecutorError.self) {
            _ = try await executeToolWithTimeout(name: "file_write", timeout: nil,
                receipt: neverStarted, ledger: original) {
                try await executor.execute(name: "file_write",
                    input: ["path": outside.path, "content": "not written"])
            }
        }
        try original.prepareFileWrite(started)
        try original.beginFileWrite(started, targetPath: target.path,
            expectedSHA256: hash("planned"), beforeSHA256: nil)
        let recovered = try ToolExecutionFactLedger(persistenceURL: journal)
        #expect(executor.queryRecoveredFileWrite(neverStarted, ledger: recovered) == .notExecuted)
        #expect(!original.fileWriteWasNeverDispatched(neverStarted))
        #expect(executor.queryRecoveredFileWrite(started, ledger: recovered) == .unknown)
        #expect(executor.queryRecoveredFileWrite(mintedOnly, ledger: recovered) == .unknown)
        let key = try #require(neverStarted.compositeKey)
        let projected = ConversationEventProjection().projectingRecoveredPendingTools(
            [neverStarted], activeExecutions: [], occurredAt: Date(),
            neverDispatchedFileWrites: Set([key]))
        #expect(projected.toolLifecycleEvents.first?.summary.contains("未执行") == true)
        #expect(recovered.pendingReceipts.count == 3 && recovered.facts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("never-started")) {
            try mint(recovered, "never-started")
        }
    }

    @Test("Legacy pending receipts without a dispatch field remain UNKNOWN")
    func legacyPendingIsUnknown() throws {
        let (_, journal, original, executor) = try fixture("legacy")
        let receipt = try mint(original, "legacy")
        try original.prepareFileWrite(receipt)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        object.removeValue(forKey: "unstartedFileWrites")
        try JSONSerialization.data(withJSONObject: object).write(to: journal, options: .atomic)
        let recovered = try ToolExecutionFactLedger(persistenceURL: journal)
        #expect(recovered.recoveredPendingReceipts == [receipt])
        #expect(!recovered.fileWriteWasNeverDispatched(receipt))
        #expect(executor.queryRecoveredFileWrite(receipt, ledger: recovered) == .unknown)
    }
}
