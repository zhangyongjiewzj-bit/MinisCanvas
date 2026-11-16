import CryptoKit
import Foundation

/// A durable compaction result. Schema 1 replaced the canonical transcript;
/// schema 2 keeps it intact and stores only a model-request projection.
public struct CompactionCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let projectionSchemaVersion = 2
    public static let segmentedProjectionSchemaVersion = 3
    /// Schema 4: `[model-written lossy summary] + [store-facts background]? +
    /// exact recent tail`. The summary cannot be reconstructed from the source,
    /// so it is verified by the source-prefix digest and the exact tail only;
    /// the store facts are verified like schema 3's.
    public static let lossySummarySchemaVersion = 4

    // Checkpoints are durable, user-controlled JSON sidecars. Keep their
    // identity path-safe and their replacement payload bounded before any
    // filesystem operation can observe it.
    static let maxPersistedBytes = 4 * 1024 * 1024
    static let maxReplacementHistoryCount = 512
    static let maxMessageContentBytes = 1 * 1024 * 1024

    public let schemaVersion: Int
    public let checkpointID: String
    public let sessionID: String
    public let sourceTranscriptRevision: UInt64
    public let resultTranscriptRevision: UInt64
    public let compactedThroughMessageID: String
    public let compactedMessageRange: Range<Int>
    public let summaryMessage: LLMMessage
    public let replacementHistory: [LLMMessage]
    /// Schema 2 only: SHA-256 of the exact canonical source prefix. A later
    /// append may extend the transcript, but it cannot change this prefix.
    public let sourcePrefixDigest: String?
    /// Schema 3 only: source-ordered mapping of summarized natural text and
    /// exact tool/media groups. Nil keeps schema-1/2 bytes and digests stable.
    public let projectionSpans: [CompactionProjectionSpan]?
    public let projectionRecentCount: Int?
    /// Schema 3: caller-supplied historical facts, bound to this checkpoint's
    /// digest and revalidated against canonical source and resumed projection.
    /// These are not live authorization or a permission to replay effects.
    public let retentionFacts: [CompactionRetainedFact]?
    /// H3 lineage snapshot. Nil is retained only for pre-H3 checkpoint files.
    public let lineage: SessionLineageIdentity?
    public let contentDigest: String
    public let createdAt: Date

    public var lineageIdentity: SessionLineageIdentity? { lineage }

    public init(
        schemaVersion: Int = CompactionCheckpoint.currentSchemaVersion,
        checkpointID: String = UUID().uuidString,
        sessionID: String,
        sourceTranscriptRevision: UInt64,
        resultTranscriptRevision: UInt64,
        compactedThroughMessageID: String,
        compactedMessageRange: Range<Int>,
        summaryMessage: LLMMessage,
        replacementHistory: [LLMMessage],
        lineage: SessionLineageIdentity? = nil,
        sourcePrefixDigest: String? = nil,
        projectionSpans: [CompactionProjectionSpan]? = nil,
        projectionRecentCount: Int? = nil,
        retentionFacts: [CompactionRetainedFact]? = nil,
        contentDigest: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.checkpointID = checkpointID
        self.sessionID = sessionID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.resultTranscriptRevision = resultTranscriptRevision
        self.compactedThroughMessageID = compactedThroughMessageID
        self.compactedMessageRange = compactedMessageRange
        self.summaryMessage = summaryMessage
        self.replacementHistory = replacementHistory
        self.lineage = lineage
        self.sourcePrefixDigest = sourcePrefixDigest
        self.projectionSpans = projectionSpans
        self.projectionRecentCount = projectionRecentCount
        self.retentionFacts = retentionFacts
        self.contentDigest = contentDigest
        self.createdAt = createdAt
    }

    /// True for schemas 2-4: the canonical transcript is kept and the
    /// checkpoint is only a model-request projection.
    public var retainsCanonicalTranscript: Bool { schemaVersion != Self.currentSchemaVersion }

    /// Build a checkpoint from the existing in-memory compaction result.
    public static func make(
        sessionID: String,
        sourceTranscriptRevision: UInt64,
        sourceMessages: [LLMMessage],
        result: CompactionResult,
        checkpointID: String = UUID().uuidString,
        createdAt: Date = Date(),
        lineage: SessionLineageIdentity? = nil
    ) throws -> CompactionCheckpoint {
        guard isSafePathComponent(sessionID),
              isSafePathComponent(checkpointID),
              sourceTranscriptRevision < UInt64.max - 1,
              result.compactedCount > 0,
              result.compactedCount <= sourceMessages.count,
              let summaryMessage = result.messages.first,
              isCanonicalSummary(summaryMessage) else {
            throw CompactionCheckpointError.invalidResult
        }

        let range = 0..<result.compactedCount
        let checkpoint = CompactionCheckpoint(
            checkpointID: checkpointID,
            sessionID: sessionID,
            sourceTranscriptRevision: sourceTranscriptRevision,
            resultTranscriptRevision: sourceTranscriptRevision &+ 1,
            compactedThroughMessageID: Compactor.stableMessageID(
                sourceMessages[result.compactedCount - 1],
                transcriptIndex: result.compactedCount - 1
            ),
            compactedMessageRange: range,
            summaryMessage: summaryMessage,
            replacementHistory: result.messages,
            lineage: lineage ?? SessionLineageIdentity.root(sessionID),
            contentDigest: "",
            createdAt: createdAt
        )
        return checkpoint.withDigest()
    }

    /// A projection checkpoint never replaces ChatSession.messages. The
    /// summary is model input only; the exact old prefix remains canonical.
    public static func makeProjection(
        sessionID: String,
        sourceTranscriptRevision: UInt64,
        sourceMessages: [LLMMessage],
        result: CompactionResult,
        checkpointID: String = UUID().uuidString,
        createdAt: Date = Date(),
        lineage: SessionLineageIdentity? = nil
    ) throws -> CompactionCheckpoint {
        if let spans = result.projectionSpans,
           let recentCount = result.projectionRecentCount {
            guard let facts = result.retentionFacts else {
                throw CompactionCheckpointError.invalidResult
            }
            guard facts.allSatisfy({ $0.source.map {
                      $0.sessionID == sessionID && $0.transcriptRevision == sourceTranscriptRevision
                          && $0.matchesTranscript(sourceMessages)
                  } ?? true }),
                  isSafePathComponent(sessionID),
                  isSafePathComponent(checkpointID),
                  sourceTranscriptRevision < UInt64.max - 1,
                  result.compactedCount > 0,
                  result.compactedCount + recentCount == sourceMessages.count,
                  result.refusalReason == nil,
                  Compactor.isSourceAnchoredProjection(from: sourceMessages,
                      to: result.messages, spans: spans,
                      keepRecentMessages: recentCount, requiredFacts: facts),
                  let firstMessage = result.messages.first,
                  let prefixDigest = digestOfSourcePrefix(
                      Array(sourceMessages.prefix(result.compactedCount))) else {
                throw CompactionCheckpointError.invalidResult
            }
            return CompactionCheckpoint(
                schemaVersion: segmentedProjectionSchemaVersion,
                checkpointID: checkpointID,
                sessionID: sessionID,
                sourceTranscriptRevision: sourceTranscriptRevision,
                resultTranscriptRevision: sourceTranscriptRevision + 1,
                compactedThroughMessageID: Compactor.stableMessageID(
                    sourceMessages[result.compactedCount - 1],
                    transcriptIndex: result.compactedCount - 1),
                compactedMessageRange: 0..<result.compactedCount,
                summaryMessage: firstMessage,
                replacementHistory: result.messages,
                lineage: lineage ?? SessionLineageIdentity.root(sessionID),
                sourcePrefixDigest: prefixDigest,
                projectionSpans: spans,
                projectionRecentCount: recentCount,
                retentionFacts: facts,
                contentDigest: "", createdAt: createdAt
            ).withDigest()
        }
        if result.isLossySummary, let recentCount = result.projectionRecentCount,
           let facts = result.retentionFacts {
            let background = CompactionFactCapture.backgroundMessage(facts)
            guard facts.allSatisfy({ $0.source.map {
                      $0.sessionID == sessionID && $0.transcriptRevision == sourceTranscriptRevision
                          && $0.matchesTranscript(sourceMessages)
                  } ?? true }),
                  isSafePathComponent(sessionID),
                  isSafePathComponent(checkpointID),
                  sourceTranscriptRevision < UInt64.max - 1,
                  result.compactedCount > 0,
                  result.compactedCount + recentCount == sourceMessages.count,
                  result.refusalReason == nil,
                  result.messages.count == 1 + (background == nil ? 0 : 1) + recentCount,
                  background == nil || result.messages[1] == background,
                  Array(result.messages.suffix(recentCount))
                    == Array(sourceMessages.dropFirst(result.compactedCount)),
                  let summaryMessage = result.messages.first,
                  isCanonicalSummary(summaryMessage),
                  let prefixDigest = digestOfSourcePrefix(
                    Array(sourceMessages.prefix(result.compactedCount))) else {
                throw CompactionCheckpointError.invalidResult
            }
            return CompactionCheckpoint(
                schemaVersion: lossySummarySchemaVersion,
                checkpointID: checkpointID,
                sessionID: sessionID,
                sourceTranscriptRevision: sourceTranscriptRevision,
                resultTranscriptRevision: sourceTranscriptRevision + 1,
                compactedThroughMessageID: Compactor.stableMessageID(
                    sourceMessages[result.compactedCount - 1],
                    transcriptIndex: result.compactedCount - 1),
                compactedMessageRange: 0..<result.compactedCount,
                summaryMessage: summaryMessage,
                replacementHistory: result.messages,
                lineage: lineage ?? SessionLineageIdentity.root(sessionID),
                sourcePrefixDigest: prefixDigest,
                projectionRecentCount: recentCount,
                retentionFacts: facts,
                contentDigest: "", createdAt: createdAt
            ).withDigest()
        }
        guard isSafePathComponent(sessionID),
              isSafePathComponent(checkpointID),
              sourceTranscriptRevision < UInt64.max - 1,
              result.compactedCount > 0,
              result.refusalReason == nil,
              Compactor.isVerifiedLosslessProjection(from: sourceMessages, result: result),
              result.compactedCount <= sourceMessages.count,
              result.messages.count == sourceMessages.count - result.compactedCount + 1,
              Compactor.hasMaterialRequestReduction(from: sourceMessages, to: result.messages),
              Array(result.messages.dropFirst()) == Array(sourceMessages.dropFirst(result.compactedCount)),
              let summaryMessage = result.messages.first,
              isCanonicalSummary(summaryMessage),
              let prefixDigest = digestOfSourcePrefix(
                Array(sourceMessages.prefix(result.compactedCount))
              ) else {
            throw CompactionCheckpointError.invalidResult
        }
        let range = 0..<result.compactedCount
        return CompactionCheckpoint(
            schemaVersion: projectionSchemaVersion,
            checkpointID: checkpointID,
            sessionID: sessionID,
            sourceTranscriptRevision: sourceTranscriptRevision,
            resultTranscriptRevision: sourceTranscriptRevision + 1,
            compactedThroughMessageID: Compactor.stableMessageID(
                sourceMessages[result.compactedCount - 1],
                transcriptIndex: result.compactedCount - 1
            ),
            compactedMessageRange: range,
            summaryMessage: summaryMessage,
            replacementHistory: result.messages,
            lineage: lineage ?? SessionLineageIdentity.root(sessionID),
            sourcePrefixDigest: prefixDigest,
            contentDigest: "",
            createdAt: createdAt
        ).withDigest()
    }

    static func digestOfSourcePrefix(_ messages: [LLMMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(messages) else { return nil }
        return bytes.withSHA256Digest()
    }

    /// Recompute the digest over every checkpoint field except the digest.
    public func withDigest() -> CompactionCheckpoint {
        let digest: String
        if schemaVersion == Self.segmentedProjectionSchemaVersion
            || schemaVersion == Self.lossySummarySchemaVersion {
            digest = (try? Self.digest(SegmentedProjectionDigestPayload(checkpoint: self))) ?? ""
        } else if schemaVersion == Self.projectionSchemaVersion {
            digest = (try? Self.digest(ProjectionDigestPayload(checkpoint: self))) ?? ""
        } else {
            digest = (try? Self.digest(DigestPayload(checkpoint: self))) ?? ""
        }
        return CompactionCheckpoint(
            schemaVersion: schemaVersion,
            checkpointID: checkpointID,
            sessionID: sessionID,
            sourceTranscriptRevision: sourceTranscriptRevision,
            resultTranscriptRevision: resultTranscriptRevision,
            compactedThroughMessageID: compactedThroughMessageID,
            compactedMessageRange: compactedMessageRange,
            summaryMessage: summaryMessage,
            replacementHistory: replacementHistory,
            lineage: lineage,
            sourcePrefixDigest: sourcePrefixDigest,
            projectionSpans: projectionSpans,
            projectionRecentCount: projectionRecentCount,
            retentionFacts: retentionFacts,
            contentDigest: digest,
            createdAt: createdAt
        )
    }

    public var hasValidDigest: Bool {
        guard hasCanonicalShape, !contentDigest.isEmpty else { return false }
        if withDigest().contentDigest == contentDigest {
            return true
        }
        // Preserve readability of H1 checkpoint files written before the
        // optional H3 lineage field existed.
        guard schemaVersion == Self.currentSchemaVersion, lineage == nil else { return false }
        let payload = LegacyDigestPayload(checkpoint: self)
        guard let data = try? Self.encodeDigestPayload(payload) else { return false }
        let legacyDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return legacyDigest == contentDigest
    }

    private var hasCanonicalShape: Bool {
        (schemaVersion == Self.currentSchemaVersion
            || schemaVersion == Self.projectionSchemaVersion
            || schemaVersion == Self.lossySummarySchemaVersion
            || schemaVersion == Self.segmentedProjectionSchemaVersion)
            && Self.isSafePathComponent(checkpointID)
            && Self.isSafePathComponent(sessionID)
            && Self.isSafePathComponent(compactedThroughMessageID)
            && contentDigest.utf8.count == 64
            && sourceTranscriptRevision < resultTranscriptRevision
            && sourceTranscriptRevision < UInt64.max - 1
            && resultTranscriptRevision < UInt64.max
            && resultTranscriptRevision == sourceTranscriptRevision + 1
            && compactedMessageRange.lowerBound == 0
            && compactedMessageRange.upperBound > compactedMessageRange.lowerBound
            && replacementHistory.count <= Self.maxReplacementHistoryCount
            && replacementHistory.allSatisfy {
                $0.content.utf8.count <= Self.maxMessageContentBytes
            }
            && !replacementHistory.isEmpty
            && replacementHistory.first == summaryMessage
            && (schemaVersion == Self.segmentedProjectionSchemaVersion
                ? projectionSpans != nil && projectionRecentCount != nil
                : Self.isCanonicalSummary(summaryMessage))
            && (schemaVersion == Self.currentSchemaVersion
                ? sourcePrefixDigest == nil
                : sourcePrefixDigest.map(Self.isSHA256Digest) == true)
            && (schemaVersion == Self.segmentedProjectionSchemaVersion
                ? projectionRecentCount.map { $0 >= 0 && $0 <= replacementHistory.count } == true
                    && retentionFacts.map(Self.factsAreBounded) == true
                : schemaVersion == Self.lossySummarySchemaVersion
                ? projectionSpans == nil
                    && projectionRecentCount.map { $0 >= 0 && $0 < replacementHistory.count } == true
                    && retentionFacts.map(Self.factsAreBounded) == true
                : projectionSpans == nil && projectionRecentCount == nil && retentionFacts == nil)
    }

    private static func factsAreBounded(_ facts: [CompactionRetainedFact]) -> Bool {
        facts.count <= maxReplacementHistoryCount
            && facts.allSatisfy {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.text.utf8.count <= maxMessageContentBytes
            }
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 255,
              !value.contains("/"),
              !value.contains("\\") else {
            return false
        }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isCanonicalSummary(_ message: LLMMessage) -> Bool {
        message.role == .user
            && message.content.contains("<context-summary>")
            && message.content.contains("</context-summary>")
    }

    private struct DigestPayload: Codable {
        let schemaVersion: Int
        let checkpointID: String
        let sessionID: String
        let sourceTranscriptRevision: UInt64
        let resultTranscriptRevision: UInt64
        let compactedThroughMessageID: String
        let compactedMessageRange: Range<Int>
        let summaryMessage: LLMMessage
        let replacementHistory: [LLMMessage]
        let lineage: SessionLineageIdentity?
        let createdAt: Date

        init(checkpoint: CompactionCheckpoint) {
            schemaVersion = checkpoint.schemaVersion
            checkpointID = checkpoint.checkpointID
            sessionID = checkpoint.sessionID
            sourceTranscriptRevision = checkpoint.sourceTranscriptRevision
            resultTranscriptRevision = checkpoint.resultTranscriptRevision
            compactedThroughMessageID = checkpoint.compactedThroughMessageID
            compactedMessageRange = checkpoint.compactedMessageRange
            summaryMessage = checkpoint.summaryMessage
            replacementHistory = checkpoint.replacementHistory
            lineage = checkpoint.lineage
            createdAt = checkpoint.createdAt
        }
    }

    private struct ProjectionDigestPayload: Codable {
        let schemaVersion: Int
        let checkpointID: String
        let sessionID: String
        let sourceTranscriptRevision: UInt64
        let resultTranscriptRevision: UInt64
        let compactedThroughMessageID: String
        let compactedMessageRange: Range<Int>
        let summaryMessage: LLMMessage
        let replacementHistory: [LLMMessage]
        let lineage: SessionLineageIdentity?
        let sourcePrefixDigest: String
        let createdAt: Date

        init(checkpoint: CompactionCheckpoint) {
            schemaVersion = checkpoint.schemaVersion
            checkpointID = checkpoint.checkpointID
            sessionID = checkpoint.sessionID
            sourceTranscriptRevision = checkpoint.sourceTranscriptRevision
            resultTranscriptRevision = checkpoint.resultTranscriptRevision
            compactedThroughMessageID = checkpoint.compactedThroughMessageID
            compactedMessageRange = checkpoint.compactedMessageRange
            summaryMessage = checkpoint.summaryMessage
            replacementHistory = checkpoint.replacementHistory
            lineage = checkpoint.lineage
            sourcePrefixDigest = checkpoint.sourcePrefixDigest ?? ""
            createdAt = checkpoint.createdAt
        }
    }

    private struct SegmentedProjectionDigestPayload: Codable {
        let schemaVersion: Int
        let checkpointID: String
        let sessionID: String
        let sourceTranscriptRevision: UInt64
        let resultTranscriptRevision: UInt64
        let compactedThroughMessageID: String
        let compactedMessageRange: Range<Int>
        let replacementHistory: [LLMMessage]
        let lineage: SessionLineageIdentity?
        let sourcePrefixDigest: String
        let projectionSpans: [CompactionProjectionSpan]
        let projectionRecentCount: Int
        let retentionFacts: [CompactionRetainedFact]
        let createdAt: Date

        init(checkpoint: CompactionCheckpoint) {
            schemaVersion = checkpoint.schemaVersion
            checkpointID = checkpoint.checkpointID
            sessionID = checkpoint.sessionID
            sourceTranscriptRevision = checkpoint.sourceTranscriptRevision
            resultTranscriptRevision = checkpoint.resultTranscriptRevision
            compactedThroughMessageID = checkpoint.compactedThroughMessageID
            compactedMessageRange = checkpoint.compactedMessageRange
            replacementHistory = checkpoint.replacementHistory
            lineage = checkpoint.lineage
            sourcePrefixDigest = checkpoint.sourcePrefixDigest ?? ""
            projectionSpans = checkpoint.projectionSpans ?? []
            projectionRecentCount = checkpoint.projectionRecentCount ?? -1
            retentionFacts = checkpoint.retentionFacts ?? []
            createdAt = checkpoint.createdAt
        }
    }

    private struct LegacyDigestPayload: Codable {
        let schemaVersion: Int
        let checkpointID: String
        let sessionID: String
        let sourceTranscriptRevision: UInt64
        let resultTranscriptRevision: UInt64
        let compactedThroughMessageID: String
        let compactedMessageRange: Range<Int>
        let summaryMessage: LLMMessage
        let replacementHistory: [LLMMessage]
        let createdAt: Date

        init(checkpoint: CompactionCheckpoint) {
            schemaVersion = checkpoint.schemaVersion
            checkpointID = checkpoint.checkpointID
            sessionID = checkpoint.sessionID
            sourceTranscriptRevision = checkpoint.sourceTranscriptRevision
            resultTranscriptRevision = checkpoint.resultTranscriptRevision
            compactedThroughMessageID = checkpoint.compactedThroughMessageID
            compactedMessageRange = checkpoint.compactedMessageRange
            summaryMessage = checkpoint.summaryMessage
            replacementHistory = checkpoint.replacementHistory
            createdAt = checkpoint.createdAt
        }
    }

    private static func digest<T: Encodable>(_ payload: T) throws -> String {
        let data = try encodeDigestPayload(payload)
        return data.withSHA256Digest()
    }

    private static func encodeDigestPayload<T: Encodable>(_ payload: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}

private extension Data {
    func withSHA256Digest() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CompactionCheckpointError: Error, Equatable, Sendable {
    case invalidResult
}
