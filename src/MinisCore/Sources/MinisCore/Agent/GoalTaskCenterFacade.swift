import Foundation

public enum GoalTaskCenterLeaseState: String, Codable, Equatable, Sendable {
    case active
    case expired
    case revoked
    case invalid
}

/// Binds a GoalEnvelope and its AutonomyLease to one canonical task fact.
///
/// GoalEnvelope intentionally does not own task identity. This value is the
/// explicit bridge between policy scope and the AgentTaskStore task/parent key.
public struct GoalTaskCenterBinding: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let goal: GoalEnvelope
    public let lease: AutonomyLease

    public init(taskID: String, parentID: String, goal: GoalEnvelope, lease: AutonomyLease) {
        self.taskID = taskID
        self.parentID = parentID
        self.goal = goal
        self.lease = lease
    }
}

public struct GoalTaskCenterGoalFact: Codable, Equatable, Sendable {
    public let goalID: UUID
    public let scopeID: String
    public let budget: Int
    public let deadline: Date
    public let leaseID: UUID
    public let leaseExpiresAt: Date
    public let leaseState: GoalTaskCenterLeaseState
}

public struct GoalTaskCenterTaskFact: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let providerID: String?
    public let modelID: String?
    public let routeReceiptID: String?
    public let revision: String
    public let status: AgentTaskStatus
    public let scopeID: String?
    public let goalID: UUID?
    public let leaseID: UUID?
    public let budget: Int?
    public let deadline: Date?
    public let leaseExpiresAt: Date?
    public let leaseState: GoalTaskCenterLeaseState
    public let controlState: AgentTaskControlState
    public let controlRevision: Int
    public let isGoalBound: Bool
    /// Stored child-boundary metadata for display only. These are not an
    /// operation grant, a current policy evaluation, or the parent's Goal.
    /// Missing fields on legacy records remain unknown.
    public let childGrantedCapabilities: Set<ProviderCapability>?
    public let childCapabilityIntersection: AgentCapabilityIntersection?
    public let childWorkingDirectory: String?
}

/// The three production request routes share the same task ledger and facade.
/// This value names the route without introducing a route-specific runtime.
public enum GoalTaskCenterRoute: String, Codable, Equatable, Sendable {
    case chat
    case tool
    case external
}

/// Stable request identity used by the vertical-slice projection.
public struct GoalTaskCenterRouteRequest: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let route: GoalTaskCenterRoute
    public let routeReceiptID: String?
    public let runID: String?

    public init(
        taskID: String,
        parentID: String,
        route: GoalTaskCenterRoute,
        routeReceiptID: String?,
        runID: String? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.route = route
        self.routeReceiptID = routeReceiptID
        self.runID = runID
    }
}

public enum GoalTaskCenterTerminalState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case needsUserReview
}

/// A terminal event and its durable receipt, kept as a redacted projection.
public struct GoalTaskCenterTerminalReceiptProjection: Codable, Equatable, Sendable {
    public let runID: String
    public let attemptID: String
    public let sequence: Int
    public let eventKind: AgentTaskEventKind
    public let outcome: AgentTaskOutcome

    public init(
        runID: String,
        attemptID: String,
        sequence: Int,
        eventKind: AgentTaskEventKind,
        outcome: AgentTaskOutcome
    ) {
        self.runID = runID
        self.attemptID = attemptID
        self.sequence = sequence
        self.eventKind = eventKind
        self.outcome = outcome
    }
}

public enum GoalTaskCenterArtifactBacklinkState: String, Codable, Equatable, Sendable {
    case linked
    case notProvided
    case invalid
    case recoveryRequired
}

/// Secret-free identity connecting one artifact receipt back to its task run.
/// The artifact store remains the owner of artifact contents and paths.
public struct GoalTaskCenterArtifactBacklink: Codable, Equatable, Sendable {
    public let artifactID: String
    public let taskID: String
    public let runID: String?
    public let attemptID: String?
    public let receiptID: String
    public let lineageID: String?
    public let state: GoalTaskCenterArtifactBacklinkState

    public init(
        artifactID: String,
        taskID: String,
        runID: String?,
        attemptID: String?,
        receiptID: String,
        lineageID: String? = nil,
        state: GoalTaskCenterArtifactBacklinkState = .linked
    ) {
        self.artifactID = artifactID
        self.taskID = taskID
        self.runID = runID
        self.attemptID = attemptID
        self.receiptID = receiptID
        self.lineageID = lineageID
        self.state = state
    }
}

public enum GoalTaskCenterCancellationState: String, Codable, Equatable, Sendable {
    case available
    case requested
    case settled
    case notApplicable
    case needsUserReview
}

public struct GoalTaskCenterCancellationProjection: Codable, Equatable, Sendable {
    public let state: GoalTaskCenterCancellationState
    public let runID: String?
    public let terminalEventKind: AgentTaskEventKind?

    public init(
        state: GoalTaskCenterCancellationState,
        runID: String?,
        terminalEventKind: AgentTaskEventKind?
    ) {
        self.state = state
        self.runID = runID
        self.terminalEventKind = terminalEventKind
    }
}

public enum GoalTaskCenterRestartState: String, Codable, Equatable, Sendable {
    case notRequired
    case available
    case needsUserReview
    case blocked
}

public struct GoalTaskCenterRestartProjection: Codable, Equatable, Sendable {
    public let state: GoalTaskCenterRestartState
    public let runID: String?
    public let attemptID: String?
    public let reason: GoalTaskCenterReviewReason?

    public init(
        state: GoalTaskCenterRestartState,
        runID: String?,
        attemptID: String?,
        reason: GoalTaskCenterReviewReason?
    ) {
        self.state = state
        self.runID = runID
        self.attemptID = attemptID
        self.reason = reason
    }
}

/// One read-only vertical slice across request, task, receipt, artifact and
/// recovery controls. It is assembled from existing owners and never writes.
public struct GoalTaskCenterVerticalSliceProjection: Codable, Equatable, Sendable {
    public let request: GoalTaskCenterRouteRequest
    public let task: GoalTaskCenterTaskFact
    public let terminalState: GoalTaskCenterTerminalState
    public let terminalReceipt: GoalTaskCenterTerminalReceiptProjection?
    public let artifactBacklink: GoalTaskCenterArtifactBacklink?
    public let cancellation: GoalTaskCenterCancellationProjection
    public let restart: GoalTaskCenterRestartProjection
    public let validationIssues: [String]

    public var isComplete: Bool { validationIssues.isEmpty }

    public init(
        request: GoalTaskCenterRouteRequest,
        task: GoalTaskCenterTaskFact,
        terminalState: GoalTaskCenterTerminalState,
        terminalReceipt: GoalTaskCenterTerminalReceiptProjection?,
        artifactBacklink: GoalTaskCenterArtifactBacklink?,
        cancellation: GoalTaskCenterCancellationProjection,
        restart: GoalTaskCenterRestartProjection,
        validationIssues: [String]
    ) {
        self.request = request
        self.task = task
        self.terminalState = terminalState
        self.terminalReceipt = terminalReceipt
        self.artifactBacklink = artifactBacklink
        self.cancellation = cancellation
        self.restart = restart
        self.validationIssues = validationIssues
    }
}

/// Immutable Goal/Task Center projection. It has no lifecycle mutation API.
public struct GoalTaskCenterProjection: Codable, Equatable, Sendable {
    public let goals: [GoalTaskCenterGoalFact]
    public let tasks: [GoalTaskCenterTaskFact]
    public let boundTaskCount: Int
    public let unboundTaskCount: Int

    public func fact(taskID: String, parentID: String) -> GoalTaskCenterTaskFact? {
        tasks.first { $0.taskID == taskID && $0.parentID == parentID }
    }
}

public enum GoalTaskCenterControlMode: String, Codable, Equatable, Sendable {
    case readOnlyProjection
}

public enum GoalTaskCenterCommand: String, Codable, Equatable, Sendable {
    case pause
    case resume
    case stop
    case retry
}

/// Every task-center command carries the full optimistic-concurrency boundary.
public struct GoalTaskCenterCommandRequest: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let revision: String
    public let scopeID: String
    public let actorID: String
    public let idempotencyKey: String
    public let command: GoalTaskCenterCommand
    public let runID: String?

    public init(
        taskID: String,
        parentID: String,
        revision: String,
        scopeID: String,
        actorID: String,
        idempotencyKey: String,
        command: GoalTaskCenterCommand,
        runID: String? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.revision = revision
        self.scopeID = scopeID
        self.actorID = actorID
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.runID = runID
    }
}

public enum GoalTaskCenterReviewReason: String, Codable, Equatable, Sendable {
    case externalSubmissionUnknown
    case recoveredRunningTask
}

public enum GoalTaskCenterCommandDecision: Codable, Equatable, Sendable {
    case needsProductionExecutor
    case needsUserReview(reason: GoalTaskCenterReviewReason)

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case needsProductionExecutor
        case needsUserReview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .needsProductionExecutor:
            self = .needsProductionExecutor
        case .needsUserReview:
            self = .needsUserReview(
                reason: try container.decode(GoalTaskCenterReviewReason.self, forKey: .reason)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .needsProductionExecutor:
            try container.encode(Kind.needsProductionExecutor, forKey: .kind)
        case .needsUserReview(let reason):
            try container.encode(Kind.needsUserReview, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct GoalTaskCenterCommandReceipt: Codable, Equatable, Sendable {
    public let request: GoalTaskCenterCommandRequest
    public let observedFact: GoalTaskCenterTaskFact
    public let decision: GoalTaskCenterCommandDecision
}

public enum GoalTaskCenterValidationError: String, Equatable, Sendable {
    case blankTaskID
    case blankParentID
    case blankRevision
    case blankScopeID
    case blankActorID
    case blankIdempotencyKey
}

public enum GoalTaskCenterFacadeError: Error, Equatable, Sendable {
    case invalidBinding
    case duplicateBinding
    case invalidRequest(GoalTaskCenterValidationError)
    case unknownTask
    case unboundGoal
    case scopeMismatch
    case revisionMismatch
    case leaseNotActive(GoalTaskCenterLeaseState)
    case idempotencyKeyConflict
    case missingRunID
    case unknownRun
    case commandNotApplicable(GoalTaskCenterCommand, AgentTaskStatus)
    case requiredEventMissing(AgentTaskEventKind)
}

/// Read-only Goal/Task Center facade.
///
/// The facade validates identity, scope, revision, lease and idempotency before
/// delegating stop/retry checks to the existing read-only command service.
/// There is intentionally no deletion, hiding, or direct AgentTaskStore mutation.
public final class GoalTaskCenterFacade: @unchecked Sendable {
    private let store: AgentTaskStore
    private let bindingsByTaskKey: [String: GoalTaskCenterBinding]
    private let commandService: AgentTaskCommandService
    private let lock = NSLock()
    private var receiptsByIdempotencyKey: [String: GoalTaskCenterCommandReceipt] = [:]

    public let controlMode: GoalTaskCenterControlMode = .readOnlyProjection

    public init(store: AgentTaskStore) {
        self.store = store
        self.bindingsByTaskKey = [:]
        self.commandService = AgentTaskCommandService(store: store)
    }

    public init(store: AgentTaskStore, bindings: [GoalTaskCenterBinding]) throws {
        var indexed: [String: GoalTaskCenterBinding] = [:]
        for binding in bindings {
            guard Self.isNonBlank(binding.taskID),
                  Self.isNonBlank(binding.parentID),
                  Self.isNonBlank(binding.goal.scopeID),
                  binding.lease.goalID == binding.goal.goalID,
                  binding.lease.scopeID == binding.goal.scopeID else {
                throw GoalTaskCenterFacadeError.invalidBinding
            }
            let key = Self.taskKey(taskID: binding.taskID, parentID: binding.parentID)
            guard indexed[key] == nil else {
                throw GoalTaskCenterFacadeError.duplicateBinding
            }
            indexed[key] = binding
        }
        self.store = store
        self.bindingsByTaskKey = indexed
        self.commandService = AgentTaskCommandService(store: store)
    }

    public func project(now: Date = Date()) -> GoalTaskCenterProjection {
        let snapshots = store.taskCenterSnapshots()
        let facts = snapshots.map { makeFact(snapshot: $0, now: now) }
        var goalsByID: [UUID: GoalTaskCenterGoalFact] = [:]
        for binding in bindingsByTaskKey.values {
            let state = leaseState(for: binding, now: now)
            goalsByID[binding.goal.goalID] = GoalTaskCenterGoalFact(
                goalID: binding.goal.goalID,
                scopeID: binding.goal.scopeID,
                budget: binding.goal.budget,
                deadline: binding.goal.deadline,
                leaseID: binding.lease.leaseID,
                leaseExpiresAt: binding.lease.expiresAt,
                leaseState: state
            )
        }
        let goals = goalsByID.values.sorted { $0.goalID.uuidString < $1.goalID.uuidString }
        return GoalTaskCenterProjection(
            goals: goals,
            tasks: facts,
            boundTaskCount: facts.count(where: \.isGoalBound),
            unboundTaskCount: facts.count(where: { !$0.isGoalBound })
        )
    }

    /// Projects one request through the existing task/run/attempt ledger.
    /// This is deliberately read-only: cancellation and restart are reported
    /// as durable facts and must still go through `submit`/the command service.
    public func verticalSliceProjection(
        taskID: String,
        parentID: String,
        route: GoalTaskCenterRoute,
        artifactBacklink: GoalTaskCenterArtifactBacklink? = nil,
        now: Date = Date()
    ) -> GoalTaskCenterVerticalSliceProjection? {
        guard Self.isNonBlank(taskID), Self.isNonBlank(parentID),
              let snapshot = store.snapshot(taskID: taskID, parentID: parentID),
              bindingsByTaskKey[Self.taskKey(taskID: taskID, parentID: parentID)] != nil else {
            return nil
        }

        let control = store.controlSnapshot(taskID: taskID, parentID: parentID)
        let fact = makeFact(snapshot: snapshot, now: now)
        let runID = control?.runID
        let events = runID.map { store.events(runID: $0) } ?? []
        let receipt = runID.flatMap { store.receipt(runID: $0) }
        let terminalEvent = events.last(where: Self.isTerminalEvent)
            ?? store.terminalEvent(taskID: taskID, parentID: parentID)
        let terminalReceipt: GoalTaskCenterTerminalReceiptProjection?
        if let receipt, let terminalEvent,
           Self.eventMatchesOutcome(terminalEvent.kind, outcome: receipt.outcome) {
            terminalReceipt = GoalTaskCenterTerminalReceiptProjection(
                runID: receipt.runID,
                attemptID: receipt.attemptID,
                sequence: terminalEvent.sequence,
                eventKind: terminalEvent.kind,
                outcome: receipt.outcome
            )
        } else {
            terminalReceipt = nil
        }

        var validationIssues: [String] = []
        if route == .tool || route == .external,
           snapshot.routeReceiptID.map(Self.isNonBlank) != true {
            validationIssues.append("route-receipt-missing")
        }
        let queuedTerminalEventIsValid = runID == nil && Self.queuedTerminalEventMatchesStatus(
            terminalEvent,
            status: snapshot.status
        )
        if (snapshot.status == .succeeded || snapshot.status == .failed || snapshot.status == .cancelled),
           terminalReceipt == nil && !queuedTerminalEventIsValid {
            validationIssues.append("terminal-receipt-missing-or-mismatched")
        }
        if let artifactBacklink {
            if !Self.isNonBlank(artifactBacklink.artifactID)
                || !Self.isNonBlank(artifactBacklink.receiptID) {
                validationIssues.append("artifact-backlink-identity-invalid")
            }
            if artifactBacklink.taskID != taskID {
                validationIssues.append("artifact-task-mismatch")
            }
            if let artifactRunID = artifactBacklink.runID, artifactRunID != runID {
                validationIssues.append("artifact-run-mismatch")
            }
            if artifactBacklink.state == .invalid || artifactBacklink.state == .recoveryRequired {
                validationIssues.append("artifact-backlink-\(artifactBacklink.state.rawValue)")
            }
        }

        let recovery = runID.flatMap { store.recoveryState(runID: $0) }
        let terminalState = Self.terminalState(
            status: snapshot.status,
            recovery: recovery
        )
        let cancellation = Self.cancellationProjection(
            status: snapshot.status,
            control: control,
            runID: runID,
            terminalEvent: terminalEvent,
            recovery: recovery
        )
        let restart = Self.restartProjection(
            status: snapshot.status,
            runID: runID,
            attemptID: runID.flatMap { store.canonicalAttemptID(runID: $0) },
            recovery: recovery
        )
        return GoalTaskCenterVerticalSliceProjection(
            request: GoalTaskCenterRouteRequest(
                taskID: taskID,
                parentID: parentID,
                route: route,
                routeReceiptID: snapshot.routeReceiptID,
                runID: runID
            ),
            task: fact,
            terminalState: terminalState,
            terminalReceipt: terminalReceipt,
            artifactBacklink: artifactBacklink,
            cancellation: cancellation,
            restart: restart,
            validationIssues: validationIssues
        )
    }

    public func submit(
        _ request: GoalTaskCenterCommandRequest,
        now: Date = Date()
    ) throws -> GoalTaskCenterCommandReceipt {
        try validate(request)

        lock.lock()
        if let prior = receiptsByIdempotencyKey[request.idempotencyKey] {
            lock.unlock()
            guard prior.request == request else {
                throw GoalTaskCenterFacadeError.idempotencyKeyConflict
            }
            return prior
        }
        lock.unlock()

        if let durable = store.controlReceipt(idempotencyKey: request.idempotencyKey) {
            let replay = try durableReplay(request: request, durable: durable, now: now)
            lock.lock()
            defer { lock.unlock() }
            if let prior = receiptsByIdempotencyKey[request.idempotencyKey] {
                guard prior.request == request else {
                    throw GoalTaskCenterFacadeError.idempotencyKeyConflict
                }
                return prior
            }
            receiptsByIdempotencyKey[request.idempotencyKey] = replay
            return replay
        }

        let key = Self.taskKey(taskID: request.taskID, parentID: request.parentID)
        guard let snapshot = store.snapshot(taskID: request.taskID, parentID: request.parentID) else {
            throw GoalTaskCenterFacadeError.unknownTask
        }
        guard let binding = bindingsByTaskKey[key] else {
            throw GoalTaskCenterFacadeError.unboundGoal
        }
        guard binding.goal.scopeID == request.scopeID else {
            throw GoalTaskCenterFacadeError.scopeMismatch
        }

        let fact = makeFact(snapshot: snapshot, binding: binding, now: now)
        guard fact.revision == request.revision else {
            throw GoalTaskCenterFacadeError.revisionMismatch
        }
        guard fact.leaseState == .active else {
            throw GoalTaskCenterFacadeError.leaseNotActive(fact.leaseState)
        }

        let decision: GoalTaskCenterCommandDecision
        switch request.command {
        case .pause:
            guard (snapshot.status == .queued || snapshot.status == .running),
                  fact.controlState == .active else {
                throw GoalTaskCenterFacadeError.commandNotApplicable(request.command, snapshot.status)
            }
            decision = .needsProductionExecutor
        case .resume:
            guard (snapshot.status == .queued || snapshot.status == .running),
                  fact.controlState == .paused else {
                throw GoalTaskCenterFacadeError.commandNotApplicable(request.command, snapshot.status)
            }
            decision = .needsProductionExecutor
        case .stop:
            decision = try delegate(
                command: .cancel,
                request: request,
                snapshot: snapshot
            )
        case .retry:
            decision = try delegate(
                command: .retry,
                request: request,
                snapshot: snapshot
            )
        }

        let receipt = GoalTaskCenterCommandReceipt(
            request: request,
            observedFact: fact,
            decision: decision
        )
        lock.lock()
        defer { lock.unlock() }
        if let prior = receiptsByIdempotencyKey[request.idempotencyKey] {
            guard prior.request == request else {
                throw GoalTaskCenterFacadeError.idempotencyKeyConflict
            }
            return prior
        }
        receiptsByIdempotencyKey[request.idempotencyKey] = receipt
        return receipt
    }

    /// Replays a command already committed by the durable control consumer.
    /// This check runs before lease evaluation so a restart cannot reinterpret
    /// an already-consumed idempotency key as a fresh command.
    private func durableReplay(
        request: GoalTaskCenterCommandRequest,
        durable: AgentTaskControlReceipt,
        now: Date
    ) throws -> GoalTaskCenterCommandReceipt {
        guard durable.taskID == request.taskID,
              durable.parentID == request.parentID,
              durable.idempotencyKey == request.idempotencyKey,
              durable.command.rawValue == request.command.rawValue,
              durable.revision == request.revision,
              durable.scopeID == request.scopeID,
              durable.actorID == request.actorID,
              durable.runID == request.runID else {
            throw GoalTaskCenterFacadeError.idempotencyKeyConflict
        }
        guard let snapshot = store.snapshot(taskID: request.taskID, parentID: request.parentID) else {
            throw GoalTaskCenterFacadeError.unknownTask
        }
        guard bindingsByTaskKey[Self.taskKey(taskID: request.taskID, parentID: request.parentID)] != nil else {
            throw GoalTaskCenterFacadeError.unboundGoal
        }
        let observedFact = durable.afterFact
            ?? makeFact(snapshot: snapshot, now: now)
        return GoalTaskCenterCommandReceipt(
            request: request,
            observedFact: observedFact,
            decision: .needsProductionExecutor
        )
    }

    private func delegate(
        command: AgentTaskCommand,
        request: GoalTaskCenterCommandRequest,
        snapshot: AgentTaskSnapshot
    ) throws -> GoalTaskCenterCommandDecision {
        let delegateRequest = AgentTaskCommandRequest(
            taskID: request.taskID,
            parentID: request.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: snapshot),
            idempotencyKey: request.idempotencyKey,
            command: command,
            runID: request.runID
        )
        do {
            let receipt = try commandService.submit(delegateRequest)
            switch receipt.decision {
            case .needsProductionExecutor:
                return .needsProductionExecutor
            case .needsUserReview(let reason):
                switch reason {
                case .externalSubmissionUnknown:
                    return .needsUserReview(reason: .externalSubmissionUnknown)
                case .recoveredRunningTask:
                    return .needsUserReview(reason: .recoveredRunningTask)
                }
            }
        } catch let error as AgentTaskCommandServiceError {
            switch error {
            case .unknownTask:
                throw GoalTaskCenterFacadeError.unknownTask
            case .snapshotIdentityMismatch:
                throw GoalTaskCenterFacadeError.revisionMismatch
            case .idempotencyKeyConflict:
                throw GoalTaskCenterFacadeError.idempotencyKeyConflict
            case .missingRunID:
                throw GoalTaskCenterFacadeError.missingRunID
            case .unknownRun:
                throw GoalTaskCenterFacadeError.unknownRun
            case .commandNotApplicable(let kind, let status):
                let facadeCommand: GoalTaskCenterCommand = kind == .cancel ? .stop : .retry
                throw GoalTaskCenterFacadeError.commandNotApplicable(facadeCommand, status)
            case .requiredEventMissing(let kind):
                throw GoalTaskCenterFacadeError.requiredEventMissing(kind)
            case .invalidRequest:
                throw GoalTaskCenterFacadeError.revisionMismatch
            case .invalidCreationRequest:
                throw GoalTaskCenterFacadeError.revisionMismatch
            case .creationIdempotencyConflict:
                throw GoalTaskCenterFacadeError.idempotencyKeyConflict
            }
        }
    }

    private func validate(_ request: GoalTaskCenterCommandRequest) throws {
        guard Self.isNonBlank(request.taskID) else {
            throw GoalTaskCenterFacadeError.invalidRequest(.blankTaskID)
        }
        guard Self.isNonBlank(request.parentID) else {
            throw GoalTaskCenterFacadeError.invalidRequest(.blankParentID)
        }
        guard Self.isNonBlank(request.revision) else {
            throw GoalTaskCenterFacadeError.invalidRequest(.blankRevision)
        }
        guard Self.isNonBlank(request.scopeID) else {
            throw GoalTaskCenterFacadeError.invalidRequest(.blankScopeID)
        }
        guard Self.isNonBlank(request.actorID) else {
            throw GoalTaskCenterFacadeError.invalidRequest(.blankActorID)
        }
        guard Self.isNonBlank(request.idempotencyKey) else {
            throw GoalTaskCenterFacadeError.invalidRequest(.blankIdempotencyKey)
        }
    }

    private func makeFact(
        snapshot: AgentTaskSnapshot,
        now: Date
    ) -> GoalTaskCenterTaskFact {
        let binding = bindingsByTaskKey[Self.taskKey(taskID: snapshot.taskID, parentID: snapshot.parentID)]
        return makeFact(snapshot: snapshot, binding: binding, now: now)
    }

    private func makeFact(
        snapshot: AgentTaskSnapshot,
        binding: GoalTaskCenterBinding?,
        now: Date,
        controlOverride: AgentTaskControlSnapshot? = nil
    ) -> GoalTaskCenterTaskFact {
        let state = binding.map { leaseState(for: $0, now: now) } ?? .invalid
        let control = controlOverride
            ?? store.controlSnapshot(taskID: snapshot.taskID, parentID: snapshot.parentID)
        return GoalTaskCenterTaskFact(
            taskID: snapshot.taskID,
            parentID: snapshot.parentID,
            providerID: snapshot.providerID,
            modelID: snapshot.modelID,
            routeReceiptID: snapshot.routeReceiptID,
            revision: Self.revision(for: snapshot, binding: binding, control: control),
            status: snapshot.status,
            scopeID: binding?.goal.scopeID,
            goalID: binding?.goal.goalID,
            leaseID: binding?.lease.leaseID,
            budget: binding?.goal.budget,
            deadline: binding?.goal.deadline,
            leaseExpiresAt: binding?.lease.expiresAt,
            leaseState: state,
            controlState: control?.state ?? .active,
            controlRevision: control?.controlRevision ?? 0,
            isGoalBound: binding != nil,
            childGrantedCapabilities: snapshot.childRuntimeIdentity?.grantedCapabilities,
            childCapabilityIntersection: snapshot.childRuntimeIdentity?.capabilityIntersection,
            childWorkingDirectory: snapshot.childRuntimeIdentity?.workingDirectory
        )
    }

    /// Builds a fact from a validated post-mutation snapshot without rereading
    /// mutable store state. The executor uses this before its atomic commit so
    /// the exact fact can be persisted with the idempotency receipt.
    public func fact(
        snapshot: AgentTaskSnapshot,
        control: AgentTaskControlSnapshot,
        now: Date = Date()
    ) -> GoalTaskCenterTaskFact? {
        let key = Self.taskKey(taskID: snapshot.taskID, parentID: snapshot.parentID)
        guard bindingsByTaskKey[key] != nil else { return nil }
        return makeFact(
            snapshot: snapshot,
            binding: bindingsByTaskKey[key],
            now: now,
            controlOverride: control
        )
    }

    private func leaseState(
        for binding: GoalTaskCenterBinding,
        now: Date
    ) -> GoalTaskCenterLeaseState {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              binding.goal.deadline.timeIntervalSinceReferenceDate.isFinite,
              binding.lease.issuedAt.timeIntervalSinceReferenceDate.isFinite,
              binding.lease.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              binding.lease.expiresAt > binding.lease.issuedAt,
              binding.lease.goalID == binding.goal.goalID,
              binding.lease.scopeID == binding.goal.scopeID else {
            return .invalid
        }
        if binding.lease.revoked { return .revoked }
        if now >= binding.goal.deadline
            || now < binding.lease.issuedAt
            || now >= binding.lease.expiresAt {
            return .expired
        }
        return .active
    }

    private static func revision(
        for snapshot: AgentTaskSnapshot,
        binding: GoalTaskCenterBinding?,
        control: AgentTaskControlSnapshot?
    ) -> String {
        var fields = [
            "v1",
            "task=\(snapshot.taskID)",
            "parent=\(snapshot.parentID)",
            "status=\(statusKey(snapshot.status))",
            "context=\(snapshot.parentContextSnapshotID ?? "-")",
            "provider=\(snapshot.providerID ?? "-")",
            "model=\(snapshot.modelID ?? "-")",
            "config=\(snapshot.configurationFingerprint ?? "-")",
            "receipt=\(snapshot.routeReceiptID ?? "-")",
            "control=\(control?.state.rawValue ?? "active")",
            "controlRevision=\(control?.controlRevision ?? 0)",
            "controlRun=\(control?.runID ?? "-")"
        ]
        if let binding {
            fields.append(contentsOf: [
                "goal=\(binding.goal.goalID.uuidString)",
                "scope=\(binding.goal.scopeID)",
                "capabilities=\(binding.goal.allowedCapabilities.sorted().joined(separator: ","))",
                "roots=\(binding.goal.fileRoots.joined(separator: ","))",
                "domains=\(binding.goal.networkDomains.sorted().joined(separator: ","))",
                "budget=\(binding.goal.budget)",
                "deadline=\(binding.goal.deadline.timeIntervalSinceReferenceDate)",
                "concurrency=\(binding.goal.concurrencyLimit)",
                "autonomy=\(binding.goal.autonomyLevel.rawValue)",
                "creator=\(binding.goal.creatorID ?? "-")",
                "created=\(binding.goal.createdAt.timeIntervalSinceReferenceDate)",
                "lease=\(binding.lease.leaseID.uuidString)",
                "leaseIssued=\(binding.lease.issuedAt.timeIntervalSinceReferenceDate)",
                "leaseExpires=\(binding.lease.expiresAt.timeIntervalSinceReferenceDate)",
                "leaseRevoked=\(binding.lease.revoked)"
            ])
        } else {
            fields.append("goal=unbound")
        }
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func statusKey(_ status: AgentTaskStatus) -> String {
        switch status {
        case .queued: return "queued"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private static func terminalState(
        status: AgentTaskStatus,
        recovery: AgentTaskRecoveryState?
    ) -> GoalTaskCenterTerminalState {
        if recovery != nil { return .needsUserReview }
        switch status {
        case .queued: return .queued
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    private static func cancellationProjection(
        status: AgentTaskStatus,
        control: AgentTaskControlSnapshot?,
        runID: String?,
        terminalEvent: AgentTaskEvent?,
        recovery: AgentTaskRecoveryState?
    ) -> GoalTaskCenterCancellationProjection {
        let state: GoalTaskCenterCancellationState
        if recovery != nil {
            state = .needsUserReview
        } else if status == .cancelled, terminalEvent?.kind == .cancelled {
            state = .settled
        } else if (status == .queued || status == .running), control?.state == .stopped {
            state = .requested
        } else if status == .queued || status == .running {
            state = .available
        } else {
            state = .notApplicable
        }
        return GoalTaskCenterCancellationProjection(
            state: state,
            runID: runID,
            terminalEventKind: terminalEvent?.kind
        )
    }

    private static func restartProjection(
        status: AgentTaskStatus,
        runID: String?,
        attemptID: String?,
        recovery: AgentTaskRecoveryState?
    ) -> GoalTaskCenterRestartProjection {
        if recovery != nil {
            return GoalTaskCenterRestartProjection(
                state: .needsUserReview,
                runID: runID,
                attemptID: attemptID,
                reason: .recoveredRunningTask
            )
        }
        let state: GoalTaskCenterRestartState =
            status == .failed || status == .cancelled ? .available : .notRequired
        return GoalTaskCenterRestartProjection(
            state: state,
            runID: runID,
            attemptID: attemptID,
            reason: nil
        )
    }

    private static func isTerminalEvent(_ event: AgentTaskEvent) -> Bool {
        switch event.kind {
        case .completed, .failed, .cancelled, .terminalDuplicate:
            return true
        case .started, .progress, .approvalRequired, .inputRequired, .submissionUnknown:
            return false
        }
    }

    private static func eventMatchesOutcome(
        _ eventKind: AgentTaskEventKind,
        outcome: AgentTaskOutcome
    ) -> Bool {
        switch outcome {
        case .succeeded: return eventKind == .completed
        case .failed: return eventKind == .failed
        case .cancelled: return eventKind == .cancelled
        }
    }

    private static func queuedTerminalEventMatchesStatus(
        _ event: AgentTaskEvent?,
        status: AgentTaskStatus
    ) -> Bool {
        guard let event else { return false }
        switch status {
        case .succeeded: return event.kind == .completed
        case .failed: return event.kind == .failed
        case .cancelled: return event.kind == .cancelled
        case .queued, .running: return false
        }
    }

    private static func taskKey(taskID: String, parentID: String) -> String {
        "\(parentID.count):\(parentID)\(taskID.count):\(taskID)"
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
