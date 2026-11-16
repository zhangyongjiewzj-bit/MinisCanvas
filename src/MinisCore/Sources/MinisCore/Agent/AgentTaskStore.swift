import Foundation
import Darwin

public enum AgentTaskStatus: Sendable, Equatable, Codable {
    case queued, running, succeeded, failed, cancelled
}

/// A runtime cancellation capability for one active task run.
///
/// The durable ledger remains the source of truth for terminal state; this
/// handle is the in-memory bridge that lets a task-center stop reach the
/// actual provider/worker operation after the terminal fact is committed.
public final class AgentTaskCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellation: @Sendable () -> Void
    private var didCancel = false

    public init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    public func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()
        cancellation()
    }
}

public enum AgentTaskControlState: String, Sendable, Equatable, Codable {
    case active
    case paused
    case stopped
    case terminal
}

public enum AgentTaskControlCommand: String, Sendable, Equatable, Codable {
    case pause
    case resume
    case stop
    case retry
}

public struct AgentTaskControlSnapshot: Sendable, Equatable, Codable {
    public let taskID: String
    public let parentID: String
    public let state: AgentTaskControlState
    public let controlRevision: Int
    public let runID: String?

    public init(
        taskID: String,
        parentID: String,
        state: AgentTaskControlState,
        controlRevision: Int,
        runID: String?
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.state = state
        self.controlRevision = controlRevision
        self.runID = runID
    }
}

/// The durable command identity stored with a control mutation.
public struct AgentTaskControlReceipt: Sendable, Equatable, Codable {
    public let taskID: String
    public let parentID: String
    public let idempotencyKey: String
    public let command: AgentTaskControlCommand
    public let revision: String
    public let scopeID: String
    public let actorID: String
    public let runID: String?
    public let resultingRunID: String?
    public let controlState: AgentTaskControlState
    public let controlRevision: Int
    public let cancelledTaskIDs: [String]
    /// Captures the exact post-command fact so durable idempotent replay does
    /// not drift after a later lifecycle update. Optional keeps older ledgers
    /// readable; new receipts always persist it.
    public let afterFact: GoalTaskCenterTaskFact?

    public init(
        taskID: String,
        parentID: String,
        idempotencyKey: String,
        command: AgentTaskControlCommand,
        revision: String,
        scopeID: String,
        actorID: String,
        runID: String?,
        resultingRunID: String?,
        controlState: AgentTaskControlState,
        controlRevision: Int,
        cancelledTaskIDs: [String],
        afterFact: GoalTaskCenterTaskFact? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.revision = revision
        self.scopeID = scopeID
        self.actorID = actorID
        self.runID = runID
        self.resultingRunID = resultingRunID
        self.controlState = controlState
        self.controlRevision = controlRevision
        self.cancelledTaskIDs = cancelledTaskIDs
        self.afterFact = afterFact
    }
}

/// A retry keeps its Task Center row but executes under a new, real parent
/// turn. Identity is keyed by run so a later attempt cannot rewrite the
/// original run's receipt or child-session provenance.
public struct RetryRunRuntimeBinding: Sendable, Equatable, Codable {
    public let taskID: String
    public let originalParentID: String
    public let runID: String
    public let attemptID: String
    public let parent: ParentRuntimeIdentity
    public let parentGoal: GoalEnvelope
    public let child: ChildRuntimeIdentity

    public init(taskID: String, originalParentID: String, runID: String,
                attemptID: String, parent: ParentRuntimeIdentity,
                parentGoal: GoalEnvelope, child: ChildRuntimeIdentity) {
        self.taskID = taskID
        self.originalParentID = originalParentID
        self.runID = runID
        self.attemptID = attemptID
        self.parent = parent
        self.parentGoal = parentGoal
        self.child = child
    }
}

public struct AgentTaskControlTransition: Sendable, Equatable {
    public let task: AgentTaskSnapshot
    public let control: AgentTaskControlSnapshot
    public let resultingRunID: String?
    public let cancelledTaskIDs: [String]

    public init(
        task: AgentTaskSnapshot,
        control: AgentTaskControlSnapshot,
        resultingRunID: String?,
        cancelledTaskIDs: [String]
    ) {
        self.task = task
        self.control = control
        self.resultingRunID = resultingRunID
        self.cancelledTaskIDs = cancelledTaskIDs
    }
}

public enum AgentPersistenceFault: Sendable, Equatable {
    case none
    case diskFull
}

public struct AgentPersistenceDiagnostic: Sendable, Equatable {
    public let operation: String
    public let reason: String
    public let message: String

    public init(operation: String, reason: String, message: String) {
        self.operation = operation
        self.reason = reason
        self.message = message
    }
}

public enum AgentTaskStoreError: Error, Equatable, Sendable {
    case duplicateTask
    case unknownTask
    case duplicateRun
    case taskAlreadyRunning
    case unknownRun
    case runClosed
    case persistenceFailed
    case persistenceRecoveryFailed(AgentPersistenceDiagnostic)
    case staleWriter
    case terminalEventRequiresSettlement
    case invalidTerminalSettlement
    case childResultInvalidEnvelope
    case childResultIdentityMismatch
    case childResultStaleAttempt
    case childResultCancelled
    case childResultLate
    case childResultIdempotencyConflict
    case childResultEnvelopeConflict
    case controlRevisionMismatch
    case controlStateConflict
    case controlReceiptConflict
    case externalSubmissionUnknown
    case creationIdempotencyConflict
    case archiveNotEligible
    case archiveIdentityMismatch
    case archiveReceiptMismatch
    case archiveIdempotencyConflict
    case archiveStateConflict
    case approvalNavigationIdentityMismatch
    case approvalNavigationConflict
}

public enum AgentTaskRecoveryState: Sendable, Equatable {
    case needsUserReview
}

/// A parent turn's durable join evidence. An unsettled child is recorded as
/// unknown, never promoted to a synthetic terminal receipt.
public struct AgentParentTurnTerminalFact: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable { case succeeded, failed, cancelled, timedOut }
    public struct Child: Sendable, Equatable, Codable {
        public enum Outcome: String, Sendable, Codable {
            case succeeded, failed, cancelled, needsUserReview
        }
        public let taskID: String
        public let runID: String
        public let attemptID: String
        public let outcome: Outcome
        /// A parent's cancellation request is not a child terminal receipt.
        public let cancellationReason: String?
    }
    public let parent: ParentRuntimeIdentity
    public let execution: AgentExecutionIdentity
    public let outcome: Outcome
    public let children: [Child]
}

public enum AgentExternalSubmissionDecision: Sendable, Equatable {
    case notSubmitted
    case needsUserReview
    case settled
}

public struct AgentExternalSubmissionIdentity: Sendable, Equatable, Codable {
    public let taskID: String
    public let runID: String
    public let attemptID: String
    public let idempotencyKey: String

    public init(taskID: String, runID: String, attemptID: String) {
        self.taskID = taskID
        self.runID = runID
        self.attemptID = attemptID
        idempotencyKey = [taskID, runID, attemptID].joined(separator: "|")
    }
}

public enum AgentTaskEventKind: Sendable, Equatable, Codable {
    case started, progress, approvalRequired, inputRequired, submissionUnknown, completed, failed, cancelled, terminalDuplicate
}

/// Payload-free categories supplied by a trusted App error switch, never parsed
/// from provider errors or caller-provided failure strings.
public enum AgentTaskPublicFailureCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case projectTargetUnavailable = "public-failure:project-target-unavailable"
    case chatRuntimeMissingRequiredSnapshot = "public-failure:chat-runtime-missing-required-snapshot"

    public var message: String {
        switch self {
        case .projectTargetUnavailable: return "执行校验未通过（PROJECT:targetUnavailable），本次请求未完成。"
        case .chatRuntimeMissingRequiredSnapshot: return "执行校验未通过（CHAT-RUNTIME:missingRequiredSnapshot），本次请求未完成。"
        }
    }

    public var title: String {
        switch self {
        case .projectTargetUnavailable: return "目标会话不可用"
        case .chatRuntimeMissingRequiredSnapshot: return "缺少冻结运行快照"
        }
    }
}

public enum AgentTaskOutcome: Sendable, Equatable, Codable {
    case succeeded
    case failed(reason: String)
    case cancelled

    fileprivate var status: AgentTaskStatus {
        switch self {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}

/// Process-local observation of a newly persisted terminal receipt. Metadata
/// only: never a tool grant, model output, or replay command after reopening.
public struct AgentTaskTerminalObservation: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case completed, failed, cancelled }
    public let taskID: String
    public let parentID: String
    public let runID: String
    public let attemptID: String
    public let sourceSessionID: String
    public let childSessionID: String?
    public let outcome: Outcome
}

public struct AgentTaskSnapshot: Sendable, Equatable, Codable {
    public let taskID: String
    public let parentID: String
    public let parentContextSnapshotID: String?
    public let providerID: String?
    public let modelID: String?
    public let configurationFingerprint: String?
    public let routeReceiptID: String?
    public let status: AgentTaskStatus
    /// Optional provenance for tasks created through the session-action
    /// consumer. Nil keeps pre-existing ledgers backward compatible.
    public let creation: SessionActionCreationMetadata?
    /// Human-readable title supplied by the real child dispatch producer.
    /// Separate from session-action creation provenance; absent in legacy ledgers.
    public let dispatchHumanTitle: String?
    /// Durable reversible archive marker. A missing value keeps legacy ledgers
    /// visible and unarchived after recovery.
    public let archivedAt: Date?
    /// Exact child transcript identity. Nil keeps older ledgers result-only.
    public let childTranscriptLocator: ChildTranscriptLocator?
    /// Exact non-secret origin captured by the existing parent turn producer.
    /// Missing on older ledgers; never reconstructed from a task ID or selection.
    public let parentRuntimeIdentity: ParentRuntimeIdentity?
    /// Verified single-level child/root/Goal facts from the dispatch producer.
    /// Nil on old ledgers and non-child tasks means unknown, never inferred.
    public let childRuntimeIdentity: ChildRuntimeIdentity?

    public var isArchived: Bool { archivedAt != nil }

    /// Canonical source-session provenance. Parent IDs and context snapshot IDs
    /// are intentionally not used as a fallback for this identity.
    public var sourceSessionID: String? { creation?.source.sessionID ?? parentRuntimeIdentity?.sessionID }

    public init(
        taskID: String,
        parentID: String,
        parentContextSnapshotID: String?,
        providerID: String?,
        modelID: String?,
        configurationFingerprint: String?,
        routeReceiptID: String?,
        status: AgentTaskStatus,
        creation: SessionActionCreationMetadata? = nil,
        dispatchHumanTitle: String? = nil,
        archivedAt: Date? = nil,
        childTranscriptLocator: ChildTranscriptLocator? = nil,
        parentRuntimeIdentity: ParentRuntimeIdentity? = nil,
        childRuntimeIdentity: ChildRuntimeIdentity? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.parentContextSnapshotID = parentContextSnapshotID
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.routeReceiptID = routeReceiptID
        self.status = status
        self.creation = creation
        self.dispatchHumanTitle = dispatchHumanTitle
        self.archivedAt = archivedAt
        self.childTranscriptLocator = childTranscriptLocator
        self.parentRuntimeIdentity = parentRuntimeIdentity
        self.childRuntimeIdentity = childRuntimeIdentity
    }
}

public enum AgentTaskArchiveAction: String, Codable, Equatable, Sendable {
    case archive
    case restore
}

/// Durable archive command. The complete task snapshot identity and terminal
/// event identity fence the request against stale rows and late writers.
public struct AgentTaskArchiveRequest: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let expectedSnapshotIdentity: AgentTaskSnapshotIdentity
    public let runID: String
    public let attemptID: String
    public let eventSequence: Int
    public let sourceSessionID: String?
    public let actorID: String
    public let idempotencyKey: String
    public let action: AgentTaskArchiveAction

    public init(
        taskID: String,
        parentID: String,
        expectedSnapshotIdentity: AgentTaskSnapshotIdentity,
        runID: String,
        attemptID: String,
        eventSequence: Int,
        sourceSessionID: String?,
        actorID: String,
        idempotencyKey: String,
        action: AgentTaskArchiveAction
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.expectedSnapshotIdentity = expectedSnapshotIdentity
        self.runID = runID
        self.attemptID = attemptID
        self.eventSequence = eventSequence
        self.sourceSessionID = sourceSessionID
        self.actorID = actorID
        self.idempotencyKey = idempotencyKey
        self.action = action
    }
}

public struct AgentTaskArchiveSnapshot: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let sourceSessionID: String?
    public let runID: String
    public let attemptID: String
    public let eventSequence: Int
    public let archivedAt: Date

    public init(
        taskID: String,
        parentID: String,
        sourceSessionID: String?,
        runID: String,
        attemptID: String,
        eventSequence: Int,
        archivedAt: Date
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.sourceSessionID = sourceSessionID
        self.runID = runID
        self.attemptID = attemptID
        self.eventSequence = eventSequence
        self.archivedAt = archivedAt
    }
}

public struct AgentTaskArchiveReceipt: Codable, Equatable, Sendable {
    public let request: AgentTaskArchiveRequest
    public let archive: AgentTaskArchiveSnapshot
    public let didChange: Bool

    public init(
        request: AgentTaskArchiveRequest,
        archive: AgentTaskArchiveSnapshot,
        didChange: Bool
    ) {
        self.request = request
        self.archive = archive
        self.didChange = didChange
    }
}

public struct AgentRunSnapshot: Sendable, Equatable, Codable {
    public let runID: String
    public let taskID: String
    public let parentContextSnapshotID: String?
    public let status: AgentTaskStatus
}

/// Read-only durable run ownership, including prior runs after a retry.
/// It carries no mutable task state and grants no control capability.
public struct AgentTaskHistoricalRunIdentity: Sendable, Equatable {
    public let taskID: String
    public let parentID: String
    public let runID: String
    public let attemptID: String
    public let parentContextSnapshotID: String?
}

public struct AgentTaskAttemptSnapshot: Sendable, Equatable, Codable {
    public let attemptID: String
    public let runID: String
    public let parentContextSnapshotID: String?
    public let attempt: Int
    public let providerID: String?
    public let modelID: String?
    public let configurationFingerprint: String?
    public let status: AgentTaskStatus
    /// Observed lifecycle times, never an execution/permission grant. Missing
    /// fields in older ledgers stay unknown rather than acquiring a new clock.
    public let startedAt: Date?
    public let finishedAt: Date?

    init(attemptID: String, runID: String, parentContextSnapshotID: String?, attempt: Int,
         providerID: String?, modelID: String?, configurationFingerprint: String?,
         status: AgentTaskStatus, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.attemptID = attemptID
        self.runID = runID
        self.parentContextSnapshotID = parentContextSnapshotID
        self.attempt = attempt
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct AgentTaskEvent: Sendable, Equatable, Codable {
    public let runID: String
    public let parentContextSnapshotID: String?
    public let sequence: Int
    public let kind: AgentTaskEventKind
    public let detail: String
}

/// A live approval prompt linked to the task ledger's own run and attempt.
/// ApprovalGate's execution run/attempt remain separate effect identities.
/// This observation never grants permission and is not restored after a crash.
public struct AgentTaskApprovalNavigationBinding: Sendable, Equatable {
    public let taskID: String
    public let parentID: String
    public let taskRunID: String
    public let taskAttemptID: String
    public let childSessionID: String
    public let childGenerationID: String
    public let approvalRequestID: String
    public let approvalBindingDigest: String
    public let approvalRunID: String
    public let approvalAttemptID: String
    public let expiresAt: Date
}

/// Bounded observational projection. A request is not an execution receipt;
/// tool inputs and outputs are never retained in this live UI surface.
public enum ChildInstructionMailboxError: Error, Equatable, Sendable {
    case invalidText, full, staleAttempt, foreignSource
}

public struct ChildInstructionQueueSnapshot: Sendable, Equatable {
    public enum State: String, Sendable { case pending, endedWithoutDelivery }
    public let queuedCount: Int
    public let state: State
}

public struct ChildToolActivity: Sendable, Equatable {
    public let runID: String
    public let attemptID: String
    public let messageIndex: Int
    public let callIndex: Int
    public let toolName: String
    public let summary: String
    public let phase: String
}

public struct AgentTaskReceipt: Sendable, Equatable, Codable {
    public let taskID: String
    public let runID: String
    public let parentContextSnapshotID: String?
    public let attemptID: String
    public let providerID: String?
    public let modelID: String?
    public let configurationFingerprint: String?
    public let outcome: AgentTaskOutcome
    public let childResultEnvelope: ChildResultEnvelope?

    public init(
        taskID: String,
        runID: String,
        parentContextSnapshotID: String?,
        attemptID: String,
        providerID: String?,
        modelID: String?,
        configurationFingerprint: String?,
        outcome: AgentTaskOutcome,
        childResultEnvelope: ChildResultEnvelope? = nil
    ) {
        self.taskID = taskID
        self.runID = runID
        self.parentContextSnapshotID = parentContextSnapshotID
        self.attemptID = attemptID
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.outcome = outcome
        self.childResultEnvelope = childResultEnvelope
    }
}

/// Bounded, payload-free evidence that a terminal child result was rejected.
/// This is separate from canonical run events and receipts so diagnostics can
/// never change the terminal outcome or the event used by archive commands.
public struct RejectedChildResultDiagnostic: Sendable, Equatable, Codable {
    public enum Reason: String, Sendable, Equatable, Codable {
        case cancelled, late, conflictingReplay
    }

    public let taskID: String
    public let runID: String
    public let attemptID: String
    public let childExecutionID: String
    public let reason: Reason
}

/// Task/Run/Event/Receipt ledger with optional versioned JSON snapshot persistence.
/// Recovered running work is surfaced for review but never automatically redispatched.
public final class AgentTaskStore: @unchecked Sendable {
    // Control snapshots and durable command receipts were added after the
    // original task ledger envelope. Keep the old v1 payload readable, but
    // rewrite it immediately so a restart cannot lose the synthesized
    // control state. Schema 3 adds inert launch intents; older writers fail
    // closed instead of dropping those facts on a later rewrite.
    private static let currentSchemaVersion = 4
    private final class InitializationRecoveryHookBox: @unchecked Sendable {
        let lock = NSLock()
        var hooks: [String: (@Sendable () -> Void)] = [:]
    }

    private final class PersistenceLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [String: NSRecursiveLock] = [:]

        func lock(for path: String) -> NSRecursiveLock {
            registryLock.lock()
            defer { registryLock.unlock() }
            if let lock = locks[path] { return lock }
            let lock = NSRecursiveLock()
            locks[path] = lock
            return lock
        }
    }

    private static let initializationRecoveryHookBox = InitializationRecoveryHookBox()
    private static let persistenceLockRegistry = PersistenceLockRegistry()
    private let childStartupQueue = DispatchQueue(label: "com.miniscanvas.agent-task-store.child-startup", qos: .userInitiated)

    internal static func setInitializationRecoveryTestHook(for persistenceURL: URL, _ hook: (@Sendable () -> Void)?) {
        let key = persistenceURL.standardizedFileURL.path
        initializationRecoveryHookBox.lock.lock()
        if let hook {
            initializationRecoveryHookBox.hooks[key] = hook
        } else {
            initializationRecoveryHookBox.hooks.removeValue(forKey: key)
        }
        initializationRecoveryHookBox.lock.unlock()
    }

    private static func runInitializationRecoveryTestHook(for persistenceURL: URL) {
        let key = persistenceURL.standardizedFileURL.path
        initializationRecoveryHookBox.lock.lock()
        let hook = initializationRecoveryHookBox.hooks[key]
        initializationRecoveryHookBox.lock.unlock()
        hook?()
    }

    private struct State: Codable {
        var tasks: [String: AgentTaskSnapshot]
        var taskKeyByRunID: [String: String]
        var runs: [String: AgentRunSnapshot]
        var attempts: [String: AgentTaskAttemptSnapshot]
        var attemptIDByRunID: [String: String]
        var events: [String: [AgentTaskEvent]]
        var rejectedChildResults: [RejectedChildResultDiagnostic]
        var receiptByRunID: [String: AgentTaskReceipt]
        var receiptOrder: [String]
        var controlByTaskKey: [String: AgentTaskControlSnapshot]
        var controlReceiptByIdempotencyKey: [String: AgentTaskControlReceipt]
        var creationTaskKeyByIdempotencyKey: [String: String]
        var archiveByTaskKey: [String: AgentTaskArchiveSnapshot]
        var archiveReceiptByIdempotencyKey: [String: AgentTaskArchiveReceipt]
        var parentTurnTerminalFacts: [AgentParentTurnTerminalFact]
        var childLaunchIntents: [String: ChildLaunchIntentRecord]
        var retryRunRuntimeBindings: [String: RetryRunRuntimeBinding]

        private enum CodingKeys: String, CodingKey {
            case tasks
            case taskKeyByRunID
            case runs
            case attempts
            case attemptIDByRunID
            case events
            case rejectedChildResults
            case receiptByRunID
            case receiptOrder
            case controlByTaskKey
            case controlReceiptByIdempotencyKey
            case creationTaskKeyByIdempotencyKey
            case archiveByTaskKey
            case archiveReceiptByIdempotencyKey
            case parentTurnTerminalFacts
            case childLaunchIntents
            case retryRunRuntimeBindings
        }

        init(
            tasks: [String: AgentTaskSnapshot],
            taskKeyByRunID: [String: String],
            runs: [String: AgentRunSnapshot],
            attempts: [String: AgentTaskAttemptSnapshot],
            attemptIDByRunID: [String: String],
            events: [String: [AgentTaskEvent]],
            rejectedChildResults: [RejectedChildResultDiagnostic] = [],
            receiptByRunID: [String: AgentTaskReceipt],
            receiptOrder: [String],
            controlByTaskKey: [String: AgentTaskControlSnapshot] = [:],
            controlReceiptByIdempotencyKey: [String: AgentTaskControlReceipt] = [:],
            creationTaskKeyByIdempotencyKey: [String: String] = [:],
            archiveByTaskKey: [String: AgentTaskArchiveSnapshot] = [:],
            archiveReceiptByIdempotencyKey: [String: AgentTaskArchiveReceipt] = [:],
            parentTurnTerminalFacts: [AgentParentTurnTerminalFact] = [],
            childLaunchIntents: [String: ChildLaunchIntentRecord] = [:],
            retryRunRuntimeBindings: [String: RetryRunRuntimeBinding] = [:]
        ) {
            self.tasks = tasks
            self.taskKeyByRunID = taskKeyByRunID
            self.runs = runs
            self.attempts = attempts
            self.attemptIDByRunID = attemptIDByRunID
            self.events = events
            self.rejectedChildResults = rejectedChildResults
            self.receiptByRunID = receiptByRunID
            self.receiptOrder = receiptOrder
            self.controlByTaskKey = controlByTaskKey
            self.controlReceiptByIdempotencyKey = controlReceiptByIdempotencyKey
            self.creationTaskKeyByIdempotencyKey = creationTaskKeyByIdempotencyKey
            self.archiveByTaskKey = archiveByTaskKey
            self.archiveReceiptByIdempotencyKey = archiveReceiptByIdempotencyKey
            self.parentTurnTerminalFacts = parentTurnTerminalFacts
            self.childLaunchIntents = childLaunchIntents
            self.retryRunRuntimeBindings = retryRunRuntimeBindings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tasks = try container.decode([String: AgentTaskSnapshot].self, forKey: .tasks)
            taskKeyByRunID = try container.decode([String: String].self, forKey: .taskKeyByRunID)
            runs = try container.decode([String: AgentRunSnapshot].self, forKey: .runs)
            attempts = try container.decode([String: AgentTaskAttemptSnapshot].self, forKey: .attempts)
            attemptIDByRunID = try container.decode([String: String].self, forKey: .attemptIDByRunID)
            events = try container.decode([String: [AgentTaskEvent]].self, forKey: .events)
            rejectedChildResults = try container.decodeIfPresent(
                [RejectedChildResultDiagnostic].self, forKey: .rejectedChildResults
            ) ?? []
            receiptByRunID = try container.decode([String: AgentTaskReceipt].self, forKey: .receiptByRunID)
            receiptOrder = try container.decode([String].self, forKey: .receiptOrder)
            controlByTaskKey = try container.decodeIfPresent(
                [String: AgentTaskControlSnapshot].self,
                forKey: .controlByTaskKey
            ) ?? [:]
            controlReceiptByIdempotencyKey = try container.decodeIfPresent(
                [String: AgentTaskControlReceipt].self,
                forKey: .controlReceiptByIdempotencyKey
            ) ?? [:]
            creationTaskKeyByIdempotencyKey = try container.decodeIfPresent(
                [String: String].self,
                forKey: .creationTaskKeyByIdempotencyKey
            ) ?? [:]
            archiveByTaskKey = try container.decodeIfPresent(
                [String: AgentTaskArchiveSnapshot].self,
                forKey: .archiveByTaskKey
            ) ?? [:]
            archiveReceiptByIdempotencyKey = try container.decodeIfPresent(
                [String: AgentTaskArchiveReceipt].self,
                forKey: .archiveReceiptByIdempotencyKey
            ) ?? [:]
            parentTurnTerminalFacts = try container.decodeIfPresent(
                [AgentParentTurnTerminalFact].self,
                forKey: .parentTurnTerminalFacts
            ) ?? []
            childLaunchIntents = try container.decodeIfPresent(
                [String: ChildLaunchIntentRecord].self, forKey: .childLaunchIntents
            ) ?? [:]
            retryRunRuntimeBindings = try container.decodeIfPresent(
                [String: RetryRunRuntimeBinding].self, forKey: .retryRunRuntimeBindings
            ) ?? [:]
        }
    }

    private struct PersistenceEnvelope: Codable {
        let schemaVersion: Int
        let state: State

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, state
        }

        init(state: State) {
            schemaVersion = AgentTaskStore.currentSchemaVersion
            self.state = state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            switch schemaVersion {
            case 0:
                state = try State(from: decoder)
            case 1, 2, 3, AgentTaskStore.currentSchemaVersion:
                state = try container.decode(State.self, forKey: .state)
            default:
                throw AgentTaskStoreError.persistenceFailed
            }
        }
    }
    private var tasks: [String: AgentTaskSnapshot] = [:]
    private var taskKeyByRunID: [String: String] = [:]
    private var runs: [String: AgentRunSnapshot] = [:]
    private var attempts: [String: AgentTaskAttemptSnapshot] = [:]
    private var attemptIDByRunID: [String: String] = [:]
    private var events: [String: [AgentTaskEvent]] = [:]
    private var rejectedChildResults: [RejectedChildResultDiagnostic] = []
    // Live observation only; canonical receipts and redacted transcripts remain
    // the durable source after restart. Retained at most 100 calls per run.
    private var childToolActivitiesByRunID: [String: [ChildToolActivity]] = [:]
    // O-04 live mailbox: separate from the parent Composer queue; never replayed
    // after restart or routed to a replacement attempt. No extra execution grant.
    private var childInstructionsByRunID: [String: (attemptID: String, messages: [String])] = [:]
    // O-04 live orchestrate calls (foreground and background). Process-local
    // lifecycle bookkeeping only: never persisted and never an authority.
    private var liveChildOrchestrations: [String: LiveChildOrchestration] = [:]
    private var liveChildOrchestrationByLocator: [ChildTranscriptLocator: String] = [:]
    @TaskLocal static var childOrchestrationRegistrationID: String?
    private var receiptByRunID: [String: AgentTaskReceipt] = [:]
    private var controlByTaskKey: [String: AgentTaskControlSnapshot] = [:]
    private var controlReceiptByIdempotencyKey: [String: AgentTaskControlReceipt] = [:]
    private var creationTaskKeyByIdempotencyKey: [String: String] = [:]
    private var archiveByTaskKey: [String: AgentTaskArchiveSnapshot] = [:]
    private var archiveReceiptByIdempotencyKey: [String: AgentTaskArchiveReceipt] = [:]
    private var parentTurnTerminalFacts: [AgentParentTurnTerminalFact] = []
    private var childLaunchIntentsByID: [String: ChildLaunchIntentRecord] = [:]
    private var retryRunRuntimeBindingsByRunID: [String: RetryRunRuntimeBinding] = [:]
    // Which inert facts came from the actual durable reopen, not this process's
    // live queue. TurnController's integer counter can restart at 1.
    private var recoveredChildLaunchIntentIDs: Set<String> = []
    private var cancellationHandlesByRunID: [String: AgentTaskCancellationHandle] = [:]
    /// Only prompts currently suspended in a real ApprovalDelegate are navigable.
    /// Durable approvalRequired events remain diagnostic after recovery; they
    /// cannot recreate a live prompt or an approval capability.
    private var pendingApprovalByTaskKey: [String: [String: AgentTaskApprovalNavigationBinding]] = [:]
    private var recoveredRunningRunIDs: Set<String> = []
    /// Completion order is explicit; Dictionary iteration is never an API ordering contract.
    private var receiptOrder: [String] = []
    private let lock = NSLock()
    private var backgroundResultObserver: (@Sendable (BackgroundChildResultNotice) -> Void)?
    private var terminalObserver: (@Sendable (AgentTaskTerminalObservation) -> Void)?
    /// Process-local seqlock for consumers that assemble a projection through
    /// several separately locked ledger reads. Never persisted or used as an
    /// authority for task identity, control, or result settlement.
    private var taskCenterMutationVersion: UInt64 = 0
    private let persistenceURL: URL?
    private var persistenceBaseline: Data?
    private var allowsRecreateAfterStructuralFailure = false
    private var persistenceDiagnostic: AgentPersistenceDiagnostic?
    private let persistenceFault: AgentPersistenceFault

    public init() {
        persistenceURL = nil
        persistenceBaseline = nil
        persistenceDiagnostic = nil
        persistenceFault = .none
    }

    public init(persistenceURL: URL, persistenceFault: AgentPersistenceFault = .none) throws {
        self.persistenceURL = persistenceURL
        self.persistenceBaseline = nil
        self.persistenceDiagnostic = nil
        self.persistenceFault = persistenceFault
        try withPersistenceLock(for: persistenceURL) {
            let fileManager = FileManager.default
            let temporaryURL = persistenceURL.appendingPathExtension("tmp")
            Self.runInitializationRecoveryTestHook(for: persistenceURL)
            let durableLedgerExists = fileManager.fileExists(atPath: persistenceURL.path)
            if fileManager.fileExists(atPath: temporaryURL.path), !durableLedgerExists {
                throw AgentTaskStoreError.persistenceRecoveryFailed(
                    AgentPersistenceDiagnostic(
                        operation: "recover",
                        reason: "durable-ledger-missing",
                        message: "An incomplete temporary ledger was found without a durable ledger; recovery was halted and the temporary evidence was retained."
                    )
                )
            }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                do {
                    try fileManager.removeItem(at: temporaryURL)
                    self.persistenceDiagnostic = AgentPersistenceDiagnostic(
                        operation: "recover",
                        reason: "orphaned-temporary-file",
                        message: "An incomplete temporary ledger was discarded; the durable ledger was retained."
                    )
                } catch {
                    self.persistenceDiagnostic = AgentPersistenceDiagnostic(
                        operation: "recover",
                        reason: "orphaned-temporary-file-cleanup-failed",
                        message: "An incomplete temporary ledger could not be discarded; the durable ledger was retained."
                    )
                }
            }
            guard fileManager.fileExists(atPath: persistenceURL.path) else { return }
            do {
                let persistedData = try Data(contentsOf: persistenceURL)
                self.persistenceBaseline = persistedData
                let envelope = try JSONDecoder().decode(PersistenceEnvelope.self, from: persistedData)
                try Self.validate(envelope.state)
                restore(envelope.state)
                recoveredChildLaunchIntentIDs = Set(envelope.state.childLaunchIntents.keys)
                ensureControlSnapshots()
                recoveredRunningRunIDs = Set(envelope.state.runs.compactMap { runID, run in
                    run.status == .running ? runID : nil
                })
                if envelope.schemaVersion < Self.currentSchemaVersion {
                    try persistUnlocked(at: persistenceURL)
                }
            } catch let error as AgentTaskStoreError {
                throw error
            } catch {
                throw AgentTaskStoreError.persistenceFailed
            }
        }
    }

    /// Capture before a governor can queue or grant this actual request.
    /// This writes inert intent data only. The producer must still verify its
    /// live parent turn, capabilities and approval before any dispatch.
    public func recordChildLaunchIntent(
        _ intent: ChildLaunchRequestIntent, task: SubAgentTask,
        parentBinding: ParentContextSnapshotV1?, parentGoal: GoalEnvelope?
    ) throws -> ChildLaunchIntentRecord {
        lock.lock(); defer { lock.unlock() }
        let incoming = ChildLaunchIntentRecord(intent: intent, task: task,
            parentBinding: parentBinding, parentGoal: parentGoal,
            status: .queued, createdAt: Date())
        guard incoming.isWellFormed, intent.executionID == nil,
              intent.runID == nil, intent.attemptID == nil,
              intent.recoveredFromIntentID == nil else {
            throw ChildLaunchIntentError.invalidIntent
        }
        if let existing = childLaunchIntentsByID[intent.intentID] {
            guard existing.status == .queued, existing.intent.parent == intent.parent,
                  existing.intent.runID == nil, existing.intent.attemptID == nil,
                  existing.parentGoal == incoming.parentGoal,
                  Self.sameChildLaunchRequest(existing, incoming) else {
                throw ChildLaunchIntentError.conflictingIntent
            }
            return existing
        }
        let previous = childLaunchIntentsByID.values.filter {
            ($0.intent.parent.turnID != intent.parent.turnID
                || recoveredChildLaunchIntentIDs.contains($0.intent.intentID))
                && Self.sameChildLaunchOwner($0, incoming)
        }
        // Even an outward terminal cannot prove an admitted effect stopped.
        // The canonical ledger/checkpoint review must resolve it separately.
        guard !previous.contains(where: { $0.status == .admitted }) else {
            throw ChildLaunchIntentError.previousEffectRequiresReview
        }
        let queuedPrevious = previous.filter { $0.status == .queued }
        // An old queued task ID cannot be laundered into a changed context.
        // A new effect must use its own task identity, not claim this recovery.
        guard queuedPrevious.allSatisfy({ Self.sameChildLaunchRequest($0, incoming) }) else {
            throw ChildLaunchIntentError.conflictingIntent
        }
        let consumed = Set(childLaunchIntentsByID.values.compactMap {
            $0.intent.recoveredFromIntentID
        })
        let recoverable = previous.filter {
            $0.status == .queued && Self.sameChildLaunchRequest($0, incoming)
                && !consumed.contains($0.intent.intentID)
        }.sorted { $0.createdAt == $1.createdAt
            ? $0.intent.intentID < $1.intent.intentID : $0.createdAt < $1.createdAt }.first
        let linked = ChildLaunchRequestIntent(intentID: intent.intentID,
            taskID: intent.taskID, parent: intent.parent,
            parentContextSnapshotID: intent.parentContextSnapshotID,
            recoveredFromIntentID: recoverable?.intent.intentID)
        let record = ChildLaunchIntentRecord(intent: linked, task: task,
            parentBinding: parentBinding, parentGoal: parentGoal,
            status: .queued, createdAt: incoming.createdAt)
        return try transaction {
            childLaunchIntentsByID[intent.intentID] = record
            return record
        }
    }

    public func childLaunchIntent(intentID: String) -> ChildLaunchIntentRecord? {
        lock.lock(); defer { lock.unlock() }
        return childLaunchIntentsByID[intentID]
    }

    public func childLaunchIntents() -> [ChildLaunchIntentRecord] {
        lock.lock(); defer { lock.unlock() }
        return childLaunchIntentsByID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.intent.intentID < $1.intent.intentID
                : $0.createdAt < $1.createdAt
        }
    }

    /// Resolve the bounded original request only when its admitted launch is
    /// tied to an exact, settled failed or cancelled child result. This is source data for
    /// a *new user-initiated* retry, not permission to replay a side effect.
    /// An UNKNOWN submission or missing historical request stays unavailable.
    public func settledFailedChildLaunchIntent(
        taskID: String, originalParentID: String, runID: String
    ) -> ChildLaunchIntentRecord? {
        lock.lock(); defer { lock.unlock() }
        return settledFailedChildLaunchIntentLocked(
            taskID: taskID, originalParentID: originalParentID, runID: runID
        )
    }

    private func settledFailedChildLaunchIntentLocked(
        taskID: String, originalParentID: String, runID: String
    ) -> ChildLaunchIntentRecord? {
        guard let key = taskKeyByRunID[runID],
              let task = tasks[key], task.taskID == taskID,
              task.parentID == originalParentID,
              let attemptID = attemptIDByRunID[runID],
              let runStatus = runs[runID]?.status,
              let attemptStatus = attempts[attemptID]?.status,
              let receipt = receiptByRunID[runID],
              let envelope = receipt.childResultEnvelope,
              envelope.runID == runID, envelope.attemptID == attemptID,
              envelope.taskID == taskID, !envelope.isPartial,
              !(events[runID] ?? []).contains(where: { $0.kind == .submissionUnknown }),
              !parentTurnTerminalFacts.contains(where: { $0.children.contains(where: {
                  $0.runID == runID && $0.outcome == .needsUserReview
              }) })
        else { return nil }
        switch (runStatus, attemptStatus, receipt.outcome) {
        case (.failed, .failed, .failed),
             (.cancelled, .cancelled, .cancelled):
            break
        default:
            return nil
        }
        let matching = childLaunchIntentsByID.values.filter { record in
            record.status == .admitted
                && record.intent.taskID == taskID
                && record.intent.parent == (retryRunRuntimeBindingsByRunID[runID]?.parent
                    ?? task.parentRuntimeIdentity)
                && record.intent.runID == runID
                && record.intent.attemptID == attemptID
                && record.intent.executionID == envelope.childExecutionID
        }
        return matching.count == 1 ? matching[0] : nil
    }

    /// A user retry has a separate admission path from crash recovery of a
    /// queued launch. An old admitted request is never automatically replayed;
    /// only a settled failed/cancelled original payload with an exact child
    /// result can be copied under a *new*
    /// already-bound parent/Goal/run. Effect-ledger review remains a caller
    /// precondition before requesting the governor's current permit.
    public func recordRetryChildLaunchIntent(
        _ intent: ChildLaunchRequestIntent, originalRunID: String,
        retryRunID: String, task: SubAgentTask,
        parentBinding: ParentContextSnapshotV1,
        parentGoal: GoalEnvelope
    ) throws -> ChildLaunchIntentRecord {
        lock.lock(); defer { lock.unlock() }
        guard let retry = retryRunRuntimeBindingsByRunID[retryRunID],
              let original = settledFailedChildLaunchIntentLocked(
                  taskID: intent.taskID,
                  originalParentID: retry.originalParentID,
                  runID: originalRunID
              ),
              intent.isWellFormed, intent.executionID == nil,
              intent.runID == nil, intent.attemptID == nil,
              intent.recoveredFromIntentID == nil,
              intent.parent == retry.parent,
              intent.taskID == retry.taskID,
              intent.parentContextSnapshotID == task.parentContextSnapshotID,
              parentGoal == retry.parentGoal,
              task.id == original.task.id,
              task.title == original.task.title,
              task.instructions == original.task.instructions,
              task.context == original.task.context,
              task.expectedOutput == original.task.expectedOutput,
              task.agentType == original.task.agentType,
              task.requiredCapabilities == original.task.requiredCapabilities,
              task.resourceRequest == original.task.resourceRequest,
              task.bindingSource == original.task.bindingSource,
              task.executionID == nil,
              parentBinding == retry.child.providerSnapshot,
              runs[retryRunID]?.status == .running,
              attempts[retry.attemptID]?.status == .running,
              !childLaunchIntentsByID.values.contains(where: {
                  $0.intent.runID == retryRunID
              }) else {
            throw ChildLaunchIntentError.conflictingIntent
        }
        let incoming = ChildLaunchIntentRecord(
            intent: intent, task: task, parentBinding: parentBinding,
            parentGoal: parentGoal, status: .queued, createdAt: Date()
        )
        guard incoming.isWellFormed else { throw ChildLaunchIntentError.invalidIntent }
        if let existing = childLaunchIntentsByID[intent.intentID] {
            guard existing == incoming else { throw ChildLaunchIntentError.conflictingIntent }
            return existing
        }
        return try transaction {
            childLaunchIntentsByID[intent.intentID] = incoming
            return incoming
        }
    }

    public func markChildLaunchIntent(intentID: String, admitted: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction { try markChildLaunchIntentLocked(intentID: intentID, admitted: admitted) }
    }

    private func markChildLaunchIntentLocked(intentID: String, admitted: Bool) throws {
        guard let record = childLaunchIntentsByID[intentID],
              record.status == .queued || (!admitted && record.intent.runID == nil) else {
            throw ChildLaunchIntentError.conflictingIntent
        }
        childLaunchIntentsByID[intentID] = ChildLaunchIntentRecord(
            intent: record.intent, task: record.task,
            parentBinding: record.parentBinding, parentGoal: record.parentGoal,
            status: admitted ? .admitted : .notAdmitted, createdAt: record.createdAt)
    }

    /// Binds only the canonical run/attempt just created by runChild. Neither
    /// queued metadata nor decoded identities can manufacture an attempt.
    public func bindChildLaunchIntent(intentID: String, executionTask: SubAgentTask,
                                      runID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try bindChildLaunchIntentLocked(intentID: intentID, executionTask: executionTask, runID: runID)
        }
    }

    private func bindChildLaunchIntentLocked(intentID: String, executionTask: SubAgentTask,
                                            runID: String) throws {
        guard let record = childLaunchIntentsByID[intentID], record.status == .admitted,
              record.intent.runID == nil, executionTask.id == record.intent.taskID,
              let executionID = executionTask.executionID,
              let key = taskKeyByRunID[runID], let task = tasks[key],
              task.taskID == record.intent.taskID,
              (retryRunRuntimeBindingsByRunID[runID].map {
                  task.parentID == $0.originalParentID
                      && record.intent.parent == $0.parent
                      && record.parentGoal == $0.parentGoal
                      && record.parentBinding == $0.child.providerSnapshot
                      && $0.child.matchesVerifiedExecutionID(executionID)
              } ?? (task.parentID == record.intent.parent.taskID
                  && task.parentRuntimeIdentity == record.intent.parent
                  && task.parentContextSnapshotID == record.intent.parentContextSnapshotID
                  && task.providerID == executionTask.providerID
                  && task.modelID == executionTask.modelID
                  && task.configurationFingerprint == executionTask.configurationFingerprint
                  && (task.childRuntimeIdentity?.matchesVerifiedExecutionID(executionID)
                      ?? (record.parentGoal == nil)))),
              executionTask.parentContextSnapshotID == record.intent.parentContextSnapshotID,
              runs[runID]?.status == .running,
              let attemptID = attemptIDByRunID[runID], attempts[attemptID]?.runID == runID else {
            throw ChildLaunchIntentError.conflictingIntent
        }
        let intent = ChildLaunchRequestIntent(intentID: record.intent.intentID,
            taskID: record.intent.taskID, parent: record.intent.parent,
            executionID: executionID,
            parentContextSnapshotID: record.intent.parentContextSnapshotID,
            runID: runID, attemptID: attemptID,
            recoveredFromIntentID: record.intent.recoveredFromIntentID)
        childLaunchIntentsByID[intentID] = ChildLaunchIntentRecord(
            intent: intent, task: record.task, parentBinding: record.parentBinding,
            parentGoal: record.parentGoal, status: .admitted, createdAt: record.createdAt)
    }

    private static func sameChildLaunchRequest(_ a: ChildLaunchIntentRecord,
                                               _ b: ChildLaunchIntentRecord) -> Bool {
        // The new live producer owns its current parent/Goal. Old values stay
        // in the previous record for history and convey no authorization.
        a.task == b.task && a.parentBinding == b.parentBinding
            && a.intent.parentContextSnapshotID == b.intent.parentContextSnapshotID
            && sameChildLaunchOwner(a, b)
    }

    private static func sameChildLaunchOwner(_ a: ChildLaunchIntentRecord,
                                             _ b: ChildLaunchIntentRecord) -> Bool {
        a.intent.taskID == b.intent.taskID
            && a.intent.parent.sessionID == b.intent.parent.sessionID
            && a.intent.parent.conversationID == b.intent.parent.conversationID
            && a.intent.parent.actorID == b.intent.parent.actorID
    }

    /// Publish one ordinary child's startup off the cooperative executor.
    /// The previously admitted launch intent remains intact if startup fails.
    func publishInitialChildRun(
        task: SubAgentTask, executionTask: SubAgentTask, parentID: String, runID: String,
        routeReceiptID: String?, parentRuntimeIdentity: ParentRuntimeIdentity?,
        childRuntimeIdentity: ChildRuntimeIdentity?, parentGoal: GoalEnvelope?,
        launchIntentID: String?, capabilityDenied: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            childStartupQueue.async { [self] in
                do {
                    try commitInitialChildRun(
                        task: task, executionTask: executionTask, parentID: parentID, runID: runID,
                        routeReceiptID: routeReceiptID, parentRuntimeIdentity: parentRuntimeIdentity,
                        childRuntimeIdentity: childRuntimeIdentity, parentGoal: parentGoal,
                        launchIntentID: launchIntentID, capabilityDenied: capabilityDenied
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func commitInitialChildRun(
        task: SubAgentTask, executionTask: SubAgentTask, parentID: String, runID: String,
        routeReceiptID: String?, parentRuntimeIdentity: ParentRuntimeIdentity?,
        childRuntimeIdentity: ChildRuntimeIdentity?, parentGoal: GoalEnvelope?,
        launchIntentID: String?, capabilityDenied: Bool
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            _ = try enqueueLocked(
                taskID: task.id, parentID: parentID,
                providerID: executionTask.providerID, modelID: executionTask.modelID,
                configurationFingerprint: executionTask.configurationFingerprint,
                routeReceiptID: routeReceiptID,
                parentContextSnapshotID: executionTask.parentContextSnapshotID,
                parentRuntimeIdentity: parentRuntimeIdentity, childRuntimeIdentity: childRuntimeIdentity,
                parentGoal: parentGoal, dispatchHumanTitle: task.title
            )
            _ = try startRunLocked(taskID: task.id, taskKey: taskKey(taskID: task.id, parentID: parentID), runID: runID)
            if let launchIntentID, childLaunchIntentsByID[launchIntentID] != nil {
                if capabilityDenied {
                    // A denied capability has no launchable child identity.
                    try markChildLaunchIntentLocked(intentID: launchIntentID, admitted: false)
                } else {
                    try bindChildLaunchIntentLocked(intentID: launchIntentID, executionTask: executionTask, runID: runID)
                }
            }
            _ = try appendEventLocked(runID: runID, kind: .started)
        }
    }

    func publishChildRunStarted(
        executionTask: SubAgentTask, runID: String, launchIntentID: String?, capabilityDenied: Bool
    ) throws {
        if let launchIntentID, childLaunchIntent(intentID: launchIntentID) != nil {
            if capabilityDenied {
                // A denied capability has no launchable child identity.
                // Retire its unused admission before recording the failed fact.
                try markChildLaunchIntent(intentID: launchIntentID, admitted: false)
            } else {
                try bindChildLaunchIntent(intentID: launchIntentID, executionTask: executionTask, runID: runID)
            }
        }
        _ = try appendEvent(runID: runID, kind: .started, detail: "child-dispatched")
    }

    public func enqueue(taskID: String, parentID: String, providerID: String?, modelID: String?, configurationFingerprint: String? = nil, routeReceiptID: String? = nil, parentContextSnapshotID: String? = nil, parentRuntimeIdentity: ParentRuntimeIdentity? = nil, childRuntimeIdentity: ChildRuntimeIdentity? = nil, parentGoal: GoalEnvelope? = nil, dispatchHumanTitle: String? = nil) throws -> AgentTaskSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            try enqueueLocked(
                taskID: taskID, parentID: parentID, providerID: providerID, modelID: modelID,
                configurationFingerprint: configurationFingerprint, routeReceiptID: routeReceiptID,
                parentContextSnapshotID: parentContextSnapshotID,
                parentRuntimeIdentity: parentRuntimeIdentity, childRuntimeIdentity: childRuntimeIdentity,
                parentGoal: parentGoal, dispatchHumanTitle: dispatchHumanTitle
            )
        }
    }

    private func enqueueLocked(
        taskID: String, parentID: String, providerID: String?, modelID: String?,
        configurationFingerprint: String?, routeReceiptID: String?, parentContextSnapshotID: String?,
        parentRuntimeIdentity: ParentRuntimeIdentity?, childRuntimeIdentity: ChildRuntimeIdentity?,
        parentGoal: GoalEnvelope?, dispatchHumanTitle: String?
    ) throws -> AgentTaskSnapshot {
        if let parentRuntimeIdentity {
            guard parentRuntimeIdentity.isValid, parentRuntimeIdentity.taskID == parentID else {
                throw AgentTaskStoreError.childResultIdentityMismatch
            }
        }
        if let childRuntimeIdentity {
            guard let parentRuntimeIdentity, let parentGoal,
                  childRuntimeIdentity.childTaskID == taskID,
                  childRuntimeIdentity.parentTaskID == parentID,
                  childRuntimeIdentity.hasVerifiedRootBoundary(
                    parent: parentRuntimeIdentity, goal: parentGoal
                  ),
                  (try? childRuntimeIdentity.requireVerifiedGeneration()) != nil else {
                throw AgentTaskStoreError.childResultIdentityMismatch
            }
        }
        let key = taskKey(taskID: taskID, parentID: parentID)
        guard tasks[key] == nil else { throw AgentTaskStoreError.duplicateTask }
        let snapshot = AgentTaskSnapshot(taskID: taskID, parentID: parentID, parentContextSnapshotID: parentContextSnapshotID, providerID: providerID, modelID: modelID, configurationFingerprint: configurationFingerprint, routeReceiptID: routeReceiptID, status: .queued, dispatchHumanTitle: dispatchHumanTitle, parentRuntimeIdentity: parentRuntimeIdentity, childRuntimeIdentity: childRuntimeIdentity)
        guard Self.hasValidOneLevelChildGraph(Array(tasks.values) + [snapshot]) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        tasks[key] = snapshot
        controlByTaskKey[key] = AgentTaskControlSnapshot(
            taskID: taskID,
            parentID: parentID,
            state: .active,
            controlRevision: 0,
            runID: nil
        )
        return snapshot
    }

    public struct IdempotentEnqueueResult: Sendable, Equatable {
        public let snapshot: AgentTaskSnapshot
        public let didCreate: Bool

        public init(snapshot: AgentTaskSnapshot, didCreate: Bool) {
            self.snapshot = snapshot
            self.didCreate = didCreate
        }
    }

    /// Enqueues one session-created task with durable, replay-safe provenance.
    /// An exact request replay returns the original snapshot without creating a
    /// second task; a changed request under the same key fails closed.
    public func enqueueIdempotent(
        taskID: String,
        parentID: String,
        providerID: String?,
        modelID: String?,
        configurationFingerprint: String? = nil,
        routeReceiptID: String? = nil,
        parentContextSnapshotID: String? = nil,
        creation: SessionActionCreationMetadata
    ) throws -> IdempotentEnqueueResult {
        lock.lock(); defer { lock.unlock() }
        let key = taskKey(taskID: taskID, parentID: parentID)
        // The index was introduced after the task payload. During recovery a
        // valid older ledger may contain creation metadata but no index entry;
        // scan that durable source before admitting a new task. This prevents
        // a replay under a different task ID from creating a second child.
        let indexedKey = creationTaskKeyByIdempotencyKey[creation.idempotencyKey]
        let recoveredKey = indexedKey ?? tasks.first {
            $0.value.creation?.idempotencyKey == creation.idempotencyKey
        }?.key
        if let existingKey = recoveredKey {
            guard let existing = tasks[existingKey], existing.taskID == taskID,
                  existing.parentID == parentID, existing.creation == creation,
                  existing.providerID == providerID,
                  existing.modelID == modelID,
                  existing.configurationFingerprint == configurationFingerprint,
                  existing.routeReceiptID == routeReceiptID,
                  existing.parentContextSnapshotID == parentContextSnapshotID else {
                throw AgentTaskStoreError.creationIdempotencyConflict
            }
            if indexedKey == nil {
                return try transaction {
                    creationTaskKeyByIdempotencyKey[creation.idempotencyKey] = existingKey
                    return IdempotentEnqueueResult(snapshot: existing, didCreate: false)
                }
            }
            return IdempotentEnqueueResult(snapshot: existing, didCreate: false)
        }
        if let existing = tasks[key] {
            guard existing.creation == creation,
                  existing.providerID == providerID,
                  existing.modelID == modelID,
                  existing.configurationFingerprint == configurationFingerprint,
                  existing.routeReceiptID == routeReceiptID,
                  existing.parentContextSnapshotID == parentContextSnapshotID else {
                throw AgentTaskStoreError.duplicateTask
            }
            return try transaction {
                creationTaskKeyByIdempotencyKey[creation.idempotencyKey] = key
                return IdempotentEnqueueResult(snapshot: existing, didCreate: false)
            }
        }
        let snapshot = AgentTaskSnapshot(
            taskID: taskID,
            parentID: parentID,
            parentContextSnapshotID: parentContextSnapshotID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: configurationFingerprint,
            routeReceiptID: routeReceiptID,
            status: .queued,
            creation: creation
        )
        guard Self.hasValidOneLevelChildGraph(Array(tasks.values) + [snapshot]) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        return try transaction {
            tasks[key] = snapshot
            creationTaskKeyByIdempotencyKey[creation.idempotencyKey] = key
            controlByTaskKey[key] = AgentTaskControlSnapshot(
                taskID: taskID,
                parentID: parentID,
                state: .active,
                controlRevision: 0,
                runID: nil
            )
            return IdempotentEnqueueResult(snapshot: snapshot, didCreate: true)
        }
    }

    public func startRun(taskID: String, runID: String) throws -> AgentRunSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let taskKey = tasks.values.first(where: { $0.taskID == taskID }).map({ taskKey(taskID: $0.taskID, parentID: $0.parentID) }) else {
            throw AgentTaskStoreError.unknownTask
        }
        return try transaction {
            try startRunLocked(taskID: taskID, taskKey: taskKey, runID: runID)
        }
    }

    /// Closes a queued task when run initialization fails before a run exists.
    /// This prevents orphaned queued records with no terminal receipt.
    public func abortQueued(taskID: String, parentID: String, reason: String = "lifecycle-initialization-failed") throws {
        lock.lock(); defer { lock.unlock() }
        let key = taskKey(taskID: taskID, parentID: parentID)
        guard let task = tasks[key] else { throw AgentTaskStoreError.unknownTask }
        guard task.status == .queued else { return }
        try transaction {
            tasks[key] = AgentTaskSnapshot(
                taskID: task.taskID,
                parentID: task.parentID,
                parentContextSnapshotID: task.parentContextSnapshotID,
                providerID: task.providerID,
                modelID: task.modelID,
                configurationFingerprint: task.configurationFingerprint,
                routeReceiptID: task.routeReceiptID,
                status: .failed,
                creation: task.creation, dispatchHumanTitle: task.dispatchHumanTitle,
                archivedAt: task.archivedAt,
                childTranscriptLocator: task.childTranscriptLocator,
                parentRuntimeIdentity: task.parentRuntimeIdentity,
                childRuntimeIdentity: task.childRuntimeIdentity
            )
            events["queued:\(key)"] = [AgentTaskEvent(runID: "queued:\(key)", parentContextSnapshotID: task.parentContextSnapshotID, sequence: 1, kind: .failed, detail: "execution-failed")]
            if let control = controlByTaskKey[key] {
                controlByTaskKey[key] = AgentTaskControlSnapshot(
                    taskID: control.taskID,
                    parentID: control.parentID,
                    state: .terminal,
                    controlRevision: control.controlRevision + 1,
                    runID: nil
                )
            }
        }
    }

    public func startRun(taskID: String, parentID: String, runID: String) throws -> AgentRunSnapshot {
        lock.lock(); defer { lock.unlock() }
        let taskKey = taskKey(taskID: taskID, parentID: parentID)
        guard tasks[taskKey] != nil else { throw AgentTaskStoreError.unknownTask }
        return try transaction {
            try startRunLocked(taskID: taskID, taskKey: taskKey, runID: runID)
        }
    }

    private func startRunLocked(taskID: String, taskKey: String, runID: String) throws -> AgentRunSnapshot {
        guard runs[runID] == nil else { throw AgentTaskStoreError.duplicateRun }
        guard let task = tasks[taskKey] else { throw AgentTaskStoreError.unknownTask }
        guard task.status != .running else { throw AgentTaskStoreError.taskAlreadyRunning }
        let run = AgentRunSnapshot(runID: runID, taskID: taskID, parentContextSnapshotID: task.parentContextSnapshotID, status: .running)
        let attemptID = "\(runID):attempt:1"
        let attempt = AgentTaskAttemptSnapshot(attemptID: attemptID, runID: runID, parentContextSnapshotID: task.parentContextSnapshotID, attempt: 1, providerID: task.providerID, modelID: tasks[taskKey]?.modelID, configurationFingerprint: tasks[taskKey]?.configurationFingerprint, status: .running, startedAt: Date())
        runs[runID] = run
        attempts[attemptID] = attempt
        attemptIDByRunID[runID] = attemptID
        taskKeyByRunID[runID] = taskKey
        updateTask(taskKey, status: .running, clearChildTranscriptLocator: true)
        if let control = controlByTaskKey[taskKey] {
            controlByTaskKey[taskKey] = AgentTaskControlSnapshot(
                taskID: control.taskID,
                parentID: control.parentID,
                state: control.state,
                controlRevision: control.controlRevision,
                runID: runID
            )
        }
        return run
    }

    /// Closes a run whose setup failed after run creation but before dispatch.
    /// The terminal event and redacted receipt are written through the same atomic path.
    public func abortRunInitialization(runID: String, reason: String = "lifecycle-initialization-failed") throws -> AgentTaskReceipt {
        try finish(runID: runID, eventKind: .failed, detail: reason, outcome: .failed(reason: reason))
    }

    /// The detail argument is intentionally discarded; ledger events retain only a bounded category.
    public func appendEvent(runID: String, kind: AgentTaskEventKind, detail: String) throws -> AgentTaskEvent {
        lock.lock(); defer { lock.unlock() }
        return try transaction { try appendEventLocked(runID: runID, kind: kind) }
    }

    private func appendEventLocked(runID: String, kind: AgentTaskEventKind) throws -> AgentTaskEvent {
        guard let run = runs[runID] else { throw AgentTaskStoreError.unknownRun }
        guard run.status == .running else { throw AgentTaskStoreError.runClosed }
        guard !Self.isTerminal(kind) else { throw AgentTaskStoreError.terminalEventRequiresSettlement }
        let sequence = (events[runID]?.last?.sequence ?? 0) + 1
        let parentContextSnapshotID = taskKeyByRunID[runID].flatMap { tasks[$0]?.parentContextSnapshotID }
        let event = AgentTaskEvent(
            runID: runID,
            parentContextSnapshotID: parentContextSnapshotID,
            sequence: sequence,
            kind: kind,
            detail: Self.eventCategory(for: kind)
        )
        events[runID, default: []].append(event)
        return event
    }

    /// Called only by the trusted child orchestration path immediately before
    /// forwarding a bound request to its existing approval delegate. The event
    /// is persisted first; a failed write must leave no navigable prompt.
    internal func beginPendingChildApproval(
        taskRunID: String,
        taskAttemptID: String,
        childIdentity: ChildRuntimeIdentity,
        request: ApprovalRequest,
        now: Date = Date()
    ) throws -> AgentTaskApprovalNavigationBinding {
        lock.lock(); defer { lock.unlock() }
        guard childIdentity.isValid,
              (try? childIdentity.requireVerifiedGeneration()) != nil,
              let generationID = childIdentity.generationID else {
            throw AgentTaskStoreError.approvalNavigationIdentityMismatch
        }
        // Navigation metadata is not an authorization context. Preserve the
        // original bound path; Composer retains its own identity and controller.
        let digest: String, approvalRunID: String, approvalAttemptID: String, expiresAt: Date
        if let approval = request.binding {
            guard approval.isValid, approval.expiresAt > now,
                  request.requestID == request.callID, request.callID == approval.effectID,
                  approval.actorID == "child:\(childIdentity.childSessionID)",
                  approval.sessionID == childIdentity.childSessionID,
                  approval.turnID == childIdentity.cancelGeneration,
                  approval.taskID == childIdentity.childTaskID,
                  approval.runID == generationID, approval.attemptID == generationID,
                  approval.grantEpoch == generationID, approval.scope == childIdentity.scopeID,
                  request.identityDigest == approval.identityDigest else {
                throw AgentTaskStoreError.approvalNavigationIdentityMismatch
            }
            digest = approval.identityDigest; approvalRunID = approval.runID
            approvalAttemptID = approval.attemptID; expiresAt = approval.expiresAt
        } else {
            guard request.composerMode != nil, request.requiresApproval,
                  let context = AgentExecutionContext.current,
                  context.offeredToolNames?.contains(request.toolName) == true,
                  context.childToolRuntimeBinding?.boundary.identity == childIdentity,
                  let snapshot = context.composerSnapshot, let facts = context.composerPolicyFacts,
                  snapshot.sessionID == childIdentity.childSessionID,
                  snapshot.turnID == childIdentity.cancelGeneration,
                  snapshot.taskID == childIdentity.childTaskID,
                  request.sessionID == snapshot.sessionID, request.turnID == snapshot.turnID,
                  request.taskID == snapshot.taskID, request.attemptID == snapshot.attemptID,
                  request.messageID == snapshot.messageID, request.composerMode == snapshot.mode.rawValue,
                  request.approvalScope == snapshot.approvalScope.rawValue,
                  request.policyRevision == snapshot.policyRevision, request.grantEpoch == snapshot.grantEpoch,
                  facts.workspaceID == snapshot.workspaceID, facts.revision == snapshot.policyRevision,
                  facts.grantEpoch == snapshot.grantEpoch, !facts.revoked, !facts.leaseID.isEmpty,
                  facts.expiresAt.timeIntervalSinceReferenceDate.isFinite, facts.expiresAt > now,
                  let presentation = ApprovalPresentationContext.current,
                  presentation.makeFact(for: request, stage: .presented, occurredAt: now) != nil,
                  let identityDigest = request.identityDigest else {
                throw AgentTaskStoreError.approvalNavigationIdentityMismatch
            }
            // These are the existing mutation-lock tools, not an action grant.
            // Other tools (including shell) retain their original parent policy.
            if ["file_write", "file_edit", "file_delete"].contains(request.toolName) {
                guard let lease = ToolFileMutationLease.current, lease.matchesApprovalContext(presentation) else {
                    throw AgentTaskStoreError.approvalNavigationIdentityMismatch
                }
            }
            if let prepared = ChildDeletionReviewPreparationContext.current {
                guard request.toolName == "file_delete", prepared.matches(request) else {
                    throw AgentTaskStoreError.approvalNavigationIdentityMismatch
                }
            }
            if let requestExpiry = request.expiresAt {
                guard requestExpiry.timeIntervalSinceReferenceDate.isFinite, requestExpiry > now else {
                    throw AgentTaskStoreError.approvalNavigationIdentityMismatch
                }
                expiresAt = min(requestExpiry, facts.expiresAt)
            } else { expiresAt = facts.expiresAt }
            digest = identityDigest; approvalRunID = presentation.compositeKey.operationID
            approvalAttemptID = presentation.compositeKey.attemptID
        }
        guard request.taskID == childIdentity.childTaskID,
              let canonical = taskRunBindingLocked(runID: taskRunID),
              canonical.task.taskID == childIdentity.childTaskID,
              {
                  // A retry retains the original Task Center row while its
                  // verified runtime belongs to a fresh parent turn. Match the
                  // same immutable backlinks used by verifiedParentSessionID.
                  if let retry = retryRunRuntimeBindingsByRunID[taskRunID] {
                      guard let runtime = AgentExecutionContext.current,
                            let bound = runtime.childToolRuntimeBinding,
                            let locator = canonical.task.childTranscriptLocator else { return false }
                      return retry.taskID == canonical.task.taskID
                          && retry.originalParentID == canonical.task.parentID
                          && retry.runID == taskRunID && retry.attemptID == taskAttemptID
                          && retry.child == childIdentity
                          && childIdentity.hasVerifiedRootBoundary(parent: retry.parent, goal: retry.parentGoal)
                          && bound.parent == retry.parent && bound.boundary.identity == childIdentity
                          && bound.locator == locator
                          && locator.parentID == canonical.task.parentID
                          && locator.runtimeParentID == retry.parent.taskID
                          && locator.runID == taskRunID && locator.attemptID == taskAttemptID
                          && locator.childSessionID == childIdentity.childSessionID
                  }
                  // An unbound retry locator cannot fall back to ordinary-child identity.
                  return canonical.task.parentID == childIdentity.parentTaskID
                      && canonical.task.childTranscriptLocator?.runtimeParentID == nil
              }(),
              canonical.task.status == .running,
              canonical.run.status == .running,
              canonical.attempt.attemptID == taskAttemptID,
              canonical.attempt.status == .running,
              canonical.control.state == .active,
              let locator = canonical.task.childTranscriptLocator,
              locator.childSessionID == childIdentity.childSessionID,
              locator.parentSessionID == childIdentity.parentSessionID,
              locator.runID == taskRunID,
              locator.attemptID == taskAttemptID else {
            throw AgentTaskStoreError.approvalNavigationIdentityMismatch
        }
        let key = canonical.taskKey
        guard pendingApprovalByTaskKey[key]?[request.requestID] == nil else {
            throw AgentTaskStoreError.approvalNavigationConflict
        }
        let navigation = AgentTaskApprovalNavigationBinding(
            taskID: canonical.task.taskID,
            parentID: canonical.task.parentID,
            taskRunID: taskRunID,
            taskAttemptID: taskAttemptID,
            childSessionID: childIdentity.childSessionID,
            childGenerationID: generationID,
            approvalRequestID: request.requestID,
            approvalBindingDigest: digest,
            approvalRunID: approvalRunID,
            approvalAttemptID: approvalAttemptID,
            expiresAt: expiresAt
        )
        let sequence = (events[taskRunID]?.last?.sequence ?? 0) + 1
        let event = AgentTaskEvent(
            runID: taskRunID,
            parentContextSnapshotID: canonical.task.parentContextSnapshotID,
            sequence: sequence,
            kind: .approvalRequired,
            detail: Self.eventCategory(for: .approvalRequired)
        )
        try transaction { events[taskRunID, default: []].append(event) }
        pendingApprovalByTaskKey[key, default: [:]][request.requestID] = navigation
        return navigation
    }

    internal func endPendingChildApproval(_ navigation: AgentTaskApprovalNavigationBinding) {
        lock.lock(); defer { lock.unlock() }
        let key = taskKey(taskID: navigation.taskID, parentID: navigation.parentID)
        guard pendingApprovalByTaskKey[key]?[navigation.approvalRequestID] == navigation else { return }
        pendingApprovalByTaskKey[key]?.removeValue(forKey: navigation.approvalRequestID)
        if pendingApprovalByTaskKey[key]?.isEmpty == true { pendingApprovalByTaskKey.removeValue(forKey: key) }
    }

    /// Presentation progress from the existing executor-dispatch fact, never
    /// from an approval decision. Late callbacks cannot revive a retired run.
    @discardableResult
    internal func recordChildToolRunningPhase(
        _ fact: ToolExecutionPhaseFact, taskRunID: String, taskAttemptID: String,
        runtime: AgentChildToolRuntimeBinding
    ) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let child = runtime.boundary.identity
        let key = fact.compositeKey
        let execution = fact.executionIdentity
        guard fact.phase == .running, key.isValid, execution.isValid,
              runtime.boundary.tools.contains(where: { $0.name == fact.toolName }),
              child.isValid, (try? child.requireVerifiedGeneration()) != nil,
              let generation = child.generationID,
              execution.turn.sessionID == child.childSessionID,
              execution.turn.turnID == child.cancelGeneration,
              execution.turn.messageID == child.childTaskID,
              execution.operationID == generation,
              key.sessionID == execution.turn.sessionID,
              key.turnID == execution.turn.turnID,
              key.messageID == execution.turn.messageID,
              key.operationID == execution.operationID,
              key.attemptNumber == execution.attempt,
              runtime.parent.isValid,
              runtime.parent.taskID == child.parentTaskID,
              runtime.parent.sessionID == child.parentSessionID,
              runtime.parent.conversationID == child.parentConversationID,
              let canonical = taskRunBindingLocked(runID: taskRunID),
              canonical.task.taskID == child.childTaskID,
              canonical.task.status == .running, canonical.run.status == .running,
              canonical.attempt.attemptID == taskAttemptID,
              canonical.attempt.status == .running, canonical.control.state == .active,
              canonical.task.childTranscriptLocator == runtime.locator,
              runtime.locator.taskID == child.childTaskID,
              runtime.locator.childSessionID == child.childSessionID,
              runtime.locator.parentSessionID == child.parentSessionID,
              runtime.locator.parentID == canonical.task.parentID,
              runtime.locator.runID == taskRunID,
              runtime.locator.attemptID == taskAttemptID,
              pendingApprovalByTaskKey[canonical.taskKey]?.isEmpty != false else { return false }
        if let retry = retryRunRuntimeBindingsByRunID[taskRunID] {
            guard retry.taskID == canonical.task.taskID,
                  retry.originalParentID == canonical.task.parentID,
                  retry.runID == taskRunID, retry.attemptID == taskAttemptID,
                  retry.parent == runtime.parent, retry.child == child,
                  runtime.locator.runtimeParentID == retry.parent.taskID,
                  child.hasVerifiedRootBoundary(parent: retry.parent, goal: retry.parentGoal) else { return false }
        } else {
            guard canonical.task.parentRuntimeIdentity == runtime.parent,
                  canonical.task.childRuntimeIdentity == child,
                  canonical.task.parentID == child.parentTaskID,
                  runtime.locator.runtimeParentID == nil else { return false }
        }
        // Only a still-waiting projection needs a resume event. Preserve all
        // other progress and prevent duplicate callbacks adding ledger noise.
        guard events[taskRunID]?.last?.kind == .approvalRequired else { return false }
        let event = AgentTaskEvent(runID: taskRunID,
            parentContextSnapshotID: canonical.task.parentContextSnapshotID,
            sequence: (events[taskRunID]?.last?.sequence ?? 0) + 1,
            kind: .progress, detail: Self.eventCategory(for: .progress))
        try transaction { events[taskRunID, default: []].append(event) }
        return true
    }

    /// A task-center row can navigate only one unambiguous, live request on
    /// the current canonical attempt. Old persisted events never qualify.
    public func currentPendingApprovalBinding(taskID: String, parentID: String, now: Date = Date()) -> AgentTaskApprovalNavigationBinding? {
        lock.lock(); defer { lock.unlock() }
        let key = taskKey(taskID: taskID, parentID: parentID)
        guard let control = controlByTaskKey[key],
              control.state == .active,
              let runID = control.runID,
              let canonical = taskRunBindingLocked(runID: runID),
              canonical.task.taskID == taskID,
              canonical.task.parentID == parentID,
              canonical.task.status == .running,
              canonical.run.status == .running,
              canonical.attempt.status == .running,
              let pending = pendingApprovalByTaskKey[key] else { return nil }
        let current = pending.values.filter {
            $0.taskRunID == runID
                && $0.taskAttemptID == canonical.attempt.attemptID
                && $0.expiresAt > now
                && canonical.task.childTranscriptLocator?.childSessionID == $0.childSessionID
        }
        return current.count == 1 ? current[0] : nil
    }

    /// Separate from the existing terminal notification observer; never replaces it.
    public func setBackgroundResultObserver(_ observer: (@Sendable (BackgroundChildResultNotice) -> Void)?) {
        lock.withLock { backgroundResultObserver = observer }
    }

    func deliverBackgroundResults(parent: ParentRuntimeIdentity, executionIdentity: AgentExecutionIdentity,
                                  tasks: [SubAgentTask], reports: [SubAgentReport],
                                  parentAuthorityCheck: @Sendable () async -> Bool,
                                  resultProjection: (@Sendable (SubAgentReport) -> String?)? = nil) async {
        guard executionIdentity.isValid, await parentAuthorityCheck() else { return }
        let observer = lock.withLock { backgroundResultObserver }
        guard let observer else { return }
        for report in reports {
            guard await parentAuthorityCheck() else { return }
            guard let task = tasks.first(where: { $0.id == report.taskID }) else { continue }
            observer(BackgroundChildResultNotice(sourceSessionID: parent.sessionID, executionIdentity: executionIdentity,
                task: task, parentID: parent.taskID, report: report,
                structuredResult: resultProjection?(report)))
        }
    }

    /// Composition installs one observer. Existing receipts are not replayed;
    /// observation never changes task authority or the durable terminal fact.
    public func setTerminalObserver(_ observer: (@Sendable (AgentTaskTerminalObservation) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        terminalObserver = observer
    }

    private func terminalObservationLocked(_ receipt: AgentTaskReceipt) -> AgentTaskTerminalObservation? {
        guard let key = taskKeyByRunID[receipt.runID], let task = tasks[key],
              let source = task.sourceSessionID, !source.isEmpty,
              let attemptID = attemptIDByRunID[receipt.runID] else { return nil }
        let outcome: AgentTaskTerminalObservation.Outcome
        switch receipt.outcome {
        case .succeeded: outcome = .completed
        case .failed: outcome = .failed
        case .cancelled: outcome = .cancelled
        }
        return AgentTaskTerminalObservation(taskID: task.taskID, parentID: task.parentID,
            runID: receipt.runID, attemptID: attemptID, sourceSessionID: source,
            childSessionID: task.childTranscriptLocator?.childSessionID, outcome: outcome)
    }

    public func finish(runID: String, outcome: AgentTaskOutcome) throws -> AgentTaskReceipt {
        let eventKind: AgentTaskEventKind
        let detail: String
        switch outcome {
        case .succeeded:
            eventKind = .completed
            detail = "completed"
        case .failed:
            eventKind = .failed
            detail = "execution-failed"
        case .cancelled:
            eventKind = .cancelled
            detail = "cancelled"
        }
        return try finish(runID: runID, eventKind: eventKind, detail: detail, outcome: outcome)
    }

    /// Atomically append the terminal event and close the run. Late writers cannot
    /// observe an open run between the two operations.
    public func finish(runID: String, eventKind: AgentTaskEventKind, detail: String, outcome: AgentTaskOutcome) throws -> AgentTaskReceipt {
        try finishTerminal(runID: runID, eventKind: eventKind, outcome: outcome, publicFailure: nil)
    }

    /// This overload can publish only a failed outcome from a closed category.
    /// The existing String-based overloads remain fully redacted.
    public func finish(runID: String, failureCategory: AgentTaskPublicFailureCategory) throws -> AgentTaskReceipt {
        try finishTerminal(runID: runID, eventKind: .failed,
            outcome: .failed(reason: failureCategory.message), publicFailure: failureCategory)
    }

    private func finishTerminal(runID: String, eventKind: AgentTaskEventKind,
                                outcome: AgentTaskOutcome,
                                publicFailure: AgentTaskPublicFailureCategory?) throws -> AgentTaskReceipt {
        var delivery: ((@Sendable (AgentTaskTerminalObservation) -> Void), AgentTaskTerminalObservation)?
        lock.lock()
        defer {
            lock.unlock()
            if let (observer, observation) = delivery { observer(observation) }
        }
        // A receipt keyed by runID is the durable terminal identity. Replaying a
        // late or duplicate settlement must not reopen a transaction or append
        // an observability marker after the canonical terminal event.
        if let existing = receiptByRunID[runID] {
            return existing
        }
        let receipt = try transaction {
            try finishLocked(runID: runID, eventKind: eventKind, outcome: outcome, publicFailure: publicFailure)
        }
        if let observer = terminalObserver, let observation = terminalObservationLocked(receipt) {
            delivery = (observer, observation)
        }
        return receipt
    }

    /// Atomically settles one versioned child result with its canonical
    /// terminal event and receipt. Exact replay is idempotent; identity,
    /// attempt, cancellation, and payload drift fail closed.
    public func settleChildResult(_ envelope: ChildResultEnvelope) throws -> AgentTaskReceipt {
        try settleChildResult(
            envelope: envelope,
            eventKind: envelope.eventKind,
            detail: envelope.eventKind == .completed ? "completed" : "child-result"
        )
    }

    /// Compatibility spelling for callers that provide the terminal event
    /// explicitly. `detail` remains bounded and is never persisted verbatim.
    public func settleChildResult(
        envelope: ChildResultEnvelope,
        eventKind: AgentTaskEventKind,
        detail: String
    ) throws -> AgentTaskReceipt {
        _ = detail
        var delivery: ((@Sendable (AgentTaskTerminalObservation) -> Void), AgentTaskTerminalObservation)?
        lock.lock()
        defer {
            lock.unlock()
            if let (observer, observation) = delivery { observer(observation) }
        }

        guard envelope.isWellFormed,
              Self.matches(eventKind: eventKind, outcome: envelope.outcome),
              let run = runs[envelope.runID],
              run.taskID == envelope.taskID,
              let taskKey = taskKeyByRunID[envelope.runID],
              let task = tasks[taskKey],
              task.parentContextSnapshotID == envelope.parentContextSnapshotID,
              (retryRunRuntimeBindingsByRunID[envelope.runID]?.child
                  ?? task.childRuntimeIdentity)?.matchesVerifiedExecutionID(
                envelope.childExecutionID
              ) ?? true,
              run.parentContextSnapshotID == envelope.parentContextSnapshotID,
              let canonicalAttemptID = attemptIDByRunID[envelope.runID],
              canonicalAttemptID == envelope.attemptID,
              let attempt = attempts[canonicalAttemptID],
              attempt.runID == envelope.runID,
              attempt.attempt == envelope.attemptNumber,
              attempt.parentContextSnapshotID == envelope.parentContextSnapshotID else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }

        let settledReceipt = receiptByRunID[envelope.runID]
        switch AsyncTerminalStateRules.lateWritebackDisposition(
            runStatus: run.status,
            attemptStatus: attempt.status,
            hasSettledReceipt: settledReceipt != nil,
            settledReceiptIsExactReplay: settledReceipt?.childResultEnvelope == envelope,
            settledReceiptIsCancelled: settledReceipt?.outcome == .cancelled
        ) {
        case .accept:
            break
        case .exactReplay:
            guard let settledReceipt else {
                throw AgentTaskStoreError.childResultIdentityMismatch
            }
            return settledReceipt
        case .rejectCancelledSticky:
            try recordRejectedChildResult(envelope, reason: .cancelled)
            throw AgentTaskStoreError.childResultCancelled
        case .rejectIdempotencyConflict:
            try recordRejectedChildResult(envelope, reason: .conflictingReplay)
            throw AgentTaskStoreError.childResultIdempotencyConflict
        case .rejectLate:
            try recordRejectedChildResult(envelope, reason: .late)
            throw AgentTaskStoreError.childResultLate
        }

        // One result key may never select a different run, and a child route
        // may never be reused by a sibling task under the same parent.
        guard !receiptByRunID.values.contains(where: {
            $0.childResultEnvelope?.idempotencyKey == envelope.idempotencyKey
        }) else {
            throw AgentTaskStoreError.childResultEnvelopeConflict
        }
        guard !receiptByRunID.values.contains(where: { receipt in
            guard let prior = receipt.childResultEnvelope,
                  prior.childExecutionID == envelope.childExecutionID,
                  let priorKey = taskKeyByRunID[receipt.runID],
                  let priorTask = tasks[priorKey] else { return false }
            return priorTask.parentID == task.parentID && priorTask.taskID != task.taskID
        }) else {
            throw AgentTaskStoreError.childResultEnvelopeConflict
        }
        guard envelope.childTranscriptLocator == task.childTranscriptLocator else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }

        let receipt = try transaction {
            try finishLocked(
                runID: envelope.runID,
                eventKind: eventKind,
                outcome: envelope.outcome,
                childResultEnvelope: envelope
            )
        }
        if let observer = terminalObserver, let observation = terminalObservationLocked(receipt) {
            delivery = (observer, observation)
        }
        return receipt
    }

    public func settleChild(_ envelope: ChildResultEnvelope) throws -> AgentTaskReceipt {
        try settleChildResult(envelope)
    }

    public func submitChildResult(_ envelope: ChildResultEnvelope) throws -> AgentTaskReceipt {
        try settleChildResult(envelope)
    }

    public func childResultEnvelope(idempotencyKey: String) -> ChildResultEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return receiptByRunID.values.first {
            $0.childResultEnvelope?.idempotencyKey == idempotencyKey
        }?.childResultEnvelope
    }

    public func childResultEnvelope(runID: String) -> ChildResultEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return receiptByRunID[runID]?.childResultEnvelope
    }

    public func childResultEnvelope(taskID: String, runID: String) -> ChildResultEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        let parents = Set(tasks.values.filter { $0.taskID == taskID }.map(\.parentID))
        guard parents.count == 1, let parentID = parents.first else { return nil }
        return childResultEnvelopeLocked(taskID: taskID, parentID: parentID, runID: runID)
    }

    public func childResultEnvelope(taskID: String, parentID: String, runID: String) -> ChildResultEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return childResultEnvelopeLocked(taskID: taskID, parentID: parentID, runID: runID)
    }

    private func childResultEnvelopeLocked(taskID: String, parentID: String, runID: String) -> ChildResultEnvelope? {
        guard let binding = taskRunBindingLocked(runID: runID),
              binding.task.taskID == taskID,
              binding.task.parentID == parentID,
              let receipt = receiptByRunID[runID],
              receipt.runID == runID,
              receipt.taskID == taskID,
              receipt.attemptID == binding.attempt.attemptID,
              receipt.parentContextSnapshotID == binding.task.parentContextSnapshotID,
              let control = controlByTaskKey[binding.taskKey],
              control.state == .terminal,
              binding.task.status == receipt.outcome.status,
              binding.run.status == receipt.outcome.status,
              binding.attempt.status == receipt.outcome.status,
              let envelope = receipt.childResultEnvelope,
              envelope.isWellFormed,
              envelope.taskID == taskID,
              envelope.runID == runID,
              envelope.attemptID == binding.attempt.attemptID,
              envelope.parentContextSnapshotID == binding.task.parentContextSnapshotID,
              envelope.childTranscriptLocator == binding.task.childTranscriptLocator else {
            return nil
        }
        return envelope
    }

    public func childResultReceipt(idempotencyKey: String) -> AgentTaskReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return receiptByRunID.values.first {
            $0.childResultEnvelope?.idempotencyKey == idempotencyKey
        }
    }

    public func receipt(runID: String) -> AgentTaskReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return receiptByRunID[runID]
    }

    /// Register the live cancellation capability for a running run. The
    /// returned handle is one-shot and may safely be retained by the caller;
    /// Task Center stop invokes it only after durable cancellation settles.
    @discardableResult
    public func registerCancellationHandle(
        runID: String,
        cancellation: @escaping @Sendable () -> Void
    ) throws -> AgentTaskCancellationHandle {
        lock.lock()
        defer { lock.unlock() }
        guard let run = runs[runID], run.status == .running else {
            throw AgentTaskStoreError.unknownRun
        }
        guard cancellationHandlesByRunID[runID] == nil else {
            throw AgentTaskStoreError.controlStateConflict
        }
        let handle = AgentTaskCancellationHandle(cancellation: cancellation)
        cancellationHandlesByRunID[runID] = handle
        return handle
    }

    /// Drop a live cancellation capability after the worker has exited.
    public func unregisterCancellationHandle(runID: String) {
        lock.lock()
        cancellationHandlesByRunID.removeValue(forKey: runID)
        lock.unlock()
    }

    /// Resolve only a canonical terminal receipt and its matching closed event
    /// category. A safe-looking message alone never supplies this qualification.
    public func publicFailureCategory(for receipt: AgentTaskReceipt) -> AgentTaskPublicFailureCategory? {
        lock.lock(); defer { lock.unlock() }
        guard receiptByRunID[receipt.runID] == receipt,
              let run = runs[receipt.runID], run.status == .failed, run.taskID == receipt.taskID,
              run.parentContextSnapshotID == receipt.parentContextSnapshotID,
              let taskKey = taskKeyByRunID[receipt.runID], let task = tasks[taskKey],
              task.taskID == receipt.taskID, task.parentContextSnapshotID == receipt.parentContextSnapshotID,
              attemptIDByRunID[receipt.runID] == receipt.attemptID,
              let attempt = attempts[receipt.attemptID], attempt.runID == receipt.runID,
              attempt.status == .failed, attempt.parentContextSnapshotID == receipt.parentContextSnapshotID,
              let runEvents = events[receipt.runID], let terminal = runEvents.last,
              runEvents.filter({ Self.isTerminal($0.kind) }).count == 1,
              terminal.kind == .failed, terminal.runID == receipt.runID,
              terminal.parentContextSnapshotID == receipt.parentContextSnapshotID,
              let category = AgentTaskPublicFailureCategory(rawValue: terminal.detail),
              receipt.outcome == .failed(reason: category.message) else { return nil }
        return category
    }

    private func finishLocked(
        runID: String,
        eventKind: AgentTaskEventKind,
        outcome: AgentTaskOutcome,
        publicFailure: AgentTaskPublicFailureCategory? = nil,
        updateControlState: Bool = true,
        persistMutation: Bool = true,
        childResultEnvelope: ChildResultEnvelope? = nil
    ) throws -> AgentTaskReceipt {
        guard let run = runs[runID] else { throw AgentTaskStoreError.unknownRun }
        if let existing = receiptByRunID[runID] {
            return existing
        }
        guard run.status == .running else { throw AgentTaskStoreError.runClosed }
        guard Self.matches(eventKind: eventKind, outcome: outcome) else { throw AgentTaskStoreError.invalidTerminalSettlement }
        let sequence = (events[runID]?.last?.sequence ?? 0) + 1
        let safeOutcome = publicFailure.map { AgentTaskOutcome.failed(reason: $0.message) }
            ?? Self.redactedOutcome(outcome)
        guard let taskKey = taskKeyByRunID[runID], let task = tasks[taskKey] else { throw AgentTaskStoreError.unknownTask }
        let attemptID = attemptIDByRunID[runID] ?? "\(runID):attempt:1"
        let receipt = AgentTaskReceipt(
            taskID: task.taskID,
            runID: runID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            attemptID: attemptID,
            providerID: task.providerID,
            modelID: task.modelID,
            configurationFingerprint: task.configurationFingerprint,
            outcome: safeOutcome,
            childResultEnvelope: childResultEnvelope
        )
        let mutation = { [self] in
            self.events[runID, default: []].append(AgentTaskEvent(
                runID: runID,
                parentContextSnapshotID: task.parentContextSnapshotID,
                sequence: sequence,
                kind: eventKind,
                detail: publicFailure?.rawValue ?? Self.eventCategory(for: eventKind)
            ))
            self.receiptByRunID[runID] = receipt
            self.receiptOrder.append(runID)
            self.runs[runID] = AgentRunSnapshot(runID: runID, taskID: run.taskID, parentContextSnapshotID: run.parentContextSnapshotID, status: safeOutcome.status)
            if let attempt = self.attempts[attemptID] {
                self.attempts[attemptID] = AgentTaskAttemptSnapshot(attemptID: attempt.attemptID, runID: attempt.runID, parentContextSnapshotID: attempt.parentContextSnapshotID, attempt: attempt.attempt, providerID: attempt.providerID, modelID: attempt.modelID, configurationFingerprint: attempt.configurationFingerprint, status: safeOutcome.status, startedAt: attempt.startedAt, finishedAt: Date())
            }
            self.updateTask(taskKey, status: safeOutcome.status)
            if updateControlState, let control = self.controlByTaskKey[taskKey] {
                self.controlByTaskKey[taskKey] = AgentTaskControlSnapshot(
                    taskID: control.taskID,
                    parentID: control.parentID,
                    state: .terminal,
                    controlRevision: control.controlRevision + 1,
                    runID: runID
                )
            }
            return receipt
        }
        if persistMutation {
            return try transaction(mutation)
        }
        return mutation()
    }

    public func snapshot(taskID: String) -> AgentTaskSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return tasks.values.first { $0.taskID == taskID }
    }

    /// Returns a deterministic read-only copy of the canonical in-memory task ledger.
    public func taskCenterSnapshots(includeArchived: Bool = true) -> [AgentTaskSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return tasks.values
            .filter { includeArchived || !$0.isArchived }
            .sorted { lhs, rhs in
            if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID }
            return lhs.taskID < rhs.taskID
        }
    }

    public func archiveReceipt(idempotencyKey: String) -> AgentTaskArchiveReceipt? {
        lock.lock(); defer { lock.unlock() }
        return archiveReceiptByIdempotencyKey[idempotencyKey]
    }

    /// Returns the durable archive history for a task, including after restore.
    /// The returned record is immutable and never authorizes redispatch.
    public func taskArchive(taskID: String, parentID: String) -> AgentTaskArchiveSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return archiveByTaskKey[taskKey(taskID: taskID, parentID: parentID)]
    }

    /// Archives or restores one completed task record through the same atomic
    /// persistence transaction used by lifecycle mutations. Only a canonical
    /// succeeded receipt and its terminal event can be archived.
    public func applyArchive(
        _ request: AgentTaskArchiveRequest,
        now: Date = Date()
    ) throws -> AgentTaskArchiveReceipt {
        lock.lock(); defer { lock.unlock() }

        guard !request.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.parentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.eventSequence > 0,
              !request.actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskStoreError.archiveNotEligible
        }

        if let prior = archiveReceiptByIdempotencyKey[request.idempotencyKey] {
            guard prior.request == request else {
                throw AgentTaskStoreError.archiveIdempotencyConflict
            }
            return AgentTaskArchiveReceipt(
                request: prior.request,
                archive: prior.archive,
                didChange: false
            )
        }

        let key = taskKey(taskID: request.taskID, parentID: request.parentID)
        guard let task = tasks[key] else { throw AgentTaskStoreError.unknownTask }
        guard AgentTaskSnapshotIdentity(snapshot: task) == request.expectedSnapshotIdentity else {
            throw AgentTaskStoreError.archiveIdentityMismatch
        }
        guard request.sourceSessionID == task.sourceSessionID else {
            throw AgentTaskStoreError.archiveIdentityMismatch
        }

        guard let receipt = receiptByRunID[request.runID],
              receipt.taskID == task.taskID,
              receipt.attemptID == request.attemptID,
              receipt.runID == request.runID,
              receipt.parentContextSnapshotID == task.parentContextSnapshotID,
              receipt.outcome == .succeeded,
              task.status == .succeeded,
              taskKeyByRunID[request.runID] == key,
              attemptIDByRunID[request.runID] == request.attemptID,
              attempts[request.attemptID]?.status == .succeeded else {
            throw AgentTaskStoreError.archiveNotEligible
        }
        guard let terminalEvent = events[request.runID]?.last,
              terminalEvent.sequence == request.eventSequence,
              terminalEvent.kind == .completed,
              terminalEvent.runID == request.runID,
              terminalEvent.parentContextSnapshotID == task.parentContextSnapshotID else {
            throw AgentTaskStoreError.archiveReceiptMismatch
        }

        let archive: AgentTaskArchiveSnapshot
        switch request.action {
        case .archive:
            guard task.archivedAt == nil else {
                throw AgentTaskStoreError.archiveStateConflict
            }
            archive = AgentTaskArchiveSnapshot(
                taskID: task.taskID,
                parentID: task.parentID,
                sourceSessionID: task.sourceSessionID,
                runID: request.runID,
                attemptID: request.attemptID,
                eventSequence: request.eventSequence,
                archivedAt: now
            )
        case .restore:
            guard task.archivedAt != nil,
                  let existingArchive = archiveByTaskKey[key],
                  existingArchive.taskID == task.taskID,
                  existingArchive.parentID == task.parentID,
                  existingArchive.sourceSessionID == task.sourceSessionID,
                  existingArchive.runID == request.runID,
                  existingArchive.attemptID == request.attemptID,
                  existingArchive.eventSequence == request.eventSequence else {
                throw AgentTaskStoreError.archiveStateConflict
            }
            archive = existingArchive
        }

        let result = AgentTaskArchiveReceipt(request: request, archive: archive, didChange: true)
        try transaction {
            tasks[key] = AgentTaskSnapshot(
                taskID: task.taskID,
                parentID: task.parentID,
                parentContextSnapshotID: task.parentContextSnapshotID,
                providerID: task.providerID,
                modelID: task.modelID,
                configurationFingerprint: task.configurationFingerprint,
                routeReceiptID: task.routeReceiptID,
                status: task.status,
                creation: task.creation, dispatchHumanTitle: task.dispatchHumanTitle,
                archivedAt: request.action == .archive ? archive.archivedAt : nil,
                childTranscriptLocator: task.childTranscriptLocator,
                parentRuntimeIdentity: task.parentRuntimeIdentity,
                childRuntimeIdentity: task.childRuntimeIdentity
            )
            archiveByTaskKey[key] = archive
            archiveReceiptByIdempotencyKey[request.idempotencyKey] = result
        }
        return result
    }

    /// Returns a read-only aggregate derived from the canonical in-memory task ledger.
    public func taskCenterProjection() -> TaskCenterProjection {
        TaskCenterProjection(snapshots: taskCenterSnapshots())
    }

    /// A read spanning several Task Center lookups is coherent only when this
    /// value agrees before and after the reads. A committed child settlement,
    /// cancellation, retry, or event append advances it under the ledger lock.
    public func taskCenterReadVersion() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return taskCenterMutationVersion
    }

    public func persistenceDiagnostics() -> AgentPersistenceDiagnostic? {
        lock.lock(); defer { lock.unlock() }
        return persistenceDiagnostic
    }

    public func snapshot(taskID: String, parentID: String) -> AgentTaskSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return tasks[taskKey(taskID: taskID, parentID: parentID)]
    }

    /// Returns the durable creation fact for replay/recovery. The index is an
    /// acceleration only; searching the task payload keeps recovery safe when
    /// a pre-index ledger is reopened.
    public func creationSnapshot(idempotencyKey: String) -> AgentTaskSnapshot? {
        lock.lock(); defer { lock.unlock() }
        if let taskKey = creationTaskKeyByIdempotencyKey[idempotencyKey],
           let snapshot = tasks[taskKey] {
            return snapshot
        }
        return tasks.values.first {
            $0.creation?.idempotencyKey == idempotencyKey
        }
    }

    public func controlSnapshot(taskID: String, parentID: String) -> AgentTaskControlSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return controlByTaskKey[taskKey(taskID: taskID, parentID: parentID)]
    }

    public func controlReceipt(idempotencyKey: String) -> AgentTaskControlReceipt? {
        lock.lock(); defer { lock.unlock() }
        return controlReceiptByIdempotencyKey[idempotencyKey]
    }

    public func controlTaskIDsToStop(taskID: String, parentID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let rootKey = taskKey(taskID: taskID, parentID: parentID)
        guard tasks[rootKey] != nil else { return [] }
        let keys = [rootKey] + descendantTaskKeysLocked(rootKey: rootKey)
        return keys.compactMap { key in
            guard let task = tasks[key],
                  task.status == .queued || task.status == .running else {
                return nil
            }
            return task.taskID
        }
    }

    /// Applies one validated control command and its durable receipt atomically.
    public func applyControl(
        taskID: String,
        parentID: String,
        command: AgentTaskControlCommand,
        expectedControlRevision: Int,
        runID: String?,
        resultingRunID: String?,
        receipt: AgentTaskControlReceipt
    ) throws -> AgentTaskControlTransition {
        lock.lock()
        if let prior = controlReceiptByIdempotencyKey[receipt.idempotencyKey] {
            guard prior == receipt else {
                lock.unlock()
                throw AgentTaskStoreError.controlReceiptConflict
            }
            guard let task = tasks[taskKey(taskID: prior.taskID, parentID: prior.parentID)],
                  let control = controlByTaskKey[taskKey(taskID: prior.taskID, parentID: prior.parentID)] else {
                lock.unlock()
                throw AgentTaskStoreError.unknownTask
            }
            lock.unlock()
            return AgentTaskControlTransition(
                task: task,
                control: control,
                resultingRunID: prior.resultingRunID,
                cancelledTaskIDs: prior.cancelledTaskIDs
            )
        }

        let key = taskKey(taskID: taskID, parentID: parentID)
        guard let task = tasks[key], let control = controlByTaskKey[key] else {
            lock.unlock()
            throw AgentTaskStoreError.unknownTask
        }
        guard control.controlRevision == expectedControlRevision else {
            lock.unlock()
            throw AgentTaskStoreError.controlRevisionMismatch
        }
        guard task.taskID == receipt.taskID,
              task.parentID == receipt.parentID,
              receipt.command == command,
              receipt.runID == runID,
              receipt.resultingRunID == resultingRunID else {
            lock.unlock()
            throw AgentTaskStoreError.controlReceiptConflict
        }

        var cancelledTaskIDs: [String] = []
        var cancellationHandles: [AgentTaskCancellationHandle] = []
        var cancellationRunIDs: Set<String> = []
        do {
            let transition = try transaction {
            switch command {
            case .pause:
                guard task.status == .queued || task.status == .running,
                      control.state == .active else {
                    throw AgentTaskStoreError.controlStateConflict
                }
                try requireRunIfNeeded(task: task, control: control, runID: runID)
                updateControl(key, state: .paused, runID: runID)

            case .resume:
                guard task.status == .queued || task.status == .running,
                      control.state == .paused else {
                    throw AgentTaskStoreError.controlStateConflict
                }
                try requireRunIfNeeded(task: task, control: control, runID: runID)
                updateControl(key, state: .active, runID: runID ?? control.runID)

            case .stop:
                guard task.status == .queued || task.status == .running,
                      control.state == .active || control.state == .paused else {
                    throw AgentTaskStoreError.controlStateConflict
                }
                let keys = descendantTaskKeysLocked(rootKey: key)
                var descendantCancelledTaskIDs: [String] = []
                for childKey in keys {
                    guard let child = tasks[childKey],
                          let childControl = controlByTaskKey[childKey] else {
                        throw AgentTaskStoreError.unknownTask
                    }
                    guard child.status == .queued || child.status == .running else { continue }
                    if child.status == .running {
                        let childRunID = childControl.runID
                        guard let childRunID,
                              externalSubmissionDecisionLocked(runID: childRunID) == .notSubmitted else {
                            throw AgentTaskStoreError.externalSubmissionUnknown
                        }
                        if cancellationRunIDs.insert(childRunID).inserted,
                           let handle = cancellationHandlesByRunID[childRunID] {
                            cancellationHandles.append(handle)
                        }
                        _ = try finishLocked(
                            runID: childRunID,
                            eventKind: .cancelled,
                            outcome: .cancelled,
                            updateControlState: false,
                            persistMutation: false
                        )
                    } else {
                        cancelQueuedLocked(childKey)
                    }
                    updateControl(childKey, state: .stopped, runID: childControl.runID)
                    descendantCancelledTaskIDs.append(child.taskID)
                }
                let targetControl = controlByTaskKey[key] ?? control
                let targetRunID = targetControl.runID
                if task.status == .running {
                    try requireRunIfNeeded(task: task, control: targetControl, runID: runID)
                    guard let targetRunID,
                          externalSubmissionDecisionLocked(runID: targetRunID) == .notSubmitted else {
                        throw AgentTaskStoreError.externalSubmissionUnknown
                    }
                    if cancellationRunIDs.insert(targetRunID).inserted,
                       let handle = cancellationHandlesByRunID[targetRunID] {
                        cancellationHandles.append(handle)
                    }
                    _ = try finishLocked(
                        runID: targetRunID,
                        eventKind: .cancelled,
                        outcome: .cancelled,
                        updateControlState: false,
                        persistMutation: false
                    )
                } else {
                    cancelQueuedLocked(key)
                }
                updateControl(key, state: .stopped, runID: targetRunID)
                cancelledTaskIDs.append(task.taskID)
                cancelledTaskIDs.append(contentsOf: descendantCancelledTaskIDs)

            case .retry:
                guard task.status == .failed || task.status == .cancelled,
                      control.state == .terminal || control.state == .stopped else {
                    throw AgentTaskStoreError.controlStateConflict
                }
                if let runID {
                    guard let run = runs[runID],
                          run.taskID == task.taskID,
                          run.status == .failed || run.status == .cancelled else {
                        throw AgentTaskStoreError.unknownRun
                    }
                }
                guard let resultingRunID else { throw AgentTaskStoreError.controlReceiptConflict }
                _ = try startRunLocked(taskID: task.taskID, taskKey: key, runID: resultingRunID)
                updateControl(key, state: .active, runID: resultingRunID)
            }

            guard let finalTask = tasks[key], let finalControl = controlByTaskKey[key] else {
                throw AgentTaskStoreError.unknownTask
            }
            guard finalControl.state == receipt.controlState,
                  finalControl.controlRevision == receipt.controlRevision,
                  receipt.cancelledTaskIDs == cancelledTaskIDs,
                  finalControl.controlRevision > expectedControlRevision else {
                throw AgentTaskStoreError.controlReceiptConflict
            }
            if let afterFact = receipt.afterFact {
                guard afterFact.taskID == finalTask.taskID,
                      afterFact.parentID == finalTask.parentID,
                      afterFact.status == finalTask.status,
                      afterFact.controlState == finalControl.state,
                      afterFact.controlRevision == finalControl.controlRevision else {
                    throw AgentTaskStoreError.controlReceiptConflict
                }
            }
            controlReceiptByIdempotencyKey[receipt.idempotencyKey] = receipt
            return AgentTaskControlTransition(
                task: finalTask,
                control: finalControl,
                resultingRunID: resultingRunID,
                cancelledTaskIDs: receipt.cancelledTaskIDs
            )
            }
            for runID in cancellationRunIDs {
                cancellationHandlesByRunID.removeValue(forKey: runID)
            }
            lock.unlock()
            cancellationHandles.forEach { $0.cancel() }
            return transition
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func attempts(runID: String) -> [AgentTaskAttemptSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return attempts.values.filter { $0.runID == runID }.sorted { $0.attempt < $1.attempt }
    }

    /// Read-only ownership of a persisted run, including a prior retry run.
    /// Current command/child-transcript APIs retain their current-run fences.
    public func historicalRunIdentity(
        runID: String,
        taskID: String,
        parentID: String
    ) -> AgentTaskHistoricalRunIdentity? {
        lock.lock(); defer { lock.unlock() }
        return historicalRunIdentityLocked(runID: runID, taskID: taskID, parentID: parentID)
    }

    private func historicalRunIdentityLocked(
        runID: String,
        taskID: String,
        parentID: String
    ) -> AgentTaskHistoricalRunIdentity? {
        guard let run = runs[runID], run.runID == runID, run.taskID == taskID,
              let mappedKey = taskKeyByRunID[runID],
              mappedKey == taskKey(taskID: taskID, parentID: parentID),
              let task = tasks[mappedKey],
              task.taskID == taskID, task.parentID == parentID,
              task.parentContextSnapshotID == run.parentContextSnapshotID,
              let attemptID = attemptIDByRunID[runID],
              let attempt = attempts[attemptID],
              attempt.attemptID == attemptID, attempt.runID == runID,
              attempt.parentContextSnapshotID == run.parentContextSnapshotID else {
            return nil
        }
        return AgentTaskHistoricalRunIdentity(
            taskID: taskID, parentID: parentID, runID: runID,
            attemptID: attemptID, parentContextSnapshotID: run.parentContextSnapshotID
        )
    }

    /// Replay identity only; a prior attempt cannot authorize a fresh action.
    func historicalAttempt(
        runID: String,
        taskID: String,
        parentID: String
    ) -> AgentTaskAttemptSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let identity = historicalRunIdentityLocked(
            runID: runID, taskID: taskID, parentID: parentID
        ) else { return nil }
        return attempts[identity.attemptID]
    }

    /// Returns the durable current attempt only when it matches the supplied
    /// attempt identity for the run.
    public func attempt(
        runID: String,
        attemptID: String
    ) -> AgentTaskAttemptSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: runID),
              binding.attempt.attemptID == attemptID else { return nil }
        return binding.attempt
    }

    /// Returns the one attempt identity issued by the durable task/run ledger.
    /// Supervisors must consume this value rather than deriving a second ID.
    public func canonicalAttemptID(runID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return taskRunBindingLocked(runID: runID)?.attempt.attemptID
    }

    /// Returns the canonical task snapshot attached to a persisted run.
    /// This read-only lookup preserves task/parent isolation at command boundaries.
    public func taskSnapshot(runID: String) -> AgentTaskSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return taskRunBindingLocked(runID: runID)?.task
    }

    /// Read the exact runtime owner of a retry without replacing the original
    /// task's parent/child identities or any historical run receipt.
    public func retryRunRuntimeBinding(runID: String) -> RetryRunRuntimeBinding? {
        lock.lock(); defer { lock.unlock() }
        return retryRunRuntimeBindingsByRunID[runID]
    }

    /// Attach a newly admitted parent turn to the already-created retry run.
    /// This is not an authority to start work: the caller must also consume
    /// the live handle, frozen Goal and durable original request at dispatch.
    /// A failed bind leaves the run unusable and must be terminalized by its
    /// owner before returning control to Task Center.
    @discardableResult
    public func bindRetryRunRuntime(
        taskID: String, originalParentID: String, runID: String,
        attemptID: String, parent: ParentRuntimeIdentity,
        parentGoal: GoalEnvelope, child: ChildRuntimeIdentity,
        childExecutionID: String,
        parentTurnHandle: TurnController.TurnHandle
    ) async throws -> RetryRunRuntimeBinding {
        guard await parentTurnHandle.isActive(),
              !(await parentTurnHandle.isCancelled()) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        return try bindRetryRunRuntimeLocked(
            taskID: taskID, originalParentID: originalParentID,
            runID: runID, attemptID: attemptID, parent: parent,
            parentGoal: parentGoal, child: child,
            childExecutionID: childExecutionID,
            parentTurnHandle: parentTurnHandle
        )
    }

    private func bindRetryRunRuntimeLocked(
        taskID: String, originalParentID: String, runID: String,
        attemptID: String, parent: ParentRuntimeIdentity,
        parentGoal: GoalEnvelope, child: ChildRuntimeIdentity,
        childExecutionID: String,
        parentTurnHandle: TurnController.TurnHandle
    ) throws -> RetryRunRuntimeBinding {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: runID),
              binding.task.taskID == taskID,
              binding.task.parentID == originalParentID,
              binding.task.status == .running,
              binding.run.status == .running,
              binding.attempt.attemptID == attemptID,
              binding.attempt.status == .running,
              binding.control.state == .active,
              binding.control.runID == runID,
              controlReceiptByIdempotencyKey.values.contains(where: {
                  $0.command == .retry && $0.taskID == taskID
                      && $0.parentID == originalParentID
                      && $0.resultingRunID == runID
              }),
              let originalParent = binding.task.parentRuntimeIdentity,
              let originalChild = binding.task.childRuntimeIdentity,
              parent.isValid,
              parent.sessionID == originalParent.sessionID,
              parent.conversationID == originalParent.conversationID,
              parent.actorID == originalParent.actorID,
              parent.taskID != originalParentID,
              // Each Chat stream owns a fresh TurnController whose local
              // handle commonly starts at 1. The durable Composer task ID,
              // not the local handle ordinal, distinguishes parent turns.
              parent.turnID == "turn-handle:\(parentTurnHandle.turnID)",
              child.childTaskID == taskID,
              child.parentTaskID == parent.taskID,
              child.childSessionID != originalChild.childSessionID,
              child.cancelGeneration == parentTurnHandle.turnID,
              child.hasVerifiedRootBoundary(parent: parent, goal: parentGoal),
              child.matchesVerifiedExecutionID(childExecutionID),
              (try? child.requireVerifiedGeneration()) != nil,
              !receiptByRunID.values.contains(where: {
                  $0.childResultEnvelope?.childTranscriptLocator?.childSessionID
                      == child.childSessionID
              }),
              !retryRunRuntimeBindingsByRunID.values.contains(where: {
                  $0.child.childSessionID == child.childSessionID
              }) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        let frozen = RetryRunRuntimeBinding(
            taskID: taskID, originalParentID: originalParentID,
            runID: runID, attemptID: attemptID, parent: parent,
            parentGoal: parentGoal, child: child
        )
        if let existing = retryRunRuntimeBindingsByRunID[runID] {
            guard existing == frozen else { throw AgentTaskStoreError.childResultIdentityMismatch }
            return existing
        }
        return try transaction {
            retryRunRuntimeBindingsByRunID[runID] = frozen
            return frozen
        }
    }

    private func taskRunBindingLocked(runID: String) -> (
        taskKey: String, task: AgentTaskSnapshot, run: AgentRunSnapshot,
        attempt: AgentTaskAttemptSnapshot, control: AgentTaskControlSnapshot
    )? {
        guard let run = runs[runID], run.runID == runID,
              let key = taskKeyByRunID[runID],
              let task = tasks[key],
              task.taskID == run.taskID,
              task.parentContextSnapshotID == run.parentContextSnapshotID,
              let attemptID = attemptIDByRunID[runID],
              let attempt = attempts[attemptID],
              attempt.attemptID == attemptID,
              attempt.runID == runID,
              attempt.parentContextSnapshotID == run.parentContextSnapshotID,
              let control = controlByTaskKey[key],
              control.taskID == task.taskID,
              control.parentID == task.parentID,
              control.runID == runID else { return nil }
        return (key, task, run, attempt, control)
    }

    /// Bind a real child session only to the current running attempt.
    @discardableResult
    public func bindChildTranscript(_ locator: ChildTranscriptLocator) throws -> AgentTaskSnapshot {
        guard locator.isWellFormed else { throw AgentTaskStoreError.childResultInvalidEnvelope }
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.taskID == locator.taskID,
              binding.task.parentID == locator.parentID,
              binding.task.parentContextSnapshotID == locator.parentContextSnapshotID,
              binding.task.sourceSessionID == nil
                || binding.task.sourceSessionID == locator.parentSessionID,
              binding.task.status == .running,
              binding.run.status == .running,
              binding.attempt.attemptID == locator.attemptID,
              binding.attempt.status == .running,
              (retryRunRuntimeBindingsByRunID[locator.runID].map {
                  locator.runtimeParentID == $0.parent.taskID
                      && locator.childSessionID == $0.child.childSessionID
                      && locator.childExecutionID != ""
              } ?? (locator.runtimeParentID == nil)) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        if let existing = binding.task.childTranscriptLocator {
            guard existing == locator else { throw AgentTaskStoreError.childResultEnvelopeConflict }
            return binding.task
        }
        let task = binding.task
        let updated = AgentTaskSnapshot(
            taskID: task.taskID, parentID: task.parentID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            providerID: task.providerID, modelID: task.modelID,
            configurationFingerprint: task.configurationFingerprint,
            routeReceiptID: task.routeReceiptID, status: task.status,
            creation: task.creation, dispatchHumanTitle: task.dispatchHumanTitle, archivedAt: task.archivedAt,
            childTranscriptLocator: locator,
            parentRuntimeIdentity: task.parentRuntimeIdentity,
            childRuntimeIdentity: task.childRuntimeIdentity
        )
        try transaction {
            tasks[binding.taskKey] = updated
        }
        // Bind only at the first successful canonical append route. A repeated
        // bind cannot attach an existing attempt to a different registration.
        if let id = Self.childOrchestrationRegistrationID,
           let entry = liveChildOrchestrations[id],
           let parent = retryRunRuntimeBindingsByRunID[locator.runID]?.parent
                ?? binding.task.parentRuntimeIdentity,
           entry.parent == parent, parent.sessionID == locator.parentSessionID,
           entry.taskIDs.contains(locator.taskID) {
            liveChildOrchestrationByLocator[locator] = id
        }
        return updated
    }

    /// A locator is usable only while its exact ledger backlinks remain intact.
    public func childTranscriptLocator(
        taskID: String, parentID: String, runID: String, attemptID: String,
        childExecutionID: String, parentContextSnapshotID: String?
    ) -> ChildTranscriptLocator? {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: runID),
              binding.task.taskID == taskID,
              binding.task.parentID == parentID,
              binding.task.parentContextSnapshotID == parentContextSnapshotID,
              binding.attempt.attemptID == attemptID,
              let locator = binding.task.childTranscriptLocator,
              locator.isWellFormed,
              binding.task.sourceSessionID == nil
                || binding.task.sourceSessionID == locator.parentSessionID,
              locator.taskID == taskID,
              locator.parentID == parentID,
              locator.runID == runID,
              locator.attemptID == attemptID,
              locator.childExecutionID == childExecutionID,
              locator.parentContextSnapshotID == parentContextSnapshotID else { return nil }
        return locator
    }

    /// Keep the task's terminal transition outside one child transcript write.
    /// The operation must be synchronous and must not call back into this store.
    public func withWritableChildTranscript<Result>(
        _ locator: ChildTranscriptLocator,
        operation: () throws -> Result
    ) throws -> Result {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.childTranscriptLocator == locator,
              binding.task.status == .running,
              binding.run.status == .running,
              binding.attempt.status == .running,
              binding.attempt.attemptID == locator.attemptID else {
            throw AgentTaskStoreError.childResultStaleAttempt
        }
        return try operation()
    }

    @discardableResult
    public func appendChildInstruction(locator: ChildTranscriptLocator,
                                       source: ParentRuntimeIdentity, text: String) throws -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 4_096 else { throw ChildInstructionMailboxError.invalidText }
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.childTranscriptLocator == locator,
              binding.task.status == .running, binding.run.status == .running,
              binding.attempt.status == .running, binding.attempt.attemptID == locator.attemptID,
              controlByTaskKey[binding.taskKey]?.state == .active else {
            throw ChildInstructionMailboxError.staleAttempt
        }
        let owner = retryRunRuntimeBindingsByRunID[locator.runID]?.parent ?? binding.task.parentRuntimeIdentity
        guard source.isValid, owner == source, source.sessionID == locator.parentSessionID else {
            throw ChildInstructionMailboxError.foreignSource
        }
        var entry = childInstructionsByRunID[locator.runID] ?? (locator.attemptID, [])
        guard entry.attemptID == locator.attemptID else { throw ChildInstructionMailboxError.staleAttempt }
        guard entry.messages.count < 8,
              entry.messages.reduce(0, { $0 + $1.utf8.count }) + text.utf8.count <= 16_384 else {
            throw ChildInstructionMailboxError.full
        }
        entry.messages.append(text)
        childInstructionsByRunID[locator.runID] = entry
        return entry.messages.count
    }

    internal func consumeChildInstructions(locator: ChildTranscriptLocator) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.childTranscriptLocator == locator,
              binding.task.status == .running, binding.run.status == .running,
              binding.attempt.status == .running, binding.attempt.attemptID == locator.attemptID,
              controlByTaskKey[binding.taskKey]?.state == .active else { throw CancellationError() }
        guard let entry = childInstructionsByRunID[locator.runID] else { return [] }
        guard entry.attemptID == locator.attemptID else { throw CancellationError() }
        childInstructionsByRunID.removeValue(forKey: locator.runID)
        return entry.messages
    }

    public func childInstructionQueueSnapshot(locator: ChildTranscriptLocator) -> ChildInstructionQueueSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.taskID == locator.taskID, binding.task.parentID == locator.parentID else { return nil }
        let entry = childInstructionsByRunID[locator.runID]
        guard entry == nil || entry?.attemptID == locator.attemptID else { return nil }
        let live = binding.task.childTranscriptLocator == locator && binding.task.status == .running
            && binding.run.status == .running && binding.attempt.status == .running
            && binding.attempt.attemptID == locator.attemptID && controlByTaskKey[binding.taskKey]?.state == .active
        return ChildInstructionQueueSnapshot(queuedCount: entry?.messages.count ?? 0,
            state: live ? .pending : .endedWithoutDelivery)
    }

    // MARK: O-04 live orchestrate calls

    /// Register one live orchestrate call. `requestBackground` must only ask the
    /// owning tool call to stop waiting; `interruptOwner` must only interrupt the
    /// retained parent turn. The caller supplies the registration id so the
    /// closures can refer to it.
    public func registerLiveChildOrchestration(
        id: String = UUID().uuidString,
        parent: ParentRuntimeIdentity,
        execution: AgentExecutionIdentity?,
        taskIDs: [String],
        requestBackground: @escaping @Sendable () async -> Bool,
        interruptOwner: @escaping @Sendable () async -> Void
    ) -> String {
        let entry = LiveChildOrchestration(
            id: id, parent: parent, execution: execution, taskIDs: taskIDs,
            phase: .foreground, startedAt: Date(),
            requestBackground: requestBackground, interruptOwner: interruptOwner)
        lock.lock(); defer { lock.unlock() }
        if liveChildOrchestrations.updateValue(entry, forKey: entry.id) != nil {
            liveChildOrchestrationByLocator = liveChildOrchestrationByLocator.filter { $0.value != entry.id }
        }
        return entry.id
    }

    /// Flip a registered foreground call to background. False for an unknown
    /// or already finished registration.
    @discardableResult
    public func markLiveChildOrchestrationBackground(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = liveChildOrchestrations[id] else { return false }
        entry.phase = .background
        liveChildOrchestrations[id] = entry
        return true
    }

    public func finishLiveChildOrchestration(id: String) {
        lock.lock(); defer { lock.unlock() }
        liveChildOrchestrations.removeValue(forKey: id)
        liveChildOrchestrationByLocator = liveChildOrchestrationByLocator.filter { $0.value != id }
    }

    /// Live background orchestrate calls of one parent session.
    public func liveBackgroundChildOrchestrations(parentSessionID: String) -> [ChildOrchestrationSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values
            .filter { $0.phase == .background && $0.parent.sessionID == parentSessionID }
            .map(\.snapshot)
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Freeze terminal child ownership while an explicit session deletion is
    /// previewed or committed. Match the task-before-session lock order used
    /// by withWritableChildTranscript. The operation must not call this store.
    public func withSessionDeletionTaskEvidence<Result>(
        sessionID: String, operation: (Set<ChildTranscriptLocator>) throws -> Result
    ) throws -> Result {
        lock.lock(); defer { lock.unlock() }
        let childPrefix = sessionID + ":child:"
        func inScope(_ id: String) -> Bool { id == sessionID || id.hasPrefix(childPrefix) }
        guard !liveChildOrchestrations.values.contains(where: { inScope($0.parent.sessionID) }),
              !liveChildOrchestrationByLocator.contains(where: {
                  inScope($0.key.childSessionID) && liveChildOrchestrations[$0.value] != nil
              }) else {
            throw SessionDeletionError.deleteFailed("会话还有正在运行的子任务，请停止或等待其完成")
        }
        let completed = tasks.values.compactMap { task -> ChildTranscriptLocator? in
            guard let locator = task.childTranscriptLocator, inScope(locator.childSessionID),
                  childResultEnvelopeLocked(taskID: task.taskID, parentID: task.parentID,
                                            runID: locator.runID)?.childTranscriptLocator == locator
            else { return nil }
            return locator
        }
        return try operation(Set(completed))
    }

    /// True while a background call retained by this exact parent execution
    /// is still running. Used only to keep that call's child authority check
    /// current; the App still re-checks mode, policy and expiry every time.
    public func hasLiveBackgroundChildOrchestration(execution: AgentExecutionIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values.contains {
            $0.phase == .background && $0.execution == execution
        }
    }

    /// True when the task belongs to a live background orchestrate call.
    public func isBackgroundChild(taskID: String, parentID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values.contains {
            $0.phase == .background && $0.parent.taskID == parentID && $0.taskIDs.contains(taskID)
        }
    }

    /// True when the task belongs to a live foreground call that can still move.
    public func canMoveChildToBackground(taskID: String, parentID: String) -> Bool {
        foregroundOrchestration(taskID: taskID, parentID: parentID) != nil
    }

    private func foregroundOrchestration(taskID: String, parentID: String) -> LiveChildOrchestration? {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values.first {
            $0.phase == .foreground && $0.parent.taskID == parentID && $0.taskIDs.contains(taskID)
        }
    }

    public func canMoveChildToBackground(locator: ChildTranscriptLocator) -> Bool {
        foregroundOrchestration(locator: locator) != nil
    }

    private func foregroundOrchestration(locator: ChildTranscriptLocator) -> LiveChildOrchestration? {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.childTranscriptLocator == locator,
              binding.task.status == .running, binding.run.status == .running,
              binding.attempt.attemptID == locator.attemptID, binding.attempt.status == .running,
              binding.control.state == .active,
              let id = liveChildOrchestrationByLocator[locator],
              let entry = liveChildOrchestrations[id], entry.phase == .foreground else { return nil }
        return entry
    }

    private func backgroundOrchestrations(parentSessionID: String) -> [LiveChildOrchestration] {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values.filter {
            $0.phase == .background && $0.parent.sessionID == parentSessionID
        }
    }

    /// Ask the foreground call that owns this child to continue in background.
    @discardableResult
    public func requestMoveChildToBackground(taskID: String, parentID: String) async -> Bool {
        guard let target = foregroundOrchestration(taskID: taskID, parentID: parentID) else { return false }
        return await target.requestBackground()
    }

    /// Resolve the exact attempt and capture its original owning call in one
    /// lock acquisition, then let that call arbitrate moving versus finishing.
    @discardableResult
    public func requestMoveChildToBackground(locator: ChildTranscriptLocator) async -> Bool {
        guard let target = foregroundOrchestration(locator: locator) else { return false }
        return await target.requestBackground()
    }

    /// Number of live background orchestrate calls across all sessions.
    public func liveBackgroundChildOrchestrationCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values.filter { $0.phase == .background }.count
    }

    /// "Stop all background": interrupt every retained background call.
    @discardableResult
    public func cancelAllBackgroundChildOrchestrations() async -> Int {
        let targets = allBackgroundOrchestrations()
        for target in targets { await target.interruptOwner() }
        return targets.count
    }

    private func allBackgroundOrchestrations() -> [LiveChildOrchestration] {
        lock.lock(); defer { lock.unlock() }
        return liveChildOrchestrations.values.filter { $0.phase == .background }
    }

    /// Parent-cancel propagation for retained background calls of a session
    /// (explicit "stop all background", session deletion after a user override,
    /// app shutdown). Returns how many calls were interrupted. Each child then
    /// settles through its own receipt; nothing is marked cancelled here.
    @discardableResult
    public func cancelBackgroundChildOrchestrations(parentSessionID: String) async -> Int {
        let targets = backgroundOrchestrations(parentSessionID: parentSessionID)
        for target in targets { await target.interruptOwner() }
        return targets.count
    }

    internal func observeChildToolRequest(
        locator: ChildTranscriptLocator, messageIndex: Int, callIndex: Int,
        name: String, summary: String
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard messageIndex >= 0, callIndex >= 0,
              let binding = taskRunBindingLocked(runID: locator.runID),
              binding.task.childTranscriptLocator == locator,
              binding.task.status == .running, binding.run.status == .running,
              binding.attempt.status == .running,
              binding.attempt.attemptID == locator.attemptID else {
            throw AgentTaskStoreError.childResultStaleAttempt
        }
        var activities = childToolActivitiesByRunID[locator.runID] ?? []
        guard !activities.contains(where: { $0.messageIndex == messageIndex && $0.callIndex == callIndex }) else { return }
        activities.append(ChildToolActivity(runID: locator.runID, attemptID: locator.attemptID,
            messageIndex: messageIndex, callIndex: callIndex,
            toolName: ProductRedactionPolicy.redact(name, maxLength: 64),
            summary: ProductRedactionPolicy.redact(summary, maxLength: 160), phase: "requested"))
        childToolActivitiesByRunID[locator.runID] = Array(activities.suffix(100))
    }

    public func childToolActivities(taskID: String, parentID: String, runID: String) -> [ChildToolActivity] {
        lock.lock(); defer { lock.unlock() }
        guard let binding = taskRunBindingLocked(runID: runID),
              binding.task.taskID == taskID, binding.task.parentID == parentID,
              binding.attempt.attemptID == attemptIDByRunID[runID] else { return [] }
        return (childToolActivitiesByRunID[runID] ?? []).filter { $0.attemptID == binding.attempt.attemptID }
    }

    public func events(runID: String) -> [AgentTaskEvent] {
        lock.lock(); defer { lock.unlock() }
        return events[runID] ?? []
    }

    /// Diagnostic consumer for rejected late child results. No output, error
    /// text, digest, or evidence reference from the envelope is retained.
    public func rejectedChildResultDiagnostics(runID: String) -> [RejectedChildResultDiagnostic] {
        lock.lock(); defer { lock.unlock() }
        return rejectedChildResults.filter { $0.runID == runID }
    }

    private func recordRejectedChildResult(
        _ envelope: ChildResultEnvelope, reason: RejectedChildResultDiagnostic.Reason
    ) throws {
        let diagnostic = RejectedChildResultDiagnostic(
            taskID: envelope.taskID, runID: envelope.runID,
            attemptID: envelope.attemptID, childExecutionID: envelope.childExecutionID,
            reason: reason
        )
        try transaction {
            rejectedChildResults.append(diagnostic)
            if rejectedChildResults.count > 64 {
                rejectedChildResults.removeFirst(rejectedChildResults.count - 64)
            }
        }
    }

    /// Returns the persisted terminal event for a task, including a queued
    /// task that was cancelled before a run/attempt existed. Queued lifecycle
    /// closures intentionally use the synthetic `queued:<taskKey>` event
    /// identity; exposing this lookup keeps projections from treating that
    /// durable cancellation fact as an unknown or active task.
    public func terminalEvent(taskID: String, parentID: String) -> AgentTaskEvent? {
        lock.lock(); defer { lock.unlock() }
        let key = taskKey(taskID: taskID, parentID: parentID)
        guard tasks[key] != nil else { return nil }
        let runID = controlByTaskKey[key]?.runID ?? "queued:\(key)"
        return events[runID]?.last(where: { Self.isTerminal($0.kind) })
    }

    public func allReceipts() -> [AgentTaskReceipt] {
        lock.lock(); defer { lock.unlock() }
        return receiptOrder.compactMap { receiptByRunID[$0] }
    }

    /// Returns a durable identity for one external submission attempt. The key is derived
    /// only from persisted task/run/attempt identifiers and therefore survives reload.
    public func externalSubmissionIdentity(runID: String) -> AgentExternalSubmissionIdentity? {
        lock.lock(); defer { lock.unlock() }
        guard let run = runs[runID], taskKeyByRunID[runID] != nil else { return nil }
        let attemptID = attemptIDByRunID[runID] ?? "\(runID):attempt:1"
        return AgentExternalSubmissionIdentity(taskID: run.taskID, runID: run.runID, attemptID: attemptID)
    }

    /// Records that the external submit may have happened but local acknowledgement is unknown.
    /// This is intentionally not a terminal event and never authorizes automatic redispatch.
    public func markExternalSubmissionUnknown(runID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let run = runs[runID] else { throw AgentTaskStoreError.unknownRun }
        guard run.status == .running else { return }
        guard !(events[runID] ?? []).contains(where: { $0.kind == .submissionUnknown }) else { return }
        let parentContextSnapshotID = taskKeyByRunID[runID].flatMap { tasks[$0]?.parentContextSnapshotID }
        let event = AgentTaskEvent(runID: runID, parentContextSnapshotID: parentContextSnapshotID, sequence: (events[runID]?.last?.sequence ?? 0) + 1, kind: .submissionUnknown, detail: Self.eventCategory(for: .submissionUnknown))
        try transaction {
            events[runID, default: []].append(event)
        }
    }

    /// The real parent turn freezes a per-child terminal or UNKNOWN join before
    /// reporting its own terminal result. Persistence failure rolls back the fact.
    public func recordParentTurnTerminal(
        parent: ParentRuntimeIdentity,
        execution: AgentExecutionIdentity,
        outcome: AgentParentTurnTerminalFact.Outcome
    ) throws -> AgentParentTurnTerminalFact? {
        lock.lock(); defer { lock.unlock() }
        let childRuns = runs.values.filter { run in
            guard let key = taskKeyByRunID[run.runID] else { return false }
            // O-04: a child that was moved to background is retained by a live
            // owner and is still running. It is not an unjoined child of this
            // foreground turn, so it must not be recorded as needs-review (that
            // would remove its controls); its own receipt settles it later.
            // Design intent, in full:
            //  - If every child of this parent turn is background, `childRuns`
            //    is empty and this returns nil exactly as for a turn without
            //    children. No fact is lost: a fact with no children is invalid
            //    (`parentTerminalFactsAreValid` requires a non-empty child list)
            //    and the background run's own receipt is its terminal fact.
            //  - A parent turn that ends `.failed` does NOT cancel its background
            //    children (they are independent runs with their own receipts and
            //    the frozen deadline). Only an explicit Stop/interrupt, a mode
            //    change or a session deletion attempt ends them.
            //  - While in background such a run has no needsUserReview fact, so
            //    `externalSubmissionDecision` is `.notSubmitted`. That is what
            //    lets the user pause/stop it from the Task Center; it never
            //    permits a re-dispatch because retry requires a terminal receipt.
            //    After an app restart `recoveredRunningRunIDs` still flags it
            //    needsUserReview, as for any other running run.
            if let task = tasks[key], run.status == .running,
               receiptByRunID[run.runID] == nil,
               liveChildOrchestrations.values.contains(where: {
                   $0.phase == .background && $0.parent == parent
                       && $0.parent.taskID == task.parentID && $0.taskIDs.contains(task.taskID)
               }) { return false }
            return (retryRunRuntimeBindingsByRunID[run.runID]?.parent
                ?? tasks[key]?.parentRuntimeIdentity) == parent
        }
        guard !childRuns.isEmpty else { return nil }
        guard Self.parentAndExecutionShareTurn(parent, execution) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        if let existing = parentTurnTerminalFacts.first(where: {
            $0.parent == parent && $0.execution == execution
        }) {
            guard existing.outcome == outcome else { throw AgentTaskStoreError.invalidTerminalSettlement }
            return existing
        }
        guard !parentTurnTerminalFacts.contains(where: {
            $0.execution == execution || $0.parent == parent
        }) else {
            throw AgentTaskStoreError.childResultIdentityMismatch
        }
        let children = childRuns.compactMap { run -> AgentParentTurnTerminalFact.Child? in
            guard let key = taskKeyByRunID[run.runID],
                  let task = tasks[key],
                  (retryRunRuntimeBindingsByRunID[run.runID]?.parent
                    ?? task.parentRuntimeIdentity) == parent,
                  let attemptID = attemptIDByRunID[run.runID] else { return nil }
            let childOutcome: AgentParentTurnTerminalFact.Child.Outcome
            if let receipt = receiptByRunID[run.runID] {
                switch receipt.outcome {
                case .succeeded: childOutcome = .succeeded
                case .failed: childOutcome = .failed
                case .cancelled: childOutcome = .cancelled
                }
            } else {
                childOutcome = .needsUserReview
            }
            let reason: String? = childOutcome == .needsUserReview
                ? (outcome == .cancelled ? "parent-cancelled" :
                    outcome == .timedOut ? "parent-timeout" : nil)
                : nil
            return .init(taskID: task.taskID, runID: run.runID,
                         attemptID: attemptID, outcome: childOutcome,
                         cancellationReason: reason)
        }.sorted { $0.runID < $1.runID }
        guard children.count == childRuns.count else {
            throw AgentTaskStoreError.persistenceFailed
        }
        let fact = AgentParentTurnTerminalFact(parent: parent, execution: execution,
                                                outcome: outcome, children: children)
        try transaction { parentTurnTerminalFacts.append(fact) }
        return fact
    }

    public func parentTurnTerminalFact(
        parent: ParentRuntimeIdentity,
        execution: AgentExecutionIdentity
    ) -> AgentParentTurnTerminalFact? {
        lock.lock(); defer { lock.unlock() }
        return parentTurnTerminalFacts.first { $0.parent == parent && $0.execution == execution }
    }

    /// The Core turn handle is a cancellation scope. Composer owns a separate,
    /// durable zero-based turn ID, so those two numbers need not be equal. The
    /// latter path is admitted only when its frozen task-attempt ID and
    /// execution-message ID bind the same session and durable turn. The
    /// attempt and message UUIDs are distinct; neither is inferred from the
    /// local handle. A parent can own only one terminal join fact.
    private static func parentAndExecutionShareTurn(
        _ parent: ParentRuntimeIdentity,
        _ execution: AgentExecutionIdentity
    ) -> Bool {
        guard parent.isValid, execution.isValid, execution.attempt > 0,
              parent.sessionID == execution.turn.sessionID else { return false }
        if parent.actorID == "app", parent.taskID.hasPrefix("chat:") {
            guard parent.conversationID == parent.sessionID,
                  parent.turnID.hasPrefix("turn-handle:"),
                  let handle = Int(parent.turnID.dropFirst("turn-handle:".count)), handle > 0 else {
                return false
            }
            let composerTurnPrefix = "chat:\(execution.turn.sessionID):\(execution.turn.turnID):"
            guard parent.taskID.hasPrefix(composerTurnPrefix),
                  UUID(uuidString: String(parent.taskID.dropFirst(composerTurnPrefix.count))) != nil,
                  UUID(uuidString: execution.turn.messageID) != nil else { return false }
            return execution.operationID == "\(composerTurnPrefix)\(execution.turn.messageID)"
        }
        return parent.turnID == "turn-handle:\(execution.turn.turnID)"
    }

    public func externalSubmissionDecision(runID: String) -> AgentExternalSubmissionDecision {
        lock.lock(); defer { lock.unlock() }
        if receiptByRunID[runID] != nil { return .settled }
        if (events[runID] ?? []).contains(where: { $0.kind == .submissionUnknown })
            || recoveredRunningRunIDs.contains(runID)
            || parentTurnTerminalFacts.contains(where: { $0.children.contains(where: {
                $0.runID == runID && $0.outcome == .needsUserReview
            }) }) {
            return .needsUserReview
        }
        return .notSubmitted
    }

    /// A persisted running run has an unknown external-submission outcome after restart.
    /// Callers must obtain user review rather than automatically resuming or redispatching it.
    public func recoveryState(runID: String) -> AgentTaskRecoveryState? {
        lock.lock(); defer { lock.unlock() }
        guard runs[runID]?.status == .running else { return nil }
        guard externalSubmissionDecisionLocked(runID: runID) == .needsUserReview else { return nil }
        return .needsUserReview
    }

    private func externalSubmissionDecisionLocked(runID: String) -> AgentExternalSubmissionDecision {
        if receiptByRunID[runID] != nil { return .settled }
        if (events[runID] ?? []).contains(where: { $0.kind == .submissionUnknown })
            || recoveredRunningRunIDs.contains(runID)
            || parentTurnTerminalFacts.contains(where: { $0.children.contains(where: {
                $0.runID == runID && $0.outcome == .needsUserReview
            }) }) {
            return .needsUserReview
        }
        return .notSubmitted
    }

    private func currentState() -> State {
        State(
            tasks: tasks,
            taskKeyByRunID: taskKeyByRunID,
            runs: runs,
            attempts: attempts,
            attemptIDByRunID: attemptIDByRunID,
            events: events,
            rejectedChildResults: rejectedChildResults,
            receiptByRunID: receiptByRunID,
            receiptOrder: receiptOrder,
            controlByTaskKey: controlByTaskKey,
            controlReceiptByIdempotencyKey: controlReceiptByIdempotencyKey,
            creationTaskKeyByIdempotencyKey: creationTaskKeyByIdempotencyKey,
            archiveByTaskKey: archiveByTaskKey,
            archiveReceiptByIdempotencyKey: archiveReceiptByIdempotencyKey,
            parentTurnTerminalFacts: parentTurnTerminalFacts,
            childLaunchIntents: childLaunchIntentsByID,
            retryRunRuntimeBindings: retryRunRuntimeBindingsByRunID
        )
    }

    private func restore(_ state: State) {
        tasks = state.tasks
        taskKeyByRunID = state.taskKeyByRunID
        runs = state.runs
        attempts = state.attempts
        attemptIDByRunID = state.attemptIDByRunID
        events = state.events
        rejectedChildResults = state.rejectedChildResults
        receiptByRunID = state.receiptByRunID
        receiptOrder = state.receiptOrder
        controlByTaskKey = state.controlByTaskKey
        controlReceiptByIdempotencyKey = state.controlReceiptByIdempotencyKey
        creationTaskKeyByIdempotencyKey = state.creationTaskKeyByIdempotencyKey
        archiveByTaskKey = state.archiveByTaskKey
        archiveReceiptByIdempotencyKey = state.archiveReceiptByIdempotencyKey
        parentTurnTerminalFacts = state.parentTurnTerminalFacts
        childLaunchIntentsByID = state.childLaunchIntents
        retryRunRuntimeBindingsByRunID = state.retryRunRuntimeBindings
    }

    private func ensureControlSnapshots() {
        for taskKey in tasks.keys where controlByTaskKey[taskKey] == nil {
            guard let task = tasks[taskKey] else { continue }
            let runID = taskKeyByRunID.first(where: { $0.value == taskKey })?.key
            let state: AgentTaskControlState = {
                switch task.status {
                case .queued, .running: return .active
                case .succeeded, .failed: return .terminal
                case .cancelled: return .stopped
                }
            }()
            controlByTaskKey[taskKey] = AgentTaskControlSnapshot(
                taskID: task.taskID,
                parentID: task.parentID,
                state: state,
                controlRevision: 0,
                runID: runID
            )
        }
    }

    private func transaction<Result>(_ mutation: () throws -> Result) throws -> Result {
        let previous = currentState()
        do {
            let result = try mutation()
            try persist()
            taskCenterMutationVersion &+= 1
            return result
        } catch {
            restore(previous)
            throw error
        }
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        do {
            try withPersistenceLock(for: persistenceURL) {
                try persistUnlocked(at: persistenceURL)
            }
        } catch let error as AgentTaskStoreError {
            if error == .staleWriter {
                persistenceDiagnostic = AgentPersistenceDiagnostic(
                    operation: "persist",
                    reason: "stale-writer",
                    message: "The task ledger changed in another instance; the mutation was rejected."
                )
            }
            throw error
        } catch {
            if persistenceDiagnostic == nil {
                persistenceDiagnostic = AgentPersistenceDiagnostic(
                    operation: "persist",
                    reason: "write-failed",
                    message: "The task ledger could not be persisted; the mutation was rolled back."
                )
            }
            throw AgentTaskStoreError.persistenceFailed
        }
    }

    private func persistUnlocked(at persistenceURL: URL) throws {
        let temporaryURL = persistenceURL.appendingPathExtension("tmp")
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: persistenceURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            allowsRecreateAfterStructuralFailure = true
            persistenceDiagnostic = AgentPersistenceDiagnostic(
                operation: "persist",
                reason: "destination-is-directory",
                message: "The task ledger destination is not a regular file; the mutation was rolled back."
            )
            throw CocoaError(.fileWriteFileExists)
        }
        if let persistedData = try? Data(contentsOf: persistenceURL) {
            guard persistenceBaseline == persistedData else { throw AgentTaskStoreError.staleWriter }
        } else {
            guard persistenceBaseline == nil || allowsRecreateAfterStructuralFailure else {
                throw AgentTaskStoreError.staleWriter
            }
        }
        try? fileManager.removeItem(at: temporaryURL)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let data = try JSONEncoder().encode(PersistenceEnvelope(state: currentState()))
        if persistenceFault == .diskFull {
            persistenceDiagnostic = AgentPersistenceDiagnostic(
                operation: "persist",
                reason: "disk-full",
                message: "The task ledger could not be written because storage is unavailable; the mutation was rolled back."
            )
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: temporaryURL)
        if fileManager.fileExists(atPath: persistenceURL.path) {
            _ = try fileManager.replaceItemAt(persistenceURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: persistenceURL)
        }
        persistenceBaseline = data
        allowsRecreateAfterStructuralFailure = false
    }

    private func withPersistenceLock<Result>(for persistenceURL: URL, _ body: () throws -> Result) throws -> Result {
        let processLock = Self.persistenceLockRegistry.lock(for: persistenceURL.standardizedFileURL.path)
        processLock.lock()
        defer { processLock.unlock() }

        let lockURL = persistenceURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AgentTaskStoreError.persistenceFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AgentTaskStoreError.persistenceFailed }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validate(_ state: State) throws {
        guard state.childLaunchIntents.allSatisfy({ key, record in
                  guard key == record.intent.intentID && record.isWellFormed else { return false }
                  guard let runID = record.intent.runID else { return true }
                  guard let taskKey = state.taskKeyByRunID[runID], let task = state.tasks[taskKey],
                        let executionID = record.intent.executionID else { return false }
                  let retry = state.retryRunRuntimeBindings[runID]
                  return task.taskID == record.intent.taskID
                      && (retry.map {
                          task.parentID == $0.originalParentID
                              && record.intent.parent == $0.parent
                              && record.parentGoal == $0.parentGoal
                              && record.parentBinding == $0.child.providerSnapshot
                        } ?? (task.parentID == record.intent.parent.taskID
                          && task.parentRuntimeIdentity == record.intent.parent
                          && task.parentContextSnapshotID == record.intent.parentContextSnapshotID))
                      && state.attemptIDByRunID[runID] == record.intent.attemptID
                      && record.intent.attemptID.flatMap { state.attempts[$0]?.runID } == runID
                      && ((retry?.child ?? task.childRuntimeIdentity)?
                          .matchesVerifiedExecutionID(executionID)
                          ?? (record.parentGoal == nil))
              }),
              state.retryRunRuntimeBindings.allSatisfy({ runID, binding in
                  guard binding.runID == runID,
                        let key = state.taskKeyByRunID[runID],
                        let task = state.tasks[key],
                        let run = state.runs[runID],
                        let attempt = state.attempts[binding.attemptID],
                        state.attemptIDByRunID[runID] == binding.attemptID,
                        task.taskID == binding.taskID,
                        task.parentID == binding.originalParentID,
                        run.taskID == binding.taskID,
                        attempt.runID == runID,
                        let originalParent = task.parentRuntimeIdentity,
                        let originalChild = task.childRuntimeIdentity else { return false }
                  return binding.parent.isValid
                      && binding.parent.sessionID == originalParent.sessionID
                      && binding.parent.conversationID == originalParent.conversationID
                      && binding.parent.actorID == originalParent.actorID
                      && binding.parent.taskID != originalParent.taskID
                      && binding.parent.taskID != originalParent.taskID
                      && binding.child.childTaskID == binding.taskID
                      && binding.child.parentTaskID == binding.parent.taskID
                      && binding.child.childSessionID != originalChild.childSessionID
                      && binding.child.hasVerifiedRootBoundary(
                          parent: binding.parent, goal: binding.parentGoal
                      )
                      && (try? binding.child.requireVerifiedGeneration()) != nil
                      && state.controlReceiptByIdempotencyKey.values.contains(where: {
                          $0.command == .retry && $0.taskID == binding.taskID
                              && $0.parentID == binding.originalParentID
                              && $0.resultingRunID == runID
                      })
              }),
              Set(state.retryRunRuntimeBindings.values.map { $0.child.childSessionID }).count
                == state.retryRunRuntimeBindings.count,
              state.childLaunchIntents.values.allSatisfy({ record in
                  guard let previousID = record.intent.recoveredFromIntentID else { return true }
                  guard let previous = state.childLaunchIntents[previousID] else { return false }
                  return previous.status != .admitted
                      && previous.intent.intentID != record.intent.intentID
                      && sameChildLaunchRequest(previous, record)
                      && state.childLaunchIntents.values.filter {
                          $0.intent.recoveredFromIntentID == previousID
                      }.count == 1
              }),
              hasValidOneLevelChildGraph(Array(state.tasks.values)),
              hasUnambiguousChildResultRoutes(state),
              state.rejectedChildResults.count <= 64,
              state.rejectedChildResults.allSatisfy({ diagnostic in
                  state.runs[diagnostic.runID]?.taskID == diagnostic.taskID
                      && state.attempts[diagnostic.attemptID]?.runID == diagnostic.runID
              }),
              state.events.values.allSatisfy({ runEvents in
                  // Validate the persisted append order before restoring a run.
                  runEvents.enumerated().allSatisfy { offset, event in
                      event.sequence == offset + 1
                  }
              }),
              Set(state.receiptOrder).count == state.receiptOrder.count,
              state.receiptOrder.allSatisfy({ state.receiptByRunID[$0] != nil }),
              state.taskKeyByRunID.allSatisfy({ runID, taskKey in
                  state.runs[runID] != nil && state.tasks[taskKey] != nil
              }),
              state.attemptIDByRunID.allSatisfy({ runID, attemptID in
                  state.runs[runID] != nil && state.attempts[attemptID]?.runID == runID
              }),
              state.runs.allSatisfy({ runID, run in
                  run.runID == runID && state.taskKeyByRunID[runID].flatMap { state.tasks[$0] }?.taskID == run.taskID
              }),
              state.tasks.allSatisfy({ taskKey, task in
                  if let origin = task.parentRuntimeIdentity {
                      guard origin.isValid, origin.taskID == task.parentID,
                            task.creation == nil || task.creation?.source == origin else { return false }
                  }
                  if let child = task.childRuntimeIdentity {
                      guard let origin = task.parentRuntimeIdentity,
                            child.schemaVersion == ChildRuntimeIdentity.currentSchemaVersion,
                            child.rootParentIdentity == origin,
                            child.parentGoalID != nil,
                            child.parentGoalScopeID?.isEmpty == false,
                            child.childTaskID == task.taskID,
                            child.parentTaskID == task.parentID,
                            (try? child.requireVerifiedGeneration()) != nil else { return false }
                  }
                  guard let locator = task.childTranscriptLocator else { return true }
                  guard locator.isWellFormed,
                        locator.taskID == task.taskID,
                        locator.parentID == task.parentID,
                        (state.retryRunRuntimeBindings[locator.runID].map {
                            locator.runtimeParentID == $0.parent.taskID
                                && locator.childSessionID == $0.child.childSessionID
                        } ?? (locator.runtimeParentID == nil)),
                        locator.parentContextSnapshotID == task.parentContextSnapshotID,
                        task.sourceSessionID == nil
                          || task.sourceSessionID == locator.parentSessionID,
                        state.taskKeyByRunID[locator.runID] == taskKey,
                        let run = state.runs[locator.runID],
                        run.taskID == task.taskID,
                        run.parentContextSnapshotID == task.parentContextSnapshotID,
                        state.attemptIDByRunID[locator.runID] == locator.attemptID,
                        let attempt = state.attempts[locator.attemptID],
                        attempt.runID == locator.runID,
                        attempt.parentContextSnapshotID == task.parentContextSnapshotID,
                        let control = state.controlByTaskKey[taskKey],
                        control.taskID == task.taskID,
                        control.parentID == task.parentID,
                        control.runID == locator.runID else { return false }
                  return true
              }),
              state.controlByTaskKey.isEmpty || state.tasks.keys.allSatisfy({ taskKey in
                  state.controlByTaskKey[taskKey]?.taskID == state.tasks[taskKey]?.taskID
              }),
              state.receiptByRunID.allSatisfy({ runID, receipt in
                  guard receipt.runID == runID, state.runs[runID] != nil else {
                      return false
                  }
                  guard let envelope = receipt.childResultEnvelope else {
                      return true
                  }
                  guard let taskKey = state.taskKeyByRunID[runID],
                        let task = state.tasks[taskKey],
                        state.attemptIDByRunID[runID] == receipt.attemptID,
                        let attempt = state.attempts[receipt.attemptID] else {
                      return false
                  }
                  return envelope.isWellFormed
                      && envelope.taskID == receipt.taskID
                      && envelope.runID == receipt.runID
                      && envelope.attemptID == receipt.attemptID
                      && envelope.parentContextSnapshotID == receipt.parentContextSnapshotID
                      && task.taskID == envelope.taskID
                      && task.parentContextSnapshotID == envelope.parentContextSnapshotID
                      && ((state.retryRunRuntimeBindings[runID]?.child
                          ?? task.childRuntimeIdentity)?.matchesVerifiedExecutionID(
                          envelope.childExecutionID
                      ) ?? true)
                      && attempt.runID == envelope.runID
                      && attempt.attempt == envelope.attemptNumber
                      && attempt.parentContextSnapshotID == envelope.parentContextSnapshotID
                      && (envelope.childTranscriptLocator == nil
                          || envelope.childTranscriptLocator?.parentID == task.parentID)
                      && (envelope.childTranscriptLocator == nil
                          || (state.retryRunRuntimeBindings[runID].map {
                              envelope.childTranscriptLocator?.runtimeParentID == $0.parent.taskID
                                  && envelope.childTranscriptLocator?.childSessionID
                                      == $0.child.childSessionID
                          } ?? (envelope.childTranscriptLocator?.runtimeParentID == nil)))
                      && (state.controlByTaskKey[taskKey]?.runID != runID
                          || envelope.childTranscriptLocator == task.childTranscriptLocator)
              }),
              state.controlReceiptByIdempotencyKey.allSatisfy({ key, receipt in
                  key == receipt.idempotencyKey
              }),
              state.tasks.allSatisfy({ _, task in
                  guard let creation = task.creation else { return true }
                  guard !creation.scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        !creation.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        creation.action.action == .new,
                        creation.action.source.taskID == task.parentID,
                        creation.action.switchAfterCreate == false,
                        let title = creation.action.title,
                        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        let projectID = creation.action.projectID,
                        !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                      return false
                  }
                  return (try? creation.action.validate(against: creation.source)) != nil
              }),
              state.creationTaskKeyByIdempotencyKey.allSatisfy({ key, taskKey in
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  state.tasks[taskKey]?.creation?.idempotencyKey == key
              }),
              state.archiveByTaskKey.allSatisfy({ taskKey, archive in
                  guard let task = state.tasks[taskKey] else { return false }
                  return archive.taskID == task.taskID
                      && archive.parentID == task.parentID
                      && archive.sourceSessionID == task.sourceSessionID
                      && archive.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                      && archive.attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                      && archive.eventSequence > 0
              }),
              state.archiveReceiptByIdempotencyKey.allSatisfy({ key, receipt in
                  guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        key == receipt.request.idempotencyKey,
                        receipt.request.taskID == receipt.archive.taskID,
                        receipt.request.parentID == receipt.archive.parentID,
                        receipt.request.runID == receipt.archive.runID,
                        receipt.request.attemptID == receipt.archive.attemptID,
                        receipt.request.eventSequence == receipt.archive.eventSequence,
                        receipt.request.sourceSessionID == receipt.archive.sourceSessionID,
                        state.tasks[receipt.archive.parentID + "\u{1F}" + receipt.archive.taskID] != nil else {
                      return false
                  }
                  return true
              }) else {
            throw AgentTaskStoreError.persistenceFailed
        }
        // Capture-before-checkpoint crashes can leave several queued links.
        // Preserve the unique chain but reject corrupt cycles; no decoded
        // record may turn that chain into a dispatch authority.
        for record in state.childLaunchIntents.values {
            var seen: Set<String> = [record.intent.intentID]
            var priorID = record.intent.recoveredFromIntentID
            while let id = priorID {
                guard seen.insert(id).inserted else { throw AgentTaskStoreError.persistenceFailed }
                priorID = state.childLaunchIntents[id]?.intent.recoveredFromIntentID
            }
        }
        guard parentTerminalFactsAreValid(state) else {
            throw AgentTaskStoreError.persistenceFailed
        }
    }

    private static func parentTerminalFactsAreValid(_ state: State) -> Bool {
        var identities = Set<AgentExecutionIdentity>()
        var parents = Set<ParentRuntimeIdentity>()
        for fact in state.parentTurnTerminalFacts {
            guard parentAndExecutionShareTurn(fact.parent, fact.execution),
                  identities.insert(fact.execution).inserted,
                  parents.insert(fact.parent).inserted,
                  !fact.children.isEmpty,
                  Set(fact.children.map(\.runID)).count == fact.children.count else {
                return false
            }
            for child in fact.children {
                guard let run = state.runs[child.runID],
                      run.taskID == child.taskID,
                      state.attemptIDByRunID[child.runID] == child.attemptID,
                      let key = state.taskKeyByRunID[child.runID],
                      (state.retryRunRuntimeBindings[child.runID]?.parent
                        ?? state.tasks[key]?.parentRuntimeIdentity) == fact.parent else {
                    return false
                }
                // A historical UNKNOWN may later gain a real receipt. A
                // claimed terminal child, however, must already have had its
                // own matching durable receipt when the parent joined it.
                if child.outcome != .needsUserReview {
                    guard let receipt = state.receiptByRunID[child.runID],
                          receipt.taskID == child.taskID,
                          receipt.attemptID == child.attemptID else {
                        return false
                    }
                    let matchesTerminal: Bool
                    switch (child.outcome, receipt.outcome) {
                    case (.succeeded, .succeeded), (.failed, .failed), (.cancelled, .cancelled):
                        matchesTerminal = true
                    default:
                        matchesTerminal = false
                    }
                    guard matchesTerminal else { return false }
                }
                if let reason = child.cancellationReason {
                    guard child.outcome == .needsUserReview,
                          (fact.outcome == .cancelled && reason == "parent-cancelled")
                            || (fact.outcome == .timedOut && reason == "parent-timeout") else {
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Only a task with a durable orchestration identity is an agent child.
    /// Generic task-center parent/child records retain their existing control
    /// semantics. Reject the forbidden second layer and any unambiguous
    /// parent cycle at both enqueue and recovery. A task ID used under more
    /// than one parent cannot identify one durable parent node by itself.
    private static func hasValidOneLevelChildGraph(_ tasks: [AgentTaskSnapshot]) -> Bool {
        let agentChildIDs = Set(tasks.compactMap { task -> String? in
            task.parentRuntimeIdentity != nil || task.childRuntimeIdentity != nil
                || task.childTranscriptLocator != nil ? task.taskID : nil
        })
        guard tasks.allSatisfy({ task in
            task.taskID != task.parentID && !agentChildIDs.contains(task.parentID)
        }) else { return false }

        let uniqueParentByTaskID = Dictionary(grouping: tasks, by: \.taskID)
            .compactMapValues { siblings in
                siblings.count == 1 ? siblings[0].parentID : nil
            }
        var knownAcyclic = Set<String>()
        for start in uniqueParentByTaskID.keys {
            var path = Set<String>()
            var current = start
            while let parent = uniqueParentByTaskID[current],
                  !knownAcyclic.contains(current) {
                guard path.insert(current).inserted else { return false }
                current = parent
            }
            knownAcyclic.formUnion(path)
        }
        return true
    }

    private static func hasUnambiguousChildResultRoutes(_ state: State) -> Bool {
        var idempotencyKeys = Set<String>()
        var ownerByRoute: [String: String] = [:]
        for receipt in state.receiptByRunID.values {
            guard let envelope = receipt.childResultEnvelope else { continue }
            guard idempotencyKeys.insert(envelope.idempotencyKey).inserted,
                  let key = state.taskKeyByRunID[receipt.runID],
                  let task = state.tasks[key] else { return false }
            let route = "\(task.parentID.utf8.count):\(task.parentID)\(envelope.childExecutionID)"
            if let owner = ownerByRoute[route], owner != task.taskID { return false }
            ownerByRoute[route] = task.taskID
        }
        return true
    }

    private static func matches(eventKind: AgentTaskEventKind, outcome: AgentTaskOutcome) -> Bool {
        switch (eventKind, outcome) {
        case (.completed, .succeeded), (.failed, .failed), (.cancelled, .cancelled): return true
        default: return false
        }
    }

    private static func isTerminal(_ kind: AgentTaskEventKind) -> Bool {
        AsyncTerminalStateRules.isTerminal(eventKind: kind)
    }

    private static func eventCategory(for kind: AgentTaskEventKind) -> String {
        switch kind {
        case .started: return "started"
        case .progress: return "progress"
        case .approvalRequired: return "approval-required"
        case .inputRequired: return "input-required"
        case .submissionUnknown: return "submission-unknown"
        case .completed: return "completed"
        case .failed: return "execution-failed"
        case .cancelled: return "cancelled"
        case .terminalDuplicate: return "terminal-duplicate"
        }
    }

    private static func redactedOutcome(_ outcome: AgentTaskOutcome) -> AgentTaskOutcome {
        switch outcome {
        case .succeeded: return .succeeded
        case .cancelled: return .cancelled
        case .failed: return .failed(reason: "execution-failed")
        }
    }

    private func updateTask(
        _ taskKey: String,
        status: AgentTaskStatus,
        clearChildTranscriptLocator: Bool = false
    ) {
        guard let task = tasks[taskKey] else { return }
        tasks[taskKey] = AgentTaskSnapshot(
            taskID: task.taskID,
            parentID: task.parentID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            providerID: task.providerID,
            modelID: task.modelID,
            configurationFingerprint: task.configurationFingerprint,
            routeReceiptID: task.routeReceiptID,
            status: status,
            creation: task.creation, dispatchHumanTitle: task.dispatchHumanTitle,
            archivedAt: task.archivedAt,
            childTranscriptLocator: clearChildTranscriptLocator ? nil : task.childTranscriptLocator,
            parentRuntimeIdentity: task.parentRuntimeIdentity,
            childRuntimeIdentity: task.childRuntimeIdentity
        )
    }

    private func updateControl(
        _ taskKey: String,
        state: AgentTaskControlState,
        runID: String?
    ) {
        guard let control = controlByTaskKey[taskKey] else { return }
        controlByTaskKey[taskKey] = AgentTaskControlSnapshot(
            taskID: control.taskID,
            parentID: control.parentID,
            state: state,
            controlRevision: control.controlRevision + 1,
            runID: runID
        )
    }

    private func requireRunIfNeeded(
        task: AgentTaskSnapshot,
        control: AgentTaskControlSnapshot,
        runID: String?
    ) throws {
        guard task.status == .running else {
            guard runID == nil else { throw AgentTaskStoreError.unknownRun }
            return
        }
        guard let runID,
              control.runID == runID,
              runs[runID]?.taskID == task.taskID,
              runs[runID]?.status == .running else {
            throw AgentTaskStoreError.unknownRun
        }
        guard externalSubmissionDecisionLocked(runID: runID) == .notSubmitted else {
            throw AgentTaskStoreError.externalSubmissionUnknown
        }
    }

    private func cancelQueuedLocked(_ taskKey: String) {
        guard let task = tasks[taskKey], task.status == .queued else { return }
        updateTask(taskKey, status: .cancelled)
        let runID = "queued:\(taskKey)"
        events[runID] = [
            AgentTaskEvent(
                runID: runID,
                parentContextSnapshotID: task.parentContextSnapshotID,
                sequence: 1,
                kind: .cancelled,
                detail: "cancelled"
            )
        ]
    }

    /// Returns all active descendants below the target, breadth-first and deterministic.
    private func descendantTaskKeysLocked(rootKey: String) -> [String] {
        guard let root = tasks[rootKey] else { return [] }
        var pending = [root.taskID]
        var result: [String] = []
        var visited: Set<String> = []
        while !pending.isEmpty {
            let parentTaskID = pending.removeFirst()
            let children = tasks.values
                .filter { $0.parentID == parentTaskID }
                .sorted {
                    if $0.parentID != $1.parentID { return $0.parentID < $1.parentID }
                    return $0.taskID < $1.taskID
                }
            for child in children {
                let childKey = taskKey(taskID: child.taskID, parentID: child.parentID)
                guard childKey != rootKey, visited.insert(childKey).inserted else { continue }
                result.append(childKey)
                pending.append(child.taskID)
            }
        }
        return result
    }

    private func taskKey(taskID: String, parentID: String) -> String {
        parentID + "\u{1F}" + taskID
    }
}
