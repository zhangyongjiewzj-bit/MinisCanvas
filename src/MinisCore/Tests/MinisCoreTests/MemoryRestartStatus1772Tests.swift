import Foundation
import Testing
@testable import MinisCore

@Suite("D-MEMORY-12 durable source and effective-state recovery", .serialized)
struct MemoryRestartStatus1772Tests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-restart-1772-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    @Test func reopenedFactRetainsSourceWhileRevokedSourceCannotSubmitAgain() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project")
        let sourceID = "synthetic-scheduled-source"
        let first = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let grant = try first.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic enable")
        let submitted = try first.submit(
            proposalID: "synthetic-proposal", text: "orbital peach preference",
            within: scope, sourceRef: "synthetic://run/1", sourceHash: "synthetic-effect-1",
            generation: 1, sourceID: sourceID,
            writeProvenance: MemoryWriteProvenanceInput(
                actorID: "synthetic-actor", runID: "synthetic-run",
                triggerID: "synthetic-trigger", sourceID: sourceID
            )
        )
        #expect(submitted.writeProvenance?.submissionEpoch == grant.epoch)
        _ = try first.approve(
            proposalID: "synthetic-proposal", within: scope,
            reason: "synthetic per-fact approval"
        )
        _ = try first.revokeCandidateSubmission(sourceID: sourceID, reason: "synthetic revoke")

        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let fact = try #require(reopened.store.activeFacts().first)
        #expect(fact.text == "orbital peach preference")
        #expect(fact.memoryScope == scope)
        #expect(fact.sourceProposalID == "synthetic-proposal")
        #expect(fact.sourceRef == "synthetic://run/1")
        #expect(fact.writeProvenance == submitted.writeProvenance)
        #expect(try reopened.candidateSubmissionAuthorizations().first(where: {
            $0.sourceID == sourceID
        })?.canSubmit == false)
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try reopened.submit(
                proposalID: "synthetic-late", text: "must remain pending",
                within: scope, sourceID: sourceID
            )
        }
        #expect(try MemoryInjector(store: reopened.store).systemPrompt(
            base: "base", userMessage: "orbital peach", memoryScope: scope
        ).contains(fact.text))
    }

    @Test func strippedTombstoneStateCannotReviveFactAfterRestart() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = MemoryStore(directory: directory)
        let fact = try writer.addFact("synthetic removed memory")
        _ = try writer.tombstoneFact(id: fact.id, reason: "synthetic deletion")
        #expect(try MemoryStore(directory: directory).activeFacts().isEmpty)

        let original = try Data(contentsOf: writer.fileURL)
        var rows = try #require(JSONSerialization.jsonObject(with: original) as? [[String: Any]])
        rows[0].removeValue(forKey: "lifecycleState")
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: writer.fileURL, options: .atomic)

        let reopened = MemoryStore(directory: directory)
        #expect(throws: MemoryStoreError.invalidLifecycleState) {
            _ = try reopened.activeFacts()
        }
        #expect(throws: MemoryStoreError.invalidLifecycleState) {
            _ = try MemoryInjector(store: reopened).systemPrompt(
                base: "base", userMessage: "synthetic removed"
            )
        }
        try original.write(to: writer.fileURL, options: .atomic)
        #expect(try MemoryStore(directory: directory).activeFacts().isEmpty)
    }

    @Test func actualLegacyFactWithoutReceiptStillLoadsAsActive() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = MemoryStore(directory: directory)
        let fact = try writer.addFact("synthetic legacy memory")
        var rows = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: writer.fileURL)
        ) as? [[String: Any]])
        rows[0].removeValue(forKey: "lifecycleState")
        rows[0].removeValue(forKey: "activatedAt")
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: writer.fileURL, options: .atomic)

        let reopened = MemoryStore(directory: directory)
        #expect(try reopened.activeFacts().map(\.id) == [fact.id])
        #expect(try reopened.lifecycleReceipts().isEmpty)
    }
}
