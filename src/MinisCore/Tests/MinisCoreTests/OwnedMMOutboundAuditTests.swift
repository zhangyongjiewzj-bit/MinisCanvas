import Foundation
import Testing
@testable import MinisCore

@Suite("Owned MM outbound attribution", .serialized)
struct OwnedMMOutboundAuditTests {
    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [OwnedMMOutboundRecord] = []
        func append(_ row: OwnedMMOutboundRecord) { lock.lock(); rows.append(row); lock.unlock() }
        var values: [OwnedMMOutboundRecord] { lock.lock(); defer { lock.unlock() }; return rows }
    }
    private func make(_ records: Records = Records()) -> OwnedMMOutboundLedger {
        OwnedMMOutboundLedger(runIdentity: "synthetic-MM-window", pid: 1234,
                              clock: { 42 }, sink: { records.append($0) })
    }
    private func finish(_ ledger: OwnedMMOutboundLedger, _ permit: OwnedMMSendPermit, task: Int) {
        // Pure callback inputs only, not a claim about Darwin URLProtocol metrics.
        ledger.recordMetrics(permit, taskID: task, count: 1)
        ledger.finish(permit, taskID: task, status: 200, errorPresent: false)
    }
    private func firstFour(_ ledger: OwnedMMOutboundLedger) throws -> OwnedMMActionTicket {
        let action = try ledger.beginAction(.providerReadinessButton)
        for phase in [OwnedMMPhase.reachability, .authentication, .modelDiscovery, .minimalText] {
            let permit = try ledger.beforeSend(action: action, phase: phase)
            finish(ledger, permit, task: phase.rawValue)
        }
        return action
    }
    @Test func fourThenVisualSharesOneBudgetAndAncestry() throws {
        let records = Records(), ledger = make(records)
        let readiness = try firstFour(ledger)
        let visual = try ledger.beginAction(.composerSendButton)
        let last = try ledger.beforeSend(action: visual, phase: .visual)
        finish(ledger, last, task: 5)
        #expect(ledger.snapshot.admitted == 5)
        #expect(ledger.snapshot.finished == 5)
        #expect(ledger.snapshot.transactions == 5)
        #expect(!ledger.snapshot.stopped && !ledger.snapshot.inFlight)
        let sends = records.values.filter { $0.event == .beforeSend }
        #expect(sends.count == 5)
        #expect(sends.prefix(4).allSatisfy { $0.actionID == readiness.actionID && $0.caller == .providerReadinessButton })
        #expect(sends.last?.actionID == visual.actionID)
        #expect(sends.last?.caller == .composerSendButton)
        #expect(sends.allSatisfy { $0.pid == 1234 && $0.monotonicNanoseconds == 42 && $0.parentInvocationID == $0.actionID })
        #expect(Set(sends.compactMap(\.invocationID)).count == 5)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: visual, phase: .visual) }
        #expect(ledger.snapshot.admitted == 5 && ledger.snapshot.stopped)
    }
    @Test func missingActionNeverAdmits() {
        let ledger = make()
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: nil, phase: .reachability) }
        #expect(ledger.snapshot.admitted == 0 && ledger.snapshot.stopped)
    }
    @Test func foreignWindowActionNeverAdmits() throws {
        let ledger = make(), other = make()
        let foreign = try other.beginAction(.providerReadinessButton)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: foreign, phase: .reachability) }
        #expect(ledger.snapshot.admitted == 0)
    }
    @Test func duplicateUIActionPermanentlyStops() throws {
        let ledger = make()
        _ = try ledger.beginAction(.providerReadinessButton)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beginAction(.providerReadinessButton) }
        #expect(ledger.snapshot.stopped && ledger.snapshot.admitted == 0)
    }
    @Test func outOfOrderAndEarlyVisualNeverAdmit() throws {
        let ledger = make(), early = make()
        let ticket = try ledger.beginAction(.providerReadinessButton)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: ticket, phase: .authentication) }
        #expect(throws: OwnedMMAuditRefusal.self) { try early.beginAction(.composerSendButton) }
        #expect(ledger.snapshot.admitted == 0 && early.snapshot.admitted == 0)
    }
    @Test func concurrentReservationsCannotOverrun() async throws {
        let ledger = make(), ticket = try ledger.beginAction(.providerReadinessButton)
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { (try? ledger.beforeSend(action: ticket, phase: .reachability)) != nil } }
            var wins = 0
            for await won in group { if won { wins += 1 } }
            return wins
        }
        #expect(wins == 1 && ledger.snapshot.admitted == 1 && ledger.snapshot.stopped)
    }
    @Test func extraMetricsAndMissingMetricsStopInsteadOfSuccess() throws {
        for count in [0, 2] {
            let ledger = make(), ticket = try ledger.beginAction(.providerReadinessButton)
            let permit = try ledger.beforeSend(action: ticket, phase: .reachability)
            ledger.recordMetrics(permit, taskID: 1, count: count)
            ledger.finish(permit, taskID: 1, status: 200, errorPresent: false)
            #expect(ledger.snapshot.stopped && ledger.snapshot.admitted == 1)
        }
        let ledger = make(), ticket = try ledger.beginAction(.providerReadinessButton)
        let permit = try ledger.beforeSend(action: ticket, phase: .reachability)
        permit.completeAfterResponse(status: 200)
        #expect(ledger.snapshot.stopped && !ledger.snapshot.inFlight)
    }
    @Test func firstHTTPFailurePreventsNextStage() throws {
        let ledger = make(), ticket = try ledger.beginAction(.providerReadinessButton)
        let permit = try ledger.beforeSend(action: ticket, phase: .reachability)
        ledger.recordMetrics(permit, taskID: 1, count: 1)
        ledger.finish(permit, taskID: 1, status: 503, errorPresent: false)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: ticket, phase: .authentication) }
        #expect(ledger.snapshot.admitted == 1 && ledger.snapshot.stopped)
    }
    @Test func writerFailurePreventsAdmissionAndCannotReset() throws {
        enum OutputFailure: Error { case synthetic }
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234, sink: { _ in throw OutputFailure.synthetic })
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beginAction(.providerReadinessButton) }
        #expect(ledger.snapshot.admitted == 0 && ledger.snapshot.stopped)
    }
    @Test func beforeSendOutputFailureConsumesReservationButNeverContinues() throws {
        enum OutputFailure: Error { case synthetic }
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234, sink: { row in
            if row.event == .beforeSend { throw OutputFailure.synthetic }
        })
        let ticket = try ledger.beginAction(.providerReadinessButton)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: ticket, phase: .reachability) }
        #expect(ledger.snapshot.admitted == 1 && ledger.snapshot.stopped && !ledger.snapshot.inFlight)
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beforeSend(action: ticket, phase: .reachability) }
        #expect(ledger.snapshot.admitted == 1)
    }
    @Test func mismatchedCompletionTaskStopsWindow() throws {
        let ledger = make(), ticket = try ledger.beginAction(.providerReadinessButton)
        let permit = try ledger.beforeSend(action: ticket, phase: .reachability)
        ledger.recordMetrics(permit, taskID: 1, count: 1)
        ledger.finish(permit, taskID: 2, status: 200, errorPresent: false)
        #expect(ledger.snapshot.stopped && ledger.snapshot.admitted == 1)
    }
    @Test func expiredInstalledWindowCannotBeginOrSend() {
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234,
            windowNonce: String(repeating: "a", count: 32), deadline: .distantPast, sink: { _ in })
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beginAction(.providerReadinessButton) }
        #expect(ledger.snapshot.admitted == 0 && ledger.snapshot.stopped)
    }
    @Test func changedOrMissingInstalledWindowRefusesWithoutFallback() {
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234,
            windowNonce: String(repeating: "a", count: 32), deadline: .distantFuture,
            windowIsCurrent: { false }, sink: { _ in })
        #expect(throws: OwnedMMAuditRefusal.self) { try ledger.beginAction(.providerReadinessButton) }
        #expect(ledger.snapshot.admitted == 0 && ledger.snapshot.stopped)
    }
    @Test func metadataGetterDoesNotConsumeExtendOrResetReadBudget() {
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        let nonce = String(repeating: "a", count: 32), deadline = Date.distantFuture
        #expect(policy.arm())
        #expect(policy.install(nonce: nonce, limit: 2, deadline: deadline))
        let before = policy.snapshot
        for _ in 0..<3 {
            #expect(policy.activeWindow?.nonce == nonce)
            #expect(policy.activeWindow?.deadline == deadline)
        }
        #expect(policy.snapshot.reserved == before.reserved && policy.snapshot.refused == before.refused)
        #expect(!policy.install(nonce: String(repeating: "b", count: 32), limit: 100, deadline: .distantFuture))
        #expect(policy.activeWindow?.nonce == nonce && policy.activeWindow?.deadline == deadline)
        #expect(policy.admit() && policy.admit() && !policy.admit())
        #expect(policy.snapshot.limit == 2 && policy.snapshot.reserved == 2)
        #expect(policy.activeWindow?.nonce == nonce)
    }
    @Test func expiredOrInvalidNoncePlanCannotExposeInstalledMetadata() {
        for badNonce in [String(repeating: "a", count: 31), String(repeating: "z", count: 32)] {
            let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
            #expect(policy.arm())
            #expect(!policy.install(nonce: badNonce, limit: 2, deadline: .distantFuture))
            #expect(policy.activeWindow == nil && !policy.admit())
        }
        let expired = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(expired.arm())
        #expect(!expired.install(nonce: String(repeating: "a", count: 32), limit: 2, deadline: .distantPast))
        #expect(expired.activeWindow == nil && !expired.admit())
    }
    @Test func taskLocalCarriesOnlySameTicketAcrossAwait() async throws {
        let ledger = make(), ticket = try ledger.beginAction(.providerReadinessButton)
        let observed = await OwnedMMOutboundContext.$action.withValue(ticket) {
            await Task.yield()
            return await Task { OwnedMMOutboundContext.action }.value
        }
        #expect(observed == ticket)
        #expect(OwnedMMOutboundContext.action == nil)
    }
    @Test func encodedRecordHasClosedNonsecretSchema() throws {
        let records = Records(), ledger = make(records)
        _ = try ledger.beginAction(.providerReadinessButton)
        let row = try #require(records.values.first)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: ["schema", "event", "runIdentity", "budgetID", "windowNonce", "pid", "caller", "actionID", "invocationID", "parentInvocationID", "phase", "monotonicNanoseconds", "admitted", "limit", "taskID", "transactions", "status", "failed"]))
        #expect(!object.keys.contains(where: { ["url", "header", "body", "key", "error"].contains($0.lowercased()) }))
    }
    @Test func nilCompletionTaskResolvesRecordedMetricsAndDuplicateSuccessIsIdempotent() throws {
        let records = Records(), ledger = make(records)
        let ticket = try ledger.beginAction(.providerReadinessButton)
        let permit = try ledger.beforeSend(action: ticket, phase: .reachability)
        ledger.recordMetrics(permit, taskID: 17, count: 1)
        ledger.finish(permit, taskID: nil, status: 200, errorPresent: false)
        ledger.finish(permit, taskID: nil, status: 200, errorPresent: false)
        #expect(!ledger.snapshot.stopped && !ledger.snapshot.inFlight)
        #expect(ledger.snapshot.finished == 1 && ledger.snapshot.transactions == 1)
        let finishes = records.values.filter { $0.event == .finish }
        #expect(finishes.count == 1 && finishes.first?.taskID == 17 && finishes.first?.failed == false)
    }
}
