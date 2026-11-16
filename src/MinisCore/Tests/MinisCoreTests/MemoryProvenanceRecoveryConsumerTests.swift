import Foundation
import Testing
@testable import MinisCore

@Suite("Memory provenance and recovery consumers", .serialized)
struct MemoryProvenanceRecoveryConsumerTests {
    private let memoryScope = MemoryScope(sessionID: "session-a", projectID: "project-a")

    private func snapshot() -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            sessionID: "session-a",
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "configuration-a",
            skillIdentifiers: ["browser"],
            conversationID: "conversation-a"
        )
    }

    private func manifest() -> (ContextManifest, ContextManifestReceipt) {
        let value = ContextManifest(
            snapshot: snapshot(),
            entries: [ContextManifest.Entry(
                identifier: "entry-a",
                tokenCost: 2,
                provenance: "memory:source-a",
                contentHash: "digest-a"
            )]
        )
        return (value, ContextManifestReceipt(
            runID: "run-a",
            requestedBudget: 4,
            usedBudget: 2,
            droppedEntryIDs: []
        ))
    }

    private func provenance() -> MemoryProvenance {
        MemoryProvenance(
            sourceID: "source-a",
            grantID: "grant-a",
            scope: MemoryReadScope(memoryScope: memoryScope, content: .metadata),
            contentDigest: "digest-a",
            sourceRevision: 4
        )
    }

    @Test("provenance-bound delete requires explicit confirmation and tombstones late writes")
    func explicitDeleteAndLateWrite() throws {
        let store = ContextManifestStore()
        let (value, receipt) = manifest()
        let origin = provenance()
        _ = try store.record(manifest: value, receipt: receipt, provenance: origin)
        let confirmation = MemoryDeleteConfirmation(
            confirmationID: "confirmation-a",
            targetID: receipt.runID,
            provenance: origin,
            actorID: "user-a",
            confirmedAt: Date(timeIntervalSince1970: 10)
        )

        let deletion = try store.delete(
            runID: receipt.runID,
            confirmation: confirmation,
            now: Date(timeIntervalSince1970: 11)
        )
        #expect(deletion.confirmationID == "confirmation-a")
        #expect(deletion.provenance == origin)
        #expect(store.manifest(runID: receipt.runID) == nil)
        #expect(store.deletionReceipt(runID: receipt.runID) == deletion)
        #expect(throws: ContextManifestStoreError.staleWrite) {
            try store.record(manifest: value, receipt: receipt, provenance: origin)
        }
        #expect(try store.delete(runID: receipt.runID, confirmation: confirmation, now: Date(timeIntervalSince1970: 12)) == deletion)
    }

    @Test("persisted tombstones remain provenance-bound across restart")
    func persistedTombstoneRejectsSameIDWithDifferentProvenance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextManifestTombstone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        let origin = provenance()
        let (value, receipt) = manifest()
        let confirmation = MemoryDeleteConfirmation(
            confirmationID: "confirmation-persisted",
            targetID: receipt.runID,
            provenance: origin,
            actorID: "user-a",
            confirmedAt: Date(timeIntervalSince1970: 10)
        )
        let first = try ContextManifestStore(persistenceURL: url)
        _ = try first.record(manifest: value, receipt: receipt, provenance: origin)
        let deletion = try first.delete(runID: receipt.runID, confirmation: confirmation, now: Date(timeIntervalSince1970: 11))

        let restarted = try ContextManifestStore(persistenceURL: url)
        #expect(restarted.deletionReceipt(runID: receipt.runID) == deletion)
        #expect(try restarted.delete(runID: receipt.runID, confirmation: confirmation, now: Date(timeIntervalSince1970: 12)) == deletion)

        let changed = MemoryProvenance(
            sourceID: origin.sourceID,
            grantID: origin.grantID,
            scope: origin.scope,
            contentDigest: "different-digest",
            sourceRevision: origin.sourceRevision + 1
        )
        let forged = MemoryDeleteConfirmation(
            confirmationID: confirmation.confirmationID,
            targetID: confirmation.targetID,
            provenance: changed,
            actorID: confirmation.actorID,
            confirmedAt: confirmation.confirmedAt
        )
        #expect(throws: ContextManifestStoreError.deletionConflict) {
            try restarted.delete(runID: receipt.runID, confirmation: forged, now: Date(timeIntervalSince1970: 12))
        }
    }

    @Test("stale manifest writer cannot overwrite a recovered checkpoint")
    func staleManifestWriterFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextManifestStale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        let origin = provenance()
        let (value, receipt) = manifest()
        let first = try ContextManifestStore(persistenceURL: url)
        let stale = try ContextManifestStore(persistenceURL: url)
        _ = try first.record(manifest: value, receipt: receipt, provenance: origin)
        #expect(throws: ContextManifestStoreError.persistenceFailed) {
            try stale.record(
                manifest: value,
                receipt: ContextManifestReceipt(
                    runID: "run-b",
                    requestedBudget: 4,
                    usedBudget: 2,
                    droppedEntryIDs: []
                ),
                provenance: origin
            )
        }
        let recovered = try ContextManifestStore(persistenceURL: url)
        #expect(recovered.manifest(runID: receipt.runID) == value)
        #expect(recovered.deletionReceipt(runID: receipt.runID) == nil)
    }

    @Test("wrong provenance and legacy records cannot be deleted")
    func deleteFailsClosed() throws {
        let store = ContextManifestStore()
        let (value, receipt) = manifest()
        _ = try store.record(manifest: value, receipt: receipt)
        let confirmation = MemoryDeleteConfirmation(
            confirmationID: "confirmation-b",
            targetID: receipt.runID,
            provenance: provenance(),
            actorID: "user-a",
            confirmedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(throws: ContextManifestStoreError.deletionRequiresProvenance) {
            try store.delete(runID: receipt.runID, confirmation: confirmation)
        }
    }

    @Test("corrupt checkpoint enters fail-closed recovery")
    func corruptCheckpointFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextManifestCorrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        try Data(#"{"schemaVersion":99,"records":{}}"#.utf8).write(to: url)
        let store = try ContextManifestStore(persistenceURL: url)
        #expect(store.persistenceDiagnostics() != nil)
        let (value, receipt) = manifest()
        #expect(throws: ContextManifestStoreError.persistenceFailed) {
            try store.record(manifest: value, receipt: receipt, provenance: provenance())
        }
    }

    @Test("turn recovery advances generation and rejects late callbacks")
    func generationFenceAndRestartRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTurnRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("turns.json")
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "session-a", turnID: 1, messageID: "message-a"),
            operationID: "operation-a",
            attempt: 0
        )
        let context = snapshot()
        let first = try AgentTurnContextStore(persistenceURL: url)
        #expect(try first.begin(identity: identity, snapshot: context, generation: 1))
        #expect(try first.recoverInterrupted(identity: identity, snapshot: context, generation: 1))

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(restarted.record(for: identity)?.status == .needsUserReview)
        #expect(try restarted.reopenAfterRecovery(identity: identity, snapshot: context, generation: 2))
        #expect(try restarted.admitWriteback(identity: identity, snapshot: context, currentSnapshot: context, generation: 1) == false)
        #expect(try restarted.admitWriteback(identity: identity, snapshot: context, currentSnapshot: context, generation: 2))
    }
}
