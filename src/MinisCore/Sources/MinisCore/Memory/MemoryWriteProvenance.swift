import Foundation
import CryptoKit

/// A source adapter's opaque identity claim for one proposed memory write.
/// This is provenance, never a candidate grant or per-fact approval. Future
/// adapters must independently bind these IDs to their real producer event.
public struct MemoryWriteProvenanceInput: Equatable, Sendable {
    public let actorID: String
    public let runID: String
    public let triggerID: String
    public let sourceID: String

    public init(actorID: String, runID: String, triggerID: String, sourceID: String) {
        self.actorID = actorID
        self.runID = runID
        self.triggerID = triggerID
        self.sourceID = sourceID
    }

    var isWellFormed: Bool {
        [actorID, runID, triggerID, sourceID].allSatisfy {
            !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Durable origin captured only after the current source grant supplies its
/// epoch. The digest detects a changed field at the existing persisted
/// proposal boundary; it is not a signature or proof of an external actor.
public struct MemoryWriteProvenance: Codable, Equatable, Hashable, Sendable {
    public let actorID: String
    public let runID: String
    public let triggerID: String
    public let sourceID: String
    public let submissionEpoch: UInt64
    public let sourceHash: String
    public let generation: Int
    public let bindingDigest: String

    private struct BindingMaterial: Encodable {
        let actorID: String
        let runID: String
        let triggerID: String
        let sourceID: String
        let submissionEpoch: UInt64
        let proposalID: String
        let memoryScope: MemoryScope
        let contentDigest: String
        let sourceHash: String
        let generation: Int
    }

    static func capture(
        _ input: MemoryWriteProvenanceInput,
        submissionEpoch: UInt64,
        proposalID: String,
        memoryScope: MemoryScope,
        contentDigest: String,
        sourceHash: String,
        generation: Int
    ) -> MemoryWriteProvenance? {
        guard input.isWellFormed,
              let digest = digest(
                actorID: input.actorID, runID: input.runID,
                triggerID: input.triggerID, sourceID: input.sourceID,
                submissionEpoch: submissionEpoch, proposalID: proposalID,
                memoryScope: memoryScope, contentDigest: contentDigest,
                sourceHash: sourceHash, generation: generation
              ) else { return nil }
        return MemoryWriteProvenance(
            actorID: input.actorID, runID: input.runID,
            triggerID: input.triggerID, sourceID: input.sourceID,
            submissionEpoch: submissionEpoch, sourceHash: sourceHash,
            generation: generation, bindingDigest: digest
        )
    }

    func matches(
        sourceID expectedSourceID: String?,
        submissionEpoch expectedEpoch: UInt64?,
        proposalID: String,
        memoryScope: MemoryScope,
        contentDigest: String,
        sourceHash: String,
        generation: Int
    ) -> Bool {
        guard let expectedSourceID, let expectedEpoch,
              sourceID == expectedSourceID,
              submissionEpoch == expectedEpoch,
              self.sourceHash == sourceHash,
              self.generation == generation,
              MemoryWriteProvenanceInput(
                actorID: actorID, runID: runID,
                triggerID: triggerID, sourceID: sourceID
              ).isWellFormed else { return false }
        return bindingDigest == Self.digest(
            actorID: actorID, runID: runID,
            triggerID: triggerID, sourceID: sourceID,
            submissionEpoch: submissionEpoch, proposalID: proposalID,
            memoryScope: memoryScope, contentDigest: contentDigest,
            sourceHash: sourceHash, generation: generation
        )
    }

    func matchesFact(
        proposalID: String?,
        memoryScope: MemoryScope?,
        contentDigest: String?
    ) -> Bool {
        guard let proposalID, let memoryScope, let contentDigest,
              memoryScope.isValid,
              !sourceHash.isEmpty, generation >= 0,
              MemoryWriteProvenanceInput(
                actorID: actorID, runID: runID,
                triggerID: triggerID, sourceID: sourceID
              ).isWellFormed else { return false }
        return bindingDigest == Self.digest(
            actorID: actorID, runID: runID,
            triggerID: triggerID, sourceID: sourceID,
            submissionEpoch: submissionEpoch, proposalID: proposalID,
            memoryScope: memoryScope, contentDigest: contentDigest,
            sourceHash: sourceHash, generation: generation
        )
    }

    private static func digest(
        actorID: String, runID: String, triggerID: String,
        sourceID: String, submissionEpoch: UInt64,
        proposalID: String, memoryScope: MemoryScope,
        contentDigest: String, sourceHash: String, generation: Int
    ) -> String? {
        let material = BindingMaterial(
            actorID: actorID, runID: runID, triggerID: triggerID,
            sourceID: sourceID, submissionEpoch: submissionEpoch,
            proposalID: proposalID, memoryScope: memoryScope,
            contentDigest: contentDigest, sourceHash: sourceHash,
            generation: generation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(material) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
