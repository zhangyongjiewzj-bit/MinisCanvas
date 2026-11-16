import Foundation

public enum GoalTaskTerminalTruthOutcome: String, Codable, Equatable, Sendable {
    case policyRefused
    case dryRun
    case executionFailed
    case cancelled
    case succeeded
}

/// Identity-bound terminal projection shared by control/UI consumers. A
/// control receipt may project only a terminal task status; rejected requests
/// must use the policy-refused outcome and can never be projected as success.
public struct GoalTaskTerminalTruth: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let revision: String
    public let scopeID: String
    public let actorID: String
    public let idempotencyKey: String
    public let runID: String?
    public let outcome: GoalTaskTerminalTruthOutcome
    public let reason: String?

    public init(
        request: GoalTaskCenterCommandRequest,
        outcome: GoalTaskTerminalTruthOutcome,
        reason: String? = nil
    ) {
        taskID = request.taskID
        parentID = request.parentID
        revision = request.revision
        scopeID = request.scopeID
        actorID = request.actorID
        idempotencyKey = request.idempotencyKey
        runID = request.runID
        self.outcome = outcome
        self.reason = reason
    }

    public var isSuccess: Bool { outcome == .succeeded }
}

public enum GoalTaskControlExecutorError: Error, Equatable, Sendable {
    case needsUserReview(GoalTaskCenterReviewReason)
    case idempotencyKeyConflict
    case controlRevisionMismatch
    case controlStateConflict
    case unknownTask
    case unknownRun
    case persistenceFailed
    case unsupportedCommand

    /// Converts a failed command admission into the same identity-bound
    /// terminal vocabulary used by the stream consumer. The original error
    /// remains available to callers; this projection is never success.
    public func terminalTruth(for request: GoalTaskCenterCommandRequest) -> GoalTaskTerminalTruth {
        switch self {
        case .needsUserReview(let reason):
            return GoalTaskTerminalTruth(
                request: request,
                outcome: .policyRefused,
                reason: reason.rawValue
            )
        default:
            return GoalTaskTerminalTruth(
                request: request,
                outcome: .executionFailed,
                reason: String(describing: self)
            )
        }
    }
}

/// Core-only command executor for Goal/Task Center controls.
///
/// It performs no provider, App, GUI, or network work. External submission
/// uncertainty and recovered running work are deliberately rejected.
public struct GoalTaskControlExecutionReceipt: Equatable, Sendable {
    public let request: GoalTaskCenterCommandRequest
    public let beforeRevision: String
    /// The durable attempt bound to the request's run, when a run was
    /// supplied. A control receipt must not make callers reconstruct this
    /// identity from a mutable task snapshot.
    public let beforeAttemptID: String?
    public let afterFact: GoalTaskCenterTaskFact
    public let resultingRunID: String?
    /// Retry creates a new run and attempt atomically. This is nil for
    /// pause/resume/stop, which do not create a replacement run.
    public let resultingAttemptID: String?
    public let cancelledTaskIDs: [String]

    public init(
        request: GoalTaskCenterCommandRequest,
        beforeRevision: String,
        beforeAttemptID: String? = nil,
        afterFact: GoalTaskCenterTaskFact,
        resultingRunID: String?,
        resultingAttemptID: String? = nil,
        cancelledTaskIDs: [String]
    ) {
        self.request = request
        self.beforeRevision = beforeRevision
        self.beforeAttemptID = beforeAttemptID
        self.afterFact = afterFact
        self.resultingRunID = resultingRunID
        self.resultingAttemptID = resultingAttemptID
        self.cancelledTaskIDs = cancelledTaskIDs
    }

    /// A command receipt is terminal only when its projected task fact is
    /// terminal. Pause/resume/retry remain non-terminal and expose no success
    /// fact, preventing an admission receipt from masquerading as execution
    /// success.
    public var terminalTruth: GoalTaskTerminalTruth? {
        let outcome: GoalTaskTerminalTruthOutcome
        switch afterFact.status {
        case .succeeded:
            outcome = .succeeded
        case .failed:
            outcome = .executionFailed
        case .cancelled:
            outcome = .cancelled
        case .queued, .running:
            return nil
        }
        return GoalTaskTerminalTruth(
            request: request,
            outcome: outcome,
            reason: outcome == .succeeded ? nil : outcome.rawValue
        )
    }
}

public final class GoalTaskControlExecutor: @unchecked Sendable {
    private let store: AgentTaskStore
    private let facade: GoalTaskCenterFacade
    private let lock = NSLock()

    public init(store: AgentTaskStore, bindings: [GoalTaskCenterBinding]) throws {
        self.store = store
        self.facade = try GoalTaskCenterFacade(store: store, bindings: bindings)
    }

    public init(store: AgentTaskStore, facade: GoalTaskCenterFacade) {
        self.store = store
        self.facade = facade
    }

    public func project(now: Date = Date()) -> GoalTaskCenterProjection {
        facade.project(now: now)
    }

    public func execute(
        _ request: GoalTaskCenterCommandRequest,
        now: Date = Date()
    ) throws -> GoalTaskControlExecutionReceipt {
        lock.lock()
        defer { lock.unlock() }

        if let durable = store.controlReceipt(idempotencyKey: request.idempotencyKey) {
            guard matches(request: request, durable: durable) else {
                throw GoalTaskControlExecutorError.idempotencyKeyConflict
            }
            guard let afterFact = durable.afterFact ?? facade.project(now: now).fact(
                taskID: request.taskID,
                parentID: request.parentID
            ) else {
                throw GoalTaskControlExecutorError.unknownTask
            }
            let beforeAttemptID = try historicalAttemptID(
                for: request.runID,
                taskID: request.taskID,
                parentID: request.parentID
            )
            let resultingAttemptID = try historicalAttemptID(
                for: durable.resultingRunID,
                taskID: request.taskID,
                parentID: request.parentID
            )
            return GoalTaskControlExecutionReceipt(
                request: request,
                beforeRevision: durable.revision,
                beforeAttemptID: beforeAttemptID,
                afterFact: afterFact,
                resultingRunID: durable.resultingRunID,
                resultingAttemptID: resultingAttemptID,
                cancelledTaskIDs: durable.cancelledTaskIDs
            )
        }

        let admission = try facade.submit(request, now: now)
        switch admission.decision {
        case .needsProductionExecutor:
            break
        case .needsUserReview(let reason):
            throw GoalTaskControlExecutorError.needsUserReview(reason)
        }

        guard let beforeFact = facade.project(now: now).fact(
            taskID: request.taskID,
            parentID: request.parentID
        ) else {
            throw GoalTaskControlExecutorError.unknownTask
        }
        let beforeAttemptID = try canonicalAttemptID(for: request.runID)
        try rejectUncertainExternalSubmission(request: request, fact: beforeFact)

        guard let command = AgentTaskControlCommand(rawValue: request.command.rawValue) else {
            throw GoalTaskControlExecutorError.unsupportedCommand
        }
        let resultingRunID: String? = {
            guard request.command == .retry else { return nil }
            return "\(request.taskID):retry:\(request.idempotencyKey)"
        }()
        let cancelledTaskIDs = command == .stop
            ? store.controlTaskIDsToStop(taskID: request.taskID, parentID: request.parentID)
            : []
        let finalState: AgentTaskControlState = {
            switch command {
            case .pause: return .paused
            case .resume, .retry: return .active
            case .stop: return .stopped
            }
        }()
        let controlRevision = beforeFact.controlRevision + 1
        guard let currentTask = store.snapshot(taskID: request.taskID, parentID: request.parentID),
              let currentControl = store.controlSnapshot(taskID: request.taskID, parentID: request.parentID) else {
            throw GoalTaskControlExecutorError.unknownTask
        }
        let afterStatus: AgentTaskStatus = command == .retry
            ? .running
            : (command == .stop ? .cancelled : currentTask.status)
        let afterControl = AgentTaskControlSnapshot(
            taskID: currentControl.taskID,
            parentID: currentControl.parentID,
            state: finalState,
            controlRevision: controlRevision,
            runID: command == .retry
                ? resultingRunID
                : (command == .stop ? currentControl.runID : (request.runID ?? currentControl.runID))
        )
        let afterTask = AgentTaskSnapshot(
            taskID: currentTask.taskID,
            parentID: currentTask.parentID,
            parentContextSnapshotID: currentTask.parentContextSnapshotID,
            providerID: currentTask.providerID,
            modelID: currentTask.modelID,
            configurationFingerprint: currentTask.configurationFingerprint,
            routeReceiptID: currentTask.routeReceiptID,
            status: afterStatus
        )
        guard let predictedAfterFact = facade.fact(
            snapshot: afterTask,
            control: afterControl,
            now: now
        ) else {
            throw GoalTaskControlExecutorError.unknownTask
        }
        let durableReceipt = AgentTaskControlReceipt(
            taskID: request.taskID,
            parentID: request.parentID,
            idempotencyKey: request.idempotencyKey,
            command: command,
            revision: beforeFact.revision,
            scopeID: request.scopeID,
            actorID: request.actorID,
            runID: request.runID,
            resultingRunID: resultingRunID,
            controlState: finalState,
            controlRevision: controlRevision,
            cancelledTaskIDs: cancelledTaskIDs,
            afterFact: predictedAfterFact
        )

        do {
            _ = try store.applyControl(
                taskID: request.taskID,
                parentID: request.parentID,
                command: command,
                expectedControlRevision: beforeFact.controlRevision,
                runID: request.runID,
                resultingRunID: resultingRunID,
                receipt: durableReceipt
            )
        } catch let error as AgentTaskStoreError {
            throw map(error)
        }

        guard let afterFact = facade.project(now: now).fact(
            taskID: request.taskID,
            parentID: request.parentID
        ) else {
            throw GoalTaskControlExecutorError.unknownTask
        }
        let resultingAttemptID = try canonicalAttemptID(for: resultingRunID)
        return GoalTaskControlExecutionReceipt(
            request: request,
            beforeRevision: beforeFact.revision,
            beforeAttemptID: beforeAttemptID,
            afterFact: afterFact,
            resultingRunID: resultingRunID,
            resultingAttemptID: resultingAttemptID,
            cancelledTaskIDs: cancelledTaskIDs
        )
    }

    private func rejectUncertainExternalSubmission(
        request: GoalTaskCenterCommandRequest,
        fact: GoalTaskCenterTaskFact
    ) throws {
        for runID in request.runID.map({ [$0] }) ?? [] {
            if store.externalSubmissionDecision(runID: runID) == .needsUserReview {
                let reason: GoalTaskCenterReviewReason = store.recoveryState(runID: runID) == .needsUserReview
                    ? .recoveredRunningTask
                    : .externalSubmissionUnknown
                throw GoalTaskControlExecutorError.needsUserReview(reason)
            }
        }
        if fact.status == .running,
           let runID = request.runID,
           store.recoveryState(runID: runID) == .needsUserReview {
            throw GoalTaskControlExecutorError.needsUserReview(.recoveredRunningTask)
        }
    }

    private func canonicalAttemptID(for runID: String?) throws -> String? {
        guard let runID else { return nil }
        guard let attemptID = store.canonicalAttemptID(runID: runID),
              !attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.attempt(runID: runID, attemptID: attemptID) != nil else {
            throw GoalTaskControlExecutorError.unknownRun
        }
        return attemptID
    }

    private func historicalAttemptID(
        for runID: String?,
        taskID: String,
        parentID: String
    ) throws -> String? {
        guard let runID else { return nil }
        guard let attempt = store.historicalAttempt(
            runID: runID,
            taskID: taskID,
            parentID: parentID
        ), !attempt.attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoalTaskControlExecutorError.unknownRun
        }
        return attempt.attemptID
    }

    private func matches(
        request: GoalTaskCenterCommandRequest,
        durable: AgentTaskControlReceipt
    ) -> Bool {
        durable.taskID == request.taskID
            && durable.parentID == request.parentID
            && durable.idempotencyKey == request.idempotencyKey
            && durable.command.rawValue == request.command.rawValue
            && durable.revision == request.revision
            && durable.scopeID == request.scopeID
            && durable.actorID == request.actorID
            && durable.runID == request.runID
    }

    private func map(_ error: AgentTaskStoreError) -> GoalTaskControlExecutorError {
        switch error {
        case .controlRevisionMismatch:
            return .controlRevisionMismatch
        case .controlStateConflict:
            return .controlStateConflict
        case .unknownRun:
            return .unknownRun
        case .externalSubmissionUnknown:
            return .needsUserReview(.externalSubmissionUnknown)
        case .controlReceiptConflict:
            return .idempotencyKeyConflict
        case .persistenceFailed, .persistenceRecoveryFailed, .staleWriter:
            return .persistenceFailed
        default:
            return .controlStateConflict
        }
    }
}
