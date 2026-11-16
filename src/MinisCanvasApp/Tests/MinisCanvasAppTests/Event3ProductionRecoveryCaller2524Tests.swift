import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private enum Event3CompletedWriteProducer {
    nonisolated static func write(root: URL, target: URL, receipt: ToolExecutionReceipt,
                                  ledger: ToolExecutionFactLedger) async throws {
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        _ = try await executeToolWithTimeout(name: "file_write", timeout: nil,
            receipt: receipt, ledger: ledger) {
            try await executor.execute(name: "file_write", input: [
                "path": target.path, "content": "owned exact completion"
            ])
        }
    }
}

@Suite("EVENT3 production recovery caller")
@MainActor
struct Event3ProductionRecoveryCaller2524Tests {
    @Test("Bridge attach settles only an exactly completed recovered write")
    func bridgeAttachReconcilesExactReceiptWithoutSettlingUnknownPeers() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("event3-caller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factURL = root.appendingPathComponent("tool-execution-facts-v4.json")
        let original = try ToolExecutionFactLedger(persistenceURL: factURL)
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "event3-session", turnID: 1, messageID: "event3-message"),
            operationID: "event3-operation", attempt: 1
        )
        func mint(_ name: String, tool: String) throws -> ToolExecutionReceipt {
            try original.mint(toolCallID: name, toolName: tool,
                attemptID: "event3-attempt", attemptNumber: 1, executionIdentity: identity)
        }

        let completed = try mint("completed", tool: "file_write")
        let target = root.appendingPathComponent("completed.txt")
        #expect(try String(contentsOf: factURL, encoding: .utf8).contains(completed.receiptID))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try await Event3CompletedWriteProducer.write(root: root, target: target,
            receipt: completed, ledger: original)
        // The real executor wrote and durably marked completion, but a crash
        // before AgentLoop settlement left its original submitted receipt.
        #expect(original.pendingReceipts.contains(completed))
        #expect(original.facts.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == "owned exact completion")

        let unknownWrite = try mint("unknown", tool: "file_write")
        let foreignRead = try mint("foreign", tool: "file_read")
        #expect(original.pendingReceipts.count == 3)
        let bridge = BridgeStore(
            preferencesDefaults: UserDefaults(suiteName: profile.userDefaultsSuiteName),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            sessionStore: SessionStore(directory: root)
        )
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: root,
            externalRunners: [:], externalNetworkAllowed: false
        ).value
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let recovered = engine.toolExecutionFactLedger
        // The production composition root owns the asynchronous recovery call;
        // this test does not invoke ChatStore.reconcileRecoveredFileWrites.
        for _ in 0..<200 {
            if recovered.facts.contains(where: { $0.receiptID == completed.receiptID }),
               bridge.chat.conversationEventProjection.toolLifecycleEvents.contains(where: {
                   $0.receiptID == completed.receiptID && $0.status == .succeeded
               }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fact = try #require(recovered.facts.first { $0.receiptID == completed.receiptID })
        #expect(fact.status == .succeeded)
        #expect(fact.compositeKey == completed.compositeKey)
        #expect(recovered.pendingReceipts.contains(unknownWrite))
        #expect(recovered.pendingReceipts.contains(foreignRead))
        #expect(recovered.facts.count == 1)
        let rows = bridge.chat.conversationEventProjection.toolLifecycleEvents
        #expect(rows.first { $0.toolCompositeKey == completed.compositeKey }?.status == .succeeded)
        #expect(rows.first { $0.toolCompositeKey == completed.compositeKey }?.receiptID == completed.receiptID)
        #expect(rows.first { $0.toolCompositeKey == unknownWrite.compositeKey }?.status == .needsReview)
        #expect(rows.first { $0.toolCompositeKey == foreignRead.compositeKey }?.status == .needsReview)
    }
}
