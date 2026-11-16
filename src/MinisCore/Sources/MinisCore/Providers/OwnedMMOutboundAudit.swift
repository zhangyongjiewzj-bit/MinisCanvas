import Foundation
import Darwin

/// Dedicated MM session metadata only. No URL, header, payload or Error text
/// is accepted by this API. Ordinary providers do not construct this object.
public enum OwnedMMCaller: String, Codable, Sendable {
    case providerReadinessButton, composerSendButton
}
public enum OwnedMMPhase: Int, Codable, Sendable {
    case reachability = 1, authentication, modelDiscovery, minimalText, visual
}
public enum OwnedMMAuditRefusal: Error, Sendable {
    case stopped, missingAction, wrongAction, sequence, inFlight, budget
    case output, unknownTask, missingMetrics, extraTransaction, failedRequest
}
public struct OwnedMMActionTicket: Sendable, Equatable {
    fileprivate let ledgerID: UUID
    public let actionID: UUID
    public let caller: OwnedMMCaller
    public let monotonicNanoseconds: UInt64
}
public enum OwnedMMOutboundContext {
    // Only carries a ticket created by a real UI handler. Missing inheritance
    // is a refusal in an audited lane, never a request to invent a caller.
    @TaskLocal public static var action: OwnedMMActionTicket?
}
public struct OwnedMMOutboundRecord: Codable, Sendable {
    public enum Event: String, Codable, Sendable { case action, beforeSend, metrics, finish, refused, bytesEOF, taskCompleted }
    public let schema: String
    public let event: Event
    public let runIdentity: String
    public let budgetID: UUID
    public let windowNonce: String?
    public let pid: Int32
    public let caller: OwnedMMCaller?
    public let actionID: UUID?
    public let invocationID: UUID?
    public let parentInvocationID: UUID?
    public let phase: OwnedMMPhase?
    public let monotonicNanoseconds: UInt64
    public let admitted: Int
    public let limit: Int
    public let taskID: Int?
    public let transactions: Int?
    public let status: Int?
    public let failed: Bool
}
public struct OwnedMMSendPermit: Sendable {
    fileprivate let ledger: OwnedMMOutboundLedger
    public let invocationID: UUID
    public let action: OwnedMMActionTicket
    public let phase: OwnedMMPhase
    public func taskDelegate() -> OwnedMMTaskAudit { OwnedMMTaskAudit(permit: self) }
    public func waitForFinish() async throws { try await ledger.waitForFinish(self) }
    /// Async URLSession data APIs may use their completion-handler path rather
    /// than didCompleteWithError. Real response completion is also a terminal
    /// boundary; absent real metrics fails closed instead of waiting forever.
    public func completeAfterResponse(status: Int?) { ledger.completeAfterResponse(self, status: status) }
    /// Called only after the production AsyncBytes iterator returns real EOF.
    public func completeAfterBytesEOF(status: Int?) { ledger.completeAfterBytesEOF(self, status: status) }
    public func fail() { ledger.fail(self) }
}

/// A single shared, synchronously reserved 4-readiness + 1-visual budget.
/// Metrics are retrospective; this does NOT promise a wire pre-send cap.
public final class OwnedMMOutboundLedger: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let admitted: Int
        public let stopped: Bool
        public let inFlight: Bool
        public let finished: Int
        public let transactions: Int
    }
    private let lock = NSLock()
    private let id = UUID()
    private let runIdentity: String
    private let pid: Int32
    private let windowNonce: String?
    private let deadline: Date?
    private let windowIsCurrent: @Sendable () -> Bool
    private let clock: @Sendable () -> UInt64
    private let sink: @Sendable (OwnedMMOutboundRecord) throws -> Void
    private var stopped = false
    private var admitted = 0
    private var finished = 0
    private var transactions = 0
    private var readinessAction: OwnedMMActionTicket?
    private var visualAction: OwnedMMActionTicket?
    private var pending: OwnedMMSendPermit?
    private var metricsTaskID: Int?
    private var metricsCount: Int?
    private var terminals: [UUID: Bool] = [:]
    private var waiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]

    public init(runIdentity: String, pid: Int32 = getpid(), windowNonce: String? = nil, deadline: Date? = nil,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                windowIsCurrent: @escaping @Sendable () -> Bool = { true },
                sink: @escaping @Sendable (OwnedMMOutboundRecord) throws -> Void = { row in
                    var data = try JSONEncoder().encode(row)
                    data.append(10)
                    try FileHandle.standardOutput.write(contentsOf: data)
                }) {
        self.runIdentity = runIdentity; self.pid = pid; self.clock = clock; self.sink = sink
        self.windowNonce = windowNonce; self.deadline = deadline
        self.windowIsCurrent = windowIsCurrent
    }
    private func emit(_ event: OwnedMMOutboundRecord.Event, action: OwnedMMActionTicket? = nil,
                      permit: OwnedMMSendPermit? = nil, taskID: Int? = nil,
                      count: Int? = nil, status: Int? = nil, failed: Bool = false) throws {
        let ticket = permit?.action ?? action
        do {
            try sink(OwnedMMOutboundRecord(schema: "MM01_OWNED_OUTBOUND_AUDIT_V1", event: event,
                runIdentity: runIdentity, budgetID: id, windowNonce: windowNonce, pid: pid, caller: ticket?.caller,
                actionID: ticket?.actionID, invocationID: permit?.invocationID,
                parentInvocationID: ticket?.actionID, phase: permit?.phase,
                monotonicNanoseconds: clock(), admitted: admitted, limit: 5,
                taskID: taskID, transactions: count, status: status, failed: failed))
        } catch { stopped = true; throw OwnedMMAuditRefusal.output }
    }
    private func refuse(_ reason: OwnedMMAuditRefusal) throws -> Never {
        stopped = true
        try emit(.refused, permit: pending, failed: true)
        throw reason
    }
    /// Caller must be the synchronous UI handler, before it creates its Task.
    public func beginAction(_ caller: OwnedMMCaller) throws -> OwnedMMActionTicket {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw OwnedMMAuditRefusal.stopped }
        guard (deadline.map({ Date() < $0 }) ?? true) && windowIsCurrent() else { try refuse(.stopped) }
        switch caller {
        case .providerReadinessButton:
            guard readinessAction == nil, admitted == 0 else { try refuse(.wrongAction) }
        case .composerSendButton:
            guard readinessAction != nil, visualAction == nil, admitted == 4,
                  finished == 4, pending == nil else { try refuse(.sequence) }
        }
        let ticket = OwnedMMActionTicket(ledgerID: id, actionID: UUID(), caller: caller,
                                        monotonicNanoseconds: clock())
        try emit(.action, action: ticket)
        if caller == .providerReadinessButton { readinessAction = ticket } else { visualAction = ticket }
        return ticket
    }
    public func validate(_ ticket: OwnedMMActionTicket?, phase: OwnedMMPhase) throws {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(ticket, phase: phase)
    }
    private func validateLocked(_ ticket: OwnedMMActionTicket?, phase: OwnedMMPhase) throws {
        guard !stopped else { throw OwnedMMAuditRefusal.stopped }
        guard (deadline.map({ Date() < $0 }) ?? true) && windowIsCurrent() else { try refuse(.stopped) }
        guard let ticket else { try refuse(.missingAction) }
        guard ticket.ledgerID == id,
              ticket == (phase == .visual ? visualAction : readinessAction) else { try refuse(.wrongAction) }
    }
    public func beforeSend(action: OwnedMMActionTicket?, phase: OwnedMMPhase) throws -> OwnedMMSendPermit {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(action, phase: phase)
        guard admitted < 5 else { try refuse(.budget) }
        guard pending == nil else { try refuse(.inFlight) }
        guard phase.rawValue == admitted + 1, finished == admitted else { try refuse(.sequence) }
        let permit = OwnedMMSendPermit(ledger: self, invocationID: UUID(), action: action!, phase: phase)
        admitted += 1; pending = permit; metricsCount = nil; metricsTaskID = nil
        do { try emit(.beforeSend, permit: permit) } // before the actual URLSession call
        catch { pending = nil; terminals[permit.invocationID] = false; throw error }
        return permit
    }
    func recordMetrics(_ permit: OwnedMMSendPermit, taskID: Int, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard pending?.invocationID == permit.invocationID, metricsCount == nil,
              taskID > 0, count >= 0 else {
            stopped = true
            try? emit(.refused, permit: permit, taskID: taskID, count: count, failed: true)
            return
        }
        metricsTaskID = taskID; metricsCount = count; transactions += count
        if count != 1 { stopped = true }
        do { try emit(.metrics, permit: permit, taskID: taskID, count: count, failed: count != 1) }
        catch { stopped = true }
    }
    func finish(_ permit: OwnedMMSendPermit, taskID: Int?, status: Int?, errorPresent: Bool) {
        lock.lock()
        if terminals[permit.invocationID] != nil {
            if errorPresent || status.map({ !(200..<300).contains($0) }) == true {
                stopped = true; try? emit(.refused, permit: permit, failed: true)
            }
            lock.unlock(); return
        }
        guard pending?.invocationID == permit.invocationID else {
            stopped = true; try? emit(.refused, permit: permit, failed: true)
            lock.unlock(); return
        }
        // Resolve the async API's task identity under this same finish lock;
        // never snapshot metricsTaskID and release the lock before settlement.
        let resolvedTaskID = taskID ?? metricsTaskID
        let pass = !stopped && !errorPresent && status.map({ (200..<300).contains($0) }) == true
            && resolvedTaskID != nil && metricsTaskID == resolvedTaskID && metricsCount == 1
        if !pass { stopped = true }
        do { try emit(.finish, permit: permit, taskID: resolvedTaskID, count: metricsCount, status: status, failed: !pass) }
        catch { stopped = true }
        let success = pass && !stopped
        terminals[permit.invocationID] = success; finished += 1; pending = nil
        let continuations = waiters.removeValue(forKey: permit.invocationID) ?? []
        lock.unlock()
        for c in continuations {
            if success { c.resume() } else { c.resume(throwing: OwnedMMAuditRefusal.failedRequest) }
        }
    }
    fileprivate func completeAfterResponse(_ permit: OwnedMMSendPermit, status: Int?) {
        finish(permit, taskID: nil, status: status, errorPresent: false)
    }
    fileprivate func completeAfterBytesEOF(_ permit: OwnedMMSendPermit, status: Int?) {
        recordBoundary(.bytesEOF, permit: permit, taskID: nil, status: status, failed: false)
        completeAfterResponse(permit, status: status)
    }
    fileprivate func recordBoundary(_ event: OwnedMMOutboundRecord.Event, permit: OwnedMMSendPermit,
                                    taskID: Int?, status: Int?, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        do { try emit(event, permit: permit, taskID: taskID, status: status, failed: failed) }
        catch { stopped = true }
    }
    fileprivate func fail(_ permit: OwnedMMSendPermit) {
        lock.lock(); stopped = true
        if terminals[permit.invocationID] == nil {
            try? emit(.finish, permit: permit, taskID: metricsTaskID, count: metricsCount, failed: true)
            terminals[permit.invocationID] = false
            if pending?.invocationID == permit.invocationID { pending = nil; finished += 1 }
        }
        let continuations = waiters.removeValue(forKey: permit.invocationID) ?? []
        lock.unlock()
        for c in continuations { c.resume(throwing: OwnedMMAuditRefusal.failedRequest) }
    }
    fileprivate func waitForFinish(_ permit: OwnedMMSendPermit) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let pass = terminals[permit.invocationID] {
                lock.unlock()
                if pass { c.resume() } else { c.resume(throwing: OwnedMMAuditRefusal.failedRequest) }
            } else {
                waiters[permit.invocationID, default: []].append(c); lock.unlock()
            }
        }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        try? emit(.refused, permit: pending, failed: true)
    }
    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(admitted: admitted, stopped: stopped, inFlight: pending != nil,
                        finished: finished, transactions: transactions)
    }
}

/// Same owned task; metrics counts only. Never inspect metrics request/URL.
public final class OwnedMMTaskAudit: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let permit: OwnedMMSendPermit
    public init(permit: OwnedMMSendPermit) { self.permit = permit }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didFinishCollecting metrics: URLSessionTaskMetrics) {
        permit.ledger.recordMetrics(permit, taskID: task.taskIdentifier,
                                    count: metrics.transactionMetrics.count)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completeTask(taskID: task.taskIdentifier,
                     status: (task.response as? HTTPURLResponse)?.statusCode,
                     errorPresent: error != nil)
    }
    /// The real delegate and deterministic tests share the same typed projection.
    internal func completeTask(taskID: Int, status: Int?, errorPresent: Bool) {
        permit.ledger.recordBoundary(.taskCompleted, permit: permit, taskID: taskID,
                                     status: status,
                                     failed: errorPresent)
        permit.ledger.finish(permit, taskID: taskID,
                             status: status,
                             errorPresent: errorPresent)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        permit.fail(); completionHandler(nil)
    }
}
