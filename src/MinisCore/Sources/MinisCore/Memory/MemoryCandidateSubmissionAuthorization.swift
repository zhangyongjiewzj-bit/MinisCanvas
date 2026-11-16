import Foundation

/// Durable permission for one source to submit memory candidates.
///
/// The epoch is advanced on every revocation. A proposal captures the epoch
/// that admitted it; an approval can only consume a proposal while the source
/// remains authorized at that exact epoch. This grant is deliberately scoped
/// to candidate submission and does not authorize memory reads, control, or
/// compaction.
public struct MemoryCandidateSubmissionAuthorization: Codable, Equatable, Sendable {
    public let sourceID: String
    public let epoch: UInt64
    public let canSubmit: Bool
    public let updatedAt: Date
    public let reason: String?

    public init(
        sourceID: String,
        epoch: UInt64 = 0,
        canSubmit: Bool,
        updatedAt: Date = Date(),
        reason: String? = nil
    ) {
        self.sourceID = sourceID
        self.epoch = epoch
        self.canSubmit = canSubmit
        self.updatedAt = updatedAt
        self.reason = reason
    }

    public var isValid: Bool {
        !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sourceID == sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Shorter product-facing spelling retained as an alias for callers that
/// treat this value as a candidate-write permission.
public typealias MemoryCandidateSubmissionPermission = MemoryCandidateSubmissionAuthorization
