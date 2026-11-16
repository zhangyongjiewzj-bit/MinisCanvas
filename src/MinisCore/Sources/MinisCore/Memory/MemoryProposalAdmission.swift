import Foundation

/// Outcome of evaluating a memory proposal at the local trust boundary.
public enum MemoryProposalAdmissionDecision: String, Codable, Equatable, Sendable {
    case admitted
    case quarantined
}

/// Stable reason for rejecting a memory proposal without mutating persistence.
public enum MemoryProposalQuarantineReason: String, Codable, Equatable, Sendable {
    case invalidMemoryScope
    case scopeMismatch
    case missingBinding
    case invalidBinding
    case invalidProposalID
    case invalidSubjectID
    case invalidSequence
    case notInitialProposal
    case unsupportedScope
}

/// Deterministic result of evaluating a memory proposal for local admission.
///
/// The receipt deliberately carries only proposal identity and lifecycle metadata.
/// It does not persist, expose, or transform memory content.
public struct MemoryProposalAdmissionReceipt: Codable, Equatable, Sendable {
    public let proposalID: String
    public let scope: MemoryProposalScope
    /// The concrete session/project scope captured with the proposal.
    ///
    /// This is optional only for decoding legacy receipts. Admission rejects
    /// a missing scope so old data cannot cross the current scope boundary.
    public let memoryScope: MemoryScope?
    /// The immutable session/workspace/proposal/source/generation fence.
    /// Missing bindings are retained for decoding only and never admitted.
    public let binding: MemoryProposalBinding?
    public let subjectID: String
    public let sequence: Int
    public let decision: MemoryProposalAdmissionDecision
    public let quarantineReason: MemoryProposalQuarantineReason?

    public init(
        proposalID: String,
        scope: MemoryProposalScope,
        memoryScope: MemoryScope? = nil,
        binding: MemoryProposalBinding? = nil,
        subjectID: String,
        sequence: Int,
        decision: MemoryProposalAdmissionDecision,
        quarantineReason: MemoryProposalQuarantineReason?
    ) {
        self.proposalID = proposalID
        self.scope = scope
        self.memoryScope = memoryScope
        self.binding = binding
        self.subjectID = subjectID
        self.sequence = sequence
        self.decision = decision
        self.quarantineReason = quarantineReason
    }
}

/// Pure fail-closed admission gate for a proposed memory fact.
///
/// This local contract admits only a first lifecycle proposal in a valid session /
/// project scope. User-wide memory requires a separate trust boundary and is
/// quarantined here. No decision performs persistence, provider, network, or UI work.
public enum MemoryProposalAdmission {
    public static func decide(
        _ proposal: MemoryProposalLifecycleReceipt,
        within memoryScope: MemoryScope,
        binding: MemoryProposalBinding? = nil
    ) -> MemoryProposalAdmissionReceipt {
        let reason: MemoryProposalQuarantineReason?
        if !memoryScope.isValid {
            reason = .invalidMemoryScope
        } else if proposal.memoryScope == nil || proposal.memoryScope?.isValid == false {
            reason = .invalidMemoryScope
        } else if proposal.memoryScope != memoryScope {
            reason = .scopeMismatch
        } else if binding == nil {
            reason = .missingBinding
        } else if binding?.isValid != true {
            reason = .invalidBinding
        } else if binding?.matches(
            scope: memoryScope,
            proposalID: proposal.proposalID,
            sourceHash: binding?.sourceHash ?? "",
            generation: binding?.generation ?? -1
        ) != true {
            reason = .invalidBinding
        } else if isBlank(proposal.proposalID) {
            reason = .invalidProposalID
        } else if isBlank(proposal.subjectID) {
            reason = .invalidSubjectID
        } else if proposal.sequence <= 0 {
            reason = .invalidSequence
        } else if proposal.action != .propose || proposal.state != .proposed {
            reason = .notInitialProposal
        } else if proposal.scope == .user {
            reason = .unsupportedScope
        } else {
            reason = nil
        }

        return MemoryProposalAdmissionReceipt(
            proposalID: proposal.proposalID,
            scope: proposal.scope,
            memoryScope: proposal.memoryScope,
            binding: binding,
            subjectID: proposal.subjectID,
            sequence: proposal.sequence,
            decision: reason == nil ? .admitted : .quarantined,
            quarantineReason: reason
        )
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
