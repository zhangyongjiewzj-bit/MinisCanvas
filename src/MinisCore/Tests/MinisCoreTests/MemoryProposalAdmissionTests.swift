import Foundation
import Testing
@testable import MinisCore

struct MemoryProposalAdmissionTests {
    private func matchingBinding(
        proposalID: String,
        scope: MemoryScope = MemoryScope(sessionID: "session-1", projectID: "project-1")
    ) -> MemoryProposalBinding {
        MemoryProposalBinding(
            sessionID: scope.sessionID,
            workspaceID: scope.workspaceID,
            proposalID: proposalID,
            sourceHash: "source-hash",
            generation: 0
        )
    }

    @Test func quarantinesProposalFromDifferentMemoryScope() {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-scope-mismatch",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-2", projectID: "project-1"),
            subjectID: "memory-001",
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: 1
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1")
        )

        #expect(receipt.decision == .quarantined)
        #expect(receipt.quarantineReason == .scopeMismatch)
    }

    @Test func admitsInitialProposalWithinValidLocalScope() {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: "memory-001",
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: 1
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: proposal.proposalID)
        )

        #expect(receipt.decision == .admitted)
        #expect(receipt.quarantineReason == nil)
        #expect(receipt.proposalID == "proposal-001")
        #expect(receipt.scope == .project)
        #expect(receipt.subjectID == "memory-001")
        #expect(receipt.sequence == 1)
    }

    @Test func quarantinesInvalidScopeBeforeAnyProposalFields() {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: "memory-001",
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: 1
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: " ", projectID: "project-1")
        )

        #expect(receipt.decision == .quarantined)
        #expect(receipt.quarantineReason == .invalidMemoryScope)
    }

    @Test func quarantinesLegacyProposalWithoutConcreteScope() {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "legacy-proposal",
            scope: .session,
            subjectID: "legacy-memory",
            action: .propose,
            state: .proposed,
            reason: "legacy receipt",
            sequence: 1
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: proposal.proposalID)
        )

        #expect(receipt.decision == .quarantined)
        #expect(receipt.quarantineReason == .invalidMemoryScope)
    }

    @Test(arguments: [
        (MemoryProposalLifecycleAction.approve, MemoryProposalLifecycleState.approved),
        (.reject, .rejected),
        (.activate, .active),
        (.rollback, .rolledBack)
    ])
    func quarantinesNonInitialLifecycleTransitions(
        _ action: MemoryProposalLifecycleAction,
        _ state: MemoryProposalLifecycleState
    ) {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .session,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: "memory-001",
            action: action,
            state: state,
            reason: "candidate memory",
            sequence: 1
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: proposal.proposalID)
        )

        #expect(receipt.decision == .quarantined)
        #expect(receipt.quarantineReason == .notInitialProposal)
    }

    @Test(arguments: [
        ("", "memory-001", 1, MemoryProposalQuarantineReason.invalidBinding),
        ("proposal-001", " ", 1, .invalidSubjectID),
        ("proposal-001", "memory-001", 0, .invalidSequence)
    ])
    func quarantinesIncompleteProposalIdentity(
        _ proposalID: String,
        _ subjectID: String,
        _ sequence: Int,
        _ reason: MemoryProposalQuarantineReason
    ) {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: proposalID,
            scope: .session,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: subjectID,
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: sequence
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: proposal.proposalID)
        )

        #expect(receipt.decision == .quarantined)
        #expect(receipt.quarantineReason == reason)
    }

    @Test func quarantinesUserScopeWithoutAUserTrustBoundary() {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .user,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: "memory-001",
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: 1
        )

        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: proposal.proposalID)
        )

        #expect(receipt.decision == .quarantined)
        #expect(receipt.quarantineReason == .unsupportedScope)
    }

    @Test func admittedDecisionCreatesOnlyAnApprovalLifecycleReceipt() {
        let admission = MemoryProposalAdmissionReceipt(
            proposalID: "proposal-001",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: "proposal-001"),
            subjectID: "memory-001",
            sequence: 1,
            decision: .admitted,
            quarantineReason: nil
        )

        let receipt = MemoryProposalLifecycle.transition(
            from: admission,
            applying: .approve,
            reason: "approved by local policy"
        )

        #expect(receipt == MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: "memory-001",
            action: .approve,
            state: .approved,
            reason: "approved by local policy",
            sequence: 1
        ))
    }

    @Test func quarantinedDecisionCreatesOnlyARejectionLifecycleReceipt() {
        let admission = MemoryProposalAdmissionReceipt(
            proposalID: "proposal-001",
            scope: .session,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: "proposal-001"),
            subjectID: "memory-001",
            sequence: 1,
            decision: .quarantined,
            quarantineReason: .invalidSubjectID
        )

        let receipt = MemoryProposalLifecycle.transition(
            from: admission,
            applying: .reject,
            reason: "quarantined"
        )

        #expect(receipt?.action == .reject)
        #expect(receipt?.state == .rejected)
        #expect(receipt?.proposalID == "proposal-001")
    }

    @Test(arguments: [
        (MemoryProposalAdmissionDecision.admitted, MemoryProposalLifecycleAction.reject),
        (.quarantined, .approve),
        (.admitted, .activate),
        (.quarantined, .rollback)
    ])
    func incompatibleAdmissionTransitionFailsClosed(
        _ decision: MemoryProposalAdmissionDecision,
        _ action: MemoryProposalLifecycleAction
    ) {
        let receipt = MemoryProposalLifecycle.transition(
            from: MemoryProposalAdmissionReceipt(
                proposalID: "proposal-001",
                scope: .project,
                memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
                binding: matchingBinding(proposalID: "proposal-001"),
                subjectID: "memory-001",
                sequence: 1,
                decision: decision,
                quarantineReason: decision == .quarantined ? .invalidSubjectID : nil
            ),
            applying: action,
            reason: "attempted transition"
        )

        #expect(receipt == nil)
    }

    @Test func inconsistentAdmissionReceiptFailsClosed() {
        let admittedWithQuarantineReason = MemoryProposalAdmissionReceipt(
            proposalID: "proposal-001",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: "proposal-001"),
            subjectID: "memory-001",
            sequence: 1,
            decision: .admitted,
            quarantineReason: .invalidSubjectID
        )
        let quarantinedWithoutReason = MemoryProposalAdmissionReceipt(
            proposalID: "proposal-002",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: "proposal-002"),
            subjectID: "memory-002",
            sequence: 1,
            decision: .quarantined,
            quarantineReason: nil
        )

        #expect(MemoryProposalLifecycle.transition(
            from: admittedWithQuarantineReason,
            applying: .approve,
            reason: "attempted transition"
        ) == nil)
        #expect(MemoryProposalLifecycle.transition(
            from: quarantinedWithoutReason,
            applying: .reject,
            reason: "attempted transition"
        ) == nil)
    }

    @Test func decisionReceiptHasStableCodableRepresentation() throws {
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .project,
            memoryScope: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            subjectID: "memory-001",
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: 1
        )
        let receipt = MemoryProposalAdmission.decide(
            proposal,
            within: MemoryScope(sessionID: "session-1", projectID: "project-1"),
            binding: matchingBinding(proposalID: proposal.proposalID)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)

        #expect(String(data: data, encoding: .utf8) == "{\"binding\":{\"generation\":0,\"proposalID\":\"proposal-001\",\"sessionID\":\"session-1\",\"sourceHash\":\"source-hash\",\"workspaceID\":\"project-1\"},\"decision\":\"admitted\",\"memoryScope\":{\"projectID\":\"project-1\",\"sessionID\":\"session-1\"},\"proposalID\":\"proposal-001\",\"scope\":\"project\",\"sequence\":1,\"subjectID\":\"memory-001\"}")
        #expect(try JSONDecoder().decode(MemoryProposalAdmissionReceipt.self, from: data) == receipt)
    }
}
