import Foundation

public enum ChildSupervisorError: Error, Equatable, Sendable {
    case staleSequence
    case staleAttempt
    case invalidLifecycle
}

public enum ChildSupervisorLeaseState: Sendable, Equatable {
    case active
    case released
}

public enum ChildSupervisorStatus: Sendable, Equatable {
    case running
    case paused
    case succeeded
    case failed
    case cancelled
}

public struct ChildSupervisorSnapshot: Sendable, Equatable {
    public let childID: String
    public let attemptID: String
    public let attemptNumber: Int
    public let sequence: Int
    public let status: ChildSupervisorStatus

    public init(
        childID: String,
        attemptID: String,
        attemptNumber: Int,
        sequence: Int,
        status: ChildSupervisorStatus
    ) {
        self.childID = childID
        self.attemptID = attemptID
        self.attemptNumber = attemptNumber
        self.sequence = sequence
        self.status = status
    }
}

/// Owns one child execution attempt and rejects stale lifecycle/writeback signals.
///
/// A new attempt is admitted only after the previous attempt reaches a terminal
/// state. Sequence numbers are supplied by the producer and must increase for
/// the active attempt.
public actor ChildSupervisor {
    public let childID: String

    private var attemptNumber = 0
    private var current: ChildSupervisorSnapshot?
    private var lease: ChildSupervisorLeaseState = .released
    private var pendingAttemptID: String?
    private var acceptedEnvelope: ChildResultEnvelope?

    public init(childID: String, attemptID: String? = nil) {
        self.childID = childID
        pendingAttemptID = attemptID
    }

    public func start() throws -> ChildSupervisorSnapshot {
        guard current == nil else {
            throw ChildSupervisorError.invalidLifecycle
        }
        attemptNumber += 1
        let attemptID = pendingAttemptID ?? "\(childID):attempt:\(attemptNumber)"
        pendingAttemptID = nil
        let snapshot = ChildSupervisorSnapshot(
            childID: childID,
            attemptID: attemptID,
            attemptNumber: attemptNumber,
            sequence: 0,
            status: .running
        )
        current = snapshot
        lease = .active
        acceptedEnvelope = nil
        return snapshot
    }

    public func start(attemptID: String) throws -> ChildSupervisorSnapshot {
        guard current == nil else {
            throw ChildSupervisorError.invalidLifecycle
        }
        pendingAttemptID = attemptID
        return try start()
    }

    public func snapshot() -> ChildSupervisorSnapshot? {
        current
    }

    /// Cancels only an active attempt. A terminal attempt is left untouched so
    /// a success/writeback decision cannot be rewritten after it wins.
    public func cancelIfRunning(attemptID: String) throws -> Bool {
        guard let current, current.attemptID == attemptID else {
            throw ChildSupervisorError.staleAttempt
        }
        guard AsyncTerminalStateRules.admitsAttemptWriteback(current.status) else {
            return false
        }
        _ = try transition(attemptID: attemptID, status: .cancelled, releasesLease: true)
        return true
    }

    /// Atomically accepts the final writeback and succeeds the attempt.
    /// Cancellation can therefore win before this operation, but cannot split
    /// the writeback from the terminal success after it has won.
    public func settleSuccess(attemptID: String, sequence: Int) throws -> Bool {
        guard let current else {
            throw ChildSupervisorError.invalidLifecycle
        }
        guard current.attemptID == attemptID else {
            return false
        }
        guard AsyncTerminalStateRules.admitsAttemptWriteback(current.status) else {
            return false
        }
        guard sequence > current.sequence else {
            throw ChildSupervisorError.staleSequence
        }
        self.current = snapshot(current, sequence: sequence, status: .succeeded)
        lease = .released
        return true
    }

    /// Applies a terminal child-result envelope only to the currently
    /// supervised attempt. The durable store performs the task/run/parent
    /// binding; this actor contributes the local attempt and sequence fence.
    public func acceptResultEnvelope(_ envelope: ChildResultEnvelope) throws -> Bool {
        guard envelope.isWellFormed else {
            return false
        }
        if acceptedEnvelope == envelope {
            return true
        }
        guard envelope.taskID == childID,
              let current,
              current.attemptID == envelope.attemptID else {
            return false
        }
        guard AsyncTerminalStateRules.admitsAttemptWriteback(current.status) else {
            return false
        }
        guard envelope.sequence > current.sequence else {
            throw ChildSupervisorError.staleSequence
        }

        let status = AsyncTerminalStateRules.supervisorStatus(for: envelope.outcome)
        self.current = snapshot(current, sequence: envelope.sequence, status: status)
        lease = .released
        acceptedEnvelope = envelope
        return true
    }

    public func restart() throws -> ChildSupervisorSnapshot {
        guard let current,
              AsyncTerminalStateRules.admitsLeaseRelease(from: current.status),
              lease == .released else {
            throw ChildSupervisorError.invalidLifecycle
        }
        self.current = nil
        return try start()
    }

    public func heartbeat(attemptID: String, sequence: Int) throws -> ChildSupervisorSnapshot {
        try record(attemptID: attemptID, sequence: sequence, status: .running)
    }

    public func progress(
        attemptID: String,
        sequence: Int,
        detail: String
    ) throws -> ChildSupervisorSnapshot {
        _ = detail
        return try record(attemptID: attemptID, sequence: sequence, status: .running)
    }

    public func pause(attemptID: String) throws -> ChildSupervisorSnapshot {
        try transition(attemptID: attemptID, status: .paused, releasesLease: false)
    }

    public func fail(attemptID: String) throws -> ChildSupervisorSnapshot {
        try transition(attemptID: attemptID, status: .failed, releasesLease: true)
    }

    public func cancel(attemptID: String) throws -> ChildSupervisorSnapshot {
        try transition(attemptID: attemptID, status: .cancelled, releasesLease: true)
    }

    public func complete(attemptID: String) throws -> ChildSupervisorSnapshot {
        try transition(attemptID: attemptID, status: .succeeded, releasesLease: true)
    }

    public func acceptWriteback(attemptID: String, sequence: Int) throws -> Bool {
        guard let current else {
            throw ChildSupervisorError.invalidLifecycle
        }
        guard current.attemptID == attemptID else { return false }
        guard AsyncTerminalStateRules.admitsAttemptWriteback(current.status) else {
            return false
        }
        guard sequence > current.sequence else {
            throw ChildSupervisorError.staleSequence
        }
        self.current = snapshot(
            current,
            sequence: sequence,
            status: current.status
        )
        return true
    }

    public func releaseLease(attemptID: String) throws {
        guard let current, current.attemptID == attemptID else {
            throw ChildSupervisorError.staleAttempt
        }
        guard AsyncTerminalStateRules.admitsLeaseRelease(from: current.status) else {
            throw ChildSupervisorError.invalidLifecycle
        }
        lease = .released
    }

    public func leaseState() -> ChildSupervisorLeaseState {
        lease
    }

    private func record(
        attemptID: String,
        sequence: Int,
        status: ChildSupervisorStatus
    ) throws -> ChildSupervisorSnapshot {
        guard let current, current.attemptID == attemptID else {
            throw ChildSupervisorError.staleAttempt
        }
        guard AsyncTerminalStateRules.admitsLiveSignal(current.status),
              sequence > current.sequence else {
            throw ChildSupervisorError.staleSequence
        }
        let updated = snapshot(current, sequence: sequence, status: status)
        self.current = updated
        return updated
    }

    private func transition(
        attemptID: String,
        status: ChildSupervisorStatus,
        releasesLease: Bool
    ) throws -> ChildSupervisorSnapshot {
        guard let current, current.attemptID == attemptID else {
            throw ChildSupervisorError.staleAttempt
        }
        guard AsyncTerminalStateRules.allowsAttemptTransition(from: current.status, to: status) else {
            throw ChildSupervisorError.invalidLifecycle
        }
        let updated = snapshot(current, sequence: current.sequence, status: status)
        self.current = updated
        if releasesLease {
            lease = .released
        }
        return updated
    }

    private func snapshot(
        _ current: ChildSupervisorSnapshot,
        sequence: Int,
        status: ChildSupervisorStatus
    ) -> ChildSupervisorSnapshot {
        ChildSupervisorSnapshot(
            childID: current.childID,
            attemptID: current.attemptID,
            attemptNumber: current.attemptNumber,
            sequence: sequence,
            status: status
        )
    }
}
