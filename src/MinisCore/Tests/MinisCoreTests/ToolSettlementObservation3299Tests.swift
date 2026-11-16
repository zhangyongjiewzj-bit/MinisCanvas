import Foundation
import Testing
@testable import MinisCore

private final class Settlement3299Values: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ToolExecutionFact] = []
    func record(_ value: ToolExecutionFact) { lock.withLock { values.append(value) } }
    var facts: [ToolExecutionFact] { lock.withLock { values } }
}

@Suite("Exact committed settlement observation, not tool execution", .serialized)
struct ToolSettlementObservation3299Tests {
    private func reservation() throws -> (ToolExecutionFactLedger, ToolExecutionReceipt, URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("settlement3299-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let execution = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "observer3299", turnID: 1, messageID: "source3299"),
            operationID: "owned-operation3299", attempt: 1)
        let receipt = try ledger.mint(toolCallID: "owned-call3299", toolName: "shell_execute",
                                     attemptID: "owned-attempt3299", attemptNumber: 1,
                                     executionIdentity: execution)
        return (ledger, receipt, url)
    }

    @Test(arguments: [false, true])
    func committedFactBeforeOrAfterRegistrationDeliversOnce(alreadySettled: Bool) throws {
        let (ledger, receipt, url) = try reservation()
        let key = try #require(receipt.compositeKey)
        let values = Settlement3299Values()
        if alreadySettled { _ = try ledger.settle(receipt, status: .cancelled) }
        let handle = ledger.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) { fact in
            // Reentrant canonical reads would deadlock if delivered under the
            // state lock. They also prove visibility only after durable commit.
            #expect(ledger.fact(compositeKey: key, receiptID: receipt.receiptID) == fact)
            #expect(ledger.pendingReceipts.isEmpty)
            values.record(fact)
        }
        if alreadySettled {
            #expect(handle == nil)
        } else {
            #expect(handle != nil && values.facts.isEmpty)
            _ = try ledger.settle(receipt, status: .cancelled)
        }
        let fact = try #require(ledger.facts.first)
        #expect(values.facts == [fact] && fact.status == .cancelled)
        #expect(try ledger.settle(receipt, status: .succeeded) == nil)
        #expect(values.facts == [fact] && ledger.facts == [fact])
        let cold = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(cold.facts == [fact] && cold.pendingReceipts.isEmpty)
        withExtendedLifetime(handle) {}
    }

    @Test func unregisterAndWrongReceiptNeverObserveOrChangeTerminalStatus() throws {
        let (ledger, receipt, _) = try reservation()
        let key = try #require(receipt.compositeKey)
        let refused = Settlement3299Values()
        let unknown = ledger.observeSettlement(compositeKey: key, receiptID: "wrong-receipt3299") {
            refused.record($0)
        }
        #expect(unknown == nil)
        let cancelled = ledger.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) {
            refused.record($0)
        }
        cancelled?.cancel()
        let succeeded = try #require(try ledger.settle(receipt, status: .succeeded))
        #expect(refused.facts.isEmpty && succeeded.status == .succeeded)
        // Observation never coerces an actual late success into cancellation.
        let observed = Settlement3299Values()
        let after = ledger.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) {
            observed.record($0)
        }
        #expect(after == nil && observed.facts == [succeeded])
        #expect(try ledger.settle(receipt, status: .cancelled) == nil)
        #expect(ledger.facts == [succeeded])
    }
    @Test func rejectedStaleWriterCommitCannotNotifyAReservationObserver() throws {
        let (old, receipt, url) = try reservation()
        let key = try #require(receipt.compositeKey)
        let values = Settlement3299Values()
        let handle = old.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) {
            values.record($0)
        }
        let current = try ToolExecutionFactLedger(persistenceURL: url)
        do {
            _ = try old.settle(receipt, status: .cancelled)
            Issue.record("A rejected canonical commit cannot produce a terminal notification")
        } catch {
            #expect(error as? ToolExecutionFactLedgerError == .staleWriter)
        }
        #expect(values.facts.isEmpty && current.facts.isEmpty)
        #expect(current.pendingReceipts == [receipt])
        handle?.cancel()
        _ = try current.settle(receipt, status: .cancelled)
        #expect(values.facts.isEmpty)
    }

}
