import Darwin
import Foundation
import CryptoKit

private final class MemoryProposalLockRegistry: @unchecked Sendable {
    let mutex = NSLock()
    var locks: [String: NSLock] = [:]
}

/// Durable proposal record used by the production memory consumer.
///
/// The proposal and every approval receipt carry the concrete
/// `(sessionID, projectID)` identity. `sourceHash` and `generation` form the
/// immutable source fence for the proposal. The optional approval receipt
/// exists for legacy decoding only; new proposals always populate it on
/// approval.
public struct MemoryProposalEnvelope: Codable, Equatable, Sendable {
    /// V5 is reserved for records that carry typed write provenance. The
    /// existing required version field keeps deleting the optional tuple from
    /// silently turning such a record into a V4 legacy proposal.
    public static let currentVersion = 5
    public static let untypedVersion = 4

    public let version: Int
    public let proposal: MemoryProposalLifecycleReceipt
    public let text: String
    public let category: MemoryCategory
    public let sourceRef: String?
    public let contentDigest: String?
    public let sourceHash: String?
    public let generation: Int?
    public let binding: MemoryProposalBinding?
    /// Source permission captured when this candidate was submitted. Nil is
    /// retained for pre-C1-A callers and is never treated as a grant.
    public let sourceID: String?
    public let submissionEpoch: UInt64?
    /// Optional typed origin, captured with the admitted source epoch. Older
    /// built-in and decoded legacy proposals intentionally keep this nil.
    public let writeProvenance: MemoryWriteProvenance?
    public let createdAt: Date
    public var state: MemoryProposalLifecycleState
    public var approvalReceipt: MemoryProposalLifecycleReceipt?
    public var approvalReason: String?

    public init(
        proposal: MemoryProposalLifecycleReceipt,
        text: String,
        category: MemoryCategory = .fact,
        sourceRef: String? = nil,
        contentDigest: String? = nil,
        sourceHash: String? = nil,
        generation: Int? = nil,
        binding: MemoryProposalBinding? = nil,
        sourceID: String? = nil,
        submissionEpoch: UInt64? = nil,
        writeProvenance: MemoryWriteProvenance? = nil,
        createdAt: Date = Date(),
        state: MemoryProposalLifecycleState = .proposed,
        approvalReceipt: MemoryProposalLifecycleReceipt? = nil,
        approvalReason: String? = nil
    ) {
        self.version = writeProvenance == nil ? Self.untypedVersion : Self.currentVersion
        self.proposal = proposal
        self.text = text
        self.category = category
        self.sourceRef = sourceRef
        self.contentDigest = contentDigest
        self.sourceHash = sourceHash
        self.generation = generation
        self.binding = binding
        self.sourceID = sourceID
        self.submissionEpoch = submissionEpoch
        self.writeProvenance = writeProvenance
        self.createdAt = createdAt
        self.state = state
        self.approvalReceipt = approvalReceipt
        self.approvalReason = approvalReason
    }
}

/// Durable receipt for an explicitly authorized backup restore/import.
public struct MemoryRestoreReceipt: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let restoreID: String
    public let createdAt: Date
    public let memoryScope: MemoryScope
    public let mode: MemoryRestoreMode
    public let reason: String
    public let inputHash: String
    public let beforeHash: String
    public let afterHash: String
    public let added: Int
    public let skipped: Int
    public let replaced: Int

    public init(
        restoreID: String = UUID().uuidString,
        createdAt: Date = Date(),
        memoryScope: MemoryScope,
        mode: MemoryRestoreMode,
        reason: String,
        inputHash: String,
        beforeHash: String,
        afterHash: String,
        added: Int,
        skipped: Int,
        replaced: Int
    ) {
        self.version = Self.currentVersion
        self.restoreID = restoreID
        self.createdAt = createdAt
        self.memoryScope = memoryScope
        self.mode = mode
        self.reason = reason
        self.inputHash = inputHash
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.added = added
        self.skipped = skipped
        self.replaced = replaced
    }
}

public struct MemoryRestoreResult: Equatable, Sendable {
    public let receipt: MemoryRestoreReceipt

    public var added: Int { receipt.added }
    public var skipped: Int { receipt.skipped }
    public var replaced: Int { receipt.replaced }

    public init(receipt: MemoryRestoreReceipt) {
        self.receipt = receipt
    }
}

/// Fail-closed errors exposed by the production memory proposal consumer.
public enum MemoryProposalConsumerError: LocalizedError, Equatable, Sendable {
    case credentialLikeContent

    public var errorDescription: String? {
        self == .credentialLikeContent ? "记忆候选可能包含凭据，请去掉密钥、令牌或密码后重试。" : nil
    }

    case invalidProposalID
    case invalidMemoryScope
    case invalidOwnerUserID
    case invalidText
    case invalidProvenance
    case invalidBinding
    case staleGeneration
    case duplicateProposal
    case duplicateConsumption
    case scopeMismatch
    case proposalNotFound
    case proposalConflict
    case persistenceLockUnavailable
    case restoreConflict
    case invalidRestoreReason
    case invalidRevocationReason
    case invalidSourceID
    case candidateSubmissionUnauthorized
    case candidateSubmissionRevoked
    case candidateSubmissionEpochMismatch
    case invalidState(MemoryProposalLifecycleState)
    case quarantined(MemoryProposalQuarantineReason)
}

/// Production consumer for memory proposal admission, approval and fact writeback.
///
/// `submit` records a proposal but never writes a fact. `approve` is the only
/// path that can write a fact, and it rechecks the current concrete scope before
/// applying the stable-id write exactly once for the captured binding.
public final class MemoryProposalConsumer: @unchecked Sendable {
    public let store: MemoryStore

    public var receiptURL: URL {
        store.directory.appendingPathComponent("memory/proposals-v1.json", isDirectory: false)
    }

    public var restoreReceiptURL: URL {
        store.directory.appendingPathComponent("memory/restores-v1.json", isDirectory: false)
    }

    /// Durable C1-A source permission ledger. It is intentionally separate
    /// from read/control/compact authorization records.
    public var candidateSubmissionAuthorizationURL: URL {
        store.directory.appendingPathComponent(
            "memory/candidate-submission-authorizations-v1.json",
            isDirectory: false
        )
    }

    /// Compatibility spelling for consumers that call the ledger an
    /// authority store.
    public var submissionAuthorizationURL: URL {
        candidateSubmissionAuthorizationURL
    }

    /// Install a built-in source's default only when it has no ledger record.
    /// A revoked record is an explicit user choice and must survive relaunch,
    /// including a launch racing with revocation on another consumer instance.
    @discardableResult
    public func provisionCandidateSubmissionIfAbsent(
        sourceID: String,
        reason: String
    ) throws -> MemoryCandidateSubmissionAuthorization {
        try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            let normalizedSourceID = try Self.normalizedSourceID(sourceID)
            return try withProposalWriteLock {
                var authorizations = try loadAuthorizationsUnlocked()
                if let existing = authorizations.first(where: {
                    $0.sourceID == normalizedSourceID
                }) {
                    return existing
                }
                let authorization = MemoryCandidateSubmissionAuthorization(
                    sourceID: normalizedSourceID,
                    canSubmit: true,
                    reason: reason
                )
                authorizations.append(authorization)
                try persistAuthorizationsUnlocked(authorizations)
                return authorization
            }
        }
    }

    /// Grant one source the narrow ability to submit memory candidates.
    ///
    /// The grant does not authorize reads, control, compaction, or approval.
    /// Calling this method again for an already-authorized source is idempotent
    /// and keeps its epoch unchanged.
    @discardableResult
    public func grantCandidateSubmission(
        sourceID: String,
        reason: String? = nil
    ) throws -> MemoryCandidateSubmissionAuthorization {
        try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            let normalizedSourceID = try Self.normalizedSourceID(sourceID)
            return try withProposalWriteLock {
                var authorizations = try loadAuthorizationsUnlocked()
                if let existing = authorizations.first(where: {
                    $0.sourceID == normalizedSourceID
                }), existing.canSubmit {
                    return existing
                }
                let priorEpoch = authorizations.first(where: {
                    $0.sourceID == normalizedSourceID
                })?.epoch ?? 0
                let authorization = MemoryCandidateSubmissionAuthorization(
                    sourceID: normalizedSourceID,
                    epoch: priorEpoch,
                    canSubmit: true,
                    reason: Self.optionalReason(reason)
                )
                authorizations.removeAll { $0.sourceID == normalizedSourceID }
                authorizations.append(authorization)
                try persistAuthorizationsUnlocked(authorizations)
                return authorization
            }
        }
    }

    /// Revoke one source's candidate-submission permission and invalidate all
    /// of its still-pending proposals in the same memory write admission.
    /// Already-active facts are deliberately preserved for recall and the
    /// existing per-fact delete/rollback flow.
    @discardableResult
    public func revokeCandidateSubmission(
        sourceID: String,
        reason: String = "candidate submission revoked"
    ) throws -> MemoryCandidateSubmissionAuthorization {
        try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            let normalizedSourceID = try Self.normalizedSourceID(sourceID)
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty else {
                throw MemoryProposalConsumerError.invalidRevocationReason
            }

            return try withProposalWriteLock {
                var authorizations = try loadAuthorizationsUnlocked()
                let previous = authorizations.first(where: {
                    $0.sourceID == normalizedSourceID
                })
                guard previous?.epoch != UInt64.max else {
                    throw MemoryProposalConsumerError.candidateSubmissionEpochMismatch
                }
                let nextEpoch = (previous?.epoch ?? 0) + 1

                var envelopes = try loadUnlocked()
                for index in envelopes.indices where
                    envelopes[index].sourceID == normalizedSourceID
                    && (envelopes[index].state == .proposed
                        || envelopes[index].state == .approved) {
                    envelopes[index].state = .revoked
                    envelopes[index].approvalReason = trimmedReason
                }

                let authorization = MemoryCandidateSubmissionAuthorization(
                    sourceID: normalizedSourceID,
                    epoch: nextEpoch,
                    canSubmit: false,
                    reason: trimmedReason
                )
                authorizations.removeAll { $0.sourceID == normalizedSourceID }
                authorizations.append(authorization)

                // Publish the revocation epoch before updating pending proposal
                // state. These are separate durable files: if the second write
                // fails or the process stops, old pending approvals and new
                // submissions must already be blocked by the authority ledger.
                // The process-local admission and lock hide the intermediate
                // state from concurrent consumers in this process.
                try persistAuthorizationsUnlocked(authorizations)
                try revocationFaultInjector?()
                try persistUnlocked(envelopes)
                return authorization
            }
        }
    }

    /// Read the persisted candidate-submission permissions. This is an
    /// authorization ledger view; it never exposes memory content.
    public func candidateSubmissionAuthorizations() throws
        -> [MemoryCandidateSubmissionAuthorization] {
        try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try withLock { try loadAuthorizationsUnlocked() }
        }
    }

    /// Alias for callers that use "permissions" for the source ledger.
    public func candidateSubmissionPermissions() throws
        -> [MemoryCandidateSubmissionAuthorization] {
        try candidateSubmissionAuthorizations()
    }

    /// Explicit-permission spelling retained for producer adapters.
    @discardableResult
    public func grantCandidateSubmissionPermission(
        sourceID: String,
        reason: String? = nil
    ) throws -> MemoryCandidateSubmissionAuthorization {
        try grantCandidateSubmission(sourceID: sourceID, reason: reason)
    }

    /// Explicit-permission spelling retained for producer adapters.
    @discardableResult
    public func revokeCandidateSubmissionPermission(
        sourceID: String,
        reason: String = "candidate submission revoked"
    ) throws -> MemoryCandidateSubmissionAuthorization {
        try revokeCandidateSubmission(sourceID: sourceID, reason: reason)
    }

    private static let lockRegistry = MemoryProposalLockRegistry()
    private let lock: NSLock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let revocationFaultInjector: (@Sendable () throws -> Void)?

    public init(store: MemoryStore) {
        self.store = store
        self.lock = Self.sharedLock(for: store.directory)
        self.revocationFaultInjector = nil
    }

    // A focused recovery test can stop between the two durable writes.
    init(store: MemoryStore, revocationFaultInjector: @escaping @Sendable () throws -> Void) {
        self.store = store
        self.lock = Self.sharedLock(for: store.directory)
        self.revocationFaultInjector = revocationFaultInjector
    }

    @discardableResult
    public func submit(
        proposalID: String = UUID().uuidString,
        text: String,
        category: MemoryCategory = .fact,
        within memoryScope: MemoryScope,
        sourceRef: String? = nil,
        contentDigest: String? = nil,
        sourceHash: String? = nil,
        generation: Int = 0,
        sourceID: String? = nil,
        writeProvenance: MemoryWriteProvenanceInput? = nil
    ) throws -> MemoryProposalEnvelope {
        let reference = sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard reference?.hasPrefix(Self.manualProjectSourcePrefix) != true,
              reference?.hasPrefix(Self.chatProjectSourcePrefix) != true,
              sourceID != Self.chatProjectSourceID else {
            throw MemoryProposalConsumerError.invalidProvenance
        }
        return try submitBound(proposalID: proposalID, text: text, category: category,
                               within: memoryScope, sourceRef: sourceRef, contentDigest: contentDigest,
                               sourceHash: sourceHash, generation: generation, sourceID: sourceID,
                               writeProvenance: writeProvenance)
    }

    private func submitBound(
        proposalID: String = UUID().uuidString,
        text: String,
        category: MemoryCategory = .fact,
        within memoryScope: MemoryScope,
        sourceRef: String? = nil,
        contentDigest: String? = nil,
        sourceHash: String? = nil,
        generation: Int = 0,
        sourceID: String? = nil,
        writeProvenance: MemoryWriteProvenanceInput? = nil
    ) throws -> MemoryProposalEnvelope {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            let trimmedID = proposalID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw MemoryProposalConsumerError.invalidProposalID
            }
            guard memoryScope.isValid else {
                throw MemoryProposalConsumerError.invalidMemoryScope
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw MemoryProposalConsumerError.invalidText
            }
            guard ContentSecretRedactor.redact(trimmedText) == trimmedText else {
                throw MemoryProposalConsumerError.credentialLikeContent
            }
            let normalizedSourceRef: String
            if let sourceRef {
                let trimmedSourceRef = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
                normalizedSourceRef = trimmedSourceRef.isEmpty
                    ? "memory://proposal/\(trimmedID)"
                    : trimmedSourceRef
            } else {
                normalizedSourceRef = "memory://proposal/\(trimmedID)"
            }
            let normalizedDigest = contentDigest ?? MemoryStore.contentDigest(for: trimmedText)
            guard normalizedDigest == MemoryStore.contentDigest(for: trimmedText) else {
                throw MemoryProposalConsumerError.invalidProvenance
            }
            guard generation >= 0 else {
                throw MemoryProposalConsumerError.staleGeneration
            }
            guard let sourceID else {
                // Legacy envelopes remain readable, but every new candidate
                // must identify the source whose explicit submission grant
                // supplied its epoch.
                throw MemoryProposalConsumerError.candidateSubmissionUnauthorized
            }
            let normalizedSourceID = try Self.normalizedSourceID(sourceID)
            if let writeProvenance,
               (!writeProvenance.isWellFormed
                || writeProvenance.sourceID != normalizedSourceID) {
                throw MemoryProposalConsumerError.invalidProvenance
            }
            let normalizedSourceHash = (sourceHash ?? normalizedDigest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSourceHash.isEmpty else {
                throw MemoryProposalConsumerError.invalidBinding
            }
            let binding = MemoryProposalBinding(
                sessionID: memoryScope.sessionID,
                workspaceID: memoryScope.workspaceID,
                proposalID: trimmedID,
                sourceHash: normalizedSourceHash,
                generation: generation
            )

            let proposal = MemoryProposalLifecycleReceipt(
                proposalID: trimmedID,
                scope: .session,
                memoryScope: memoryScope,
                subjectID: trimmedID,
                action: .propose,
                state: .proposed,
                reason: "memory proposal",
                sequence: 1
            )
            let admission = MemoryProposalAdmission.decide(
                proposal,
                within: memoryScope,
                binding: binding
            )
            guard admission.decision == .admitted else {
                throw Self.consumerError(for: admission.quarantineReason)
            }

            return try withProposalWriteLock {
                guard let authorization = try loadAuthorizationsUnlocked()
                    .first(where: { $0.sourceID == normalizedSourceID }) else {
                    throw MemoryProposalConsumerError.candidateSubmissionUnauthorized
                }
                guard authorization.canSubmit else {
                    throw MemoryProposalConsumerError.candidateSubmissionRevoked
                }
                let submissionEpoch = authorization.epoch
                let capturedProvenance: MemoryWriteProvenance?
                if let writeProvenance {
                    guard let captured = MemoryWriteProvenance.capture(
                        writeProvenance,
                        submissionEpoch: submissionEpoch,
                        proposalID: trimmedID,
                        memoryScope: memoryScope,
                        contentDigest: normalizedDigest,
                        sourceHash: normalizedSourceHash,
                        generation: generation
                    ) else {
                        throw MemoryProposalConsumerError.invalidProvenance
                    }
                    capturedProvenance = captured
                } else {
                    capturedProvenance = nil
                }
                var envelopes = try loadUnlocked()
                if envelopes.contains(where: { $0.proposal.proposalID == trimmedID }) {
                    throw MemoryProposalConsumerError.duplicateProposal
                }

                let envelope = MemoryProposalEnvelope(
                    proposal: proposal,
                    text: trimmedText,
                    category: category,
                    sourceRef: normalizedSourceRef,
                    contentDigest: normalizedDigest,
                    sourceHash: normalizedSourceHash,
                    generation: generation,
                    binding: binding,
                    sourceID: normalizedSourceID,
                    submissionEpoch: submissionEpoch,
                    writeProvenance: capturedProvenance
                )
                envelopes.append(envelope)
                try persistUnlocked(envelopes)
                return envelope
            }

        }
    }

    static let manualProjectSourcePrefix = "settings://memory/manual-project/"
    private static let manualProjectApprovalReason = "用户在设置中手动添加项目记忆"

    private static let chatProjectSourcePrefix = "composer://memory/user-fact/"
    private static let chatProjectApprovalReason = "用户在设置中批准对话记忆"
    public static let chatProjectSourceID = "composer-user-memory"

    public func submitUserRequestedChatFact(
        proposalID: String, text: String, within scope: MemoryScope, execution: AgentExecutionIdentity
    ) throws -> MemoryProposalEnvelope {
        guard let receipt = ToolExecutionReceiptContext.current,
              receipt.toolName == "memory_propose_fact",
              receipt.executionIdentity == execution, receipt.childTranscriptLocator == nil,
              execution.turn.sessionID == scope.sessionID,
              ToolExecutionReceiptContext.ledger?.pendingReceipts.contains(receipt) == true else {
            throw MemoryProposalConsumerError.invalidProvenance
        }
        return try submitBound(proposalID: proposalID, text: text, within: scope,
                               sourceRef: Self.chatProjectSourcePrefix + proposalID,
                               sourceID: Self.chatProjectSourceID)
    }

    public func addManualProjectFact(
        text: String, category: MemoryCategory, within scope: MemoryScope
    ) throws -> MemoryProposalLifecycleReceipt {
        let proposalID = UUID().uuidString
        let envelope = try submitBound(proposalID: proposalID, text: text, category: category,
                                       within: scope, sourceRef: Self.manualProjectSourcePrefix + proposalID,
                                       sourceID: "settings-center")
        return try approveBound(proposalID: envelope.proposal.proposalID, within: scope,
                                reason: Self.manualProjectApprovalReason)
    }

    /// Approve and activate one proposal in the current concrete scope.
    ///
    /// The returned receipt is the immutable approval receipt. A repeated or
    /// stale approval fails closed and does not rewrite `facts.json`.
    @discardableResult
    public func approve(
        proposalID: String,
        within memoryScope: MemoryScope,
        reason: String,
        generation: Int? = nil,
        sourceHash: String? = nil
    ) throws -> MemoryProposalLifecycleReceipt {
        guard reason.trimmingCharacters(in: .whitespacesAndNewlines)
                != Self.manualProjectApprovalReason,
              reason.trimmingCharacters(in: .whitespacesAndNewlines) != Self.chatProjectApprovalReason else {
            throw MemoryProposalConsumerError.invalidProvenance
        }
        return try approveBound(proposalID: proposalID, within: memoryScope, reason: reason,
                                generation: generation, sourceHash: sourceHash)
    }

    private func approveBound(
        proposalID: String, within memoryScope: MemoryScope, reason: String,
        generation: Int? = nil, sourceHash: String? = nil
    ) throws -> MemoryProposalLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            guard memoryScope.isValid else {
                throw MemoryProposalConsumerError.invalidMemoryScope
            }

            return try withProposalWriteLock {
                var envelopes = try loadUnlocked()
                guard let index = envelopes.firstIndex(where: { $0.proposal.proposalID == proposalID }) else {
                    throw MemoryProposalConsumerError.proposalNotFound
                }

                let envelope = envelopes[index]
                guard envelope.proposal.memoryScope == memoryScope else {
                    throw MemoryProposalConsumerError.scopeMismatch
                }
                let binding = try Self.validatedBinding(
                    for: envelope,
                    within: memoryScope,
                    generation: generation,
                    sourceHash: sourceHash
                )
                try validateSubmissionEpoch(for: envelope)

                let admission = MemoryProposalAdmission.decide(
                    envelope.proposal,
                    within: memoryScope,
                    binding: binding
                )
                guard admission.decision == .admitted else {
                    throw Self.consumerError(for: admission.quarantineReason)
                }

                let reason = envelope.sourceID == Self.chatProjectSourceID
                    && envelope.sourceRef == Self.chatProjectSourcePrefix + proposalID
                    ? Self.chatProjectApprovalReason : reason
                let approvalReceipt: MemoryProposalLifecycleReceipt
                switch envelope.state {
                case .proposed:
                    guard let receipt = MemoryProposalLifecycle.transition(
                        from: admission,
                        applying: .approve,
                        reason: reason
                    ) else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    approvalReceipt = receipt
                    envelopes[index].state = .approved
                    envelopes[index].approvalReceipt = receipt
                    envelopes[index].approvalReason = reason
                    try persistUnlocked(envelopes)
                case .approved:
                    guard let receipt = envelope.approvalReceipt else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    guard Self.isValidApprovalReceipt(receipt, for: envelope) else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    throw MemoryProposalConsumerError.duplicateConsumption
                case .active:
                    guard let receipt = envelope.approvalReceipt else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    guard Self.isValidApprovalReceipt(receipt, for: envelope) else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    throw MemoryProposalConsumerError.duplicateConsumption
                default:
                    throw MemoryProposalConsumerError.invalidState(envelope.state)
                }

                _ = try persistApprovedFact(envelopes[index], within: memoryScope)

                if envelopes[index].state != .active {
                    envelopes[index].state = .active
                    try persistUnlocked(envelopes)
                }
                return approvalReceipt
            }

        }
    }

    /// Reject exactly the pending proposal observed by the user. This only
    /// settles the candidate ledger; it never writes or changes a memory fact.
    @discardableResult
    public func reject(
        _ displayed: MemoryProposalEnvelope,
        within memoryScope: MemoryScope
    ) throws -> MemoryProposalLifecycleReceipt {
        try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            guard memoryScope.isValid else {
                throw MemoryProposalConsumerError.invalidMemoryScope
            }
            return try withProposalWriteLock {
                var envelopes = try loadUnlocked()
                guard let index = envelopes.firstIndex(where: {
                    $0.proposal.proposalID == displayed.proposal.proposalID
                }) else { throw MemoryProposalConsumerError.proposalNotFound }
                let envelope = envelopes[index]
                guard envelope.proposal.memoryScope == memoryScope else {
                    throw MemoryProposalConsumerError.scopeMismatch
                }
                guard envelope == displayed else {
                    throw MemoryProposalConsumerError.proposalConflict
                }
                guard envelope.state == .proposed else {
                    throw MemoryProposalConsumerError.invalidState(envelope.state)
                }
                _ = try Self.validatedBinding(for: envelope, within: memoryScope,
                    generation: displayed.generation, sourceHash: displayed.sourceHash)
                try validateSubmissionEpoch(for: envelope)
                let receipt = MemoryProposalLifecycleReceipt(
                    proposalID: envelope.proposal.proposalID,
                    scope: envelope.proposal.scope, memoryScope: memoryScope,
                    subjectID: envelope.proposal.subjectID, action: .reject, state: .rejected,
                    reason: "用户明确拒绝该条记忆提议", sequence: envelope.proposal.sequence + 1)
                envelopes[index].state = .rejected
                try persistUnlocked(envelopes)
                return receipt
            }
        }
    }

    /// Approve a proposal as an append-only revision of one active fact.
    ///
    /// This is the only proposal consumer path that can supersede an existing
    /// fact. The target scope and the proposal provenance are checked before
    /// the shared `MemoryStore` appends the new revision.
    @discardableResult
    public func approveRevision(
        proposalID: String,
        supersedingFactID: String,
        within memoryScope: MemoryScope,
        reason: String,
        generation: Int? = nil,
        sourceHash: String? = nil
    ) throws -> MemoryProposalLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            guard memoryScope.isValid else {
                throw MemoryProposalConsumerError.invalidMemoryScope
            }
            guard !supersedingFactID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryProposalConsumerError.proposalConflict
            }

            return try withProposalWriteLock {
                var envelopes = try loadUnlocked()
                guard let index = envelopes.firstIndex(where: {
                    $0.proposal.proposalID == proposalID
                }) else {
                    throw MemoryProposalConsumerError.proposalNotFound
                }

                let envelope = envelopes[index]
                guard envelope.proposal.memoryScope == memoryScope else {
                    throw MemoryProposalConsumerError.scopeMismatch
                }
                let binding = try Self.validatedBinding(
                    for: envelope,
                    within: memoryScope,
                    generation: generation,
                    sourceHash: sourceHash
                )
                try validateSubmissionEpoch(for: envelope)
                guard let sourceRef = envelope.sourceRef,
                      let contentDigest = envelope.contentDigest else {
                    throw MemoryProposalConsumerError.invalidProvenance
                }

                let admission = MemoryProposalAdmission.decide(
                    envelope.proposal,
                    within: memoryScope,
                    binding: binding
                )
                guard admission.decision == .admitted else {
                    throw Self.consumerError(for: admission.quarantineReason)
                }

                let approvalReceipt: MemoryProposalLifecycleReceipt
                switch envelope.state {
                case .proposed:
                    guard let receipt = MemoryProposalLifecycle.transition(
                        from: admission,
                        applying: .approve,
                        reason: reason
                    ) else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    approvalReceipt = receipt
                    envelopes[index].state = .approved
                    envelopes[index].approvalReceipt = receipt
                    envelopes[index].approvalReason = reason
                    try persistUnlocked(envelopes)
                case .approved, .active:
                    guard let receipt = envelope.approvalReceipt,
                          Self.isValidApprovalReceipt(receipt, for: envelope) else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    throw MemoryProposalConsumerError.duplicateConsumption
                default:
                    throw MemoryProposalConsumerError.invalidState(envelope.state)
                }

                let existingRevision = try store.facts().first {
                    $0.id == envelope.proposal.subjectID
                }
                if let existingRevision {
                    guard existingRevision.lifecycleState == .active,
                          existingRevision.supersedesFactID == supersedingFactID,
                          existingRevision.memoryScope == memoryScope,
                          existingRevision.sourceProposalID == envelope.proposal.proposalID,
                          existingRevision.sourceRef == sourceRef,
                          existingRevision.contentDigest == contentDigest,
                          existingRevision.writeProvenance == envelope.writeProvenance else {
                        throw MemoryProposalConsumerError.proposalConflict
                    }
                } else {
                    do {
                        _ = try store.appendRevision(
                            to: supersedingFactID,
                            id: envelope.proposal.subjectID,
                            text: envelope.text,
                            sourceSessionID: memoryScope.sessionID,
                            category: envelope.category,
                            memoryScope: memoryScope,
                            sourceProposalID: envelope.proposal.proposalID,
                            sourceRef: sourceRef,
                            contentDigest: contentDigest,
                            writeProvenance: envelope.writeProvenance,
                            createdAt: envelope.createdAt
                        )
                    } catch let error as MemoryStoreError {
                        throw Self.consumerError(for: error)
                    }
                }

                if envelopes[index].state != .active {
                    envelopes[index].state = .active
                    try persistUnlocked(envelopes)
                }
                return approvalReceipt
            }

        }
    }

    /// Resolve the proposal envelope that authored a fact, if provenance exists.
    ///
    /// Legacy facts without a proposal id return `nil`; facts that claim
    /// provenance but cannot be matched exactly fail closed.
    public func proposalLineage(
        forFactID factID: String,
        within memoryScope: MemoryScope
    ) throws -> MemoryProposalEnvelope? {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try {
            guard memoryScope.isValid else {
                throw MemoryProposalConsumerError.invalidMemoryScope
            }

            return try withLock {
                let envelopes = try loadUnlocked()
                guard let fact = try store.facts().first(where: { $0.id == factID }) else {
                    throw MemoryProposalConsumerError.proposalNotFound
                }
                try Self.validateProposalLineage(
                    for: fact,
                    within: memoryScope,
                    envelopes: envelopes
                )
                guard let proposalID = fact.sourceProposalID else {
                    return nil
                }
                return envelopes.first { $0.proposal.proposalID == proposalID }
            }

            }()
        }
    }

    /// Roll back an active fact through the proposal consumer's scope boundary.
    @discardableResult
    public func rollbackFact(
        id: String,
        within memoryScope: MemoryScope,
        reason: String
    ) throws -> MemoryFactLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try transitionFact(
                id: id,
                within: memoryScope,
                action: .rollback,
                reason: reason
            )

        }
    }

    /// Tombstone an active fact through the proposal consumer's scope boundary.
    @discardableResult
    public func tombstoneFact(
        id: String,
        within memoryScope: MemoryScope,
        reason: String
    ) throws -> MemoryFactLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try transitionFact(
                id: id,
                within: memoryScope,
                action: .tombstone,
                reason: reason
            )

        }
    }

    /// Restore facts from an explicitly authorized backup/import operation.
    ///
    /// Imported scope metadata is untrusted: a missing scope is bound to the
    /// explicit target scope, while a different or invalid scope is rejected.
    /// The store performs the complete merge/replace transaction under its
    /// lock; this consumer persists a durable receipt for idempotent retries.
    @discardableResult
    public func restoreFacts(
        _ facts: [MemoryFact],
        within memoryScope: MemoryScope,
        mode: MemoryRestoreMode = .merge,
        reason: String,
        trustedPrincipal: MemoryTrustedPrincipal? = nil
    ) throws -> MemoryRestoreResult {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            guard memoryScope.isValid else {
                throw MemoryProposalConsumerError.invalidMemoryScope
            }
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty else {
                throw MemoryProposalConsumerError.invalidRestoreReason
            }

            return try withLock {
                let normalized = try Self.normalize(facts, within: memoryScope)
                // Authorization is checked before receipt replay as well as a new write.
                for fact in normalized where fact.visibility == .personal {
                    guard let owner = fact.ownerUserID, trustedPrincipal?.userID == owner else {
                        throw MemoryVisibilityError.personalPrincipalUnavailable
                    }
                }
                let inputHash = try Self.factsHash(normalized)
                var receipts = try loadRestoreReceiptsUnlocked()
                if let existing = receipts.first(where: {
                    $0.memoryScope == memoryScope
                        && $0.mode == mode
                        && $0.inputHash == inputHash
                }) {
                    return MemoryRestoreResult(receipt: existing)
                }

                let stored: MemoryStoreRestoreResult
                do {
                    stored = try store.restoreFacts(
                        normalized,
                        within: memoryScope,
                        mode: mode,
                        trustedPrincipal: trustedPrincipal
                    )
                } catch let error as MemoryStoreError {
                    throw Self.consumerError(for: error)
                }
                let receipt = MemoryRestoreReceipt(
                    memoryScope: memoryScope,
                    mode: mode,
                    reason: trimmedReason,
                    inputHash: inputHash,
                    beforeHash: stored.beforeHash,
                    afterHash: stored.afterHash,
                    added: stored.added,
                    skipped: stored.skipped,
                    replaced: stored.replaced
                )
                receipts.append(receipt)
                try persistRestoreReceiptsUnlocked(receipts)
                return MemoryRestoreResult(receipt: receipt)
            }

        }
    }

    public func restoreReceipts() throws -> [MemoryRestoreReceipt] {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try {
            try withLock { try loadRestoreReceiptsUnlocked() }

            }()
        }
    }

    /// Replays durable approvals after restart. Approval is already an
    /// explicit user decision, so recovery uses the proposal's captured scope
    /// rather than a possibly changed active UI scope.
    ///
    /// The stable fact id makes replay idempotent. A corrupt receipt or an
    /// unreadable facts file fails closed and leaves the proposal evidence
    /// available for diagnosis.
    @discardableResult
    public func recoverApprovedProposals() throws -> Int {
        return try PersistenceTransactionFence.withWrite([store.persistenceDomain]) {
            try withProposalWriteLock {
                var envelopes = try loadUnlocked()
                // An approved proposal may have stopped before its first fact
                // write. An active proposal has already committed that write:
                // a later Settings deletion or lifecycle transition must not
                // be undone by startup replay.
                let factsAtRecovery = try store.facts()
                var recovered = 0
                var changed = false

                for index in envelopes.indices where
                    envelopes[index].state == .approved || envelopes[index].state == .active {
                    let envelope = envelopes[index]
                    guard let receipt = envelope.approvalReceipt,
                          Self.isValidApprovalReceipt(receipt, for: envelope),
                          let memoryScope = envelope.proposal.memoryScope,
                          memoryScope.isValid else {
                        throw MemoryProposalConsumerError.invalidState(envelope.state)
                    }
                    // An active fact remains recoverable after revocation.
                    // A not-yet-materialized approved proposal must still
                    // carry the live source epoch before it can write.
                    if envelope.state == .approved {
                        try validateSubmissionEpoch(for: envelope)
                    } else {
                        guard let committed = factsAtRecovery.first(where: {
                            $0.id == envelope.proposal.subjectID
                        }), committed.lifecycleState == .active else {
                            continue
                        }
                    }

                    _ = try persistApprovedFact(envelope, within: memoryScope)
                    recovered += 1
                    if envelopes[index].state == .approved {
                        envelopes[index].state = .active
                        changed = true
                    }
                }

                if changed {
                    try persistUnlocked(envelopes)
                }
                return recovered
            }

        }
    }

    public func envelopes() throws -> [MemoryProposalEnvelope] {
        return try PersistenceTransactionFence.withRead([store.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(store.persistenceDomain)
            return try {
            try withLock { try loadUnlocked() }

            }()
        }
    }

    private func transitionFact(
        id: String,
        within memoryScope: MemoryScope,
        action: MemoryFactLifecycleAction,
        reason: String
    ) throws -> MemoryFactLifecycleReceipt {
        guard memoryScope.isValid else {
            throw MemoryProposalConsumerError.invalidMemoryScope
        }

        return try withLock {
            let envelopes = try loadUnlocked()
            guard let fact = try store.facts().first(where: { $0.id == id }) else {
                throw MemoryProposalConsumerError.proposalNotFound
            }
            try Self.validateProposalLineage(
                for: fact,
                within: memoryScope,
                envelopes: envelopes
            )

            do {
                switch action {
                case .rollback:
                    return try store.rollbackFact(id: id, reason: reason)
                case .tombstone:
                    return try store.tombstoneFact(id: id, reason: reason)
                case .revision:
                    // Edits use the original appendRevision admission path.
                    throw MemoryStoreError.invalidLifecycleState
                }
            } catch let error as MemoryStoreError {
                throw Self.consumerError(for: error)
            }
        }
    }

    private static func validateProposalLineage(
        for fact: MemoryFact,
        within memoryScope: MemoryScope,
        envelopes: [MemoryProposalEnvelope]
    ) throws {
        guard fact.memoryScope == memoryScope else {
            throw MemoryProposalConsumerError.scopeMismatch
        }
        guard let proposalID = fact.sourceProposalID else {
            return
        }
        guard let envelope = envelopes.first(where: {
            $0.proposal.proposalID == proposalID
        }) else {
            throw MemoryProposalConsumerError.proposalConflict
        }
        guard envelope.proposal.memoryScope == memoryScope,
              envelope.sourceRef == fact.sourceRef,
              envelope.contentDigest == fact.contentDigest,
              envelope.writeProvenance == fact.writeProvenance,
              envelope.state == .approved || envelope.state == .active else {
            throw MemoryProposalConsumerError.proposalConflict
        }
    }

    private static func isValidApprovalReceipt(
        _ receipt: MemoryProposalLifecycleReceipt,
        for envelope: MemoryProposalEnvelope
    ) -> Bool {
        receipt.proposalID == envelope.proposal.proposalID
            && receipt.scope == envelope.proposal.scope
            && receipt.memoryScope == envelope.proposal.memoryScope
            && receipt.subjectID == envelope.proposal.subjectID
            && receipt.action == .approve
            && receipt.state == .approved
            && receipt.sequence == envelope.proposal.sequence
    }

    private static func validatedBinding(
        for envelope: MemoryProposalEnvelope,
        within memoryScope: MemoryScope,
        generation requestedGeneration: Int?,
        sourceHash requestedSourceHash: String?
    ) throws -> MemoryProposalBinding {
        guard let proposalScope = envelope.proposal.memoryScope,
              let sourceHash = envelope.sourceHash,
              let storedGeneration = envelope.generation,
              let binding = envelope.binding else {
            throw MemoryProposalConsumerError.invalidBinding
        }
        guard proposalScope == memoryScope else {
            throw MemoryProposalConsumerError.scopeMismatch
        }
        guard binding.isValid,
              binding.matches(
                  scope: memoryScope,
                  proposalID: envelope.proposal.proposalID,
                  sourceHash: sourceHash,
                  generation: storedGeneration
              ) else {
            throw MemoryProposalConsumerError.invalidBinding
        }
        try validateWriteProvenance(envelope)
        if let requestedSourceHash, requestedSourceHash != sourceHash {
            throw MemoryProposalConsumerError.invalidBinding
        }
        if let requestedGeneration, requestedGeneration != storedGeneration {
            throw MemoryProposalConsumerError.staleGeneration
        }
        return binding
    }

    private func validateSubmissionEpoch(
        for envelope: MemoryProposalEnvelope
    ) throws {
        guard let sourceID = envelope.sourceID else {
            // Legacy envelopes contain no source permission identity. They
            // retain their existing approval semantics and do not infer a
            // grant from READ, control, or compaction state.
            return
        }
        guard let proposalEpoch = envelope.submissionEpoch else {
            throw MemoryProposalConsumerError.invalidBinding
        }
        guard let authorization = try loadAuthorizationsUnlocked().first(where: {
            $0.sourceID == sourceID
        }) else {
            throw MemoryProposalConsumerError.candidateSubmissionRevoked
        }
        guard authorization.canSubmit else {
            throw MemoryProposalConsumerError.candidateSubmissionRevoked
        }
        guard authorization.epoch == proposalEpoch else {
            throw MemoryProposalConsumerError.candidateSubmissionEpochMismatch
        }
    }

    private static func validateWriteProvenance(
        _ envelope: MemoryProposalEnvelope
    ) throws {
        if envelope.version == MemoryProposalEnvelope.currentVersion {
            guard envelope.writeProvenance != nil else {
                throw MemoryProposalConsumerError.invalidProvenance
            }
        } else {
            guard envelope.writeProvenance == nil else {
                throw MemoryProposalConsumerError.invalidProvenance
            }
        }
        guard let provenance = envelope.writeProvenance else { return }
        guard let memoryScope = envelope.proposal.memoryScope,
              let contentDigest = envelope.contentDigest,
              let sourceHash = envelope.sourceHash,
              let generation = envelope.generation,
              provenance.matches(
                sourceID: envelope.sourceID,
                submissionEpoch: envelope.submissionEpoch,
                proposalID: envelope.proposal.proposalID,
                memoryScope: memoryScope,
                contentDigest: contentDigest,
                sourceHash: sourceHash,
                generation: generation
              ) else {
            throw MemoryProposalConsumerError.invalidProvenance
        }
    }

    private static func normalizedSourceID(
        _ sourceID: String
    ) throws -> String {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == sourceID else {
            throw MemoryProposalConsumerError.invalidSourceID
        }
        return trimmed
    }

    private static func optionalReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistApprovedFact(
        _ envelope: MemoryProposalEnvelope,
        within memoryScope: MemoryScope
    ) throws -> MemoryFact {
        let visibility: MemoryVisibility?
        if envelope.approvalReason == Self.chatProjectApprovalReason
            || envelope.approvalReceipt?.reason == Self.chatProjectApprovalReason
            || envelope.sourceRef?.hasPrefix(Self.chatProjectSourcePrefix) == true {
            guard envelope.sourceID == Self.chatProjectSourceID,
                  envelope.sourceRef == Self.chatProjectSourcePrefix + envelope.proposal.proposalID,
                  envelope.proposal.memoryScope == memoryScope,
                  envelope.approvalReason == Self.chatProjectApprovalReason,
                  let receipt = envelope.approvalReceipt,
                  receipt.reason == Self.chatProjectApprovalReason,
                  Self.isValidApprovalReceipt(receipt, for: envelope) else {
                throw MemoryProposalConsumerError.invalidProvenance
            }
            visibility = .project
        } else if envelope.approvalReason == Self.manualProjectApprovalReason
            || envelope.approvalReceipt?.reason == Self.manualProjectApprovalReason
            || envelope.sourceRef?.hasPrefix(Self.manualProjectSourcePrefix) == true {
            guard envelope.sourceID == "settings-center",
                  envelope.sourceRef == Self.manualProjectSourcePrefix + envelope.proposal.proposalID,
                  envelope.proposal.memoryScope == memoryScope,
                  envelope.approvalReason == Self.manualProjectApprovalReason,
                  let receipt = envelope.approvalReceipt,
                  receipt.reason == Self.manualProjectApprovalReason,
                  Self.isValidApprovalReceipt(receipt, for: envelope) else {
                throw MemoryProposalConsumerError.invalidProvenance
            }
            visibility = .project
        } else {
            visibility = nil
        }
        guard let sourceRef = envelope.sourceRef,
              let contentDigest = envelope.contentDigest else {
            return try store.addFact(
                id: envelope.proposal.subjectID,
                text: envelope.text,
                sourceSessionID: memoryScope.sessionID,
                category: envelope.category,
                createdAt: envelope.createdAt,
                memoryScope: memoryScope,
                visibility: visibility
            )
        }
        return try store.addFact(
            id: envelope.proposal.subjectID,
            text: envelope.text,
            sourceSessionID: memoryScope.sessionID,
            category: envelope.category,
            createdAt: envelope.createdAt,
            memoryScope: memoryScope,
            visibility: visibility,
            sourceProposalID: envelope.proposal.proposalID,
            sourceRef: sourceRef,
            contentDigest: contentDigest,
            writeProvenance: envelope.writeProvenance
        )
    }

    private static func consumerError(
        for reason: MemoryProposalQuarantineReason?
    ) -> MemoryProposalConsumerError {
        switch reason {
        case .invalidMemoryScope:
            return .invalidMemoryScope
        case .scopeMismatch:
            return .scopeMismatch
        case .missingBinding, .invalidBinding:
            return .invalidBinding
        case .some(let reason):
            return .quarantined(reason)
        case .none:
            return .quarantined(.invalidMemoryScope)
        }
    }

    private static func consumerError(
        for error: MemoryStoreError
    ) -> MemoryProposalConsumerError {
        switch error {
        case .emptyFact:
            return .invalidText
        case .invalidFactID:
            return .invalidProposalID
        case .invalidMemoryScope:
            return .invalidMemoryScope
        case .invalidOwnerUserID:
            return .invalidOwnerUserID
        case .scopeMismatch:
            return .scopeMismatch
        case .conflictingFactID:
            return .restoreConflict
        case .concurrentMutation:
            return .restoreConflict
        case .invalidProvenance:
            return .invalidProvenance
        case .invalidRevision,
             .unknownSupersededFact,
             .unknownFact,
             .invalidLifecycleState,
             .invalidLifecycleReason:
            return .restoreConflict
        }
    }

    private func loadUnlocked() throws -> [MemoryProposalEnvelope] {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            return []
        }
        let data = try Data(contentsOf: receiptURL)
        let envelopes = try decoder.decode([MemoryProposalEnvelope].self, from: data)
        var proposalIDs = Set<String>()
        for envelope in envelopes {
            guard envelope.version == MemoryProposalEnvelope.currentVersion
                || envelope.version == MemoryProposalEnvelope.untypedVersion
                || envelope.version == MemoryProposalEnvelope.untypedVersion - 1 else {
                throw MemoryProposalConsumerError.invalidBinding
            }
            guard proposalIDs.insert(envelope.proposal.proposalID).inserted else {
                throw MemoryProposalConsumerError.duplicateProposal
            }
            guard let memoryScope = envelope.proposal.memoryScope,
                  let sourceHash = envelope.sourceHash,
                  let generation = envelope.generation,
                  let binding = envelope.binding else {
                throw MemoryProposalConsumerError.invalidBinding
            }
            guard binding.isValid,
                  binding.matches(
                      scope: memoryScope,
                      proposalID: envelope.proposal.proposalID,
                      sourceHash: sourceHash,
                      generation: generation
                  ) else {
                throw MemoryProposalConsumerError.invalidBinding
            }
            if envelope.sourceID != nil, envelope.submissionEpoch == nil {
                throw MemoryProposalConsumerError.invalidBinding
            }
            try Self.validateWriteProvenance(envelope)
        }
        return envelopes
    }

    private func loadRestoreReceiptsUnlocked() throws -> [MemoryRestoreReceipt] {
        guard FileManager.default.fileExists(atPath: restoreReceiptURL.path) else {
            return []
        }
        let data = try Data(contentsOf: restoreReceiptURL)
        let receipts = try decoder.decode([MemoryRestoreReceipt].self, from: data)
        for receipt in receipts where receipt.version != MemoryRestoreReceipt.currentVersion {
            throw MemoryProposalConsumerError.restoreConflict
        }
        return receipts
    }

    private func loadAuthorizationsUnlocked()
        throws -> [MemoryCandidateSubmissionAuthorization] {
        guard FileManager.default.fileExists(
            atPath: candidateSubmissionAuthorizationURL.path
        ) else {
            return []
        }
        let data = try Data(contentsOf: candidateSubmissionAuthorizationURL)
        let authorizations = try decoder.decode(
            [MemoryCandidateSubmissionAuthorization].self,
            from: data
        )
        var sourceIDs = Set<String>()
        for authorization in authorizations {
            guard authorization.isValid,
                  sourceIDs.insert(authorization.sourceID).inserted else {
                throw MemoryProposalConsumerError.invalidSourceID
            }
        }
        return authorizations
    }

    private func persistRestoreReceiptsUnlocked(_ receipts: [MemoryRestoreReceipt]) throws {
        try FileManager.default.createDirectory(
            at: restoreReceiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(receipts).write(to: restoreReceiptURL, options: .atomic)
    }

    private func persistAuthorizationsUnlocked(
        _ authorizations: [MemoryCandidateSubmissionAuthorization]
    ) throws {
        try FileManager.default.createDirectory(
            at: candidateSubmissionAuthorizationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(authorizations).write(
            to: candidateSubmissionAuthorizationURL,
            options: .atomic
        )
    }

    private static func normalize(
        _ facts: [MemoryFact],
        within memoryScope: MemoryScope
    ) throws -> [MemoryFact] {
        var normalized: [MemoryFact] = []
        var byID: [String: MemoryFact] = [:]
        for fact in facts {
            let id = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw MemoryProposalConsumerError.invalidProposalID
            }
            guard !text.isEmpty else {
                throw MemoryProposalConsumerError.invalidText
            }
            if let factScope = fact.memoryScope {
                guard factScope.isValid else {
                    throw MemoryProposalConsumerError.invalidMemoryScope
                }
                guard factScope == memoryScope else {
                    throw MemoryProposalConsumerError.scopeMismatch
                }
            }

            let scopedFact = MemoryFact(
                id: id,
                text: text,
                sourceSessionID: fact.sourceSessionID,
                createdAt: fact.createdAt,
                category: fact.category,
                memoryScope: memoryScope,
                ownerUserID: fact.ownerUserID,
                visibility: fact.visibility,
                temporaryLifetimeID: fact.temporaryLifetimeID,
                sourceProposalID: fact.sourceProposalID,
                sourceRef: fact.sourceRef,
                contentDigest: fact.contentDigest,
                writeProvenance: fact.writeProvenance,
                revision: fact.revision,
                supersedesFactID: fact.supersedesFactID,
                lifecycleState: fact.lifecycleState,
                activatedAt: fact.activatedAt
            )
            if let previous = byID[id] {
                guard previous == scopedFact else {
                    throw MemoryProposalConsumerError.restoreConflict
                }
                continue
            }
            byID[id] = scopedFact
            normalized.append(scopedFact)
        }
        return normalized
    }

    private static func factsHash(_ facts: [MemoryFact]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(facts.sorted { $0.id < $1.id })
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func persistUnlocked(_ envelopes: [MemoryProposalEnvelope]) throws {
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(envelopes).write(to: receiptURL, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Serialize proposal and source-grant read/modify/write transactions
    /// across independent App processes. Locking the canonical root directory
    /// leaves no extra file in Memory backup/import inventories or denied writes;
    /// atomic JSON replacement cannot change the directory lock inode.
    private func withProposalWriteLock<T>(_ body: () throws -> T) throws -> T {
        let directory = store.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pathInfo = stat()
        guard Darwin.lstat(directory.path, &pathInfo) == 0,
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              pathInfo.st_uid == getuid(),
              (pathInfo.st_mode & mode_t(0o022)) == 0 else {
            throw MemoryProposalConsumerError.persistenceLockUnavailable
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MemoryProposalConsumerError.persistenceLockUnavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var lockInfo = stat()
        guard Darwin.fstat(descriptor, &lockInfo) == 0,
              lockInfo.st_dev == pathInfo.st_dev,
              lockInfo.st_ino == pathInfo.st_ino,
              flock(descriptor, LOCK_EX) == 0 else {
            throw MemoryProposalConsumerError.persistenceLockUnavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        var currentPath = stat()
        guard Darwin.lstat(directory.path, &currentPath) == 0,
              currentPath.st_dev == lockInfo.st_dev,
              currentPath.st_ino == lockInfo.st_ino else {
            throw MemoryProposalConsumerError.persistenceLockUnavailable
        }
        return try withLock(body)
    }

    private static func sharedLock(for directory: URL) -> NSLock {
        let key = directory.standardizedFileURL.path
        let registry = lockRegistry
        registry.mutex.lock()
        defer { registry.mutex.unlock() }
        if let existing = registry.locks[key] {
            return existing
        }
        let created = NSLock()
        registry.locks[key] = created
        return created
    }
}
