import Foundation
import Testing
@testable import MinisCore

@Suite("D-MEMA typed source provenance substrate")
struct MemoryWriteProvenance1680Tests {
    private let sourceID = "opaque-scheduled-fixture-1680"
    private let scope = MemoryScope(sessionID: "mema1680-session", projectID: "mema1680-project")

    private func fixture() throws -> (URL, MemoryProposalConsumer) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mema1680-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return (root, MemoryProposalConsumer(store: MemoryStore(directory: root)))
    }

    private func origin(sourceID: String) -> MemoryWriteProvenanceInput {
        MemoryWriteProvenanceInput(
            actorID: "fixture-actor", runID: "fixture-run",
            triggerID: "fixture-occurrence", sourceID: sourceID
        )
    }

    private func rewriteFirstRecord(
        at url: URL,
        _ change: (inout [String: Any]) -> Void
    ) throws {
        var records = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        )
        change(&records[0])
        try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
    }

    @Test func explicitGrantThenSeparateApprovalPersistsTheSameTypedOrigin() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionUnauthorized) {
            _ = try consumer.submit(
                proposalID: "ungranted", text: "synthetic fact", within: scope,
                sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
            )
        }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        let submitted = try consumer.submit(
            proposalID: "typed-proposal", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        let captured = try #require(submitted.writeProvenance)
        #expect(submitted.version == MemoryProposalEnvelope.currentVersion)
        #expect(captured.actorID == "fixture-actor")
        #expect(captured.runID == "fixture-run")
        #expect(captured.triggerID == "fixture-occurrence")
        #expect(captured.sourceID == submitted.sourceID)
        #expect(captured.submissionEpoch == submitted.submissionEpoch)
        #expect(try consumer.store.facts().isEmpty)

        let displayed = try #require(consumer.envelopes().first)
        #expect(displayed == submitted)
        _ = try consumer.approve(
            proposalID: displayed.proposal.proposalID, within: scope,
            reason: "synthetic per-fact user approval",
            generation: displayed.generation, sourceHash: displayed.sourceHash
        )
        let fact = try #require(consumer.store.facts().first)
        #expect(fact.writeProvenance == captured)
        #expect(fact.sourceProposalID == displayed.proposal.proposalID)
        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: root))
        #expect(try reopened.envelopes().first?.writeProvenance == captured)
        #expect(try reopened.store.facts().first?.writeProvenance == captured)
        #expect(try reopened.recoverApprovedProposals() == 1)

        _ = try reopened.revokeCandidateSubmission(sourceID: sourceID, reason: "synthetic revoke")
        #expect(try reopened.store.activeFacts().first?.writeProvenance == captured)
    }

    @Test func sourceMismatchAndOldEpochCannotBeApproved() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            _ = try consumer.submit(
                proposalID: "wrong-source", text: "synthetic fact", within: scope,
                sourceID: sourceID,
                writeProvenance: origin(sourceID: "other-opaque-source")
            )
        }
        #expect(try consumer.envelopes().isEmpty)
        let pending = try consumer.submit(
            proposalID: "old-epoch", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        _ = try consumer.revokeCandidateSubmission(sourceID: sourceID, reason: "synthetic revoke")
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic re-enable")
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionEpochMismatch) {
            _ = try consumer.approve(
                proposalID: pending.proposal.proposalID,
                within: scope, reason: "old epoch must not revive"
            )
        }
        #expect(try consumer.store.facts().isEmpty)
    }

    @Test(arguments: ["actorID", "runID", "triggerID", "sourceID"])
    func changedOriginFieldCannotReachApproval(_ field: String) throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        _ = try consumer.submit(
            proposalID: "tamper-proposal", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        let data = try Data(contentsOf: consumer.receiptURL)
        var records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var storedOrigin = try #require(records[0]["writeProvenance"] as? [String: Any])
        storedOrigin[field] = "different-opaque-id"
        records[0]["writeProvenance"] = storedOrigin
        try JSONSerialization.data(withJSONObject: records).write(to: consumer.receiptURL, options: .atomic)

        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            _ = try consumer.approve(
                proposalID: "tamper-proposal", within: scope,
                reason: "changed origin must fail"
            )
        }
        #expect(try consumer.store.facts().isEmpty)
    }

    @Test func changedDurableFactOriginIsRejectedOnReload() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        _ = try consumer.submit(
            proposalID: "fact-tamper", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        _ = try consumer.approve(
            proposalID: "fact-tamper", within: scope,
            reason: "synthetic per-fact user approval"
        )
        let data = try Data(contentsOf: consumer.store.fileURL)
        var records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var storedOrigin = try #require(records[0]["writeProvenance"] as? [String: Any])
        storedOrigin["runID"] = "different-run"
        records[0]["writeProvenance"] = storedOrigin
        try JSONSerialization.data(withJSONObject: records).write(to: consumer.store.fileURL, options: .atomic)
        #expect(throws: MemoryStoreError.invalidProvenance) {
            _ = try MemoryStore(directory: root).facts()
        }
    }

    @Test func deletingWholeTypedProposalFieldCannotDowngradeApproval() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        let submitted = try consumer.submit(
            proposalID: "proposal-field-removed", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        #expect(submitted.version == MemoryProposalEnvelope.currentVersion)
        try rewriteFirstRecord(at: consumer.receiptURL) {
            _ = $0.removeValue(forKey: "writeProvenance")
        }
        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            _ = try consumer.approve(
                proposalID: submitted.proposal.proposalID, within: scope,
                reason: "must not approve stripped origin"
            )
        }
        #expect(try consumer.store.facts().isEmpty)
    }

    @Test func deletingWholeTypedProposalFieldCannotDowngradeRecovery() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        _ = try consumer.submit(
            proposalID: "recovery-field-removed", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        _ = try consumer.approve(
            proposalID: "recovery-field-removed", within: scope,
            reason: "synthetic per-fact user approval"
        )
        let beforeFacts = try Data(contentsOf: consumer.store.fileURL)
        try rewriteFirstRecord(at: consumer.receiptURL) {
            $0["state"] = "approved"
            _ = $0.removeValue(forKey: "writeProvenance")
        }
        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            _ = try MemoryProposalConsumer(store: MemoryStore(directory: root))
                .recoverApprovedProposals()
        }
        #expect(try Data(contentsOf: consumer.store.fileURL) == beforeFacts)
    }

    @Test func deletingWholeTypedFactFieldFailsOrdinaryFactsAndActiveFactsReads() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        _ = try consumer.submit(
            proposalID: "fact-field-removed", text: "synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        _ = try consumer.approve(
            proposalID: "fact-field-removed", within: scope,
            reason: "synthetic per-fact user approval"
        )
        try rewriteFirstRecord(at: consumer.store.fileURL) {
            _ = $0.removeValue(forKey: "writeProvenance")
        }
        let reopened = MemoryStore(directory: root)
        #expect(throws: MemoryStoreError.invalidProvenance) { _ = try reopened.facts() }
        #expect(throws: MemoryStoreError.invalidProvenance) { _ = try reopened.activeFacts() }
    }

    @Test func typedRevisionKeepsTheNewProposalOriginWithoutChangingTheOldFact() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        let first = try consumer.submit(
            proposalID: "revision-base", text: "first synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: origin(sourceID: sourceID)
        )
        _ = try consumer.approve(
            proposalID: first.proposal.proposalID, within: scope,
            reason: "synthetic per-fact user approval"
        )
        let next = try consumer.submit(
            proposalID: "revision-next", text: "revised synthetic fact", within: scope,
            sourceID: sourceID, writeProvenance: MemoryWriteProvenanceInput(
                actorID: "fixture-actor", runID: "fixture-second-run",
                triggerID: "fixture-second-occurrence", sourceID: sourceID
            )
        )
        _ = try consumer.approveRevision(
            proposalID: next.proposal.proposalID,
            supersedingFactID: first.proposal.subjectID,
            within: scope, reason: "synthetic separate revision approval"
        )
        let facts = try consumer.store.facts()
        #expect(facts.count == 2)
        #expect(facts.first { $0.id == first.proposal.subjectID }?.writeProvenance == first.writeProvenance)
        #expect(facts.first { $0.id == next.proposal.subjectID }?.writeProvenance == next.writeProvenance)
    }

    @Test func truePreTypedVersionThreeRecordStillDecodesWithoutAnOrigin() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic explicit grant")
        _ = try consumer.submit(
            proposalID: "old-format", text: "legacy synthetic fact", within: scope,
            sourceID: sourceID
        )
        try rewriteFirstRecord(at: consumer.receiptURL) {
            $0["version"] = 3
            _ = $0.removeValue(forKey: "sourceID")
            _ = $0.removeValue(forKey: "submissionEpoch")
        }
        let old = try #require(consumer.envelopes().first)
        #expect(old.version == 3)
        #expect(old.writeProvenance == nil)
    }

    @Test func legacyBuiltInProposalWithoutTypedOriginKeepsExistingApproval() throws {
        let (root, consumer) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try consumer.grantCandidateSubmission(sourceID: "composer-command", reason: "synthetic built-in grant")
        let submitted = try consumer.submit(
            proposalID: "legacy-built-in", text: "synthetic fact", within: scope,
            sourceID: "composer-command"
        )
        #expect(submitted.writeProvenance == nil)
        #expect(submitted.version == MemoryProposalEnvelope.untypedVersion)
        _ = try consumer.approve(
            proposalID: submitted.proposal.proposalID, within: scope,
            reason: "synthetic per-fact user approval"
        )
        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: root))
        #expect(try reopened.envelopes().first?.writeProvenance == nil)
        #expect(try reopened.store.facts().first?.writeProvenance == nil)
    }
}
