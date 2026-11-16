import Foundation

/// Describes which boundary owns an orchestration request.
///
/// Library/contract callers may use the legacy mode when they do not claim a
/// production turn. Production mode is fail-closed until the composition root
/// supplies the exact parent `TurnHandle`.
public enum OrchestrationRuntimeMode: String, Sendable, Equatable, Codable {
    case legacyLibrary
    case production
}

public enum OrchestrationFailureIsolation: String, Sendable, Equatable, Codable {
    case perChild
}

public enum ChildResult: Sendable, Equatable {
    case success
    case failed
    case cancelled
    case timedOut
}

/// Durable location of one child transcript. Older result-only ledgers decode
/// a missing locator as nil; a caller must never infer a child session from an ID.
public struct ChildTranscriptLocator: Sendable, Equatable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let childSessionID: String
    public let parentSessionID: String
    public let taskID: String
    public let parentID: String
    /// Nil on historical locators. A retry keeps `parentID` as the logical
    /// Task Center owner and pins this distinct real Composer parent turn.
    public let runtimeParentID: String?
    public let runID: String
    public let attemptID: String
    public let childExecutionID: String
    public let parentContextSnapshotID: String?
    public let lineageVersion: Int

    public init(
        childSessionID: String,
        parentSessionID: String,
        taskID: String,
        parentID: String,
        runtimeParentID: String? = nil,
        runID: String,
        attemptID: String,
        childExecutionID: String,
        parentContextSnapshotID: String?,
        lineageVersion: Int = 1,
        schemaVersion: Int = ChildTranscriptLocator.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.childSessionID = childSessionID
        self.parentSessionID = parentSessionID
        self.taskID = taskID
        self.parentID = parentID
        self.runtimeParentID = runtimeParentID
        self.runID = runID
        self.attemptID = attemptID
        self.childExecutionID = childExecutionID
        self.parentContextSnapshotID = parentContextSnapshotID
        self.lineageVersion = lineageVersion
    }

    public var isWellFormed: Bool {
        (1...Self.currentSchemaVersion).contains(schemaVersion)
            && lineageVersion > 0
            && [childSessionID, parentSessionID, taskID, parentID, runID, attemptID, childExecutionID]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && childSessionID != parentSessionID
            && (runtimeParentID == nil || (schemaVersion == 2
                && !runtimeParentID!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }
}

/// Provider-reported usage for this exact child attempt, not an estimate of
/// requests whose provider omitted usage. Old envelopes decode missing usage as nil.
public struct ChildResultTokenUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let reportedCallCount: Int
    /// Total input (uncached + cache read + cache write), when the usage
    /// records could report it. Nil on older envelopes: `inputTokens` then
    /// stands in for it.
    public let totalInputTokens: Int?
    public init(inputTokens: Int, outputTokens: Int, reportedCallCount: Int, totalInputTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.reportedCallCount = reportedCallCount
        self.totalInputTokens = totalInputTokens
    }
    public var effectiveInputTokens: Int { totalInputTokens ?? inputTokens }
    public var isWellFormed: Bool {
        inputTokens >= 0 && outputTokens >= 0 && reportedCallCount > 0
            && (totalInputTokens ?? 0) >= 0
            && !inputTokens.addingReportingOverflow(outputTokens).overflow
    }
}

/// The durable fact for one child completion.
///
/// The task ledger owns persistence and settlement. This value deliberately
/// carries identity and bounded evidence references, while callers may omit
/// optional presentation fields when only a redacted digest is available.
public struct ChildResultEnvelope: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let taskID: String
    public let runID: String
    public let attemptID: String
    public let attemptNumber: Int
    public let sequence: Int
    public let parentContextSnapshotID: String?
    public let childExecutionID: String
    /// Nil on older result-only records.
    public let childTranscriptLocator: ChildTranscriptLocator?
    public let agentType: String?
    public let tokenUsage: ChildResultTokenUsage?
    public let outcome: AgentTaskOutcome
    /// Only present when a child reached its iteration limit.
    public let iterationLimitReached: Bool?
    public var isPartial: Bool { iterationLimitReached == true }
    static let iterationLimitReason = "child-iteration-limit"
    /// 子任务回复被单次输出上限截断时，放在半截报告最前面的说明（失败状态不变）。
    static let outputTruncatedNote = "［子任务回复因达到单次输出上限被截断，以下为部分报告，内容不完整］"
    public let output: String?
    public let error: String?
    public let outputDigest: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let evidenceRefs: [String]
    public let idempotencyKey: String

    public init(
        taskID: String,
        runID: String,
        attemptID: String,
        attemptNumber: Int = 1,
        sequence: Int = 1,
        parentContextSnapshotID: String?,
        childExecutionID: String,
        outcome: AgentTaskOutcome,
        outputDigest: String? = nil,
        resultDigest: String? = nil,
        evidenceRefs: [String] = [],
        idempotencyKey: String? = nil,
        agentType: String? = nil,
        tokenUsage: ChildResultTokenUsage? = nil,
        output: String? = nil,
        error: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        childTranscriptLocator: ChildTranscriptLocator? = nil,
        iterationLimitReached: Bool? = nil,
        schemaVersion: Int = ChildResultEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.runID = runID
        self.attemptID = attemptID
        self.attemptNumber = attemptNumber
        self.sequence = sequence
        self.parentContextSnapshotID = parentContextSnapshotID
        self.childExecutionID = childExecutionID
        self.childTranscriptLocator = childTranscriptLocator
        self.agentType = agentType
        self.tokenUsage = tokenUsage
        self.outcome = outcome
        self.iterationLimitReached = iterationLimitReached
        self.output = output
        self.error = error
        self.outputDigest = outputDigest ?? resultDigest ?? ""
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.evidenceRefs = evidenceRefs
        self.idempotencyKey = idempotencyKey
            ?? [taskID, runID, attemptID, childExecutionID].joined(separator: "|")
    }

    /// Compatibility spelling used by the earlier H2 producer.
    public var resultDigest: String { outputDigest }

    var isWellFormed: Bool {
        schemaVersion == Self.currentSchemaVersion
            && [taskID, runID, attemptID, childExecutionID, outputDigest, idempotencyKey]
                .allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            && attemptNumber > 0
            && sequence > 0
            && evidenceRefs.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            && (startedAt == nil || finishedAt == nil || finishedAt! >= startedAt!)
            && (output == nil || error == nil)
            && (iterationLimitReached == nil
                || (isPartial && outcome == .failed(reason: Self.iterationLimitReason)
                    && output != nil && error == nil))
            && (tokenUsage?.isWellFormed ?? true)
            && (childTranscriptLocator.map { locator in
                locator.isWellFormed
                    && locator.taskID == taskID
                    && locator.runID == runID
                    && locator.attemptID == attemptID
                    && locator.childExecutionID == childExecutionID
                    && locator.parentContextSnapshotID == parentContextSnapshotID
            } ?? true)
    }

    var eventKind: AgentTaskEventKind {
        switch outcome {
        case .succeeded: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}

/// Compatibility name retained for callers that used the prefixed H2 type.
public typealias AgentChildResultEnvelope = ChildResultEnvelope

public struct ChildResultLookup: Sendable, Equatable {
    public let envelope: ChildResultEnvelope
    public let receipt: AgentTaskReceipt

    public init(envelope: ChildResultEnvelope, receipt: AgentTaskReceipt) {
        self.envelope = envelope
        self.receipt = receipt
    }
}

public struct OrchestrationPlan: Sendable, Equatable {
    public let parent: ParentRuntimeIdentity
    public let childIdentities: [ChildRuntimeIdentity]
    public let effectiveParallelism: Int
    public let deadline: Date
    public let failureIsolation: OrchestrationFailureIsolation

    public init(
        parent: ParentRuntimeIdentity,
        childIdentities: [ChildRuntimeIdentity],
        requestedParallelism: Int,
        maxParallelism: Int,
        deadline: Date
    ) throws {
        guard requestedParallelism > 0, maxParallelism > 0 else {
            throw ChildRuntimeIdentityError.invalidField("parallelism")
        }
        guard maxParallelism <= AgentOrchestrator.hardMaxConcurrentChildren else {
            throw ChildRuntimeIdentityError.invalidField("maxParallelism")
        }
        guard Set(childIdentities.map(\.childTaskID)).count == childIdentities.count else {
            throw ChildRuntimeIdentityError.invalidField("childTaskID")
        }
        guard childIdentities.allSatisfy({
            $0.parentSessionID == parent.sessionID &&
            $0.parentConversationID == parent.conversationID &&
            $0.parentTurnID == parent.turnID &&
            $0.parentTaskID == parent.taskID
        }) else {
            throw ChildRuntimeIdentityError.parentMismatch
        }
        self.parent = parent
        self.childIdentities = childIdentities
        self.effectiveParallelism = min(requestedParallelism, maxParallelism)
        self.deadline = deadline
        self.failureIsolation = .perChild
    }
}

public actor ChildResultGuard {
    private static let maxGeneration = Int.max

    private enum State {
        case running
        case succeeded
        case recoverable
        case cancelled
    }

    private let identity: ChildRuntimeIdentity
    private let identityAccepted: Bool
    private let requiresIdentityBinding: Bool
    private var currentGeneration: Int
    private var state: State = .running

    public init(
        identity: ChildRuntimeIdentity,
        requireVerifiedIdentity: Bool = false
    ) {
        self.identity = identity
        self.requiresIdentityBinding = requireVerifiedIdentity
        self.identityAccepted = !requireVerifiedIdentity || (
            identity.schemaVersion == ChildRuntimeIdentity.currentSchemaVersion &&
            identity.cancelGeneration < Self.maxGeneration &&
            (try? identity.requireVerifiedGeneration()) != nil
        )
        self.currentGeneration = identity.cancelGeneration
    }

    /// Production consumers use this gate before dispatching or writing back
    /// a child result. Legacy callers may keep the original permissive lane.
    public func isReady() -> Bool {
        identityAccepted
    }

    public func accept(_ result: ChildResult, generation: Int) -> Bool {
        guard !requiresIdentityBinding else { return false }
        guard canAccept(generation: generation) else { return false }
        return apply(result)
    }

    /// Identity-aware result admission prevents a different Unicode-composed
    /// child identity from reusing the same numeric generation.
    public func accept(
        _ result: ChildResult,
        identity: ChildRuntimeIdentity,
        generation: Int
    ) -> Bool {
        guard identityAccepted,
              identity.compositeIdentityKey == self.identity.compositeIdentityKey else {
            return false
        }
        guard canAccept(generation: generation) else { return false }
        return apply(result)
    }

    private func canAccept(generation: Int) -> Bool {
        guard identityAccepted, generation == currentGeneration else { return false }
        guard currentGeneration < Self.maxGeneration else { return false }
        guard case .running = state else { return false }
        return true
    }

    private func apply(_ result: ChildResult) -> Bool {
        switch result {
        case .success:
            state = .succeeded
            return true
        case .failed:
            return false
        case .cancelled:
            state = .cancelled
            _ = advanceGeneration()
            return false
        case .timedOut:
            state = .recoverable
            return true
        }
    }

    /// Atomically closes the result lane. A success that races this method is
    /// ordered by the actor: exactly one terminal decision can win.
    @discardableResult
    public func cancel(generation: Int) -> Bool {
        guard !requiresIdentityBinding else { return false }
        guard canAccept(generation: generation) else { return false }
        state = .cancelled
        return advanceGeneration()
    }

    @discardableResult
    public func cancel(
        identity: ChildRuntimeIdentity,
        generation: Int
    ) -> Bool {
        guard identityAccepted,
              identity.compositeIdentityKey == self.identity.compositeIdentityKey else {
            return false
        }
        guard canAccept(generation: generation) else { return false }
        state = .cancelled
        return advanceGeneration()
    }

    public func recover() -> Bool {
        guard !requiresIdentityBinding else { return false }
        return recoverTransition()
    }

    public func recover(identity: ChildRuntimeIdentity) -> Bool {
        guard identityAccepted,
              identity.compositeIdentityKey == self.identity.compositeIdentityKey else {
            return false
        }
        return recoverTransition()
    }

    private func recoverTransition() -> Bool {
        guard identityAccepted, case .recoverable = state else { return false }
        guard advanceGeneration() else { return false }
        state = .running
        return true
    }

    private func advanceGeneration() -> Bool {
        guard currentGeneration < Self.maxGeneration else { return false }
        currentGeneration += 1
        return true
    }
}
