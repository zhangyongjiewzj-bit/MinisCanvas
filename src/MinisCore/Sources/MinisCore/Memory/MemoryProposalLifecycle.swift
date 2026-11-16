import Foundation

/// Visibility boundary for a proposed memory change.
public enum MemoryProposalScope: String, Codable, Equatable, Sendable {
    case session
    case project
    case user
}

/// Pure fail-closed bridge from a local admission decision to its permitted lifecycle receipt.
///
/// An admitted proposal may only be approved; a quarantined proposal may only be rejected.
/// Invalid or internally inconsistent admission receipts produce no lifecycle receipt.
/// No transition performs persistence, provider, network, or UI work.
public enum MemoryProposalLifecycle {
    public static func transition(
        from admission: MemoryProposalAdmissionReceipt,
        applying action: MemoryProposalLifecycleAction,
        reason: String
    ) -> MemoryProposalLifecycleReceipt? {
        let state: MemoryProposalLifecycleState

        switch (admission.decision, admission.quarantineReason, action) {
        case (.admitted, nil, .approve):
            state = .approved
        case (.quarantined, .some, .reject):
            state = .rejected
        default:
            return nil
        }

        return MemoryProposalLifecycleReceipt(
            proposalID: admission.proposalID,
            scope: admission.scope,
            memoryScope: admission.memoryScope,
            subjectID: admission.subjectID,
            action: action,
            state: state,
            reason: reason,
            sequence: admission.sequence
        )
    }
}

/// Local lifecycle operation recorded for a memory proposal.
public enum MemoryProposalLifecycleAction: String, Codable, Equatable, Sendable {
    case propose
    case approve
    case reject
    case activate
    case rollback
}

/// State after applying a lifecycle operation to a proposal.
public enum MemoryProposalLifecycleState: String, Codable, Equatable, Sendable {
    case proposed
    case approved
    case rejected
    case active
    case rolledBack
    /// The source's candidate-submission permission was revoked before this
    /// proposal reached an active fact. Existing facts remain independent.
    case revoked
}

/// Deterministic local receipt DTO for a memory proposal lifecycle transition.
/// This is a value-only contract; it performs no persistence or side effects.
public struct MemoryProposalLifecycleReceipt: Codable, Equatable, Sendable {
    public let proposalID: String
    public let scope: MemoryProposalScope
    /// Concrete session/project identity captured at proposal creation.
    ///
    /// Optional decoding keeps old receipts readable; admission treats a
    /// missing or invalid value as quarantined.
    public let memoryScope: MemoryScope?
    public let subjectID: String
    public let action: MemoryProposalLifecycleAction
    public let state: MemoryProposalLifecycleState
    public let reason: String
    public let sequence: Int

    public init(
        proposalID: String,
        scope: MemoryProposalScope,
        memoryScope: MemoryScope? = nil,
        subjectID: String,
        action: MemoryProposalLifecycleAction,
        state: MemoryProposalLifecycleState,
        reason: String,
        sequence: Int
    ) {
        self.proposalID = proposalID
        self.scope = scope
        self.memoryScope = memoryScope
        self.subjectID = subjectID
        self.action = action
        self.state = state
        self.reason = reason
        self.sequence = sequence
    }
}

/// Content-free proposal contract for an external memory read.
public struct MemoryProposal: Codable, Sendable, Equatable {
    public let proposalID: String
    public let target: MemoryReadScope
    public let requestedMemoryScope: MemoryProposalScope
    public let sourceRef: String
    public let contentDigest: String
    public let createdAt: Date
    public let state: MemoryProposalState

    public init(
        proposalID: String,
        target: MemoryReadScope,
        requestedMemoryScope: MemoryProposalScope,
        sourceRef: String,
        contentDigest: String,
        createdAt: Date,
        state: MemoryProposalState = .proposed
    ) {
        self.proposalID = proposalID
        self.target = target
        self.requestedMemoryScope = requestedMemoryScope
        self.sourceRef = sourceRef
        self.contentDigest = contentDigest
        self.createdAt = createdAt
        self.state = state
    }

    fileprivate var isWellFormed: Bool {
        !proposalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && target.isValid
            && !sourceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contentDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate func changingState(_ state: MemoryProposalState) -> MemoryProposal {
        MemoryProposal(
            proposalID: proposalID,
            target: target,
            requestedMemoryScope: requestedMemoryScope,
            sourceRef: sourceRef,
            contentDigest: contentDigest,
            createdAt: createdAt,
            state: state
        )
    }
}

public enum MemoryProposalState: String, Codable, Sendable {
    case proposed
    case reviewed
    case approved
    case rejected
    case active
    case rolledBack
}

/// Audit receipt for a proposal decision or lifecycle transition.
public struct MemoryReceipt: Codable, Sendable, Equatable {
    public let receiptID: String
    public let proposalID: String
    public let state: MemoryProposalState
    public let actor: String
    public let recordedAt: Date
    public let reason: String?

    public init(
        receiptID: String = UUID().uuidString,
        proposalID: String,
        state: MemoryProposalState,
        actor: String,
        recordedAt: Date = Date(),
        reason: String? = nil
    ) {
        self.receiptID = receiptID
        self.proposalID = proposalID
        self.state = state
        self.actor = actor
        self.recordedAt = recordedAt
        self.reason = reason
    }

    public static func from(
        _ proposal: MemoryProposal,
        actor: String
    ) -> MemoryReceipt? {
        guard proposal.isWellFormed,
              [.approved, .rejected].contains(proposal.state),
              !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MemoryReceipt(
            proposalID: proposal.proposalID,
            state: proposal.state,
            actor: actor
        )
    }

    public var redactedLogValue: String {
        "memory-receipt state=\(state.rawValue)"
    }
}

public extension MemoryProposalLifecycle {
    static func review(_ proposal: MemoryProposal) -> MemoryProposal? {
        guard proposal.isWellFormed, proposal.state == .proposed else { return nil }
        return proposal.changingState(.reviewed)
    }

    static func approve(_ proposal: MemoryProposal) -> MemoryProposal? {
        guard proposal.isWellFormed,
              proposal.state == .reviewed,
              proposal.requestedMemoryScope != .user else {
            return nil
        }
        return proposal.changingState(.approved)
    }

    static func reject(_ proposal: MemoryProposal) -> MemoryProposal? {
        guard proposal.isWellFormed, proposal.state == .reviewed else { return nil }
        return proposal.changingState(.rejected)
    }

    static func activate(_ receipt: MemoryReceipt) -> MemoryReceipt? {
        guard receipt.state == .approved else { return nil }
        return MemoryReceipt(
            receiptID: receipt.receiptID,
            proposalID: receipt.proposalID,
            state: .active,
            actor: receipt.actor,
            recordedAt: receipt.recordedAt,
            reason: receipt.reason
        )
    }

    static func rollback(_ receipt: MemoryReceipt, reason: String) -> MemoryReceipt? {
        guard receipt.state == .active,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MemoryReceipt(
            receiptID: receipt.receiptID,
            proposalID: receipt.proposalID,
            state: .rolledBack,
            actor: receipt.actor,
            recordedAt: receipt.recordedAt,
            reason: reason
        )
    }
}
