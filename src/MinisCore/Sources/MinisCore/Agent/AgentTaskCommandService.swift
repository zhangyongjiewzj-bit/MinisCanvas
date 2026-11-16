import Foundation

/// The typed user intent accepted by the task-center command boundary.
public enum AgentTaskCommand: Sendable, Equatable, Codable {
    case cancel
    case retry
    case recover
    case approve
    case reject(reason: String)
    case provideInput(String)

    public var kind: AgentTaskCommandKind {
        switch self {
        case .cancel: return .cancel
        case .retry: return .retry
        case .recover: return .recover
        case .approve: return .approve
        case .reject: return .reject
        case .provideInput: return .provideInput
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case cancel, retry, recover, approve, reject, provideInput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .cancel: self = .cancel
        case .retry: self = .retry
        case .recover: self = .recover
        case .approve: self = .approve
        case .reject:
            self = .reject(reason: try container.decode(String.self, forKey: .value))
        case .provideInput:
            self = .provideInput(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Kind(rawValue: kind.rawValue), forKey: .kind)
        switch self {
        case .reject(let reason):
            try container.encode(reason, forKey: .value)
        case .provideInput(let input):
            try container.encode(input, forKey: .value)
        case .cancel, .retry, .recover, .approve:
            break
        }
    }
}

public enum AgentTaskCommandKind: String, Sendable, Equatable, Codable {
    case cancel
    case retry
    case recover
    case approve
    case reject
    case provideInput
}

/// The only outcomes this minimal service can honestly produce before a
/// production mutation/execution dependency is injected.
public enum AgentTaskCommandDecision: Sendable, Equatable, Codable {
    case needsProductionExecutor
    case needsUserReview(reason: AgentTaskCommandReviewReason)
}

public enum AgentTaskCommandReviewReason: String, Sendable, Equatable, Codable {
    case recoveredRunningTask
    case externalSubmissionUnknown
}

/// All fields that make an AgentTaskStore snapshot a particular fact.
///
/// AgentTaskStore currently has no integer revision. The complete immutable value
/// is therefore the revision identity for this contract; omitting a field would
/// allow a stale command to pass after a route or lifecycle change.
public struct AgentTaskSnapshotIdentity: Sendable, Equatable, Hashable, Codable {
    public let taskID: String
    public let parentID: String
    public let parentContextSnapshotID: String?
    public let providerID: String?
    public let modelID: String?
    public let configurationFingerprint: String?
    public let routeReceiptID: String?
    public let status: AgentTaskStatus
    public let creation: SessionActionCreationMetadata?

    public init(snapshot: AgentTaskSnapshot) {
        taskID = snapshot.taskID
        parentID = snapshot.parentID
        parentContextSnapshotID = snapshot.parentContextSnapshotID
        providerID = snapshot.providerID
        modelID = snapshot.modelID
        configurationFingerprint = snapshot.configurationFingerprint
        routeReceiptID = snapshot.routeReceiptID
        status = snapshot.status
        creation = snapshot.creation
    }
}

public struct AgentTaskCommandRequest: Sendable, Equatable, Codable {
    public let taskID: String
    public let parentID: String
    public let expectedSnapshotIdentity: AgentTaskSnapshotIdentity
    public let idempotencyKey: String
    public let command: AgentTaskCommand
    public let runID: String?

    public init(
        taskID: String,
        parentID: String,
        expectedSnapshotIdentity: AgentTaskSnapshotIdentity,
        idempotencyKey: String,
        command: AgentTaskCommand,
        runID: String? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.expectedSnapshotIdentity = expectedSnapshotIdentity
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.runID = runID
    }

    public init(
        taskID: String,
        parentID: String,
        expectedSnapshotIdentity: AgentTaskSnapshotIdentity,
        command: AgentTaskCommand,
        idempotencyKey: String,
        runID: String? = nil
    ) {
        self.init(
            taskID: taskID,
            parentID: parentID,
            expectedSnapshotIdentity: expectedSnapshotIdentity,
            idempotencyKey: idempotencyKey,
            command: command,
            runID: runID
        )
    }
}

public enum AgentTaskCommandServiceError: Error, Sendable, Equatable {
    case invalidRequest(AgentTaskCommandValidationError)
    case unknownTask
    case snapshotIdentityMismatch
    case idempotencyKeyConflict
    case missingRunID
    case unknownRun
    case commandNotApplicable(AgentTaskCommandKind, AgentTaskStatus)
    case requiredEventMissing(AgentTaskEventKind)
    case invalidCreationRequest(AgentTaskCreationValidationError)
    case creationIdempotencyConflict
}

public enum AgentTaskCommandValidationError: String, Sendable, Equatable {
    case blankTaskID
    case blankParentID
    case blankIdempotencyKey
    case expectedIdentityDoesNotMatchRequest
    case blankRejectionReason
    case blankInput
}

public struct AgentTaskCreationRequest: Sendable, Equatable, Codable {
    public let taskID: String
    public let parentID: String
    public let source: ParentRuntimeIdentity
    public let title: String
    public let projectID: String
    public let workingDirectory: String?
    public let scopeID: String
    public let idempotencyKey: String
    public let providerID: String?
    public let modelID: String?
    public let configurationFingerprint: String?
    public let routeReceiptID: String?
    public let parentContextSnapshotID: String?

    public init(
        taskID: String,
        parentID: String,
        source: ParentRuntimeIdentity,
        title: String,
        projectID: String,
        workingDirectory: String? = nil,
        scopeID: String,
        idempotencyKey: String,
        providerID: String? = nil,
        modelID: String? = nil,
        configurationFingerprint: String? = nil,
        routeReceiptID: String? = nil,
        parentContextSnapshotID: String? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.source = source
        self.title = title
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.scopeID = scopeID
        self.idempotencyKey = idempotencyKey
        self.providerID = providerID
        self.modelID = modelID
        self.configurationFingerprint = configurationFingerprint
        self.routeReceiptID = routeReceiptID
        self.parentContextSnapshotID = parentContextSnapshotID
    }
}

/// Frozen policy facts required before an autonomous task may be enqueued.
/// Manual/session-created tasks continue to use `AgentTaskCreationRequest`;
/// autonomous entry points must carry this explicit envelope and lease.
public struct AgentAutomaticTaskCreationRequest: Sendable, Equatable, Codable {
    public let creation: AgentTaskCreationRequest
    public let goal: GoalEnvelope
    public let lease: AutonomyLease

    public init(
        creation: AgentTaskCreationRequest,
        goal: GoalEnvelope,
        lease: AutonomyLease
    ) {
        self.creation = creation
        self.goal = goal
        self.lease = lease
    }
}

/// Stable, user-visible reasons why an automatic task was not admitted.
public enum AgentTaskAutomaticCreationRejection: String, Sendable, Equatable, Codable {
    case goalScopeMismatch
    case goalBudgetExhausted
    case goalExpired
    case goalDeadlineInvalid
    case leaseGoalMismatch
    case leaseScopeMismatch
    case leaseRevoked
    case leaseNotActive
    case leaseExpired
    case leaseWindowInvalid
}

public enum AgentTaskAutomaticCreationError: Error, Sendable, Equatable {
    case rejected(AgentTaskAutomaticCreationRejection)
    case invalidRequest(AgentTaskCreationValidationError)
    case idempotencyConflict
}

/// Receipt carrying the exact policy values admitted for this task. The `let`
/// fields make the policy immutable for the downstream production consumer.
public struct AgentAutomaticTaskCreationReceipt: Sendable, Equatable, Codable {
    public let creation: AgentTaskCreationReceipt
    public let goal: GoalEnvelope
    public let lease: AutonomyLease
    public let admittedAt: Date

    public init(
        creation: AgentTaskCreationReceipt,
        goal: GoalEnvelope,
        lease: AutonomyLease,
        admittedAt: Date
    ) {
        self.creation = creation
        self.goal = goal
        self.lease = lease
        self.admittedAt = admittedAt
    }

    public var didCreate: Bool { creation.didCreate }
}

public enum AgentTaskCreationValidationError: Sendable, Equatable, Codable {
    case blankTaskID, blankParentID, blankTitle, blankProjectID, blankScopeID, blankIdempotencyKey
    case invalidSource
    case sourceParentMismatch
    case unknownProject
    case scopeDenied
}

public struct AgentTaskCreationReceipt: Sendable, Equatable, Codable {
    public let request: AgentTaskCreationRequest
    public let action: SessionAction
    public let snapshot: AgentTaskSnapshot
    public let didCreate: Bool

    public init(request: AgentTaskCreationRequest, action: SessionAction, snapshot: AgentTaskSnapshot, didCreate: Bool) {
        self.request = request
        self.action = action
        self.snapshot = snapshot
        self.didCreate = didCreate
    }
}

/// The durable replay result for a session-created task. This is deliberately
/// reconstructed from the task ledger rather than an in-memory receipt cache,
/// so a new command service after restart can hand the same request to the
/// downstream task/session consumer without creating or switching anything.
public struct AgentTaskCreationRecovery: Sendable, Equatable, Codable {
    public let receipt: AgentTaskCreationReceipt

    public init(receipt: AgentTaskCreationReceipt) {
        self.receipt = receipt
    }
}

public struct AgentTaskCommandReceipt: Sendable, Equatable, Codable {
    public let request: AgentTaskCommandRequest
    public let observedSnapshotIdentity: AgentTaskSnapshotIdentity
    public let decision: AgentTaskCommandDecision

    public var command: AgentTaskCommand { request.command }
}

/// Read-only task-center admission boundary.
///
/// This service intentionally never mutates AgentTaskStore. The
/// GoalTaskControlExecutor owns the durable control mutation and receipt path;
/// this service remains the fail-closed validator used before that executor.
public final class AgentTaskCommandService: @unchecked Sendable {
    private let store: AgentTaskStore
    private let knownProjectIDs: Set<String>
    private let authorizedScopeIDs: Set<String>
    private let lock = NSLock()
    private var receiptsByIdempotencyKey: [String: AgentTaskCommandReceipt] = [:]

    public init(store: AgentTaskStore) {
        self.store = store
        knownProjectIDs = []
        authorizedScopeIDs = []
    }

    public init(store: AgentTaskStore, knownProjectIDs: Set<String>, authorizedScopeIDs: Set<String>) {
        self.store = store
        self.knownProjectIDs = knownProjectIDs
        self.authorizedScopeIDs = authorizedScopeIDs
    }

    /// Creates a queued child task linked to the exact parent turn. The
    /// operation is durable and idempotent; it never changes the current
    /// session, leaving switching to an explicit later action.
    public func create(_ request: AgentTaskCreationRequest) throws -> AgentTaskCreationReceipt {
        try validateCreation(request)
        let action = SessionAction.new(
            title: request.title,
            projectID: request.projectID,
            workingDirectory: request.workingDirectory,
            switchAfterCreate: false,
            source: request.source
        )
        try action.validate(against: request.source)
        let metadata = SessionActionCreationMetadata(
            scopeID: request.scopeID,
            idempotencyKey: request.idempotencyKey,
            action: action
        )
        let result: AgentTaskStore.IdempotentEnqueueResult
        do {
            result = try store.enqueueIdempotent(
                taskID: request.taskID,
                parentID: request.parentID,
                providerID: request.providerID,
                modelID: request.modelID,
                configurationFingerprint: request.configurationFingerprint,
                routeReceiptID: request.routeReceiptID,
                parentContextSnapshotID: request.parentContextSnapshotID,
                creation: metadata
            )
        } catch AgentTaskStoreError.creationIdempotencyConflict,
                AgentTaskStoreError.duplicateTask {
            throw AgentTaskCommandServiceError.creationIdempotencyConflict
        }
        guard result.snapshot.creation == metadata else {
            throw AgentTaskCommandServiceError.creationIdempotencyConflict
        }
        guard result.snapshot.providerID == request.providerID,
              result.snapshot.modelID == request.modelID,
              result.snapshot.configurationFingerprint == request.configurationFingerprint,
              result.snapshot.routeReceiptID == request.routeReceiptID,
              result.snapshot.parentContextSnapshotID == request.parentContextSnapshotID else {
            throw AgentTaskCommandServiceError.creationIdempotencyConflict
        }
        return AgentTaskCreationReceipt(request: request, action: action, snapshot: result.snapshot, didCreate: result.didCreate)
    }

    /// Admit one autonomous task only when its frozen GoalEnvelope and
    /// AutonomyLease are valid at the same instant as creation. No automatic
    /// caller may bypass the zero-budget, deadline, revocation, or scope gates.
    public func createAutomatic(
        _ request: AgentAutomaticTaskCreationRequest,
        now: Date = Date()
    ) throws -> AgentAutomaticTaskCreationReceipt {
        try validateAutomaticAdmission(request, now: now)
        let creation: AgentTaskCreationReceipt
        do {
            creation = try create(request.creation)
        } catch AgentTaskCommandServiceError.invalidCreationRequest(let reason) {
            throw AgentTaskAutomaticCreationError.invalidRequest(reason)
        } catch AgentTaskCommandServiceError.creationIdempotencyConflict {
            throw AgentTaskAutomaticCreationError.idempotencyConflict
        }
        return AgentAutomaticTaskCreationReceipt(
            creation: creation,
            goal: request.goal,
            lease: request.lease,
            admittedAt: now
        )
    }

    private func validateAutomaticAdmission(
        _ request: AgentAutomaticTaskCreationRequest,
        now: Date
    ) throws {
        guard request.goal.scopeID == request.creation.scopeID else {
            throw AgentTaskAutomaticCreationError.rejected(.goalScopeMismatch)
        }
        guard request.goal.budget > 0 else {
            throw AgentTaskAutomaticCreationError.rejected(.goalBudgetExhausted)
        }
        guard request.goal.deadline.timeIntervalSinceReferenceDate.isFinite else {
            throw AgentTaskAutomaticCreationError.rejected(.goalDeadlineInvalid)
        }
        guard now < request.goal.deadline else {
            throw AgentTaskAutomaticCreationError.rejected(.goalExpired)
        }
        guard request.lease.goalID == request.goal.goalID else {
            throw AgentTaskAutomaticCreationError.rejected(.leaseGoalMismatch)
        }
        guard request.lease.scopeID == request.goal.scopeID else {
            throw AgentTaskAutomaticCreationError.rejected(.leaseScopeMismatch)
        }
        guard request.lease.issuedAt.timeIntervalSinceReferenceDate.isFinite,
              request.lease.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              request.lease.expiresAt > request.lease.issuedAt else {
            throw AgentTaskAutomaticCreationError.rejected(.leaseWindowInvalid)
        }
        guard !request.lease.revoked else {
            throw AgentTaskAutomaticCreationError.rejected(.leaseRevoked)
        }
        guard now >= request.lease.issuedAt else {
            throw AgentTaskAutomaticCreationError.rejected(.leaseNotActive)
        }
        guard now < request.lease.expiresAt else {
            throw AgentTaskAutomaticCreationError.rejected(.leaseExpired)
        }
    }

    /// Rehydrates a previously admitted creation from durable task metadata.
    /// A missing or malformed fact returns nil and never guesses a project,
    /// parent, or title. The returned receipt is informational (`didCreate`
    /// is always false); admission remains the responsibility of `create`.
    public func recoverCreation(idempotencyKey: String) -> AgentTaskCreationRecovery? {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let snapshot = store.creationSnapshot(idempotencyKey: idempotencyKey),
              let metadata = snapshot.creation,
              metadata.idempotencyKey == idempotencyKey,
              metadata.source.taskID == snapshot.parentID,
              metadata.action.switchAfterCreate == false,
              let title = metadata.action.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let projectID = metadata.action.projectID,
              !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? metadata.action.validate(against: metadata.source)) != nil else {
            return nil
        }
        let request = AgentTaskCreationRequest(
            taskID: snapshot.taskID,
            parentID: snapshot.parentID,
            source: metadata.source,
            title: title,
            projectID: projectID,
            workingDirectory: metadata.action.workingDirectory,
            scopeID: metadata.scopeID,
            idempotencyKey: metadata.idempotencyKey,
            providerID: snapshot.providerID,
            modelID: snapshot.modelID,
            configurationFingerprint: snapshot.configurationFingerprint,
            routeReceiptID: snapshot.routeReceiptID,
            parentContextSnapshotID: snapshot.parentContextSnapshotID
        )
        return AgentTaskCreationRecovery(
            receipt: AgentTaskCreationReceipt(
                request: request,
                action: metadata.action,
                snapshot: snapshot,
                didCreate: false
            )
        )
    }

    private func validateCreation(_ request: AgentTaskCreationRequest) throws {
        func nonblank(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonblank(request.taskID) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.blankTaskID) }
        guard nonblank(request.parentID) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.blankParentID) }
        guard nonblank(request.title) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.blankTitle) }
        guard nonblank(request.projectID) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.blankProjectID) }
        guard nonblank(request.scopeID) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.blankScopeID) }
        guard nonblank(request.idempotencyKey) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.blankIdempotencyKey) }
        guard request.source.isValid else { throw AgentTaskCommandServiceError.invalidCreationRequest(.invalidSource) }
        guard request.source.taskID == request.parentID else { throw AgentTaskCommandServiceError.invalidCreationRequest(.sourceParentMismatch) }
        guard knownProjectIDs.contains(request.projectID) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.unknownProject) }
        guard authorizedScopeIDs.contains(request.scopeID) else { throw AgentTaskCommandServiceError.invalidCreationRequest(.scopeDenied) }
    }

    public func submit(_ request: AgentTaskCommandRequest) throws -> AgentTaskCommandReceipt {
        try validate(request)

        lock.lock()
        if let prior = receiptsByIdempotencyKey[request.idempotencyKey] {
            lock.unlock()
            guard prior.request == request else {
                throw AgentTaskCommandServiceError.idempotencyKeyConflict
            }
            return prior
        }
        lock.unlock()

        guard let snapshot = store.snapshot(taskID: request.taskID, parentID: request.parentID) else {
            throw AgentTaskCommandServiceError.unknownTask
        }
        let observedIdentity = AgentTaskSnapshotIdentity(snapshot: snapshot)
        guard observedIdentity == request.expectedSnapshotIdentity else {
            throw AgentTaskCommandServiceError.snapshotIdentityMismatch
        }

        let decision = try decision(for: request, snapshot: snapshot)
        let receipt = AgentTaskCommandReceipt(
            request: request,
            observedSnapshotIdentity: observedIdentity,
            decision: decision
        )

        lock.lock()
        defer { lock.unlock() }
        if let prior = receiptsByIdempotencyKey[request.idempotencyKey] {
            guard prior.request == request else {
                throw AgentTaskCommandServiceError.idempotencyKeyConflict
            }
            return prior
        }
        receiptsByIdempotencyKey[request.idempotencyKey] = receipt
        return receipt
    }

    private func validate(_ request: AgentTaskCommandRequest) throws {
        guard !request.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskCommandServiceError.invalidRequest(.blankTaskID)
        }
        guard !request.parentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskCommandServiceError.invalidRequest(.blankParentID)
        }
        guard !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskCommandServiceError.invalidRequest(.blankIdempotencyKey)
        }
        guard request.expectedSnapshotIdentity.taskID == request.taskID,
              request.expectedSnapshotIdentity.parentID == request.parentID else {
            throw AgentTaskCommandServiceError.invalidRequest(.expectedIdentityDoesNotMatchRequest)
        }

        switch request.command {
        case .reject(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentTaskCommandServiceError.invalidRequest(.blankRejectionReason)
            }
        case .provideInput(let input):
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentTaskCommandServiceError.invalidRequest(.blankInput)
            }
        case .cancel, .retry, .recover, .approve:
            break
        }
    }

    private func decision(
        for request: AgentTaskCommandRequest,
        snapshot: AgentTaskSnapshot
    ) throws -> AgentTaskCommandDecision {
        switch request.command {
        case .cancel:
            guard snapshot.status == .queued || snapshot.status == .running else {
                throw AgentTaskCommandServiceError.commandNotApplicable(request.command.kind, snapshot.status)
            }
            let runID = try optionalRunID(
                request,
                required: snapshot.status == .running
            )
            if let runID, hasUnknownExternalSubmission(runID: runID) {
                return .needsUserReview(reason: .externalSubmissionUnknown)
            }
            return .needsProductionExecutor

        case .retry:
            guard snapshot.status == .failed || snapshot.status == .cancelled else {
                throw AgentTaskCommandServiceError.commandNotApplicable(request.command.kind, snapshot.status)
            }
            if let runID = try optionalRunID(request, required: false),
               hasUnknownExternalSubmission(runID: runID) {
                return .needsUserReview(reason: .externalSubmissionUnknown)
            }
            return .needsProductionExecutor

        case .recover:
            let runID = try requireRunID(request)
            guard snapshot.status == .running else {
                throw AgentTaskCommandServiceError.commandNotApplicable(request.command.kind, snapshot.status)
            }
            if hasUnknownExternalSubmission(runID: runID) {
                return .needsUserReview(reason: .externalSubmissionUnknown)
            }
            if store.recoveryState(runID: runID) == .needsUserReview {
                return .needsUserReview(reason: .recoveredRunningTask)
            }
            return .needsProductionExecutor

        case .approve:
            let runID = try requireRunID(request)
            try requireRunningTask(runID: runID, taskID: request.taskID, status: snapshot.status, command: request.command.kind)
            try requireLatestEvent(.approvalRequired, runID: runID)
            return .needsProductionExecutor

        case .reject:
            let runID = try requireRunID(request)
            try requireRunningTask(runID: runID, taskID: request.taskID, status: snapshot.status, command: request.command.kind)
            try requireLatestEvent(.approvalRequired, runID: runID)
            return .needsProductionExecutor

        case .provideInput:
            let runID = try requireRunID(request)
            try requireRunningTask(runID: runID, taskID: request.taskID, status: snapshot.status, command: request.command.kind)
            try requireLatestEvent(.inputRequired, runID: runID)
            return .needsProductionExecutor
        }
    }

    private func requireRunID(_ request: AgentTaskCommandRequest) throws -> String {
        guard let runID = request.runID,
              !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskCommandServiceError.missingRunID
        }
        guard let task = store.taskSnapshot(runID: runID),
              task.taskID == request.taskID,
              task.parentID == request.parentID,
              store.attempts(runID: runID).contains(where: { $0.runID == runID }) else {
            throw AgentTaskCommandServiceError.unknownRun
        }
        return runID
    }

    private func optionalRunID(
        _ request: AgentTaskCommandRequest,
        required: Bool
    ) throws -> String? {
        guard request.runID != nil || required else { return nil }
        return try requireRunID(request)
    }

    private func requireRunningTask(
        runID: String,
        taskID: String,
        status: AgentTaskStatus,
        command: AgentTaskCommandKind
    ) throws {
        guard status == .running else {
            throw AgentTaskCommandServiceError.commandNotApplicable(command, status)
        }
        guard store.taskSnapshot(runID: runID)?.taskID == taskID,
              store.externalSubmissionIdentity(runID: runID) != nil else {
            throw AgentTaskCommandServiceError.unknownRun
        }
    }

    private func hasUnknownExternalSubmission(runID: String) -> Bool {
        store.events(runID: runID).contains { $0.kind == .submissionUnknown }
    }

    private func requireLatestEvent(_ kind: AgentTaskEventKind, runID: String) throws {
        guard store.events(runID: runID).last?.kind == kind else {
            throw AgentTaskCommandServiceError.requiredEventMissing(kind)
        }
    }
}
