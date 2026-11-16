import Foundation

/// Disposition for one attempt to settle a child result against state that
/// may already have crossed the terminal boundary.
public enum AsyncTerminalWritebackDisposition: Sendable, Equatable {
    /// The producing run/attempt is still open; the settlement may proceed.
    case accept
    /// A durable receipt already exists and the envelope is byte-identical;
    /// the caller must return the stored receipt unchanged.
    case exactReplay
    /// Cancellation won first; every later writeback is rejected as the
    /// cancellation so the sticky fact cannot be rewritten.
    case rejectCancelledSticky
    /// A durable receipt exists with a different payload; drift fails closed.
    case rejectIdempotencyConflict
    /// The run/attempt reached a terminal state without this envelope; the
    /// writeback is late and must never mutate the ledger.
    case rejectLate
}

/// Unified terminal-state and late-writeback rules for the cross-domain
/// async chain Session -> Turn -> Run -> Task -> Attempt -> Effect receipt.
///
/// Before this type, the attempt domain (``ChildSupervisor``) and the durable
/// settlement domain (``AgentTaskStore.settleChildResult``) each reimplemented
/// the same terminal classification, cancel-stickiness and late-writeback
/// decision inline. Both production domains now route their admission guards
/// through this single source of truth so a terminal fact decided in one
/// domain cannot be rewritten in the other. The turn and session domains keep
/// their own inline fences until their owners adopt these rules; this type is
/// the canonical rule set they must match.
public enum AsyncTerminalStateRules {

    // MARK: - Cross-domain terminal classification

    /// A supervisor attempt status that can no longer accept lifecycle or
    /// writeback signals.
    public static func isTerminal(_ status: ChildSupervisorStatus) -> Bool {
        switch status {
        case .running, .paused: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }

    /// A durable task/run/attempt status that has decided its final fact.
    public static func isTerminal(_ status: AgentTaskStatus) -> Bool {
        switch status {
        case .queued, .running: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }

    /// Event kinds that represent a terminal settlement. They are never
    /// admitted as ordinary events; they must go through the settlement
    /// entry points so the late-writeback decision below is enforced.
    public static func isTerminal(eventKind: AgentTaskEventKind) -> Bool {
        switch eventKind {
        case .completed, .failed, .cancelled: return true
        case .started, .progress, .approvalRequired, .inputRequired,
             .submissionUnknown, .terminalDuplicate:
            return false
        }
    }

    // MARK: - Attempt domain (ChildSupervisor)

    /// Whether a supervised attempt still admits terminal writebacks,
    /// cancellation or settlement. A terminal attempt admits nothing.
    public static func admitsAttemptWriteback(_ status: ChildSupervisorStatus) -> Bool {
        !isTerminal(status)
    }

    /// Whether a supervised attempt still admits live progress signals.
    /// Only a running attempt does; a paused attempt must not drift forward.
    public static func admitsLiveSignal(_ status: ChildSupervisorStatus) -> Bool {
        status == .running
    }

    /// Legal in-attempt transitions. Terminal states are frozen: no
    /// transition out of them is legal, which is what keeps a late writeback
    /// from reopening a settled attempt.
    public static func allowsAttemptTransition(
        from current: ChildSupervisorStatus,
        to target: ChildSupervisorStatus
    ) -> Bool {
        guard !isTerminal(current) else { return false }
        switch (current, target) {
        case (.running, .running),
             (.running, .paused),
             (.running, .succeeded),
             (.running, .failed),
             (.running, .cancelled),
             (.paused, .paused),
             (.paused, .succeeded),
             (.paused, .failed),
             (.paused, .cancelled):
            return true
        default:
            return false
        }
    }

    /// Only a failed or cancelled attempt releases its lease and may be
    /// restarted; a succeeded attempt's decision is final.
    public static func admitsLeaseRelease(from status: ChildSupervisorStatus) -> Bool {
        status == .failed || status == .cancelled
    }

    /// Canonical mapping from the durable outcome carried by a child result
    /// envelope to the supervised attempt status it decides.
    public static func supervisorStatus(for outcome: AgentTaskOutcome) -> ChildSupervisorStatus {
        switch outcome {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    // MARK: - Durable settlement domain (AgentTaskStore)

    /// The single decision table for settling one child result envelope
    /// against the current durable facts of its run and attempt.
    ///
    /// - Parameters:
    ///   - runStatus: status of the durable run the envelope targets.
    ///   - attemptStatus: status of the canonical attempt for that run.
    ///   - hasSettledReceipt: whether the run already owns a terminal receipt.
    ///   - settledReceiptIsExactReplay: whether the incoming envelope is
    ///     identical to the envelope stored with that receipt.
    ///   - settledReceiptIsCancelled: whether the settled receipt's outcome
    ///     is cancellation.
    public static func lateWritebackDisposition(
        runStatus: AgentTaskStatus,
        attemptStatus: AgentTaskStatus,
        hasSettledReceipt: Bool,
        settledReceiptIsExactReplay: Bool,
        settledReceiptIsCancelled: Bool
    ) -> AsyncTerminalWritebackDisposition {
        if hasSettledReceipt {
            if settledReceiptIsExactReplay { return .exactReplay }
            if settledReceiptIsCancelled || runStatus == .cancelled {
                return .rejectCancelledSticky
            }
            return .rejectIdempotencyConflict
        }
        if runStatus == .running && attemptStatus == .running {
            return .accept
        }
        if runStatus == .cancelled || attemptStatus == .cancelled {
            return .rejectCancelledSticky
        }
        return .rejectLate
    }
}
