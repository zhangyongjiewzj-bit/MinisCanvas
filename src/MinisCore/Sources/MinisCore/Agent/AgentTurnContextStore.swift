import Foundation
import Darwin

/// Durable lifecycle state for one immutable agent execution identity.
public enum AgentTurnContextStatus: String, Codable, Equatable, Hashable, Sendable {
    case active
    /// Writeback has been admitted, but the transcript/result persistence has
    /// not finished yet. This state is durable so a restart cannot re-admit a
    /// callback while its transcript commit is still in flight.
    case writingBack
    case completed
    case failed
    case needsUserReview
    case cancelled
    case policyRefused
    case dryRun
}

/// The persisted facts needed to reject a duplicate or late turn after restart.
public struct AgentTurnContextRecord: Codable, Equatable, Hashable, Sendable {
    public let identity: AgentExecutionIdentity
    public let snapshot: ConversationContextSnapshotV1
    public let status: AgentTurnContextStatus
    /// Monotonic writeback generation; late callbacks from an older recovery
    /// attempt are rejected even when the immutable turn identity is reused.
    public let generation: Int
    /// Monotonic stream sequence persisted with the turn. A restart therefore
    /// rejects duplicate and late deltas before they can reach a transcript.
    public let streamSequence: Int
    /// Identity-bound terminal fact persisted with the lifecycle record. This
    /// lets a restarted caller reconstruct the outcome instead of treating a
    /// terminal status as an in-memory observation only.
    public let terminalTruth: AgentTerminalTruth?

    public init(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        status: AgentTurnContextStatus,
        generation: Int = 0,
        streamSequence: Int = 0,
        terminalTruth: AgentTerminalTruth? = nil
    ) {
        self.identity = identity
        self.snapshot = snapshot
        self.status = status
        self.generation = generation
        self.streamSequence = streamSequence
        self.terminalTruth = terminalTruth
    }

    private enum CodingKeys: String, CodingKey {
        case identity, snapshot, status, generation, streamSequence, terminalTruth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identity = try container.decode(AgentExecutionIdentity.self, forKey: .identity)
        self.snapshot = try container.decode(ConversationContextSnapshotV1.self, forKey: .snapshot)
        self.status = try container.decode(AgentTurnContextStatus.self, forKey: .status)
        self.generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        self.streamSequence = try container.decodeIfPresent(Int.self, forKey: .streamSequence) ?? 0
        self.terminalTruth = try container.decodeIfPresent(AgentTerminalTruth.self, forKey: .terminalTruth)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identity, forKey: .identity)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(status, forKey: .status)
        try container.encode(generation, forKey: .generation)
        try container.encode(streamSequence, forKey: .streamSequence)
        try container.encodeIfPresent(terminalTruth, forKey: .terminalTruth)
    }
}

public enum AgentTurnContextStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidSnapshot
    case invalidSnapshotRecovery(AgentTurnContextSnapshotRecoveryReason)
    case conflictingIdentity
    case corruptStore
    case persistenceFailed
    case staleGeneration
    case staleSequence
}

/// Fixed, payload-free startup diagnostics. These do not relax snapshot
/// validation or make a historical snapshot executable.
public enum AgentTurnContextSnapshotRecoveryReason: String, Equatable, Sendable {
    case recordNonLossless
    case stateNonLossless
    /// Reserved fallback when an old-formula rejection has no finer stage.
    case legacyFormulaUnsafeShape
    case legacySizeLimit
    case legacyBindingShape
    case legacySessionBinding
    case legacyFingerprintShape
    case legacySnapshotBindingCollision
    /// The declared non-framed ID does not match the old formula.
    case legacyFormulaMismatch
    /// A declared framed ID does not match the current canonical projection.
    case currentCanonicalMismatch
}

/// Small Core-owned durable turn tombstone store.
///
/// A turn is admitted before asynchronous work starts. Completion and
/// cancellation are terminal transitions; a later process cannot re-admit the
/// same immutable identity or accept its old writeback. The store has no
/// Provider, UI, or application-composition dependency.
public final class AgentTurnContextStore: @unchecked Sendable {
    private static let schemaVersion = 1

    private final class PersistenceLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [String: NSRecursiveLock] = [:]

        func lock(for path: String) -> NSRecursiveLock {
            registryLock.lock()
            defer { registryLock.unlock() }
            if let lock = locks[path] {
                return lock
            }
            let lock = NSRecursiveLock()
            locks[path] = lock
            return lock
        }
    }

    private static let persistenceLockRegistry = PersistenceLockRegistry()

    private struct State: Codable {
        let schemaVersion: Int
        let records: [AgentTurnContextRecord]
    }

    private let persistenceURL: URL?
    private let lock = NSLock()
    private var recordsByIdentity: [AgentExecutionIdentity: AgentTurnContextRecord]
    /// Old delimiter-based IDs are retained for deduplication only. They are
    /// never returned to a stream or writeback consumer.
    private var legacyRecordIdentities: Set<AgentExecutionIdentity>
    private var persistenceBaseline: Data?

    public init() {
        persistenceURL = nil
        recordsByIdentity = [:]
        legacyRecordIdentities = []
        persistenceBaseline = nil
    }

    public init(persistenceURL: URL) throws {
        let standardizedURL = persistenceURL.standardizedFileURL
        self.persistenceURL = standardizedURL
        self.recordsByIdentity = [:]
        self.legacyRecordIdentities = []
        self.persistenceBaseline = nil

        do {
            try FileManager.default.createDirectory(
                at: standardizedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw AgentTurnContextStoreError.persistenceFailed
        }

        try Self.withPersistenceLock(for: standardizedURL) {
            guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
                return
            }

            do {
                let data = try Data(contentsOf: standardizedURL)
                let state = try JSONDecoder().decode(State.self, from: data)
                guard state.schemaVersion == Self.schemaVersion else {
                    throw AgentTurnContextStoreError.corruptStore
                }

                var decoded: [AgentExecutionIdentity: AgentTurnContextRecord] = [:]
                var legacy: Set<AgentExecutionIdentity> = []
                var bindingsBySnapshotID: [String: Set<ConversationContextSnapshotV1>] = [:]
                var legacySnapshotIDs: Set<String> = []
                var rawRecords: [Any]?
                for (index, record) in state.records.enumerated() {
                    let isLegacy = record.snapshot.isRecognizedLegacyProductionSnapshot
                    if isLegacy {
                        if rawRecords == nil {
                            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                            rawRecords = root?["records"] as? [Any]
                        }
                        guard let rawRecords, rawRecords.count == state.records.count,
                              LegacyContextJSON.roundTripsWithoutFieldLoss(
                                record, originalJSON: rawRecords[index]
                              ) else {
                            throw AgentTurnContextStoreError.invalidSnapshotRecovery(.recordNonLossless)
                        }
                        try Self.validateRecognizedLegacy(record)
                        legacy.insert(record.identity)
                    } else {
                        do {
                            try Self.validate(record)
                        } catch AgentTurnContextStoreError.invalidSnapshot {
                            let snapshot = record.snapshot
                            let reason: AgentTurnContextSnapshotRecoveryReason
                            if snapshot.snapshotID == snapshot.historicalCanonicalSnapshotID() {
                                switch snapshot.historicalRetentionClassification {
                                case .sizeLimit: reason = .legacySizeLimit
                                case .bindingShape: reason = .legacyBindingShape
                                case .sessionBinding: reason = .legacySessionBinding
                                case .fingerprintShape: reason = .legacyFingerprintShape
                                case .recognized, .currentCanonical, .formulaMismatch:
                                    reason = .legacyFormulaUnsafeShape
                                }
                            } else if snapshot.snapshotID.hasPrefix("context:v2:") {
                                reason = .currentCanonicalMismatch
                            } else {
                                reason = .legacyFormulaMismatch
                            }
                            throw AgentTurnContextStoreError.invalidSnapshotRecovery(reason)
                        }
                    }
                    let snapshotID = record.snapshot.snapshotID
                    let priorBindings = bindingsBySnapshotID[snapshotID] ?? []
                    if (isLegacy || legacySnapshotIDs.contains(snapshotID))
                        && priorBindings.contains(where: { $0 != record.snapshot }) {
                        // An old delimiter-based ID must not alias two distinct
                        // decoded bindings within this durable authority.
                        throw AgentTurnContextStoreError.invalidSnapshotRecovery(
                            .legacySnapshotBindingCollision
                        )
                    }
                    bindingsBySnapshotID[snapshotID, default: []].insert(record.snapshot)
                    if isLegacy { legacySnapshotIDs.insert(snapshotID) }
                    guard decoded[record.identity] == nil else {
                        throw AgentTurnContextStoreError.corruptStore
                    }
                    decoded[record.identity] = record
                }
                if !legacy.isEmpty {
                    let originalJSON = try JSONSerialization.jsonObject(with: data)
                    guard LegacyContextJSON.roundTripsWithoutFieldLoss(
                        state, originalJSON: originalJSON
                    ) else {
                        throw AgentTurnContextStoreError.invalidSnapshotRecovery(.stateNonLossless)
                    }
                }
                self.recordsByIdentity = decoded
                self.legacyRecordIdentities = legacy
                self.persistenceBaseline = data
            } catch let error as AgentTurnContextStoreError {
                throw error
            } catch {
                throw AgentTurnContextStoreError.corruptStore
            }
        }
    }

    /// Admit a fresh identity exactly once. Repeating the same immutable
    /// identity is idempotently rejected; a changed snapshot is a conflict.
    @discardableResult
    public func begin(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) throws -> Bool {
        try Self.validate(identity: identity, snapshot: snapshot)
        guard generation >= 0 else { throw AgentTurnContextStoreError.staleGeneration }
        lock.lock()
        defer { lock.unlock() }

        if let existing = recordsByIdentity[identity] {
            guard existing.snapshot == snapshot else {
                throw AgentTurnContextStoreError.conflictingIdentity
            }
            return false
        }

        var candidate = recordsByIdentity
        candidate[identity] = AgentTurnContextRecord(
            identity: identity,
            snapshot: snapshot,
            status: .active,
            generation: generation,
            streamSequence: 0
        )
        try persist(candidate)
        recordsByIdentity = candidate
        return true
    }

    /// Atomically consume writeback admission. The record becomes
    /// `.writingBack` before the caller can write a result, so duplicate
    /// callbacks and callbacks arriving after restart fail closed while the
    /// transcript commit is still in flight.
    @discardableResult
    public func admitWriteback(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        currentSnapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) throws -> Bool {
        try Self.validate(identity: identity, snapshot: snapshot)
        guard generation >= 0 else { throw AgentTurnContextStoreError.staleGeneration }
        guard currentSnapshot.snapshotID == currentSnapshot.canonicalSnapshotID() else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }

        guard let existing = recordsByIdentity[identity],
              existing.status == .active,
              existing.generation == generation,
              existing.snapshot.matches(snapshot),
              snapshot.matches(currentSnapshot) else {
            return false
        }

        var candidate = recordsByIdentity
        candidate[identity] = AgentTurnContextRecord(
            identity: existing.identity,
            snapshot: existing.snapshot,
            status: .writingBack,
            generation: existing.generation,
            streamSequence: existing.streamSequence
        )
        try persist(candidate)
        recordsByIdentity = candidate
        return true
    }

    /// Persist one strictly newer stream delta for an active turn. Sequence
    /// admission is the durable boundary: equal/older callbacks return false,
    /// and terminal or stale-generation callbacks cannot mutate the record.
    @discardableResult
    public func acceptStreamSequence(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        sequence: Int,
        generation: Int = 0
    ) throws -> Bool {
        try Self.validate(identity: identity, snapshot: snapshot)
        guard generation >= 0 else { throw AgentTurnContextStoreError.staleGeneration }
        guard sequence > 0 else { throw AgentTurnContextStoreError.staleSequence }
        lock.lock()
        defer { lock.unlock() }

        guard let existing = recordsByIdentity[identity],
              existing.generation == generation,
              existing.snapshot.matches(snapshot),
              existing.status == .active || existing.status == .writingBack else {
            return false
        }
        guard sequence > existing.streamSequence else {
            return false
        }
        var candidate = recordsByIdentity
        candidate[identity] = AgentTurnContextRecord(
            identity: existing.identity,
            snapshot: existing.snapshot,
            status: existing.status,
            generation: existing.generation,
            streamSequence: sequence
        )
        try persist(candidate)
        recordsByIdentity = candidate
        return true
    }

    /// Retire an admitted identity without permitting future writeback.
    @discardableResult
    public func complete(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) throws -> Bool {
        try transition(
            identity: identity,
            snapshot: snapshot,
            status: .completed,
            allowedStatuses: [.writingBack],
            generation: generation
        )
    }

    /// Retire a Composer plan stream after its transcript writeback has been
    /// durably admitted. Plan mode may consult the Provider and read-only
    /// tools, while every side-effect capability is simulated by the policy
    /// executor; the terminal fact must therefore be distinct from success.
    @discardableResult
    public func completeDryRunAfterWriteback(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0,
        reason: String? = nil
    ) throws -> Bool {
        try transition(
            identity: identity,
            snapshot: snapshot,
            status: .dryRun,
            allowedStatuses: [.writingBack],
            generation: generation,
            reason: reason
        )
    }

    /// Persist a policy refusal before provider work starts. Refusals use the
    /// same identity ledger as running turns, so a restarted composition root
    /// can reconstruct the refusal and cannot accidentally begin the turn.
    @discardableResult
    public func refuseByPolicy(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0,
        reason: String
    ) throws -> Bool {
        try recordTerminal(
            identity: identity,
            snapshot: snapshot,
            status: .policyRefused,
            outcome: .policyRefused,
            generation: generation,
            reason: reason,
            allowActiveExisting: true
        )
    }

    /// Persist a dry-run result without creating a provider stream. This is a
    /// terminal durable fact rather than an in-memory preview flag.
    @discardableResult
    public func completeDryRun(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0,
        reason: String? = nil
    ) throws -> Bool {
        try recordTerminal(
            identity: identity,
            snapshot: snapshot,
            status: .dryRun,
            outcome: .dryRun,
            generation: generation,
            reason: reason
        )
    }

    /// Cancel an admitted identity without permitting future writeback.
    @discardableResult
    public func cancel(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) throws -> Bool {
        // Once writeback is admitted, that callback owns the durable slot
        // until its transcript/result commit settles. A late cancellation
        // must not replace the in-flight writeback with a competing terminal
        // outcome.
        try transition(
            identity: identity,
            snapshot: snapshot,
            status: .cancelled,
            allowedStatuses: [.active],
            generation: generation
        )
    }

    /// Mark a writeback whose transcript/result persistence failed. The
    /// terminal fact is retained across restart and cannot be retried
    /// implicitly.
    @discardableResult
    public func fail(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0,
        reason: String? = nil
    ) throws -> Bool {
        try transition(
            identity: identity,
            snapshot: snapshot,
            status: .failed,
            generation: generation,
            reason: reason
        )
    }

    /// Mark a writeback as requiring explicit user review after restart or an
    /// otherwise ambiguous persistence/external side effect.
    @discardableResult
    public func markNeedsUserReview(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) throws -> Bool {
        try transition(identity: identity, snapshot: snapshot, status: .needsUserReview, generation: generation)
    }

    /// Converts an interrupted active/writeback record into an explicit review
    /// state. This is the restart recovery boundary; no late callback is
    /// admitted until the caller explicitly reopens a newer generation.
    @discardableResult
    public func recoverInterrupted(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) throws -> Bool {
        try transition(
            identity: identity,
            snapshot: snapshot,
            status: .needsUserReview,
            allowedStatuses: [.active, .writingBack],
            generation: generation
        )
    }

    /// Explicitly reopens a reviewed record under a strictly newer generation.
    /// The prior generation remains invalid for all writeback callbacks.
    @discardableResult
    public func reopenAfterRecovery(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int
    ) throws -> Bool {
        try Self.validate(identity: identity, snapshot: snapshot)
        guard generation > 0 else { throw AgentTurnContextStoreError.staleGeneration }
        lock.lock()
        defer { lock.unlock() }
        guard let existing = recordsByIdentity[identity], existing.snapshot.matches(snapshot),
              existing.status == .needsUserReview, generation > existing.generation else {
            return false
        }
        var candidate = recordsByIdentity
        candidate[identity] = AgentTurnContextRecord(
            identity: existing.identity,
            snapshot: existing.snapshot,
            status: .active,
            generation: generation,
            streamSequence: 0
        )
        try persist(candidate)
        recordsByIdentity = candidate
        return true
    }

    public func record(for identity: AgentExecutionIdentity) -> AgentTurnContextRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard !legacyRecordIdentities.contains(identity) else { return nil }
        return recordsByIdentity[identity]
    }

    private func transition(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        status: AgentTurnContextStatus,
        allowedStatuses: Set<AgentTurnContextStatus> = [.active, .writingBack],
        generation: Int = 0,
        reason: String? = nil
    ) throws -> Bool {
        try Self.validate(identity: identity, snapshot: snapshot)
        guard generation >= 0 else { throw AgentTurnContextStoreError.staleGeneration }
        lock.lock()
        defer { lock.unlock() }

        guard let existing = recordsByIdentity[identity] else {
            return false
        }
        guard existing.snapshot.matches(snapshot) else {
            throw AgentTurnContextStoreError.conflictingIdentity
        }
        guard existing.generation == generation else {
            throw AgentTurnContextStoreError.staleGeneration
        }
        guard allowedStatuses.contains(existing.status) else {
            return false
        }

        var candidate = recordsByIdentity
        candidate[identity] = AgentTurnContextRecord(
            identity: existing.identity,
            snapshot: existing.snapshot,
            status: status,
            generation: existing.generation,
            streamSequence: existing.streamSequence,
            terminalTruth: Self.terminalTruth(
                status: status,
                identity: existing.identity,
                generation: existing.generation,
                reason: reason
            )
        )
        try persist(candidate)
        recordsByIdentity = candidate
        return true
    }

    private func recordTerminal(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        status: AgentTurnContextStatus,
        outcome: AgentTerminalTruthOutcome,
        generation: Int,
        reason: String?,
        allowActiveExisting: Bool = false
    ) throws -> Bool {
        try Self.validate(identity: identity, snapshot: snapshot)
        guard generation >= 0 else { throw AgentTurnContextStoreError.staleGeneration }
        lock.lock()
        defer { lock.unlock() }

        if let existing = recordsByIdentity[identity] {
            guard allowActiveExisting,
                  existing.status == .active,
                  existing.snapshot.matches(snapshot),
                  existing.generation == generation,
                  existing.streamSequence == 0 else {
                return false
            }
            let terminalTruth = AgentTerminalTruth(
                identity: existing.identity,
                generation: existing.generation,
                outcome: outcome,
                reason: reason
            )
            var candidate = recordsByIdentity
            candidate[identity] = AgentTurnContextRecord(
                identity: existing.identity,
                snapshot: existing.snapshot,
                status: status,
                generation: existing.generation,
                streamSequence: existing.streamSequence,
                terminalTruth: terminalTruth
            )
            try persist(candidate)
            recordsByIdentity = candidate
            return true
        }
        let terminalTruth = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: outcome,
            reason: reason
        )
        var candidate = recordsByIdentity
        candidate[identity] = AgentTurnContextRecord(
            identity: identity,
            snapshot: snapshot,
            status: status,
            generation: generation,
            streamSequence: 0,
            terminalTruth: terminalTruth
        )
        try persist(candidate)
        recordsByIdentity = candidate
        return true
    }

    private func persist(
        _ records: [AgentExecutionIdentity: AgentTurnContextRecord]
    ) throws {
        guard let persistenceURL else {
            return
        }
        do {
            let fileManager = FileManager.default
            let parent = persistenceURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try Self.withPersistenceLock(for: persistenceURL) {
                if fileManager.fileExists(atPath: persistenceURL.path) {
                    let current = try Data(contentsOf: persistenceURL)
                    guard persistenceBaseline == current else {
                        throw AgentTurnContextStoreError.persistenceFailed
                    }
                } else {
                    guard persistenceBaseline == nil else {
                        throw AgentTurnContextStoreError.persistenceFailed
                    }
                }

                let data = try JSONEncoder().encode(State(
                    schemaVersion: Self.schemaVersion,
                    records: records.values.sorted {
                        Self.sortKey($0.identity) < Self.sortKey($1.identity)
                    }
                ))
                try data.write(to: persistenceURL, options: [.atomic])
                persistenceBaseline = data
            }
        } catch let error as AgentTurnContextStoreError {
            throw error
        } catch {
            throw AgentTurnContextStoreError.persistenceFailed
        }
    }

    private static func withPersistenceLock<Result>(
        for persistenceURL: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        let processLock = persistenceLockRegistry.lock(
            for: persistenceURL.standardizedFileURL.path
        )
        processLock.lock()
        defer { processLock.unlock() }

        let lockURL = persistenceURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AgentTurnContextStoreError.persistenceFailed
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AgentTurnContextStoreError.persistenceFailed
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validate(_ record: AgentTurnContextRecord) throws {
        try validate(identity: record.identity, snapshot: record.snapshot)
        try validateRecordMetadata(record)
    }

    private static func validateRecognizedLegacy(_ record: AgentTurnContextRecord) throws {
        guard record.identity.isValid,
              record.identity.turn.sessionID == record.snapshot.sessionID else {
            throw AgentTurnContextStoreError.invalidIdentity
        }
        guard record.snapshot.isRecognizedLegacyProductionSnapshot else {
            throw AgentTurnContextStoreError.invalidSnapshot
        }
        try validateRecordMetadata(record)
    }

    private static func validateRecordMetadata(_ record: AgentTurnContextRecord) throws {
        guard record.generation >= 0 else {
            throw AgentTurnContextStoreError.corruptStore
        }
        guard record.streamSequence >= 0 else {
            throw AgentTurnContextStoreError.corruptStore
        }
        if let terminalTruth = record.terminalTruth {
            guard terminalTruth.matches(
                identity: record.identity,
                generation: record.generation
            ), terminalTruth.outcome == terminalOutcome(for: record.status) else {
                throw AgentTurnContextStoreError.corruptStore
            }
        }
    }

    private static func validate(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1
    ) throws {
        guard identity.isValid else {
            throw AgentTurnContextStoreError.invalidIdentity
        }
        guard identity.turn.sessionID == snapshot.sessionID else {
            throw AgentTurnContextStoreError.invalidIdentity
        }
        guard snapshot.snapshotID == snapshot.canonicalSnapshotID() else {
            throw AgentTurnContextStoreError.invalidSnapshot
        }
    }

    private static func sortKey(_ identity: AgentExecutionIdentity) -> String {
        [
            identity.turn.sessionID,
            String(identity.turn.turnID),
            identity.turn.messageID,
            identity.operationID,
            String(identity.attempt)
        ].joined(separator: "\u{0}")
    }

    private static func terminalOutcome(
        for status: AgentTurnContextStatus
    ) -> AgentTerminalTruthOutcome? {
        switch status {
        case .completed:
            return .succeeded
        case .failed:
            return .executionFailed
        case .cancelled:
            return .cancelled
        case .policyRefused:
            return .policyRefused
        case .dryRun:
            return .dryRun
        case .active, .writingBack, .needsUserReview:
            return nil
        }
    }

    private static func terminalTruth(
        status: AgentTurnContextStatus,
        identity: AgentExecutionIdentity,
        generation: Int,
        reason: String?
    ) -> AgentTerminalTruth? {
        guard let outcome = terminalOutcome(for: status) else {
            return nil
        }
        return AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: outcome,
            reason: reason
        )
    }
}
