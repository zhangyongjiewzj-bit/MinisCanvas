import Foundation
import CryptoKit

private final class MemoryStoreLockRegistry: @unchecked Sendable {
    let mutex = NSLock()
    var locks: [String: NSLock] = [:]
}

enum MemoryLifecycleTransactionFaultPoint: Equatable, Sendable {
    case afterFactsPersisted
}

typealias MemoryLifecycleTransactionFaultInjector =
    @Sendable (MemoryLifecycleTransactionFaultPoint) throws -> Void

public enum MemoryFactLifecycleState: String, Codable, Hashable, Sendable {
    case active
    case superseded
    case rolledBack
    case tombstoned
}

public enum MemoryFactLifecycleAction: String, Codable, Hashable, Sendable {
    case rollback
    case tombstone
    case revision
}

public struct MemoryFactLifecycleReceipt: Codable, Equatable, Sendable {
    public let receiptID: String
    public let factID: String
    public let action: MemoryFactLifecycleAction
    public let revision: Int
    public let reason: String
    public let createdAt: Date
    /// Approval replay travels with the existing lifecycle receipt transaction.
    public let settingsReplay: BL6MemoryReplayRecord?

    public init(
        receiptID: String = UUID().uuidString,
        factID: String,
        action: MemoryFactLifecycleAction,
        revision: Int,
        reason: String,
        createdAt: Date = Date(),
        settingsReplay: BL6MemoryReplayRecord? = nil
    ) {
        self.receiptID = receiptID
        self.factID = factID
        self.action = action
        self.revision = revision
        self.reason = reason
        self.createdAt = createdAt
        self.settingsReplay = settingsReplay
    }
}

/// The approved directory call is metadata of the canonical memory lifecycle
/// receipt, never a second ledger or an alternate fact writer.
public typealias BL6MemoryReplayRecordFactory = @Sendable (MemoryFact, MemoryFact, [MemoryFact], [MemoryFact]) throws -> BL6SettingsReplayRecord

public struct BL6MemoryReplayRecord: Codable, Equatable, Sendable {
    public let settings: BL6SettingsReplayRecord
    public let before: MemoryFact
    public let after: MemoryFact

    public init(settings: BL6SettingsReplayRecord, before: MemoryFact, after: MemoryFact) {
        self.settings = settings
        self.before = before
        self.after = after
    }
}

// MARK: - MemoryFact

/// A single persistent memory entry, captured across sessions.
public struct MemoryFact: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    /// The remembered fact / note text.
    public let text: String
    /// The session id the fact was captured from ("" when unknown).
    public let sourceSessionID: String
    /// Concrete session/project scope captured for new production facts.
    ///
    /// Optional decoding preserves compatibility with legacy facts. Scoped
    /// consumers must reject a missing value instead of treating it as shared.
    public let memoryScope: MemoryScope?
    /// Stable user identity required for an explicit user-scope read.
    public let ownerUserID: String?
    /// Absent for legacy facts; absence never implies Personal or Temporary.
    public let visibility: MemoryVisibility?
    /// Explicit opaque lifetime for Temporary only. Core does not expire it.
    public let temporaryLifetimeID: String?
    public let createdAt: Date
    /// Classification of the fact. Defaults to `.fact`.
    ///
    /// Decoded with `decodeIfPresent` so facts persisted by older versions
    /// (which never wrote a `category` key) load as `.fact` instead of
    /// failing to decode.
    public let category: MemoryCategory
    public let sourceProposalID: String?
    public let sourceRef: String?
    public let contentDigest: String?
    /// Captured origin of a reviewed proposal, when one was supplied. This
    /// records provenance only and does not itself authorize fact creation.
    public let writeProvenance: MemoryWriteProvenance?
    public let revision: Int
    public let supersedesFactID: String?
    public let lifecycleState: MemoryFactLifecycleState
    public let activatedAt: Date?

    public init(
        id: String = UUID().uuidString,
        text: String,
        sourceSessionID: String = "",
        createdAt: Date = Date(),
        category: MemoryCategory = .fact,
        memoryScope: MemoryScope? = nil,
        ownerUserID: String? = nil,
        visibility: MemoryVisibility? = nil,
        temporaryLifetimeID: String? = nil,
        sourceProposalID: String? = nil,
        sourceRef: String? = nil,
        contentDigest: String? = nil,
        writeProvenance: MemoryWriteProvenance? = nil,
        revision: Int = 1,
        supersedesFactID: String? = nil,
        lifecycleState: MemoryFactLifecycleState = .active,
        activatedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.sourceSessionID = sourceSessionID
        self.memoryScope = memoryScope
        self.ownerUserID = ownerUserID
        self.visibility = visibility
        self.temporaryLifetimeID = temporaryLifetimeID
        self.createdAt = createdAt
        self.category = category
        self.sourceProposalID = sourceProposalID
        self.sourceRef = sourceRef
        self.contentDigest = contentDigest
        self.writeProvenance = writeProvenance
        self.revision = revision
        self.supersedesFactID = supersedesFactID
        self.lifecycleState = lifecycleState
        self.activatedAt = activatedAt ?? (lifecycleState == .active ? createdAt : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, sourceSessionID, memoryScope, ownerUserID, visibility
        case temporaryLifetimeID, createdAt, category
        case sourceProposalID, sourceRef, contentDigest, writeProvenance, revision, supersedesFactID
        case lifecycleState, activatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.text = try c.decode(String.self, forKey: .text)
        self.sourceSessionID = try c.decodeIfPresent(String.self, forKey: .sourceSessionID) ?? ""
        self.memoryScope = try c.decodeIfPresent(MemoryScope.self, forKey: .memoryScope)
        self.ownerUserID = try c.decodeIfPresent(String.self, forKey: .ownerUserID)
        self.visibility = try c.decodeIfPresent(MemoryVisibility.self, forKey: .visibility)
        self.temporaryLifetimeID = try c.decodeIfPresent(String.self, forKey: .temporaryLifetimeID)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // Backward compatibility: older payloads have no `category` key.
        self.category = try c.decodeIfPresent(MemoryCategory.self, forKey: .category) ?? .fact
        self.sourceProposalID = try c.decodeIfPresent(String.self, forKey: .sourceProposalID)
        self.sourceRef = try c.decodeIfPresent(String.self, forKey: .sourceRef)
        self.contentDigest = try c.decodeIfPresent(String.self, forKey: .contentDigest)
        self.writeProvenance = try c.decodeIfPresent(MemoryWriteProvenance.self, forKey: .writeProvenance)
        self.revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        self.supersedesFactID = try c.decodeIfPresent(String.self, forKey: .supersedesFactID)
        self.lifecycleState = try c.decodeIfPresent(
            MemoryFactLifecycleState.self,
            forKey: .lifecycleState
        ) ?? .active
        self.activatedAt = try c.decodeIfPresent(Date.self, forKey: .activatedAt)
            ?? (self.lifecycleState == .active ? self.createdAt : nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(sourceSessionID, forKey: .sourceSessionID)
        try c.encodeIfPresent(memoryScope, forKey: .memoryScope)
        try c.encodeIfPresent(ownerUserID, forKey: .ownerUserID)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        try c.encodeIfPresent(temporaryLifetimeID, forKey: .temporaryLifetimeID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(category, forKey: .category)
        try c.encodeIfPresent(sourceProposalID, forKey: .sourceProposalID)
        try c.encodeIfPresent(sourceRef, forKey: .sourceRef)
        try c.encodeIfPresent(contentDigest, forKey: .contentDigest)
        try c.encodeIfPresent(writeProvenance, forKey: .writeProvenance)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(supersedesFactID, forKey: .supersedesFactID)
        try c.encode(lifecycleState, forKey: .lifecycleState)
        try c.encodeIfPresent(activatedAt, forKey: .activatedAt)
    }
}

// MARK: - MemoryStore

public enum MemoryRestoreMode: String, Codable, Sendable {
    case merge
    case replace
}

/// The outcome of the most recent persisted lifecycle recovery attempt.
///
/// This is process-local provenance: a new store starts as `clean`, a
/// successfully replayed transaction records its durable transaction ID, and
/// a malformed or unrecognized transaction becomes `blocked`. The status is
/// deliberately observable without exposing fact content or filesystem paths.
public enum MemoryStoreRecoveryStatus: Equatable, Sendable {
    case clean
    case recovered(transactionID: String)
    case blocked
}

public struct MemoryStoreRestoreResult: Equatable, Sendable {
    public let added: Int
    public let skipped: Int
    public let replaced: Int
    public let beforeHash: String
    public let afterHash: String

    public init(
        added: Int,
        skipped: Int,
        replaced: Int,
        beforeHash: String,
        afterHash: String
    ) {
        self.added = added
        self.skipped = skipped
        self.replaced = replaced
        self.beforeHash = beforeHash
        self.afterHash = afterHash
    }
}

/// Opaque rollback capability returned by a deletion transaction.
///
/// The snapshot and expected post-delete hash are intentionally not
/// constructible outside this file. Callers can only replay a rollback
/// capability produced by this store, and only while the post-delete state
/// still matches.
public struct MemoryFactDeletionRollback: Sendable {
    fileprivate let snapshot: [MemoryFact]
    fileprivate let expectedCurrentHash: String
    public let affectedCount: Int

    fileprivate init(
        snapshot: [MemoryFact],
        expectedCurrentHash: String,
        affectedCount: Int
    ) {
        self.snapshot = snapshot
        self.expectedCurrentHash = expectedCurrentHash
        self.affectedCount = affectedCount
    }
}

/// Persistent memory store backed by a single JSON file:
/// `<directory>/memory/facts.json`.
///
/// All reads/writes are serialized under an internal lock; writes are atomic.
/// The store is safe to share across tasks.
public final class MemoryStore: @unchecked Sendable {
    private struct LifecycleTransactionIntent: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let transactionID: String
        let beforeFacts: [MemoryFact]
        let afterFacts: [MemoryFact]
        let beforeReceipts: [MemoryFactLifecycleReceipt]
        let afterReceipts: [MemoryFactLifecycleReceipt]
        let contentDigest: String

        init(
            version: Int = Self.currentVersion,
            transactionID: String,
            beforeFacts: [MemoryFact],
            afterFacts: [MemoryFact],
            beforeReceipts: [MemoryFactLifecycleReceipt],
            afterReceipts: [MemoryFactLifecycleReceipt],
            contentDigest: String = ""
        ) {
            self.version = version
            self.transactionID = transactionID
            self.beforeFacts = beforeFacts
            self.afterFacts = afterFacts
            self.beforeReceipts = beforeReceipts
            self.afterReceipts = afterReceipts
            self.contentDigest = contentDigest
        }

        func withDigest() -> LifecycleTransactionIntent {
            LifecycleTransactionIntent(
                version: version,
                transactionID: transactionID,
                beforeFacts: beforeFacts,
                afterFacts: afterFacts,
                beforeReceipts: beforeReceipts,
                afterReceipts: afterReceipts,
                contentDigest: Self.digest(for: self)
            )
        }

        var hasValidDigest: Bool {
            !contentDigest.isEmpty && Self.digest(for: self) == contentDigest
        }

        private struct DigestPayload: Codable {
            let version: Int
            let transactionID: String
            let beforeFacts: [MemoryFact]
            let afterFacts: [MemoryFact]
            let beforeReceipts: [MemoryFactLifecycleReceipt]
            let afterReceipts: [MemoryFactLifecycleReceipt]

            init(intent: LifecycleTransactionIntent) {
                version = intent.version
                transactionID = intent.transactionID
                beforeFacts = intent.beforeFacts
                afterFacts = intent.afterFacts
                beforeReceipts = intent.beforeReceipts
                afterReceipts = intent.afterReceipts
            }
        }

        private static func digest(
            for intent: LifecycleTransactionIntent
        ) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(DigestPayload(intent: intent)) else {
                return ""
            }
            return SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    /// Root directory the store persists under (the "project directory").
    public let directory: URL
    public var persistenceDomain: PersistenceTransactionFence.Domain { .memories(directory) }

    /// The JSON file holding all facts.
    public var fileURL: URL {
        directory.appendingPathComponent("memory/facts.json", isDirectory: false)
    }

    public var lifecycleReceiptURL: URL {
        directory.appendingPathComponent("memory/lifecycle-v1.json", isDirectory: false)
    }

    var lifecycleTransactionURL: URL {
        directory.appendingPathComponent(
            "memory/lifecycle-transaction-v1.json",
            isDirectory: false
        )
    }

    private static let lockRegistry = MemoryStoreLockRegistry()
    private let lock: NSLock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lifecycleTransactionFaultInjector:
        MemoryLifecycleTransactionFaultInjector?
    private let beforeFactsReadForTesting: (@Sendable () -> Void)?
    private var recoveryState: MemoryStoreRecoveryStatus = .clean

    public convenience init(directory: URL) {
        self.init(directory: directory, lifecycleTransactionFaultInjector: nil)
    }

    init(
        directory: URL,
        lifecycleTransactionFaultInjector:
            MemoryLifecycleTransactionFaultInjector?,
        beforeFactsReadForTesting: (@Sendable () -> Void)? = nil
    ) {
        let admission = PersistenceTransactionFence.read([.memories(directory)])
        defer { admission.release() }
        self.directory = directory
        self.lifecycleTransactionFaultInjector =
            lifecycleTransactionFaultInjector
        self.beforeFactsReadForTesting = beforeFactsReadForTesting
        self.lock = Self.sharedLock(
            for: directory
                .appendingPathComponent("memory/facts.json", isDirectory: false)
                .standardizedFileURL
        )
    }

    /// The latest lifecycle recovery outcome observed by this store instance.
    ///
    /// Recovery is lazy and occurs on the first read or write after restart.
    /// A `recovered` value binds the observation to the transaction intent
    /// that was replayed; `blocked` means the store refused to infer or replace
    /// damaged state.
    public var recoveryStatus: MemoryStoreRecoveryStatus {
        lock.withLock { recoveryState }
    }

    public static func contentDigest(for text: String) -> String {
        let canonicalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(canonicalText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Add a new fact and persist. Returns the created fact.
    @discardableResult
    public func addFact(
        _ text: String,
        sourceSessionID: String = "",
        category: MemoryCategory = .fact,
        memoryScope: MemoryScope? = nil,
        ownerUserID: String? = nil,
        visibility: MemoryVisibility? = nil,
        temporaryLifetimeID: String? = nil,
        trustedPrincipal: MemoryTrustedPrincipal? = nil,
        sourceProposalID: String? = nil,
        sourceRef: String? = nil,
        contentDigest: String? = nil,
        writeProvenance: MemoryWriteProvenance? = nil,
        revision: Int = 1,
        supersedesFactID: String? = nil,
        lifecycleState: MemoryFactLifecycleState = .active,
        activatedAt: Date? = nil
    ) throws -> MemoryFact {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MemoryStoreError.emptyFact
            }
            if let memoryScope, !memoryScope.isValid {
                throw MemoryStoreError.invalidMemoryScope
            }
            if let ownerUserID,
               ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MemoryStoreError.invalidOwnerUserID
            }
            try Self.validateVisibilityMetadata(
                scope: memoryScope,
                ownerUserID: ownerUserID,
                visibility: visibility,
                temporaryLifetimeID: temporaryLifetimeID,
                trustedPrincipal: trustedPrincipal
            )
            try Self.requireTrustedPrincipalForWrite(
                visibility: visibility,
                ownerUserID: ownerUserID,
                trustedPrincipal: trustedPrincipal
            )
            try Self.validateVersionedFields(
                text: trimmed,
                sourceProposalID: sourceProposalID,
                sourceRef: sourceRef,
                contentDigest: contentDigest,
                revision: revision,
                supersedesFactID: supersedesFactID,
                factID: nil
            )
            try Self.validateWriteProvenance(
                writeProvenance, proposalID: sourceProposalID,
                scope: memoryScope, contentDigest: contentDigest
            )
            let fact = MemoryFact(
                text: trimmed,
                sourceSessionID: sourceSessionID,
                category: category,
                memoryScope: memoryScope,
                ownerUserID: ownerUserID,
                visibility: visibility,
                temporaryLifetimeID: temporaryLifetimeID,
                sourceProposalID: sourceProposalID,
                sourceRef: sourceRef,
                contentDigest: contentDigest,
                writeProvenance: writeProvenance,
                revision: revision,
                supersedesFactID: supersedesFactID,
                lifecycleState: lifecycleState,
                activatedAt: activatedAt
            )
            try lock.withLock {
                var facts = try loadUnlocked()
                facts.append(fact)
                try persistUnlocked(facts)
            }
            return fact

        }
    }

    /// Add a fact with a stable id for proposal approval/replay.
    ///
    /// Reusing an id with the same payload is idempotent and does not rewrite
    /// `facts.json`. Reusing it with a different payload fails closed.
    @discardableResult
    public func addFact(
        id: String,
        text: String,
        sourceSessionID: String = "",
        category: MemoryCategory = .fact,
        createdAt: Date = Date(),
        memoryScope: MemoryScope? = nil,
        ownerUserID: String? = nil,
        visibility: MemoryVisibility? = nil,
        temporaryLifetimeID: String? = nil,
        trustedPrincipal: MemoryTrustedPrincipal? = nil,
        sourceProposalID: String? = nil,
        sourceRef: String? = nil,
        contentDigest: String? = nil,
        writeProvenance: MemoryWriteProvenance? = nil,
        revision: Int = 1,
        supersedesFactID: String? = nil,
        lifecycleState: MemoryFactLifecycleState = .active,
        activatedAt: Date? = nil
    ) throws -> MemoryFact {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw MemoryStoreError.invalidFactID
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw MemoryStoreError.emptyFact
            }
            if let memoryScope, !memoryScope.isValid {
                throw MemoryStoreError.invalidMemoryScope
            }
            if let ownerUserID,
               ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MemoryStoreError.invalidOwnerUserID
            }
            try Self.validateVisibilityMetadata(
                scope: memoryScope,
                ownerUserID: ownerUserID,
                visibility: visibility,
                temporaryLifetimeID: temporaryLifetimeID,
                trustedPrincipal: trustedPrincipal
            )
            try Self.requireTrustedPrincipalForWrite(
                visibility: visibility,
                ownerUserID: ownerUserID,
                trustedPrincipal: trustedPrincipal
            )
            try Self.validateVersionedFields(
                text: trimmedText,
                sourceProposalID: sourceProposalID,
                sourceRef: sourceRef,
                contentDigest: contentDigest,
                revision: revision,
                supersedesFactID: supersedesFactID,
                factID: trimmedID
            )
            try Self.validateWriteProvenance(
                writeProvenance, proposalID: sourceProposalID,
                scope: memoryScope, contentDigest: contentDigest
            )

            return try lock.withLock {
                var facts = try loadUnlocked()
                if let existing = facts.first(where: { $0.id == trimmedID }) {
                    guard existing.text == trimmedText,
                          existing.sourceSessionID == sourceSessionID,
                          existing.category == category,
                          existing.memoryScope == memoryScope,
                          existing.ownerUserID == ownerUserID,
                          existing.visibility == visibility,
                          existing.temporaryLifetimeID == temporaryLifetimeID,
                          existing.sourceProposalID == sourceProposalID,
                          existing.sourceRef == sourceRef,
                          existing.contentDigest == contentDigest,
                          existing.writeProvenance == writeProvenance,
                          existing.revision == revision,
                          existing.supersedesFactID == supersedesFactID,
                          existing.lifecycleState == lifecycleState else {
                        throw MemoryStoreError.conflictingFactID
                    }
                    return existing
                }

                let fact = MemoryFact(
                    id: trimmedID,
                    text: trimmedText,
                    sourceSessionID: sourceSessionID,
                    createdAt: createdAt,
                    category: category,
                    memoryScope: memoryScope,
                    ownerUserID: ownerUserID,
                    visibility: visibility,
                    temporaryLifetimeID: temporaryLifetimeID,
                    sourceProposalID: sourceProposalID,
                    sourceRef: sourceRef,
                    contentDigest: contentDigest,
                    writeProvenance: writeProvenance,
                    revision: revision,
                    supersedesFactID: supersedesFactID,
                    lifecycleState: lifecycleState,
                    activatedAt: activatedAt
                )
                facts.append(fact)
                try persistUnlocked(facts)
                return fact
            }

        }
    }

    /// All facts, newest first.
    ///
    /// Reads at this boundary are strict. A corrupt or unreadable facts file
    /// must remain observable to callers so an export, restore, or UI action
    /// cannot mistake it for an empty memory store.
    public func facts() throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try lock.withLock {
                try loadUnlocked().sorted(by: Self.newestFirst)
            }

            }()
        }
    }

    /// Strict read used by export/import boundaries. Corrupt or unreadable
    /// persistence is surfaced instead of being treated as an empty store.
    public func loadFacts() throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try lock.withLock {
                try loadUnlocked().sorted(by: Self.newestFirst)
            }

            }()
        }
    }

    /// Active projection used by retrieval. Historical versions remain
    /// available through `facts()` for management and audit views.
    public func activeFacts() throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try facts().filter { $0.lifecycleState == .active }

            }()
        }
    }

    /// Active pre-classification facts admitted by one historical selector.
    ///
    /// Invalid selectors and legacy facts without the required identity fail
    /// closed instead of becoming a shared global projection.
    public func activeFacts(within scope: MemoryScopeFilter) throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            guard scope.isValid else { return [] }
            return try activeFacts().filter {
                $0.visibility == nil
                    && scope.matches(memoryScope: $0.memoryScope, ownerUserID: $0.ownerUserID)
            }

            }()
        }
    }

    func activeFactsForDisplay(within filter: MemoryScopeFilter) throws -> [MemoryFact] {
        guard filter.isValid else { return [] }
        guard case .session(let scope) = filter else { return try activeFacts(within: filter) }
        return try activeFacts().filter { fact in
            switch fact.visibility {
            case nil: return fact.memoryScope == scope
            case .project:
                return fact.memoryScope?.isValid == true && fact.memoryScope?.projectID == scope.projectID
            default: return false
            }
        }
    }

    /// Append a new active revision and supersede the current revision.
    ///
    /// When an expectation is supplied, the predecessor's revision and
    /// fingerprint are checked while holding the same lock as the mutation.
    /// This keeps a preview from appending after another writer advanced the
    /// generation.
    @discardableResult
    public func appendRevision(
        to factID: String,
        id: String = UUID().uuidString,
        text: String,
        sourceSessionID: String? = nil,
        category: MemoryCategory? = nil,
        memoryScope: MemoryScope? = nil,
        ownerUserID: String? = nil,
        trustedPrincipal: MemoryTrustedPrincipal? = nil,
        sourceProposalID: String,
        sourceRef: String,
        contentDigest: String,
        writeProvenance: MemoryWriteProvenance? = nil,
        createdAt: Date = Date(),
        expectedRevision: Int? = nil,
        expectedFingerprint: String? = nil,
        makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> MemoryFact {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            guard (expectedRevision == nil) == (expectedFingerprint == nil) else {
                throw MemoryStoreError.concurrentMutation
            }
            let canonicalFactID = factID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalFactID.isEmpty else { throw MemoryStoreError.invalidFactID }
            let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { throw MemoryStoreError.invalidFactID }
            guard !trimmedText.isEmpty else { throw MemoryStoreError.emptyFact }
            try Self.validateVersionedFields(
                text: trimmedText,
                sourceProposalID: sourceProposalID,
                sourceRef: sourceRef,
                contentDigest: contentDigest,
                revision: 1,
                supersedesFactID: canonicalFactID,
                factID: trimmedID
            )

            return try lock.withLock {
                var facts = try loadUnlocked()
                let beforeFacts = facts
                guard let index = facts.firstIndex(where: { $0.id == canonicalFactID }) else {
                    throw MemoryStoreError.unknownSupersededFact
                }
                let previous = facts[index]
                guard previous.lifecycleState == .active else {
                    throw MemoryStoreError.invalidRevision
                }
                if let expectedRevision, let expectedFingerprint {
                    guard previous.revision == expectedRevision,
                          try Self.valueHash(previous) == expectedFingerprint else {
                        throw MemoryStoreError.concurrentMutation
                    }
                }
                let targetScope = memoryScope ?? previous.memoryScope
                if let targetScope, !targetScope.isValid {
                    throw MemoryStoreError.invalidMemoryScope
                }
                if let targetScope, previous.memoryScope != nil, targetScope != previous.memoryScope {
                    throw MemoryStoreError.scopeMismatch
                }
                try Self.validateWriteProvenance(
                    writeProvenance, proposalID: sourceProposalID,
                    scope: targetScope, contentDigest: contentDigest
                )
                let targetOwner = ownerUserID ?? previous.ownerUserID
                if previous.visibility == .personal,
                   targetOwner != previous.ownerUserID {
                    throw MemoryStoreError.scopeMismatch
                }
                try Self.validateVisibilityMetadata(
                    scope: targetScope,
                    ownerUserID: targetOwner,
                    visibility: previous.visibility,
                    temporaryLifetimeID: previous.temporaryLifetimeID,
                    trustedPrincipal: trustedPrincipal
                )
                try Self.requireTrustedPrincipalForWrite(
                    visibility: previous.visibility,
                    ownerUserID: targetOwner,
                    trustedPrincipal: trustedPrincipal
                )
                guard !facts.contains(where: { $0.id == trimmedID }) else {
                    throw MemoryStoreError.conflictingFactID
                }

                facts[index] = MemoryFact(
                    id: previous.id,
                    text: previous.text,
                    sourceSessionID: previous.sourceSessionID,
                    createdAt: previous.createdAt,
                    category: previous.category,
                    memoryScope: previous.memoryScope,
                    ownerUserID: previous.ownerUserID,
                    visibility: previous.visibility,
                    temporaryLifetimeID: previous.temporaryLifetimeID,
                    sourceProposalID: previous.sourceProposalID,
                    sourceRef: previous.sourceRef,
                    contentDigest: previous.contentDigest,
                    writeProvenance: previous.writeProvenance,
                    revision: previous.revision,
                    supersedesFactID: previous.supersedesFactID,
                    lifecycleState: .superseded,
                    activatedAt: previous.activatedAt
                )
                let next = MemoryFact(
                    id: trimmedID,
                    text: trimmedText,
                    sourceSessionID: sourceSessionID ?? previous.sourceSessionID,
                    createdAt: createdAt,
                    category: category ?? previous.category,
                    memoryScope: targetScope,
                    ownerUserID: targetOwner,
                    visibility: previous.visibility,
                    temporaryLifetimeID: previous.temporaryLifetimeID,
                    sourceProposalID: sourceProposalID,
                    sourceRef: sourceRef,
                    contentDigest: contentDigest,
                    writeProvenance: writeProvenance,
                    revision: previous.revision + 1,
                    supersedesFactID: previous.id,
                    lifecycleState: .active,
                    activatedAt: createdAt
                )
                facts.append(next)
                if let makeSettingsReplayRecord {
                    let settings = try makeSettingsReplayRecord(previous, next, beforeFacts, facts)
                    let replay = BL6MemoryReplayRecord(settings: settings, before: previous, after: next)
                    try Self.validateSettingsReplay(replay, beforeFacts: beforeFacts, afterFacts: facts)
                    let beforeReceipts = try loadLifecycleReceiptsUnlocked()
                    guard !beforeReceipts.contains(where: { $0.settingsReplay?.settings.requestID == settings.requestID }) else {
                        throw MemoryStoreError.concurrentMutation
                    }
                    let receipt = MemoryFactLifecycleReceipt(
                        receiptID: settings.receipt.receiptID, factID: next.id, action: .revision,
                        revision: next.revision, reason: "已批准目录记忆修订", settingsReplay: replay
                    )
                    try persistLifecycleChangeUnlocked(beforeFacts: beforeFacts, afterFacts: facts,
                        beforeReceipts: beforeReceipts, receipt: receipt)
                } else {
                    try persistUnlocked(facts)
                }
                return next
            }

        }
    }

    @discardableResult
    public func rollbackFact(id: String, reason: String) throws -> MemoryFactLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try transitionFact(id: id, to: .rolledBack, action: .rollback, reason: reason)

        }
    }

    /// Roll back an edit only while both sides of its revision chain still
    /// equal the facts reviewed by the caller. The comparison and transition
    /// share the store lock, including across independent MemoryStore owners.
    @discardableResult
    public func rollbackRevision(
        expectedSuccessor: MemoryFact,
        expectedPredecessor: MemoryFact,
        reason: String,
        makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> MemoryFactLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            guard expectedSuccessor.lifecycleState == .active,
                  expectedPredecessor.lifecycleState == .superseded,
                  expectedSuccessor.supersedesFactID == expectedPredecessor.id,
                  expectedSuccessor.revision == expectedPredecessor.revision + 1,
                  expectedSuccessor.memoryScope == expectedPredecessor.memoryScope else {
                throw MemoryStoreError.concurrentMutation
            }
            return try transitionFact(
                id: expectedSuccessor.id,
                to: .rolledBack,
                action: .rollback,
                reason: reason,
                expectedCurrent: expectedSuccessor,
                expectedPredecessor: expectedPredecessor,
                makeSettingsReplayRecord: makeSettingsReplayRecord
            )
        }
    }

    @discardableResult
    public func tombstoneFact(
        id: String, reason: String, makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> MemoryFactLifecycleReceipt {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try transitionFact(id: id, to: .tombstoned, action: .tombstone, reason: reason,
                makeSettingsReplayRecord: makeSettingsReplayRecord)

        }
    }

    public func lifecycleReceipts() throws -> [MemoryFactLifecycleReceipt] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try lock.withLock {
                try loadLifecycleReceiptsUnlocked()
            }

            }()
        }
    }

    /// Restore a scoped batch while holding the store lock for the complete
    /// read/validate/merge-or-replace/write transaction.
    @discardableResult
    public func restoreFacts(
        _ incoming: [MemoryFact],
        within memoryScope: MemoryScope,
        mode: MemoryRestoreMode,
        trustedPrincipal: MemoryTrustedPrincipal? = nil
    ) throws -> MemoryStoreRestoreResult {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            guard memoryScope.isValid else {
                throw MemoryStoreError.invalidMemoryScope
            }

            return try lock.withLock {
                let existing = try loadUnlocked()
                let beforeHash = try Self.factsHash(existing)
                var normalized: [MemoryFact] = []
                var byID: [String: MemoryFact] = [:]

                for fact in incoming {
                    let id = fact.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { throw MemoryStoreError.invalidFactID }
                    guard !text.isEmpty else { throw MemoryStoreError.emptyFact }
                    if let factScope = fact.memoryScope, factScope != memoryScope {
                        throw MemoryStoreError.scopeMismatch
                    }
                    if let ownerUserID = fact.ownerUserID,
                       ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw MemoryStoreError.invalidOwnerUserID
                    }
                    try Self.validateVisibilityMetadata(
                        scope: memoryScope,
                        ownerUserID: fact.ownerUserID,
                        visibility: fact.visibility,
                        temporaryLifetimeID: fact.temporaryLifetimeID,
                        trustedPrincipal: trustedPrincipal
                    )
                    try Self.requireTrustedPrincipalForWrite(
                        visibility: fact.visibility,
                        ownerUserID: fact.ownerUserID,
                        trustedPrincipal: trustedPrincipal
                    )

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
                            throw MemoryStoreError.conflictingFactID
                        }
                        continue
                    }
                    byID[id] = scopedFact
                    normalized.append(scopedFact)
                }

                let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                var skipped = 0
                var added = 0
                for fact in normalized {
                    if let previous = existingByID[fact.id] {
                        guard previous == fact else {
                            throw MemoryStoreError.conflictingFactID
                        }
                        skipped += 1
                    } else {
                        added += 1
                    }
                }

                let next: [MemoryFact]
                let replaced: Int
                switch mode {
                case .merge:
                    next = existing + normalized.filter { existingByID[$0.id] == nil }
                    replaced = 0
                case .replace:
                    // The old replace operation addresses only a concrete
                    // session/project, not a visibility class. Until its
                    // consumer supplies a class-aware contract, it cannot
                    // remove newly classified facts as a side effect.
                    guard !normalized.contains(where: { $0.visibility != nil }),
                          !existing.contains(where: {
                              $0.memoryScope == memoryScope && $0.visibility != nil
                          }) else {
                        throw MemoryVisibilityError.replaceUnavailable
                    }
                    let targetIDs = Set(normalized.map(\.id))
                    replaced = existing.filter {
                        $0.memoryScope == memoryScope && !targetIDs.contains($0.id)
                    }.count
                    next = existing.filter { $0.memoryScope != memoryScope } + normalized
                }

                let afterHash = try Self.factsHash(next)
                if afterHash != beforeHash {
                    try persistUnlocked(next)
                }
                return MemoryStoreRestoreResult(
                    added: added,
                    skipped: skipped,
                    replaced: replaced,
                    beforeHash: beforeHash,
                    afterHash: afterHash
                )
            }

        }
    }

    /// Delete one fact and return an opaque, compare-and-swap rollback
    /// capability for the exact post-delete state.
    @discardableResult
    public func removeFactForRollback(id: String) throws -> MemoryFactDeletionRollback {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try _removeFactForRollback(
                id: id,
                expectedRevision: nil,
                expectedFingerprint: nil
            )

        }
    }

    /// Delete one fact only when the caller's preview still matches the
    /// current fact. The expectation check and deletion share one lock.
    @discardableResult
    public func removeFactForRollback(
        id: String,
        expectedRevision: Int,
        expectedFingerprint: String
    ) throws -> MemoryFactDeletionRollback {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try _removeFactForRollback(
                id: id,
                expectedRevision: expectedRevision,
                expectedFingerprint: expectedFingerprint
            )

        }
    }

    private func _removeFactForRollback(
        id: String,
        expectedRevision: Int?,
        expectedFingerprint: String?
    ) throws -> MemoryFactDeletionRollback {
        guard (expectedRevision == nil) == (expectedFingerprint == nil) else {
            throw MemoryStoreError.concurrentMutation
        }
        let canonicalID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalID.isEmpty else { throw MemoryStoreError.invalidFactID }
        return try lock.withLock {
            let existing = try loadUnlocked()
            if let expectedRevision, let expectedFingerprint {
                let current = existing.first { $0.id == canonicalID }
                let currentRevision = current.map {
                    Int(clamping: Int64($0.createdAt.timeIntervalSince1970.rounded(.down)))
                } ?? -1
                let currentFingerprint = try current.map(Self.valueHash) ?? ""
                guard currentRevision == expectedRevision,
                      currentFingerprint == expectedFingerprint else {
                    throw MemoryStoreError.concurrentMutation
                }
            }
            let next = existing.filter { $0.id != canonicalID }
            let beforeHash = try Self.factsHash(existing)
            let afterHash = try Self.factsHash(next)
            if afterHash != beforeHash {
                try persistUnlocked(next)
            }
            return MemoryFactDeletionRollback(
                snapshot: existing,
                expectedCurrentHash: afterHash,
                affectedCount: existing.count - next.count
            )
        }
    }

    /// Delete all facts atomically and return an opaque rollback capability.
    @discardableResult
    public func removeAllFactsForRollback() throws -> MemoryFactDeletionRollback {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try _removeAllFactsForRollback(
                expectedRevision: nil,
                expectedFingerprint: nil
            )

        }
    }

    /// Delete all facts only when the caller's preview still matches the
    /// current snapshot. The expectation check and deletion share one lock.
    @discardableResult
    public func removeAllFactsForRollback(
        expectedRevision: Int,
        expectedFingerprint: String
    ) throws -> MemoryFactDeletionRollback {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try _removeAllFactsForRollback(
                expectedRevision: expectedRevision,
                expectedFingerprint: expectedFingerprint
            )

        }
    }

    private func _removeAllFactsForRollback(
        expectedRevision: Int?,
        expectedFingerprint: String?
    ) throws -> MemoryFactDeletionRollback {
        guard (expectedRevision == nil) == (expectedFingerprint == nil) else {
            throw MemoryStoreError.concurrentMutation
        }
        return try lock.withLock {
            let existing = try loadUnlocked()
            if let expectedRevision, let expectedFingerprint {
                let ordered = existing.sorted { $0.createdAt > $1.createdAt }
                let currentFingerprint = try Self.valueHash(ordered)
                guard existing.count == expectedRevision,
                      currentFingerprint == expectedFingerprint else {
                    throw MemoryStoreError.concurrentMutation
                }
            }
            let beforeHash = try Self.factsHash(existing)
            let afterHash = try Self.factsHash([])
            if afterHash != beforeHash {
                try persistUnlocked([])
            }
            return MemoryFactDeletionRollback(
                snapshot: existing,
                expectedCurrentHash: afterHash,
                affectedCount: existing.count
            )
        }
    }

    /// Restore a deletion only if no other writer changed the post-delete
    /// state. The opaque receipt prevents arbitrary snapshot replacement.
    public func rollback(_ receipt: MemoryFactDeletionRollback) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                let current = try loadUnlocked()
                let currentHash = try Self.factsHash(current)
                guard currentHash == receipt.expectedCurrentHash else {
                    throw MemoryStoreError.concurrentMutation
                }
                try Self.validatePersistedFacts(receipt.snapshot)
                try persistUnlocked(receipt.snapshot)
            }

        }
    }

    /// Facts whose text contains `keyword` (case-insensitive substring match).
    /// Returns `[]` for empty keywords.
    public func searchFacts(keyword: String) throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return [] }
            return try activeFacts().filter { $0.text.lowercased().contains(needle) }

            }()
        }
    }

    /// Facts matching any of `keywords`, ranked by number of matched keywords
    /// (descending), then by recency (descending).
    public func searchFacts(keywords: [String]) throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            let needles = keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard !needles.isEmpty else { return [] }

            return try activeFacts()
                .map { fact -> (fact: MemoryFact, hits: Int) in
                    let lower = fact.text.lowercased()
                    let hits = needles.filter { lower.contains($0) }.count
                    return (fact, hits)
                }
                .filter { $0.hits > 0 }
                .sorted {
                    if $0.hits != $1.hits { return $0.hits > $1.hits }
                    return Self.newestFirst($0.fact, $1.fact)
                }
                .map(\.fact)

            }()
        }
    }

    /// Search only pre-classification facts admitted by a historical session,
    /// project, or user selector. Unscoped facts are excluded.
    public func searchFacts(
        keywords: [String],
        within scope: MemoryScopeFilter
    ) throws -> [MemoryFact] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            guard scope.isValid else { return [] }
            return try searchFacts(keywords: keywords)
                .filter {
                    $0.visibility == nil && scope.matches(
                        memoryScope: $0.memoryScope,
                        ownerUserID: $0.ownerUserID
                    )
                }

            }()
        }
    }

    /// Remove a fact by id. No-op when the id does not exist.
    public func removeFact(id: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            let canonicalID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalID.isEmpty else { throw MemoryStoreError.invalidFactID }
            try lock.withLock {
                var facts = try loadUnlocked()
                facts.removeAll { $0.id == canonicalID }
                try persistUnlocked(facts)
            }

        }
    }

    // MARK: - Internals

    private func transitionFact(
        id: String,
        to state: MemoryFactLifecycleState,
        action: MemoryFactLifecycleAction,
        reason: String,
        expectedCurrent: MemoryFact? = nil,
        expectedPredecessor: MemoryFact? = nil,
        makeSettingsReplayRecord: BL6MemoryReplayRecordFactory? = nil
    ) throws -> MemoryFactLifecycleReceipt {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            throw MemoryStoreError.invalidLifecycleReason
        }
        return try lock.withLock {
            var facts = try loadUnlocked()
            let beforeFacts = facts
            guard let index = facts.firstIndex(where: { $0.id == id }) else {
                throw MemoryStoreError.unknownFact
            }
            let current = facts[index]
            if let expectedCurrent, let expectedPredecessor {
                guard current == expectedCurrent,
                      let predecessor = facts.first(where: { $0.id == expectedPredecessor.id }),
                      predecessor == expectedPredecessor else {
                    throw MemoryStoreError.concurrentMutation
                }
            }
            let persistedReceipts = try loadLifecycleReceiptsUnlocked()
            if let existingReceipt = persistedReceipts.last(where: {
                $0.factID == current.id
                    && $0.action == action
                    && $0.revision == current.revision
                    && $0.reason == trimmedReason
            }) {
                if expectedCurrent != nil {
                    throw MemoryStoreError.concurrentMutation
                }
                return existingReceipt
            }
            guard current.lifecycleState == .active else {
                throw MemoryStoreError.invalidLifecycleState
            }
            facts[index] = MemoryFact(
                id: current.id,
                text: current.text,
                sourceSessionID: current.sourceSessionID,
                createdAt: current.createdAt,
                category: current.category,
                memoryScope: current.memoryScope,
                ownerUserID: current.ownerUserID,
                visibility: current.visibility,
                temporaryLifetimeID: current.temporaryLifetimeID,
                sourceProposalID: current.sourceProposalID,
                sourceRef: current.sourceRef,
                contentDigest: current.contentDigest,
                writeProvenance: current.writeProvenance,
                revision: current.revision,
                supersedesFactID: current.supersedesFactID,
                lifecycleState: state,
                activatedAt: current.activatedAt
            )
            if action == .rollback, let predecessorID = current.supersedesFactID,
               let predecessorIndex = facts.firstIndex(where: { $0.id == predecessorID }) {
                let predecessor = facts[predecessorIndex]
                facts[predecessorIndex] = MemoryFact(
                    id: predecessor.id,
                    text: predecessor.text,
                    sourceSessionID: predecessor.sourceSessionID,
                    createdAt: predecessor.createdAt,
                    category: predecessor.category,
                    memoryScope: predecessor.memoryScope,
                    ownerUserID: predecessor.ownerUserID,
                    visibility: predecessor.visibility,
                    temporaryLifetimeID: predecessor.temporaryLifetimeID,
                    sourceProposalID: predecessor.sourceProposalID,
                    sourceRef: predecessor.sourceRef,
                    contentDigest: predecessor.contentDigest,
                    writeProvenance: predecessor.writeProvenance,
                    revision: predecessor.revision,
                    supersedesFactID: predecessor.supersedesFactID,
                    lifecycleState: .active,
                    activatedAt: predecessor.activatedAt ?? predecessor.createdAt
                )
            }
            let replay: BL6MemoryReplayRecord?
            if let makeSettingsReplayRecord {
                let resulting: MemoryFact
                if action == .rollback, let predecessorID = current.supersedesFactID,
                   let restored = facts.first(where: { $0.id == predecessorID }) {
                    resulting = restored
                } else if action == .tombstone {
                    resulting = facts[index]
                } else { throw MemoryStoreError.concurrentMutation }
                let settings = try makeSettingsReplayRecord(current, resulting, beforeFacts, facts)
                let value = BL6MemoryReplayRecord(settings: settings, before: current, after: resulting)
                try Self.validateSettingsReplay(value, beforeFacts: beforeFacts, afterFacts: facts)
                guard !persistedReceipts.contains(where: { $0.settingsReplay?.settings.requestID == settings.requestID }) else {
                    throw MemoryStoreError.concurrentMutation
                }
                replay = value
            } else { replay = nil }
            let receipt = MemoryFactLifecycleReceipt(
                receiptID: replay?.settings.receipt.receiptID ?? UUID().uuidString,
                factID: current.id, action: action, revision: current.revision,
                reason: trimmedReason, settingsReplay: replay
            )
            try persistLifecycleChangeUnlocked(beforeFacts: beforeFacts, afterFacts: facts,
                beforeReceipts: persistedReceipts, receipt: receipt)
            return receipt
        }
    }

    /// Directory revisions include the scoped revision chain, including undo
    /// history, while excluding personal and temporary facts.
    public static func bl6MemoryRevision(facts: [MemoryFact], within scope: MemoryScope) throws -> String {
        guard scope.isValid else { throw MemoryStoreError.invalidMemoryScope }
        return try factsHash(facts.filter {
            $0.memoryScope == scope && ($0.visibility == nil || $0.visibility == .project)
        }.sorted { $0.id < $1.id })
    }

    public func bl6MemoryRevision(within scope: MemoryScope) throws -> String {
        try Self.bl6MemoryRevision(facts: facts(), within: scope)
    }

    public func bl6MemoryReplayRecord(for requestID: String, profileID: String) throws -> BL6MemoryReplayRecord? {
        let records = try lifecycleReceipts().compactMap(\.settingsReplay).filter { $0.settings.requestID == requestID }
        guard records.count <= 1 else { throw MemoryStoreError.concurrentMutation }
        guard let record = records.first else { return nil }
        guard record.settings.profileID == profileID else { throw MemoryStoreError.scopeMismatch }
        return record
    }

    public func bl6MemoryReplayRecord(receiptID: String, profileID: String) throws -> BL6MemoryReplayRecord? {
        let records = try lifecycleReceipts().compactMap(\.settingsReplay).filter { $0.settings.receipt.receiptID == receiptID }
        guard records.count <= 1 else { throw MemoryStoreError.concurrentMutation }
        guard let record = records.first else { return nil }
        guard record.settings.profileID == profileID else { throw MemoryStoreError.scopeMismatch }
        return record
    }

    /// Replaying a committed approved call is an exact receipt read. It never
    /// re-applies its old revision after a later undo or edit.
    public func replayBL6MemoryRecord(_ expected: BL6MemoryReplayRecord, profileID: String) throws -> BL6SettingsReceipt {
        guard let stored = try bl6MemoryReplayRecord(for: expected.settings.requestID, profileID: profileID),
              stored == expected, Date() < stored.settings.approvalExpiresAt else {
            throw MemoryStoreError.concurrentMutation
        }
        return stored.settings.receipt
    }

    private func persistLifecycleChangeUnlocked(
        beforeFacts: [MemoryFact], afterFacts: [MemoryFact],
        beforeReceipts: [MemoryFactLifecycleReceipt], receipt: MemoryFactLifecycleReceipt
    ) throws {
        let receipts = beforeReceipts + [receipt]
        let intent = LifecycleTransactionIntent(transactionID: receipt.receiptID,
            beforeFacts: beforeFacts, afterFacts: afterFacts,
            beforeReceipts: beforeReceipts, afterReceipts: receipts).withDigest()
        try persistLifecycleTransactionIntentUnlocked(intent)
        try persistUnlocked(afterFacts)
        try lifecycleTransactionFaultInjector?(.afterFactsPersisted)
        try persistLifecycleReceiptsUnlocked(receipts)
        try clearLifecycleTransactionIntentUnlocked()
    }

    private static func validateSettingsReplayMetadata(_ replay: BL6MemoryReplayRecord) throws {
        let record = replay.settings
        guard let scope = replay.before.memoryScope, scope.isValid, replay.after.memoryScope == scope,
              (replay.before.visibility == nil || replay.before.visibility == .project),
              (replay.after.visibility == nil || replay.after.visibility == .project),
              !record.requestID.isEmpty, !record.payloadDigest.isEmpty,
              !record.approvalBindingDigest.isEmpty, !record.profileID.isEmpty,
              !record.scope.isEmpty, record.sessionID == scope.sessionID,
              !record.policyRevision.isEmpty, !record.grantEpoch.isEmpty,
              record.approvalExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              !record.receipt.receiptID.isEmpty, record.receipt.requestID == record.requestID,
              record.receipt.operation == record.operation, record.frozenInput.operation == record.operation,
              record.frozenInput.expectedRevision == record.receipt.previousRevision,
              !record.receipt.previousRevision.isEmpty, !record.receipt.effectiveRevision.isEmpty,
              !record.receipt.secretValuesExposed, record.receipt.rollbackValues.isEmpty,
              record.rollbackValues.isEmpty, record.receipt.changedKeys.count == 1,
              (try? record.frozenInput.validateForApprovedEffect()) != nil else {
            throw MemoryStoreError.concurrentMutation
        }
        let key = record.operation == .rollback ? "memory.fact.\(replay.after.id)" : "memory.fact.\(replay.before.id)"
        guard record.receipt.changedKeys == [key], record.operation == .apply || record.operation == .rollback else {
            throw MemoryStoreError.concurrentMutation
        }
    }

    private static func validateSettingsReplay(
        _ replay: BL6MemoryReplayRecord, beforeFacts: [MemoryFact], afterFacts: [MemoryFact]
    ) throws {
        try validateSettingsReplayMetadata(replay)
        let record = replay.settings
        guard let scope = replay.before.memoryScope, scope.isValid,
              replay.after.memoryScope == scope, record.sessionID == scope.sessionID,
              !record.requestID.isEmpty, record.receipt.requestID == record.requestID,
              record.operation == record.frozenInput.operation, record.operation == record.receipt.operation,
              record.receipt.changedKeys.count == 1,
              record.frozenInput.expectedRevision == record.receipt.previousRevision,
              record.receipt.previousRevision == (try bl6MemoryRevision(facts: beforeFacts, within: scope)),
              record.receipt.effectiveRevision == (try bl6MemoryRevision(facts: afterFacts, within: scope)) else {
            throw MemoryStoreError.concurrentMutation
        }
        switch record.operation {
        case .apply:
            guard record.receipt.changedKeys == ["memory.fact.\(replay.before.id)"],
                  Set(record.frozenInput.changes.keys) == Set(record.receipt.changedKeys),
                  (replay.after.supersedesFactID == replay.before.id
                    && replay.after.revision == replay.before.revision + 1
                    && replay.after.lifecycleState == .active)
                    || (replay.after.id == replay.before.id
                        && replay.after.revision == replay.before.revision
                        && replay.after.lifecycleState == .tombstoned) else {
                throw MemoryStoreError.concurrentMutation
            }
        case .rollback:
            guard record.receipt.changedKeys == ["memory.fact.\(replay.after.id)"],
                  replay.before.supersedesFactID == replay.after.id,
                  record.frozenInput.changes.isEmpty, record.frozenInput.undoReceiptID != nil else {
                throw MemoryStoreError.concurrentMutation
            }
        default: throw MemoryStoreError.concurrentMutation
        }
    }

    private static func sharedLock(for fileURL: URL) -> NSLock {
        let key = fileURL.standardizedFileURL.path
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

    private func loadUnlocked() throws -> [MemoryFact] {
        try recoverLifecycleTransactionIfNeededUnlocked()
        let facts = try loadFactsFileUnlocked()
        // A missing lifecycle field is decoded as active for genuine legacy
        // rows. Once a durable rollback/tombstone receipt exists, however, a
        // retained fact with that ID cannot be revived by losing the field on
        // disk. Removed facts may leave historical receipts, so validate only
        // IDs still present in the current facts snapshot.
        let retainedIDs = Set(facts.map(\.id))
        let retainedReceipts = try loadLifecycleReceiptFileUnlocked().filter {
            retainedIDs.contains($0.factID)
        }
        try Self.validateLifecycleReceipts(retainedReceipts, against: facts)
        return facts
    }

    private func loadFactsFileUnlocked() throws -> [MemoryFact] {
        let fm = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                // A non-directory parent is damaged persistence. Treating the
                // missing child path as [] would let recovery overwrite the
                // user's only remaining evidence with an empty snapshot.
                throw MemoryStoreError.concurrentMutation
            }
        }
        guard fm.fileExists(atPath: fileURL.path) else {
            return []
        }
        beforeFactsReadForTesting?()
        let data = try Data(contentsOf: fileURL)
        let facts = try decoder.decode([MemoryFact].self, from: data)
        try Self.validatePersistedFacts(facts)
        try validateProposalOriginBindings(facts)
        return facts
    }

    private func persistUnlocked(_ facts: [MemoryFact]) throws {
        let fm = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MemoryStoreError.concurrentMutation
            }
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try Self.validatePersistedFacts(facts)
        try validateProposalOriginBindings(facts)
        let data = try encoder.encode(facts)
        try data.write(to: fileURL, options: .atomic)
    }

    /// A proposal-origin fact must retain the tuple declared by its durable
    /// V5 proposal. This checks ordinary facts()/activeFacts() reads too, not
    /// only the proposal consumer's lineage API. The proposal journal is in
    /// the same persistence domain as facts and is read under the caller's
    /// existing domain admission.
    private func validateProposalOriginBindings(_ facts: [MemoryFact]) throws {
        guard facts.contains(where: { $0.sourceProposalID != nil || $0.writeProvenance != nil }) else {
            return
        }
        let proposalURL = directory.appendingPathComponent(
            "memory/proposals-v1.json", isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: proposalURL.path) else {
            guard !facts.contains(where: { $0.writeProvenance != nil }) else {
                throw MemoryStoreError.invalidProvenance
            }
            return // Genuine legacy or imported facts may have no proposal journal.
        }
        let envelopes: [MemoryProposalEnvelope]
        do {
            envelopes = try decoder.decode(
                [MemoryProposalEnvelope].self,
                from: Data(contentsOf: proposalURL)
            )
        } catch {
            throw MemoryStoreError.invalidProvenance
        }
        var byProposalID: [String: MemoryProposalEnvelope] = [:]
        for envelope in envelopes {
            guard envelope.version == MemoryProposalEnvelope.currentVersion
                || envelope.version == MemoryProposalEnvelope.untypedVersion
                || envelope.version == MemoryProposalEnvelope.untypedVersion - 1 else {
                throw MemoryStoreError.invalidProvenance
            }
            guard byProposalID.updateValue(envelope, forKey: envelope.proposal.proposalID) == nil else {
                throw MemoryStoreError.invalidProvenance
            }
            if envelope.version == MemoryProposalEnvelope.currentVersion {
                guard let provenance = envelope.writeProvenance,
                      let scope = envelope.proposal.memoryScope,
                      let contentDigest = envelope.contentDigest,
                      let sourceHash = envelope.sourceHash,
                      let generation = envelope.generation,
                      provenance.matches(
                        sourceID: envelope.sourceID,
                        submissionEpoch: envelope.submissionEpoch,
                        proposalID: envelope.proposal.proposalID,
                        memoryScope: scope,
                        contentDigest: contentDigest,
                        sourceHash: sourceHash,
                        generation: generation
                      ) else {
                    throw MemoryStoreError.invalidProvenance
                }
            } else if envelope.writeProvenance != nil {
                throw MemoryStoreError.invalidProvenance
            }
        }
        for fact in facts {
            guard let proposalID = fact.sourceProposalID else { continue }
            guard let envelope = byProposalID[proposalID] else {
                if fact.writeProvenance != nil {
                    throw MemoryStoreError.invalidProvenance
                }
                continue
            }
            if envelope.version == MemoryProposalEnvelope.currentVersion {
                guard fact.writeProvenance == envelope.writeProvenance,
                      fact.memoryScope == envelope.proposal.memoryScope,
                      fact.contentDigest == envelope.contentDigest,
                      fact.sourceRef == envelope.sourceRef else {
                    throw MemoryStoreError.invalidProvenance
                }
            } else if fact.writeProvenance != nil {
                throw MemoryStoreError.invalidProvenance
            }
        }
    }

    private func loadLifecycleReceiptsUnlocked() throws -> [MemoryFactLifecycleReceipt] {
        try recoverLifecycleTransactionIfNeededUnlocked()
        let receipts = try loadLifecycleReceiptFileUnlocked()
        try Self.validateLifecycleReceipts(
            receipts,
            against: try loadFactsFileUnlocked()
        )
        return receipts
    }

    private func loadLifecycleReceiptFileUnlocked() throws -> [MemoryFactLifecycleReceipt] {
        guard FileManager.default.fileExists(atPath: lifecycleReceiptURL.path) else {
            return []
        }
        return try decoder.decode(
            [MemoryFactLifecycleReceipt].self,
            from: Data(contentsOf: lifecycleReceiptURL)
        )
    }

    private func persistLifecycleReceiptsUnlocked(
        _ receipts: [MemoryFactLifecycleReceipt]
    ) throws {
        let parent = lifecycleReceiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try encoder.encode(receipts).write(to: lifecycleReceiptURL, options: .atomic)
    }

    private func persistLifecycleTransactionIntentUnlocked(
        _ intent: LifecycleTransactionIntent
    ) throws {
        let parent = lifecycleTransactionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try encoder.encode(intent).write(
            to: lifecycleTransactionURL,
            options: .atomic
        )
    }

    private func clearLifecycleTransactionIntentUnlocked() throws {
        guard FileManager.default.fileExists(
            atPath: lifecycleTransactionURL.path
        ) else {
            return
        }
        try FileManager.default.removeItem(at: lifecycleTransactionURL)
    }

    private func recoverLifecycleTransactionIfNeededUnlocked() throws {
        guard FileManager.default.fileExists(
            atPath: lifecycleTransactionURL.path
        ) else {
            return
        }
        let intent: LifecycleTransactionIntent
        do {
            intent = try decoder.decode(
                LifecycleTransactionIntent.self,
                from: Data(contentsOf: lifecycleTransactionURL)
            )
        } catch {
            recoveryState = .blocked
            throw MemoryStoreError.concurrentMutation
        }
        guard intent.version == LifecycleTransactionIntent.currentVersion,
              !intent.transactionID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.hasValidDigest,
              intent.beforeFacts != intent.afterFacts,
              intent.afterReceipts.count == intent.beforeReceipts.count + 1,
              Array(intent.afterReceipts.dropLast()) == intent.beforeReceipts,
              intent.afterReceipts.last?.receiptID == intent.transactionID else {
            recoveryState = .blocked
            throw MemoryStoreError.concurrentMutation
        }
        do {
            try Self.validatePersistedFacts(intent.beforeFacts)
            try Self.validatePersistedFacts(intent.afterFacts)
            try Self.validateLifecycleReceipts(
                intent.beforeReceipts,
                against: intent.beforeFacts
            )
            try Self.validateLifecycleReceipts(
                intent.afterReceipts,
                against: intent.afterFacts
            )
        } catch {
            recoveryState = .blocked
            throw MemoryStoreError.concurrentMutation
        }

        let currentFacts: [MemoryFact]
        let currentReceipts: [MemoryFactLifecycleReceipt]
        do {
            currentFacts = try loadFactsFileUnlocked()
            currentReceipts = try loadLifecycleReceiptFileUnlocked()
        } catch {
            recoveryState = .blocked
            throw error
        }
        let factsRecognized = currentFacts == intent.beforeFacts
            || currentFacts == intent.afterFacts
        let receiptsRecognized = currentReceipts == intent.beforeReceipts
            || currentReceipts == intent.afterReceipts
        guard factsRecognized, receiptsRecognized else {
            recoveryState = .blocked
            throw MemoryStoreError.concurrentMutation
        }

        do {
            if currentFacts != intent.afterFacts {
                try persistUnlocked(intent.afterFacts)
            }
            if currentReceipts != intent.afterReceipts {
                try persistLifecycleReceiptsUnlocked(intent.afterReceipts)
            }
            try clearLifecycleTransactionIntentUnlocked()
        } catch {
            recoveryState = .blocked
            throw error
        }
        recoveryState = .recovered(transactionID: intent.transactionID)
    }
}

// MARK: - Errors

public enum MemoryStoreError: Error, Equatable, Sendable {
    case emptyFact
    case invalidFactID
    case invalidMemoryScope
    case invalidOwnerUserID
    case scopeMismatch
    case conflictingFactID
    case concurrentMutation
    case invalidProvenance
    case invalidRevision
    case unknownSupersededFact
    case unknownFact
    case invalidLifecycleState
    case invalidLifecycleReason
}

/// New class-specific failures stay separate from the legacy store error
/// switch used by existing consumers. Product import adapters must surface
/// these as unavailable/pending instead of treating them as an empty result.
public enum MemoryVisibilityError: Error, Equatable, Sendable {
    case invalidMetadata
    case personalPrincipalUnavailable
    case replaceUnavailable
}

// MARK: - Lock helper

extension NSLock {
    /// Run `body` while holding the lock.
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension MemoryStore {
    static func validateVisibilityMetadata(
        scope: MemoryScope?,
        ownerUserID: String?,
        visibility: MemoryVisibility?,
        temporaryLifetimeID: String?,
        trustedPrincipal: MemoryTrustedPrincipal? = nil
    ) throws {
        switch visibility {
        case nil:
            guard temporaryLifetimeID == nil else {
                throw MemoryVisibilityError.invalidMetadata
            }
        case .personal:
            guard let scope, scope.isValid,
                  let ownerUserID, !ownerUserID.isEmpty,
                  ownerUserID == ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines),
                  ownerUserID != "local-user",
                  temporaryLifetimeID == nil else {
                throw MemoryVisibilityError.invalidMetadata
            }
            if let trustedPrincipal {
                guard trustedPrincipal.userID == ownerUserID else {
                    throw MemoryVisibilityError.personalPrincipalUnavailable
                }
            }
        case .project:
            guard let scope, scope.isValid, temporaryLifetimeID == nil else {
                throw MemoryVisibilityError.invalidMetadata
            }
        case .temporary:
            guard let scope, scope.isValid,
                  let temporaryLifetimeID,
                  MemoryTemporaryLifetime(id: temporaryLifetimeID).isValid else {
                throw MemoryVisibilityError.invalidMetadata
            }
        }
    }

    static func requireTrustedPrincipalForWrite(
        visibility: MemoryVisibility?,
        ownerUserID: String?,
        trustedPrincipal: MemoryTrustedPrincipal?
    ) throws {
        guard visibility == .personal else { return }
        guard let ownerUserID,
              trustedPrincipal?.userID == ownerUserID else {
            throw MemoryVisibilityError.personalPrincipalUnavailable
        }
    }

    static func newestFirst(_ lhs: MemoryFact, _ rhs: MemoryFact) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.revision != rhs.revision {
            return lhs.revision > rhs.revision
        }
        return lhs.id < rhs.id
    }

    static func validatePersistedFacts(_ facts: [MemoryFact]) throws {
        var ids = Set<String>()
        for fact in facts {
            guard !fact.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryStoreError.invalidFactID
            }
            guard !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryStoreError.emptyFact
            }
            if let memoryScope = fact.memoryScope, !memoryScope.isValid {
                throw MemoryStoreError.invalidMemoryScope
            }
            if let ownerUserID = fact.ownerUserID,
               ownerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MemoryStoreError.invalidOwnerUserID
            }
            try validateVisibilityMetadata(
                scope: fact.memoryScope,
                ownerUserID: fact.ownerUserID,
                visibility: fact.visibility,
                temporaryLifetimeID: fact.temporaryLifetimeID
            )
            try validateVersionedFields(
                text: fact.text,
                sourceProposalID: fact.sourceProposalID,
                sourceRef: fact.sourceRef,
                contentDigest: fact.contentDigest,
                revision: fact.revision,
                supersedesFactID: fact.supersedesFactID,
                factID: fact.id
            )
            try validateWriteProvenance(
                fact.writeProvenance, proposalID: fact.sourceProposalID,
                scope: fact.memoryScope, contentDigest: fact.contentDigest
            )
            guard ids.insert(fact.id).inserted else {
                throw MemoryStoreError.conflictingFactID
            }
        }
        let factsByID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        for fact in facts {
            if let supersedesFactID = fact.supersedesFactID,
               let predecessor = factsByID[supersedesFactID] {
                guard fact.revision == predecessor.revision + 1,
                      fact.memoryScope == predecessor.memoryScope else {
                    throw MemoryStoreError.invalidRevision
                }
            } else if fact.supersedesFactID != nil {
                throw MemoryStoreError.unknownSupersededFact
            }
        }
        // A rollback may keep a historical child while reactivating its
        // predecessor for a later revision. Only one version in that entire
        // lineage may be current, and an active version cannot descend from
        // a tombstoned or rolled-back ancestor.
        var activeRoots = Set<String>()
        for fact in facts where fact.lifecycleState == .active {
            var ancestor = fact
            while let predecessorID = ancestor.supersedesFactID {
                guard let predecessor = factsByID[predecessorID],
                      predecessor.lifecycleState == .superseded else {
                    throw MemoryStoreError.invalidLifecycleState
                }
                ancestor = predecessor
            }
            guard activeRoots.insert(ancestor.id).inserted else {
                throw MemoryStoreError.invalidLifecycleState
            }
        }
    }

    static func validateVersionedFields(
        text: String,
        sourceProposalID: String?,
        sourceRef: String?,
        contentDigest: String?,
        revision: Int,
        supersedesFactID: String?,
        factID: String?
    ) throws {
        guard revision > 0 else { throw MemoryStoreError.invalidRevision }
        if let supersedesFactID, supersedesFactID == factID {
            throw MemoryStoreError.invalidRevision
        }
        let values = [sourceProposalID, sourceRef, contentDigest]
        if values.contains(where: { $0 != nil }) {
            guard values.allSatisfy({
                guard let value = $0 else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw MemoryStoreError.invalidProvenance
            }
            guard contentDigest == MemoryStore.contentDigest(for: text) else {
                throw MemoryStoreError.invalidProvenance
            }
        }
    }

    static func validateWriteProvenance(
        _ provenance: MemoryWriteProvenance?,
        proposalID: String?,
        scope: MemoryScope?,
        contentDigest: String?
    ) throws {
        guard let provenance else { return }
        guard provenance.matchesFact(
            proposalID: proposalID,
            memoryScope: scope,
            contentDigest: contentDigest
        ) else {
            throw MemoryStoreError.invalidProvenance
        }
    }

    static func validateLifecycleReceipts(
        _ receipts: [MemoryFactLifecycleReceipt],
        against facts: [MemoryFact]
    ) throws {
        var receiptIDs = Set<String>()
        let factsByID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })

        for receipt in receipts {
            guard !receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  receiptIDs.insert(receipt.receiptID).inserted else {
                throw MemoryStoreError.invalidLifecycleReason
            }
            guard !receipt.factID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryStoreError.unknownFact
            }
            guard receipt.revision > 0,
                  !receipt.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MemoryStoreError.invalidLifecycleReason
            }
            guard let fact = factsByID[receipt.factID] else {
                throw MemoryStoreError.unknownFact
            }
            guard fact.revision == receipt.revision else {
                throw MemoryStoreError.invalidRevision
            }

            if let replay = receipt.settingsReplay {
                try validateSettingsReplayMetadata(replay)
                guard replay.settings.receipt.receiptID == receipt.receiptID else {
                    throw MemoryStoreError.concurrentMutation
                }
            }
            // A revision receipt records a past append. Subsequent approved
            // edits or undo can change the current state without erasing it.
            if receipt.action == .revision {
                guard let replay = receipt.settingsReplay, replay.after.id == receipt.factID,
                      replay.after.revision == receipt.revision, replay.settings.operation == .apply else {
                    throw MemoryStoreError.invalidLifecycleState
                }
                continue
            }
            let expectedState: MemoryFactLifecycleState
            switch receipt.action {
            case .rollback:
                expectedState = .rolledBack
            case .tombstone:
                expectedState = .tombstoned
            case .revision:
                throw MemoryStoreError.invalidLifecycleState
            }
            guard fact.lifecycleState == expectedState else {
                throw MemoryStoreError.invalidLifecycleState
            }
        }
    }

    static func factsHash(_ facts: [MemoryFact]) throws -> String {
        try valueHash(facts.sorted { $0.id < $1.id })
    }

    static func valueHash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
