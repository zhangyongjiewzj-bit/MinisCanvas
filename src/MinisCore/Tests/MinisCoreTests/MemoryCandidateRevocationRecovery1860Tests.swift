import Foundation
import Testing
@testable import MinisCore

private enum MemoryRevocationInterruption1860: Error {
    case afterAuthorityPersisted
}

@Suite("D-MEMA revocation survives interruption between durable records")
struct MemoryCandidateRevocationRecovery1860Tests {
    @Test func interruptedRevocationRejectsOldApprovalAndNewSubmissionAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-revoke-1860-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scope = MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project")
        let sourceID = "scheduler-task:synthetic-task"
        let origin = MemoryWriteProvenanceInput(
            actorID: "synthetic-actor", runID: "synthetic-run",
            triggerID: "synthetic-occurrence", sourceID: sourceID
        )
        let seed = MemoryProposalConsumer(store: MemoryStore(directory: root))
        _ = try seed.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic task enabled")
        let active = try seed.submit(
            proposalID: "already-active", text: "approved synthetic fact",
            within: scope, sourceID: sourceID, writeProvenance: origin
        )
        _ = try seed.approve(
            proposalID: active.proposal.proposalID, within: scope,
            reason: "individual synthetic fact approval"
        )
        let pending = try seed.submit(
            proposalID: "pending-before-revoke", text: "pending synthetic fact",
            within: scope, sourceID: sourceID, writeProvenance: origin
        )

        let interrupted = MemoryProposalConsumer(
            store: MemoryStore(directory: root),
            revocationFaultInjector: { throw MemoryRevocationInterruption1860.afterAuthorityPersisted }
        )
        #expect(throws: MemoryRevocationInterruption1860.afterAuthorityPersisted) {
            _ = try interrupted.revokeCandidateSubmission(
                sourceID: sourceID, reason: "synthetic explicit revoke"
            )
        }

        // The proposal projection has not yet been updated. Recovery must
        // still use the durable authority epoch to reject both operations.
        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: root))
        let authorization = try #require(reopened.candidateSubmissionAuthorizations()
            .first(where: { $0.sourceID == sourceID }))
        #expect(!authorization.canSubmit)
        #expect(authorization.epoch == pending.submissionEpoch.map { $0 + 1 })
        #expect(try reopened.envelopes().first(where: {
            $0.proposal.proposalID == pending.proposal.proposalID
        })?.state == .proposed)
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try reopened.approve(
                proposalID: pending.proposal.proposalID, within: scope,
                reason: "old pending fact must stay blocked"
            )
        }
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try reopened.submit(
                proposalID: "new-after-revoke", text: "must not enter",
                within: scope, sourceID: sourceID, writeProvenance: origin
            )
        }
        let facts = try reopened.store.activeFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.sourceProposalID == active.proposal.proposalID)
        #expect(facts.first?.writeProvenance == active.writeProvenance)

        _ = try reopened.grantCandidateSubmission(
            sourceID: sourceID, reason: "synthetic user separately reenabled task"
        )
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionEpochMismatch) {
            _ = try reopened.approve(
                proposalID: pending.proposal.proposalID, within: scope,
                reason: "old epoch cannot revive after reenable"
            )
        }
        #expect(try reopened.store.activeFacts().count == 1)
    }
}
