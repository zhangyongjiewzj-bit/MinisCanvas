import CryptoKit
import Foundation

public enum AgentDurableEffectJournalError: Error, Equatable, Sendable {
    case invalidIdentity
    case identityMismatch
    case invalidAttemptLineage
    case duplicateAttempt
    case unknownAttempt
    case unknownEffect
    case staleAttempt
    case idempotencyConflict
    case leaseMismatch
    case leaseExpired
    case invalidTransition
    case submittedEffectRequiresReview
    case corruptLedger
    case persistenceFailed
}

public enum AgentDurableEffectStatus: String, Codable, Equatable, Hashable, Sendable {
    case leased
    case submitted
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .leased, .submitted:
            return false
        }
    }
}

public enum AgentDurableEffectOutcomeStatus: String, Codable, Equatable, Hashable, Sendable {
    case succeeded
    case failed
}

public enum AgentDurableEffectReplayDecision: String, Codable, Equatable, Hashable, Sendable {
    case execute
    case submittedNeedsReview
    case terminal
}

public enum AgentDurableEffectJournalEventKind: String, Codable, Equatable, Hashable, Sendable {
    case attemptStarted
    case effectLeased
    case effectSubmitted
    case effectCompleted
    case effectCancelled
}

/// Frozen replay classification for the durable event vocabulary.
///
/// Schema version 1 carries only required entries. Version 2 also preserves
/// unknown event kinds explicitly marked ignorable, including their opaque
/// string metadata, in the authenticated chain. Missing classification is
/// required; known replay events cannot be relabeled ignorable.
public enum AgentDurableEventReplayRequirement: String, Codable, Equatable, Hashable, Sendable {
    case required
    case ignorable
}

extension AgentDurableEffectJournalEventKind {
    /// The frozen closed replay vocabulary. Version 2 may persist unknown
    /// ignorable metadata without widening this executable set.
    public static var frozenVocabulary: [AgentDurableEffectJournalEventKind] {
        [
            .attemptStarted,
            .effectLeased,
            .effectSubmitted,
            .effectCompleted,
            .effectCancelled,
        ]
    }

    /// Every vocabulary member is required for deterministic replay; nothing
    /// may be skipped when folding the journal.
    public var replayRequirement: AgentDurableEventReplayRequirement {
        .required
    }
}

/// The immutable identity of one externally visible effect.
public struct AgentDurableEffectIdentity: Codable, Equatable, Hashable, Sendable {
    public let taskID: String
    public let runID: String
    public let attemptID: String
    public let effectID: String

    public init(taskID: String, runID: String, attemptID: String, effectID: String) {
        self.taskID = taskID
        self.runID = runID
        self.attemptID = attemptID
        self.effectID = effectID
    }
}

/// A lease is copied into every durable record. A released lease can never be
/// reused for a later effect transition.
public struct AgentDurableEffectLease: Codable, Equatable, Hashable, Sendable {
    public let leaseID: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let releasedAt: Date?

    public init(leaseID: String, issuedAt: Date, expiresAt: Date) {
        self.init(
            leaseID: leaseID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            releasedAt: nil
        )
    }

    public var isReleased: Bool {
        releasedAt != nil
    }

    fileprivate init(
        leaseID: String,
        issuedAt: Date,
        expiresAt: Date,
        releasedAt: Date?
    ) {
        self.leaseID = leaseID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }

    fileprivate func released(at date: Date) -> AgentDurableEffectLease {
        AgentDurableEffectLease(
            leaseID: leaseID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            releasedAt: date
        )
    }
}

public struct AgentDurableEffectRequest: Codable, Equatable, Hashable, Sendable {
    public let identity: AgentDurableEffectIdentity
    public let lease: AgentDurableEffectLease
    public let idempotencyKey: String
    public let inputDigest: String

    public init(
        identity: AgentDurableEffectIdentity,
        lease: AgentDurableEffectLease,
        idempotencyKey: String,
        inputDigest: String
    ) {
        self.identity = identity
        self.lease = lease
        self.idempotencyKey = idempotencyKey
        self.inputDigest = inputDigest
    }
}

/// Attempt identity is immutable. A retry creates a new value whose
/// `supersedesAttemptID` points to the prior attempt.
public struct AgentDurableEffectAttempt: Codable, Equatable, Hashable, Sendable {
    public let taskID: String
    public let runID: String
    public let attemptID: String
    public let attemptNumber: Int
    public let supersedesAttemptID: String?

    public init(
        taskID: String,
        runID: String,
        attemptID: String,
        attemptNumber: Int,
        supersedesAttemptID: String?
    ) {
        self.taskID = taskID
        self.runID = runID
        self.attemptID = attemptID
        self.attemptNumber = attemptNumber
        self.supersedesAttemptID = supersedesAttemptID
    }
}

public struct AgentDurableEffectRecord: Codable, Equatable, Hashable, Sendable {
    public let identity: AgentDurableEffectIdentity
    public let lease: AgentDurableEffectLease
    public let idempotencyKey: String
    public let inputDigest: String
    public let status: AgentDurableEffectStatus
    public let redactedOutcome: String?
    public let sequence: Int
    public let checksum: String

    public init(
        identity: AgentDurableEffectIdentity,
        lease: AgentDurableEffectLease,
        idempotencyKey: String,
        inputDigest: String,
        status: AgentDurableEffectStatus,
        redactedOutcome: String?,
        sequence: Int,
        checksum: String
    ) {
        self.identity = identity
        self.lease = lease
        self.idempotencyKey = idempotencyKey
        self.inputDigest = inputDigest
        self.status = status
        self.redactedOutcome = redactedOutcome
        self.sequence = sequence
        self.checksum = checksum
    }
}

public struct AgentDurableEffectJournalEntry: Codable, Equatable, Hashable, Sendable {
    public let sequence: Int
    public let kind: AgentDurableEffectJournalEventKind
    public let identity: AgentDurableEffectIdentity?
    public let attemptID: String?
    public let previousChecksum: String?
    public let checksum: String

    fileprivate init(
        sequence: Int,
        kind: AgentDurableEffectJournalEventKind,
        identity: AgentDurableEffectIdentity?,
        attemptID: String?,
        previousChecksum: String?,
        checksum: String
    ) {
        self.sequence = sequence
        self.kind = kind
        self.identity = identity
        self.attemptID = attemptID
        self.previousChecksum = previousChecksum
        self.checksum = checksum
    }
}

/// A Core-only append-only effect journal.
///
/// The journal intentionally has no executor callback. It records durable
/// intent and outcome facts; callers must make submitted replay an explicit
/// user-reviewed decision instead of accidentally re-running an external
/// effect after restart.
public final class AgentDurableEffectJournal: @unchecked Sendable {
    private static let schemaVersion = 2

    private let persistenceURL: URL
    private let lock = NSLock()
    private var state: State

    /// Number of trailing journal entries discarded by bounded torn-tail
    /// recovery during the most recent load. Zero when the ledger loaded
    /// without recovery; never exceeds one, which is the recovery bound.
    public private(set) var recoveredTornTailEntryCount = 0

    private struct State: Codable {
        var schemaVersion: Int
        var attemptsByID: [String: AgentDurableEffectAttempt]
        var currentAttemptIDByRun: [String: String]
        var effectsByID: [String: AgentDurableEffectRecord]
        var effectIDByIdempotencyKey: [String: String]
        var entries: [PersistedEntry]
        var snapshotChecksum: String?

        static let empty = State(
            schemaVersion: AgentDurableEffectJournal.schemaVersion,
            attemptsByID: [:],
            currentAttemptIDByRun: [:],
            effectsByID: [:],
            effectIDByIdempotencyKey: [:],
            entries: [],
            snapshotChecksum: nil
        )
    }

    private struct StateMaterial: Codable {
        let schemaVersion: Int
        let attemptsByID: [String: AgentDurableEffectAttempt]
        let currentAttemptIDByRun: [String: String]
        let effectsByID: [String: AgentDurableEffectRecord]
        let effectIDByIdempotencyKey: [String: String]
        let entries: [PersistedEntry]

        init(state: State) {
            schemaVersion = state.schemaVersion
            attemptsByID = state.attemptsByID
            currentAttemptIDByRun = state.currentAttemptIDByRun
            effectsByID = state.effectsByID
            effectIDByIdempotencyKey = state.effectIDByIdempotencyKey
            entries = state.entries
        }
    }

    private struct EventPayload: Codable, Equatable {
        // Keep the wire kind intact for checksum verification and future rewrites.
        // The public replay vocabulary remains closed.
        let kind: String
        let replayRequirement: AgentDurableEventReplayRequirement?
        let opaquePayload: [String: String]?
        var knownKind: AgentDurableEffectJournalEventKind? {
            AgentDurableEffectJournalEventKind(rawValue: kind)
        }
        let taskID: String
        let runID: String
        let attemptID: String
        let effectID: String?
        let attemptNumber: Int?
        let supersedesAttemptID: String?
        let leaseID: String?
        let idempotencyKey: String?
        let inputDigest: String?
        let status: AgentDurableEffectStatus?
        let redactedOutcome: String?
        let timestamp: Date
    }

    private struct PersistedEntry: Codable, Equatable {
        let sequence: Int
        let event: EventPayload
        let previousChecksum: String?
        let checksum: String
    }

    private struct ChecksumMaterial: Codable {
        let sequence: Int
        let event: EventPayload
        let previousChecksum: String?
    }

    public init(persistenceURL: URL) throws {
        self.persistenceURL = persistenceURL.standardizedFileURL

        guard FileManager.default.fileExists(atPath: self.persistenceURL.path) else {
            self.state = .empty
            return
        }

        do {
            let data = try Data(contentsOf: self.persistenceURL)
            guard let decoded = try? Self.makeDecoder().decode(State.self, from: data) else {
                // Byte-level damage (including a physically truncated JSON
                // blob) leaves no verifiable entry boundary, so it fails
                // closed instead of guessing a recovery point.
                throw AgentDurableEffectJournalError.corruptLedger
            }
            // Classification failures are never eligible for torn-tail recovery.
            try Self.validateReplayRequirements(decoded)
            if (try? Self.validate(decoded)) != nil {
                self.state = decoded
                return
            }
            guard let recovered = Self.recoveringTornTail(from: decoded) else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
            let repairedData = try Self.makeEncoder().encode(recovered)
            try repairedData.write(to: persistenceURL, options: [.atomic])
            self.state = recovered
            self.recoveredTornTailEntryCount = 1
        } catch let error as AgentDurableEffectJournalError {
            switch error {
            case .corruptLedger:
                throw error
            default:
                throw AgentDurableEffectJournalError.corruptLedger
            }
        } catch {
            throw AgentDurableEffectJournalError.corruptLedger
        }
    }

    @discardableResult
    public func beginAttempt(
        taskID: String,
        runID: String,
        attemptID: String,
        supersedesAttemptID: String? = nil,
        now: Date = Date()
    ) throws -> AgentDurableEffectAttempt {
        try validateIdentityParts(taskID, runID, attemptID)
        if let supersedesAttemptID {
            try validateIdentityParts(taskID, runID, supersedesAttemptID)
        }

        return try commit { candidate in
            if let existing = candidate.attemptsByID[attemptID] {
                guard existing.taskID == taskID,
                      existing.runID == runID,
                      existing.supersedesAttemptID == supersedesAttemptID else {
                    throw AgentDurableEffectJournalError.identityMismatch
                }
                return existing
            }

            let runKey = Self.runKey(taskID: taskID, runID: runID)
            let current = candidate.currentAttemptIDByRun[runKey].flatMap {
                candidate.attemptsByID[$0]
            }

            let attemptNumber: Int
            if let current {
                guard supersedesAttemptID == current.attemptID else {
                    throw AgentDurableEffectJournalError.invalidAttemptLineage
                }
                try Self.closeLeasedEffects(
                    for: current,
                    in: &candidate,
                    now: now,
                    redactedOutcome: "superseded by retry"
                )
                attemptNumber = current.attemptNumber + 1
            } else {
                guard supersedesAttemptID == nil else {
                    throw AgentDurableEffectJournalError.invalidAttemptLineage
                }
                attemptNumber = 1
            }

            let attempt = AgentDurableEffectAttempt(
                taskID: taskID,
                runID: runID,
                attemptID: attemptID,
                attemptNumber: attemptNumber,
                supersedesAttemptID: supersedesAttemptID
            )
            _ = try Self.append(
                Self.event(
                    kind: .attemptStarted,
                    taskID: taskID,
                    runID: runID,
                    attemptID: attemptID,
                    attemptNumber: attemptNumber,
                    supersedesAttemptID: supersedesAttemptID,
                    timestamp: now
                ),
                to: &candidate
            )
            candidate.attemptsByID[attemptID] = attempt
            candidate.currentAttemptIDByRun[runKey] = attemptID
            return attempt
        }
    }

    @discardableResult
    public func retryAttempt(
        taskID: String,
        runID: String,
        previousAttemptID: String,
        nextAttemptID: String,
        now: Date = Date()
    ) throws -> AgentDurableEffectAttempt {
        try beginAttempt(
            taskID: taskID,
            runID: runID,
            attemptID: nextAttemptID,
            supersedesAttemptID: previousAttemptID,
            now: now
        )
    }

    @discardableResult
    public func reserveEffect(
        _ request: AgentDurableEffectRequest,
        now: Date = Date()
    ) throws -> AgentDurableEffectRecord {
        try Self.validate(request)

        return try commit { candidate in
            if let existingEffectID = candidate.effectIDByIdempotencyKey[request.idempotencyKey] {
                guard let existing = candidate.effectsByID[existingEffectID] else {
                    throw AgentDurableEffectJournalError.corruptLedger
                }
                guard existing.identity == request.identity,
                      existing.lease.leaseID == request.lease.leaseID,
                      existing.inputDigest == request.inputDigest,
                      existing.lease.issuedAt == request.lease.issuedAt,
                      existing.lease.expiresAt == request.lease.expiresAt else {
                    throw AgentDurableEffectJournalError.idempotencyConflict
                }
                return existing
            }

            if let existing = candidate.effectsByID[request.identity.effectID] {
                guard existing.identity == request.identity else {
                    throw AgentDurableEffectJournalError.identityMismatch
                }
                throw AgentDurableEffectJournalError.idempotencyConflict
            }

            try Self.requireCurrentAttempt(request.identity, in: candidate)
            guard now < request.lease.expiresAt else {
                throw AgentDurableEffectJournalError.leaseExpired
            }

            let entry = try Self.append(
                Self.event(
                    kind: .effectLeased,
                    request: request,
                    status: .leased,
                    timestamp: now
                ),
                to: &candidate
            )
            let record = AgentDurableEffectRecord(
                identity: request.identity,
                lease: request.lease,
                idempotencyKey: request.idempotencyKey,
                inputDigest: request.inputDigest,
                status: .leased,
                redactedOutcome: nil,
                sequence: entry.sequence,
                checksum: entry.checksum
            )
            candidate.effectsByID[request.identity.effectID] = record
            candidate.effectIDByIdempotencyKey[request.idempotencyKey] = request.identity.effectID
            return record
        }
    }

    @discardableResult
    public func submitEffect(
        _ identity: AgentDurableEffectIdentity,
        leaseID: String,
        now: Date = Date()
    ) throws -> AgentDurableEffectRecord {
        try validate(identity)
        try validateIdentityParts(leaseID)

        return try commit { candidate in
            try Self.requireCurrentAttempt(identity, in: candidate)
            let current = try Self.effect(identity, in: candidate)
            guard current.lease.leaseID == leaseID else {
                throw AgentDurableEffectJournalError.leaseMismatch
            }
            switch current.status {
            case .submitted:
                return current
            case .leased:
                guard !current.lease.isReleased else {
                    throw AgentDurableEffectJournalError.invalidTransition
                }
                guard now < current.lease.expiresAt else {
                    throw AgentDurableEffectJournalError.leaseExpired
                }
            case .succeeded, .failed, .cancelled:
                throw AgentDurableEffectJournalError.invalidTransition
            }

            let entry = try Self.append(
                Self.event(
                    kind: .effectSubmitted,
                    record: current,
                    status: .submitted,
                    timestamp: now
                ),
                to: &candidate
            )
            let record = current.updated(
                lease: current.lease,
                status: .submitted,
                redactedOutcome: nil,
                entry: entry
            )
            candidate.effectsByID[identity.effectID] = record
            return record
        }
    }

    @discardableResult
    public func completeEffect(
        _ identity: AgentDurableEffectIdentity,
        leaseID: String,
        status: AgentDurableEffectOutcomeStatus,
        redactedOutcome: String,
        now: Date = Date()
    ) throws -> AgentDurableEffectRecord {
        try validate(identity)
        try validateIdentityParts(leaseID)
        try validateIdentityParts(redactedOutcome)

        return try commit { candidate in
            try Self.requireCurrentAttempt(identity, in: candidate)
            let current = try Self.effect(identity, in: candidate)
            guard current.lease.leaseID == leaseID else {
                throw AgentDurableEffectJournalError.leaseMismatch
            }
            guard current.status == .submitted else {
                throw AgentDurableEffectJournalError.invalidTransition
            }

            let terminalStatus: AgentDurableEffectStatus = status == .succeeded
                ? .succeeded
                : .failed
            let releasedLease = current.lease.released(at: now)
            let entry = try Self.append(
                Self.event(
                    kind: .effectCompleted,
                    record: current,
                    status: terminalStatus,
                    redactedOutcome: redactedOutcome,
                    timestamp: now
                ),
                to: &candidate
            )
            let record = current.updated(
                lease: releasedLease,
                status: terminalStatus,
                redactedOutcome: redactedOutcome,
                entry: entry
            )
            candidate.effectsByID[identity.effectID] = record
            return record
        }
    }

    @discardableResult
    public func cancelEffect(
        _ identity: AgentDurableEffectIdentity,
        leaseID: String,
        redactedOutcome: String,
        now: Date = Date()
    ) throws -> AgentDurableEffectRecord {
        try validate(identity)
        try validateIdentityParts(leaseID)
        try validateIdentityParts(redactedOutcome)

        return try commit { candidate in
            try Self.requireCurrentAttempt(identity, in: candidate)
            let current = try Self.effect(identity, in: candidate)
            guard current.lease.leaseID == leaseID else {
                throw AgentDurableEffectJournalError.leaseMismatch
            }
            guard current.status == .leased else {
                if current.status == .submitted {
                    throw AgentDurableEffectJournalError.submittedEffectRequiresReview
                }
                throw AgentDurableEffectJournalError.invalidTransition
            }

            let releasedLease = current.lease.released(at: now)
            let entry = try Self.append(
                Self.event(
                    kind: .effectCancelled,
                    record: current,
                    status: .cancelled,
                    redactedOutcome: redactedOutcome,
                    timestamp: now
                ),
                to: &candidate
            )
            let record = current.updated(
                lease: releasedLease,
                status: .cancelled,
                redactedOutcome: redactedOutcome,
                entry: entry
            )
            candidate.effectsByID[identity.effectID] = record
            return record
        }
    }

    public func record(for identity: AgentDurableEffectIdentity) -> AgentDurableEffectRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = state.effectsByID[identity.effectID], record.identity == identity else {
            return nil
        }
        return record
    }

    public func attempt(attemptID: String) -> AgentDurableEffectAttempt? {
        lock.lock()
        defer { lock.unlock() }
        return state.attemptsByID[attemptID]
    }

    public func journalEntries() -> [AgentDurableEffectJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        // Ignorable entries remain in persistence and in the checksum chain, but
        // do not become executable events in the closed replay vocabulary.
        return state.entries.compactMap { entry in
            guard let kind = entry.event.knownKind else { return nil }
            return Self.publicEntry(entry, kind: kind)
        }
    }

    public func replayDecision(
        for identity: AgentDurableEffectIdentity
    ) throws -> AgentDurableEffectReplayDecision {
        try validate(identity)
        lock.lock()
        defer { lock.unlock() }
        let record = try Self.effect(identity, in: state)
        switch record.status {
        case .leased:
            return .execute
        case .submitted:
            return .submittedNeedsReview
        case .succeeded, .failed, .cancelled:
            return .terminal
        }
    }

    private func commit<Result>(
        _ mutation: (inout State) throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }

        var candidate = state
        let result = try mutation(&candidate)
        candidate.snapshotChecksum = try Self.snapshotChecksum(candidate)
        try Self.validate(candidate)
        do {
            let data = try Self.makeEncoder().encode(candidate)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            throw AgentDurableEffectJournalError.persistenceFailed
        }
        state = candidate
        return result
    }

    private static func append(
        _ event: EventPayload,
        to state: inout State
    ) throws -> AgentDurableEffectJournalEntry {
        guard let kind = event.knownKind else {
            throw AgentDurableEffectJournalError.corruptLedger
        }
        let sequence = state.entries.count + 1
        let previousChecksum = state.entries.last?.checksum
        let checksum = try Self.checksum(
            sequence: sequence,
            event: event,
            previousChecksum: previousChecksum
        )
        let persisted = PersistedEntry(
            sequence: sequence,
            event: event,
            previousChecksum: previousChecksum,
            checksum: checksum
        )
        state.entries.append(persisted)
        return Self.publicEntry(persisted, kind: kind)
    }

    private static func closeLeasedEffects(
        for attempt: AgentDurableEffectAttempt,
        in state: inout State,
        now: Date,
        redactedOutcome: String
    ) throws {
        let effects = state.effectsByID.values
            .filter { $0.identity.attemptID == attempt.attemptID }
            .sorted { $0.sequence < $1.sequence }
        guard !effects.contains(where: { $0.status == .submitted }) else {
            throw AgentDurableEffectJournalError.submittedEffectRequiresReview
        }

        for current in effects where current.status == .leased {
            let releasedLease = current.lease.released(at: now)
            let entry = try Self.append(
                Self.event(
                    kind: .effectCancelled,
                    record: current,
                    status: .cancelled,
                    redactedOutcome: redactedOutcome,
                    timestamp: now
                ),
                to: &state
            )
            state.effectsByID[current.identity.effectID] = current.updated(
                lease: releasedLease,
                status: .cancelled,
                redactedOutcome: redactedOutcome,
                entry: entry
            )
        }
    }

    private static func effect(
        _ identity: AgentDurableEffectIdentity,
        in state: State
    ) throws -> AgentDurableEffectRecord {
        guard let record = state.effectsByID[identity.effectID] else {
            throw AgentDurableEffectJournalError.unknownEffect
        }
        guard record.identity == identity else {
            throw AgentDurableEffectJournalError.identityMismatch
        }
        return record
    }

    private static func requireCurrentAttempt(
        _ identity: AgentDurableEffectIdentity,
        in state: State
    ) throws {
        guard let attempt = state.attemptsByID[identity.attemptID] else {
            throw AgentDurableEffectJournalError.unknownAttempt
        }
        guard attempt.taskID == identity.taskID, attempt.runID == identity.runID else {
            throw AgentDurableEffectJournalError.identityMismatch
        }
        let key = runKey(taskID: identity.taskID, runID: identity.runID)
        guard state.currentAttemptIDByRun[key] == identity.attemptID else {
            throw AgentDurableEffectJournalError.staleAttempt
        }
    }

    private static func validate(_ request: AgentDurableEffectRequest) throws {
        try validate(request.identity)
        try validateIdentityParts(request.lease.leaseID)
        try validateIdentityParts(request.idempotencyKey)
        try validateIdentityParts(request.inputDigest)
        guard request.lease.expiresAt > request.lease.issuedAt,
              request.lease.issuedAt.timeIntervalSinceReferenceDate.isFinite,
              request.lease.expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AgentDurableEffectJournalError.invalidIdentity
        }
    }

    private static func validate(_ identity: AgentDurableEffectIdentity) throws {
        try validateIdentityParts(
            identity.taskID,
            identity.runID,
            identity.attemptID,
            identity.effectID
        )
    }

    private static func validateIdentityParts(_ values: String...) throws {
        guard values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw AgentDurableEffectJournalError.invalidIdentity
        }
    }

    private static func runKey(taskID: String, runID: String) -> String {
        "\(taskID)\u{0}\(runID)"
    }

    private static func event(
        kind: AgentDurableEffectJournalEventKind,
        taskID: String,
        runID: String,
        attemptID: String,
        effectID: String? = nil,
        attemptNumber: Int? = nil,
        supersedesAttemptID: String? = nil,
        leaseID: String? = nil,
        idempotencyKey: String? = nil,
        inputDigest: String? = nil,
        status: AgentDurableEffectStatus? = nil,
        redactedOutcome: String? = nil,
        timestamp: Date
    ) -> EventPayload {
        EventPayload(
            kind: kind.rawValue,
            replayRequirement: nil,
            opaquePayload: nil,
            taskID: taskID,
            runID: runID,
            attemptID: attemptID,
            effectID: effectID,
            attemptNumber: attemptNumber,
            supersedesAttemptID: supersedesAttemptID,
            leaseID: leaseID,
            idempotencyKey: idempotencyKey,
            inputDigest: inputDigest,
            status: status,
            redactedOutcome: redactedOutcome,
            timestamp: timestamp
        )
    }

    private static func event(
        kind: AgentDurableEffectJournalEventKind,
        request: AgentDurableEffectRequest,
        status: AgentDurableEffectStatus,
        redactedOutcome: String? = nil,
        timestamp: Date
    ) -> EventPayload {
        event(
            kind: kind,
            taskID: request.identity.taskID,
            runID: request.identity.runID,
            attemptID: request.identity.attemptID,
            effectID: request.identity.effectID,
            leaseID: request.lease.leaseID,
            idempotencyKey: request.idempotencyKey,
            inputDigest: request.inputDigest,
            status: status,
            redactedOutcome: redactedOutcome,
            timestamp: timestamp
        )
    }

    private static func event(
        kind: AgentDurableEffectJournalEventKind,
        record: AgentDurableEffectRecord,
        status: AgentDurableEffectStatus,
        redactedOutcome: String? = nil,
        timestamp: Date
    ) -> EventPayload {
        event(
            kind: kind,
            taskID: record.identity.taskID,
            runID: record.identity.runID,
            attemptID: record.identity.attemptID,
            effectID: record.identity.effectID,
            leaseID: record.lease.leaseID,
            idempotencyKey: record.idempotencyKey,
            inputDigest: record.inputDigest,
            status: status,
            redactedOutcome: redactedOutcome,
            timestamp: timestamp
        )
    }

    private static func checksum(
        sequence: Int,
        event: EventPayload,
        previousChecksum: String?
    ) throws -> String {
        let material = ChecksumMaterial(
            sequence: sequence,
            event: event,
            previousChecksum: previousChecksum
        )
        let data = try makeEncoder().encode(material)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func snapshotChecksum(_ state: State) throws -> String {
        let data = try makeEncoder().encode(StateMaterial(state: state))
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func publicEntry(
        _ entry: PersistedEntry, kind: AgentDurableEffectJournalEventKind
    ) -> AgentDurableEffectJournalEntry {
        let identity: AgentDurableEffectIdentity?
        if let effectID = entry.event.effectID {
            identity = AgentDurableEffectIdentity(
                taskID: entry.event.taskID,
                runID: entry.event.runID,
                attemptID: entry.event.attemptID,
                effectID: effectID
            )
        } else {
            identity = nil
        }
        return AgentDurableEffectJournalEntry(
            sequence: entry.sequence,
            kind: kind,
            identity: identity,
            attemptID: entry.event.attemptID,
            previousChecksum: entry.previousChecksum,
            checksum: entry.checksum
        )
    }

    /// Bounded torn-tail recovery for an already-decoded ledger.
    ///
    /// Recovery tolerates damage confined to the final journal entry only:
    /// every entry before the last must verify the append-only chain
    /// (contiguous sequence, previous-checksum link, recomputed checksum)
    /// and the final entry must be the single violator. The torn entry is
    /// dropped, attempt projections are refolded from the surviving
    /// `attemptStarted` events. An effect whose latest mutation was torn is
    /// restored to its last verified event, so a surviving submitted fact
    /// cannot become a fresh executable effect. The rebuilt state must
    /// still pass the full validation invariant. This replay is a pure
    /// projection fold: it never invokes an executor and never re-runs an
    /// external effect. Any damage beyond this bound fails closed.
    private static func recoveringTornTail(from decoded: State) -> State? {
        // A ledger whose only entry is damaged has no surviving verifiable
        // prefix; starting it over would silently discard durable facts.
        guard decoded.entries.count >= 2 else { return nil }

        for (index, entry) in decoded.entries.enumerated() {
            let expectedSequence = index + 1
            let expectedPreviousChecksum = index == 0 ? nil : decoded.entries[index - 1].checksum
            let passesChain =
                entry.sequence == expectedSequence
                && entry.previousChecksum == expectedPreviousChecksum
                && entry.checksum == (try? checksum(
                    sequence: entry.sequence,
                    event: entry.event,
                    previousChecksum: entry.previousChecksum
                ))
            if index == decoded.entries.count - 1 {
                // The final entry must be the violator; otherwise the failure
                // is not a torn tail (for example a mid-ledger break or a
                // projection-only mismatch) and must fail closed.
                guard !passesChain else { return nil }
            } else if !passesChain {
                return nil
            }
        }

        // The stored snapshot checksum authenticates the projection fields,
        // including lease dates and identity, only if restoring the final
        // entry's chain metadata reproduces the original snapshot. Without
        // this proof, using decoded.effectsByID to rebuild a record would
        // promote arbitrary damaged projection data into trusted state.
        let tailIndex = decoded.entries.count - 1
        let tail = decoded.entries[tailIndex]
        let previousChecksum = decoded.entries[tailIndex - 1].checksum
        guard let verifiedChecksum = try? checksum(
            sequence: tailIndex + 1,
            event: tail.event,
            previousChecksum: previousChecksum
        ) else { return nil }
        var verifiedOriginal = decoded
        verifiedOriginal.entries[tailIndex] = PersistedEntry(
            sequence: tailIndex + 1,
            event: tail.event,
            previousChecksum: previousChecksum,
            checksum: verifiedChecksum
        )
        guard decoded.snapshotChecksum == (try? snapshotChecksum(verifiedOriginal)) else {
            return nil
        }

        var candidate = decoded
        candidate.entries.removeLast()

        var attemptsByID: [String: AgentDurableEffectAttempt] = [:]
        var currentAttemptIDByRun: [String: String] = [:]
        for entry in candidate.entries {
            guard entry.event.knownKind == .attemptStarted else { continue }
            guard let attemptNumber = entry.event.attemptNumber, attemptNumber > 0 else {
                return nil
            }
            let attempt = AgentDurableEffectAttempt(
                taskID: entry.event.taskID,
                runID: entry.event.runID,
                attemptID: entry.event.attemptID,
                attemptNumber: attemptNumber,
                supersedesAttemptID: entry.event.supersedesAttemptID
            )
            attemptsByID[attempt.attemptID] = attempt
            currentAttemptIDByRun[runKey(taskID: attempt.taskID, runID: attempt.runID)] = attempt.attemptID
        }
        candidate.attemptsByID = attemptsByID
        candidate.currentAttemptIDByRun = currentAttemptIDByRun

        var recoveredEffects: [String: AgentDurableEffectRecord] = [:]
        for (effectID, record) in candidate.effectsByID {
            if record.sequence > 0,
               record.sequence <= candidate.entries.count,
               candidate.entries[record.sequence - 1].checksum == record.checksum {
                recoveredEffects[effectID] = record
                continue
            }
            // Only the final entry was discarded. A record pointing at any
            // other entry is inconsistent with that bounded failure model.
            guard record.sequence == decoded.entries.count,
                  decoded.entries.last?.event.effectID == effectID else { return nil }
            guard let previous = candidate.entries.last(where: { $0.event.effectID == effectID }) else {
                // A torn lease has never reached an external executor.
                continue
            }
            let event = previous.event
            guard event.taskID == record.identity.taskID,
                  event.runID == record.identity.runID,
                  event.attemptID == record.identity.attemptID,
                  event.leaseID == record.lease.leaseID,
                  event.idempotencyKey == record.idempotencyKey,
                  event.inputDigest == record.inputDigest,
                  event.knownKind == .effectSubmitted,
                  event.status == .submitted else { return nil }
            let lease = AgentDurableEffectLease(
                leaseID: record.lease.leaseID,
                issuedAt: record.lease.issuedAt,
                expiresAt: record.lease.expiresAt
            )
            recoveredEffects[effectID] = AgentDurableEffectRecord(
                identity: record.identity,
                lease: lease,
                idempotencyKey: record.idempotencyKey,
                inputDigest: record.inputDigest,
                status: .submitted,
                redactedOutcome: event.redactedOutcome,
                sequence: previous.sequence,
                checksum: previous.checksum
            )
        }
        candidate.effectsByID = recoveredEffects

        var effectIDsByIdempotencyKey: [String: String] = [:]
        for (effectID, record) in candidate.effectsByID {
            guard effectIDsByIdempotencyKey[record.idempotencyKey] == nil else { return nil }
            effectIDsByIdempotencyKey[record.idempotencyKey] = effectID
        }
        candidate.effectIDByIdempotencyKey = effectIDsByIdempotencyKey

        guard let snapshot = try? snapshotChecksum(candidate) else { return nil }
        candidate.snapshotChecksum = snapshot
        guard (try? validate(candidate)) != nil else { return nil }
        return candidate
    }

    private static func validateReplayRequirements(_ state: State) throws {
        guard (1...schemaVersion).contains(state.schemaVersion) else {
            throw AgentDurableEffectJournalError.corruptLedger
        }
        for entry in state.entries {
            let requirement = entry.event.replayRequirement ?? .required
            if entry.event.knownKind != nil {
                // No writer can downgrade an event that changes replay state.
                guard requirement == .required, entry.event.opaquePayload == nil else {
                    throw AgentDurableEffectJournalError.corruptLedger
                }
            } else {
                guard state.schemaVersion == 2, requirement == .ignorable,
                      !entry.event.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      entry.event.effectID == nil,
                      entry.event.attemptNumber == nil,
                      entry.event.supersedesAttemptID == nil,
                      entry.event.leaseID == nil,
                      entry.event.idempotencyKey == nil,
                      entry.event.inputDigest == nil,
                      entry.event.status == nil,
                      entry.event.redactedOutcome == nil else {
                    throw AgentDurableEffectJournalError.corruptLedger
                }
            }
        }
    }

    private static func validate(_ state: State) throws {
        try validateReplayRequirements(state)
        guard state.snapshotChecksum == (try? snapshotChecksum(state)) else {
            throw AgentDurableEffectJournalError.corruptLedger
        }

        for (index, entry) in state.entries.enumerated() {
            let expectedSequence = index + 1
            guard entry.sequence == expectedSequence else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
            let expectedPreviousChecksum = index == 0
                ? nil
                : state.entries[index - 1].checksum
            guard entry.previousChecksum == expectedPreviousChecksum else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
            guard entry.checksum == (try? checksum(
                sequence: entry.sequence,
                event: entry.event,
                previousChecksum: entry.previousChecksum
            )) else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
        }

        for (attemptID, attempt) in state.attemptsByID {
            guard attemptID == attempt.attemptID,
                  attempt.attemptNumber > 0,
                  !attempt.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !attempt.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !attempt.attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
            if let parentID = attempt.supersedesAttemptID {
                guard let parent = state.attemptsByID[parentID],
                      parent.taskID == attempt.taskID,
                      parent.runID == attempt.runID,
                      parent.attemptNumber + 1 == attempt.attemptNumber else {
                    throw AgentDurableEffectJournalError.corruptLedger
                }
            } else {
                guard attempt.attemptNumber == 1 else {
                    throw AgentDurableEffectJournalError.corruptLedger
                }
            }
        }

        for (runKey, attemptID) in state.currentAttemptIDByRun {
            guard let attempt = state.attemptsByID[attemptID],
                  runKey == Self.runKey(taskID: attempt.taskID, runID: attempt.runID) else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
        }

        var effectIDsByIdempotency: [String: String] = [:]
        for (effectID, record) in state.effectsByID {
            guard effectID == record.identity.effectID,
                  let attempt = state.attemptsByID[record.identity.attemptID],
                  attempt.taskID == record.identity.taskID,
                  attempt.runID == record.identity.runID,
                  effectIDsByIdempotency[record.idempotencyKey] == nil,
                  record.sequence > 0,
                  record.sequence <= state.entries.count,
                  state.entries[record.sequence - 1].checksum == record.checksum,
                  state.entries[record.sequence - 1].event.knownKind != nil else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
            effectIDsByIdempotency[record.idempotencyKey] = effectID
            guard state.effectIDByIdempotencyKey[record.idempotencyKey] == effectID else {
                throw AgentDurableEffectJournalError.corruptLedger
            }
        }
        guard effectIDsByIdempotency == state.effectIDByIdempotencyKey else {
            throw AgentDurableEffectJournalError.corruptLedger
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

private extension AgentDurableEffectRecord {
    func updated(
        lease: AgentDurableEffectLease,
        status: AgentDurableEffectStatus,
        redactedOutcome: String?,
        entry: AgentDurableEffectJournalEntry
    ) -> AgentDurableEffectRecord {
        AgentDurableEffectRecord(
            identity: identity,
            lease: lease,
            idempotencyKey: idempotencyKey,
            inputDigest: inputDigest,
            status: status,
            redactedOutcome: redactedOutcome,
            sequence: entry.sequence,
            checksum: entry.checksum
        )
    }
}

private extension AgentDurableEffectJournal {
    func validateIdentityParts(_ values: String...) throws {
        guard values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw AgentDurableEffectJournalError.invalidIdentity
        }
    }

    func validate(_ identity: AgentDurableEffectIdentity) throws {
        try validateIdentityParts(
            identity.taskID,
            identity.runID,
            identity.attemptID,
            identity.effectID
        )
    }
}
