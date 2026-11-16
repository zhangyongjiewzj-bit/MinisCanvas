import Foundation
import Testing
@testable import MinisCore

enum MM03MemoryCompletionOrder: String, CaseIterable, Sendable {
    case callbackBeforeEOF, eofBeforeCallback
}
private final class MM03MemoryRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [OwnedMMOutboundRecord] = []
    func append(_ row: OwnedMMOutboundRecord) { lock.lock(); rows.append(row); lock.unlock() }
    var values: [OwnedMMOutboundRecord] { lock.lock(); defer { lock.unlock() }; return rows }
}
private struct MM03MemoryEnvelope: Encodable {
    let scope = "SYNTHETIC_MEMORY_PERMUTATION_NOT_FOUNDATION_NOT_UI_NOT_WIRE"
    let order: String
    let record: OwnedMMOutboundRecord
}

@Suite("MM03 shared production raw producer memory permutations", .serialized)
struct OwnedMMRawCompletionPermutationTests {
    @Test(arguments: MM03MemoryCompletionOrder.allCases)
    func productionRawDoneExactlyOnceForBothCompletionOrders(order: MM03MemoryCompletionOrder) async throws {
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        _ = try #require(resolved)
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let deadline = Date().addingTimeInterval(30)
        #expect(policy.arm())
        try #require(policy.install(nonce: nonce, limit: 1, deadline: deadline))
        let window = try #require(policy.activeWindow)
        let rows = MM03MemoryRows()
        let ledger = OwnedMMOutboundLedger(runIdentity: "TEST_ONLY_MM03_MEMORY_" + order.rawValue,
            windowNonce: window.nonce, deadline: window.deadline,
            windowIsCurrent: { policy.activeWindow?.nonce == window.nonce && policy.activeWindow?.deadline == window.deadline },
            sink: { row in
                rows.append(row)
                var data = try JSONEncoder().encode(MM03MemoryEnvelope(order: order.rawValue, record: row))
                data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
            })
        let readiness = try ledger.beginAction(.providerReadinessButton)
        // All metrics/callback inputs in this test are synthetic; no Foundation
        // task or transport is created to produce an automatic second source.
        for phase in [OwnedMMPhase.reachability, .authentication, .modelDiscovery, .minimalText] {
            let permit = try ledger.beforeSend(action: readiness, phase: phase)
            ledger.recordMetrics(permit, taskID: phase.rawValue, count: 1)
            ledger.finish(permit, taskID: phase.rawValue, status: 200, errorPresent: false)
        }
        let visual = try ledger.beginAction(.composerSendButton)
        let permit = try ledger.beforeSend(action: visual, phase: .visual)
        let audit = permit.taskDelegate()
        ledger.recordMetrics(permit, taskID: 5, count: 1)
        let input = AsyncThrowingStream<String, Error>.makeStream()
        defer { input.continuation.finish() }
        let provider = OpenAICompatibleProvider(apiKey: "[configured locally]", ownedMMOutboundLedger: ledger)
        // This is the same producer called by production streamRaw. It receives
        // only a controlled memory line sequence; there is no duplicate logic.
        let output = provider.makeRawLineStream(lines: input.stream, statusCode: 200, streamPermit: permit)
        input.continuation.yield("data: synthetic-memory-fragment")
        input.continuation.yield("data: [DONE]")
        input.continuation.yield("")
        if order == .callbackBeforeEOF {
            audit.completeTask(taskID: 5, status: 200, errorPresent: false)
            #expect(rows.values.filter { $0.phase == .visual && $0.event == .bytesEOF }.isEmpty)
        }
        input.continuation.finish()
        var doneCount = 0
        var doneObservedAfterSettlement = false
        for try await line in output {
            if line == "data: [DONE]" {
                doneCount += 1
                let state = ledger.snapshot
                doneObservedAfterSettlement = state.finished == 5 && !state.inFlight && !state.stopped
                #expect(doneObservedAfterSettlement)
                let atDone = rows.values.filter { $0.phase == .visual }
                #expect(atDone.filter { $0.event == .bytesEOF }.count == 1)
                #expect(atDone.filter { $0.event == .finish && !$0.failed }.count == 1)
            }
        }
        if order == .eofBeforeCallback {
            #expect(rows.values.filter { $0.phase == .visual && $0.event == .taskCompleted }.isEmpty)
            audit.completeTask(taskID: 5, status: 200, errorPresent: false)
        }
        let visualRows = rows.values.filter { $0.phase == .visual }
        let eof = try #require(visualRows.firstIndex { $0.event == .bytesEOF })
        let callback = try #require(visualRows.firstIndex { $0.event == .taskCompleted })
        if order == .callbackBeforeEOF { #expect(callback < eof) }
        else { #expect(eof < callback) }
        #expect(doneCount == 1 && doneObservedAfterSettlement)
        #expect(visualRows.filter { $0.event == .bytesEOF }.count == 1)
        #expect(visualRows.filter { $0.event == .taskCompleted }.count == 1)
        #expect(visualRows.filter { $0.event == .metrics && $0.transactions == 1 }.count == 1)
        #expect(visualRows.filter { $0.event == .finish && !$0.failed }.count == 1)
        #expect(!ledger.snapshot.stopped && !ledger.snapshot.inFlight)
        #expect(ledger.snapshot.admitted == 5 && ledger.snapshot.finished == 5 && ledger.snapshot.transactions == 5)
        #expect(policy.snapshot.reserved == 0 && policy.snapshot.refused == 0)
    }
}
