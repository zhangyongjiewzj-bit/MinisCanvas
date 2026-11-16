import Foundation

/// The only terminal outcomes a production stream may expose to UI/control
/// consumers.  The identity and generation are part of the fact so a late
/// callback cannot turn a rejected or failed operation into success.
public enum AgentTerminalTruthOutcome: String, Codable, Equatable, Sendable {
    case policyRefused
    case dryRun
    case executionFailed
    case cancelled
    case succeeded
}

public struct AgentTerminalTruth: Codable, Equatable, Hashable, Sendable {
    public let identity: AgentExecutionIdentity
    public let generation: Int
    public let outcome: AgentTerminalTruthOutcome
    public let reason: String?

    public init(
        identity: AgentExecutionIdentity,
        generation: Int,
        outcome: AgentTerminalTruthOutcome,
        reason: String? = nil
    ) {
        self.identity = identity
        self.generation = generation
        self.outcome = outcome
        self.reason = reason
    }

    public var isSuccess: Bool { outcome == .succeeded }

    public func matches(identity: AgentExecutionIdentity, generation: Int) -> Bool {
        self.identity == identity && self.generation == generation
    }
}

/// Durable lifecycle boundary for one provider stream.
///
/// The provider may deliver callbacks after cancellation, process restart, or
/// a resumed attempt. This consumer admits only callbacks for the currently
/// active generation and delegates sequence admission to the durable turn
/// store before a transcript consumer is allowed to append a delta.
public final class AgentStreamLifecycleConsumer: @unchecked Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case unstarted
        case active
        case needsUserReview
        case cancelled
        case completed
        case rejected
        case dryRun
        case failed
    }

    private let lock = NSLock()
    private let store: AgentTurnContextStore
    private let identity: AgentExecutionIdentity
    private let snapshot: ConversationContextSnapshotV1
    private var generation: Int
    private var phase: Phase = .unstarted
    private var terminalTruthValue: AgentTerminalTruth?

    /// The consumer owns no transcript or provider state. It is the durable
    /// admission seam used by those production consumers.
    public init(
        store: AgentTurnContextStore,
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1,
        generation: Int = 0
    ) {
        self.store = store
        self.identity = identity
        self.snapshot = snapshot
        self.generation = generation
        if let record = store.record(for: identity), record.snapshot.matches(snapshot) {
            self.generation = record.generation
            self.phase = Self.phase(for: record.status)
            self.terminalTruthValue = record.terminalTruth ?? Self.terminalTruth(
                for: record.status,
                identity: record.identity,
                generation: record.generation
            )
        }
    }

    public var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    public var currentPhase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    /// The identity-bound terminal fact consumed by UI and durable control
    /// projections. It is nil until one terminal path wins.
    public var terminalTruth: AgentTerminalTruth? {
        lock.lock()
        defer { lock.unlock() }
        return terminalTruthValue
    }

    /// Records a policy refusal without admitting provider work. A refusal is
    /// terminal for this identity and therefore cannot later be reported as a
    /// successful stream.
    @discardableResult
    public func refuseByPolicy(reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard (phase == .unstarted || phase == .active), terminalTruthValue == nil else { return false }
        guard (try? store.refuseByPolicy(
            identity: identity,
            snapshot: snapshot,
            generation: generation,
            reason: reason
        )) == true else { return false }
        terminalTruthValue = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: .policyRefused,
            reason: reason
        )
        phase = .rejected
        return true
    }

    /// Records a dry-run result without creating a durable running stream.
    @discardableResult
    public func completeDryRun(reason: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .unstarted, terminalTruthValue == nil else { return false }
        guard (try? store.completeDryRun(
            identity: identity,
            snapshot: snapshot,
            generation: generation,
            reason: reason
        )) == true else { return false }
        terminalTruthValue = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: .dryRun,
            reason: reason
        )
        phase = .dryRun
        return true
    }

    /// Starts the stream exactly once for this immutable execution identity.
    @discardableResult
    public func begin() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .unstarted, terminalTruthValue == nil else { return false }
        guard try store.begin(
            identity: identity,
            snapshot: snapshot,
            generation: generation
        ) else {
            return false
        }
        phase = .active
        return true
    }

    /// Admits one stream delta before the downstream transcript consumer
    /// appends it. Equal/older sequences are harmless duplicates/late results
    /// and return false; terminal or stale-generation callbacks also fail
    /// closed through the durable store.
    @discardableResult
    public func admitDelta(sequence: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .active, terminalTruthValue == nil else { return false }
        return try store.acceptStreamSequence(
            identity: identity,
            snapshot: snapshot,
            sequence: sequence,
            generation: generation
        )
    }

    /// Cancels the active stream and durably retires its generation. A late
    /// provider callback cannot re-enter the transcript after this returns.
    @discardableResult
    public func cancel() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .active, terminalTruthValue == nil else { return false }
        guard try store.cancel(
            identity: identity,
            snapshot: snapshot,
            generation: generation
        ) else {
            return false
        }
        terminalTruthValue = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: .cancelled
        )
        phase = .cancelled
        return true
    }

    /// Settles a provider/execution failure through the same durable terminal
    /// boundary as cancellation and success.
    @discardableResult
    public func fail(reason: String = "execution-failed") throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .active, terminalTruthValue == nil else { return false }
        guard try store.fail(
            identity: identity,
            snapshot: snapshot,
            generation: generation,
            reason: reason
        ) else {
            return false
        }
        terminalTruthValue = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: .executionFailed,
            reason: reason
        )
        phase = .failed
        return true
    }

    /// Converts an interrupted active stream into explicit recovery state.
    /// Recovery is persisted before a caller can offer resume to the user.
    @discardableResult
    public func recoverAfterInterruption() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .active, terminalTruthValue == nil else { return false }
        guard try store.recoverInterrupted(
            identity: identity,
            snapshot: snapshot,
            generation: generation
        ) else {
            return false
        }
        phase = .needsUserReview
        return true
    }

    /// Explicitly resumes a reviewed stream under a newer generation. The
    /// sequence starts at zero for the new generation, while old callbacks
    /// remain rejected by the durable identity/generation fence.
    @discardableResult
    public func resume(generation newGeneration: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .needsUserReview, newGeneration > generation else {
            return false
        }
        guard try store.reopenAfterRecovery(
            identity: identity,
            snapshot: snapshot,
            generation: newGeneration
        ) else {
            return false
        }
        generation = newGeneration
        phase = .active
        return true
    }

    /// Finishes only after the downstream transcript writeback has been
    /// durably admitted. This keeps an in-flight writeback distinguishable
    /// from a completed stream across restart.
    @discardableResult
    public func finishAfterWriteback() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .active else { return false }
        if let record = store.record(for: identity) {
            guard record.snapshot.matches(snapshot), record.generation == generation else {
                return false
            }
            if record.status == .active {
                guard try store.admitWriteback(
                    identity: identity,
                    snapshot: snapshot,
                    currentSnapshot: snapshot,
                    generation: generation
                ) else {
                    return false
                }
            } else if record.status != .writingBack {
                return false
            }
        } else {
            return false
        }
        guard try store.complete(
            identity: identity,
            snapshot: snapshot,
            generation: generation
        ) else {
            return false
        }
        terminalTruthValue = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: .succeeded
        )
        phase = .completed
        return true
    }

    /// Finishes a Composer plan stream after downstream transcript writeback
    /// is durably admitted. Plan mode may run the Provider to produce a plan,
    /// but its policy executor simulates side-effect tools, so success must
    /// never be projected as an executed turn.
    @discardableResult
    public func finishDryRunAfterWriteback(reason: String? = nil) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .active else { return false }
        if let record = store.record(for: identity) {
            guard record.snapshot.matches(snapshot), record.generation == generation else {
                return false
            }
            if record.status == .active {
                guard try store.admitWriteback(
                    identity: identity,
                    snapshot: snapshot,
                    currentSnapshot: snapshot,
                    generation: generation
                ) else {
                    return false
                }
            } else if record.status != .writingBack {
                return false
            }
        } else {
            return false
        }
        guard try store.completeDryRunAfterWriteback(
            identity: identity,
            snapshot: snapshot,
            generation: generation,
            reason: reason
        ) else {
            return false
        }
        terminalTruthValue = AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: .dryRun,
            reason: reason
        )
        phase = .dryRun
        return true
    }

    private static func phase(for status: AgentTurnContextStatus) -> Phase {
        switch status {
        case .active, .writingBack:
            return .active
        case .needsUserReview:
            return .needsUserReview
        case .cancelled:
            return .cancelled
        case .completed:
            return .completed
        case .policyRefused:
            return .rejected
        case .dryRun:
            return .dryRun
        case .failed:
            return .failed
        }
    }

    private static func terminalTruth(
        for status: AgentTurnContextStatus,
        identity: AgentExecutionIdentity,
        generation: Int
    ) -> AgentTerminalTruth? {
        let outcome: AgentTerminalTruthOutcome
        switch status {
        case .cancelled:
            outcome = .cancelled
        case .completed:
            outcome = .succeeded
        case .failed:
            outcome = .executionFailed
        case .policyRefused:
            outcome = .policyRefused
        case .dryRun:
            outcome = .dryRun
        case .active, .writingBack, .needsUserReview:
            return nil
        }
        return AgentTerminalTruth(
            identity: identity,
            generation: generation,
            outcome: outcome
        )
    }
}
