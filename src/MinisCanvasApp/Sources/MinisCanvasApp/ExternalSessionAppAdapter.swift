import Foundation
import Darwin
import MinisCore

public enum ExternalSessionRuntimeState: String, Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case waitingApproval
    case cancelling
    case cancelled
    case failed
    case orphaned
    case recoveryRequired
}

public enum ExternalSessionRecoveryAction: String, Codable, Equatable, Sendable {
    case reconnect
    case retry
    case inspect

    public var title: String {
        switch self {
        case .reconnect: return "重新连接"
        case .retry: return "重试"
        case .inspect: return "检查状态"
        }
    }
}

/// Stable, secret-free output backlink.  Only the external event identity and
/// a bounded redacted summary are durable; raw output never crosses this seam.
public struct ExternalSessionOutputBacklink: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumSummaryCharacters = 512

    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let eventID: ExternalSessionEventID?
    /// Reconnect/attempt identity used to fence duplicate terminal delivery.
    /// Optional keeps older persisted backlinks decodable.
    public let correlationID: String?
    public let attemptID: String?
    public let sequence: UInt64
    public let sourceCursor: ExternalSessionCursorV1
    public let occurredAt: Date
    public let connectionGeneration: UInt64
    public let summary: String

    public init(
        schemaVersion: Int = ExternalSessionOutputBacklink.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        eventID: ExternalSessionEventID? = nil,
        correlationID: String? = nil,
        attemptID: String? = nil,
        sequence: UInt64,
        sourceCursor: ExternalSessionCursorV1,
        occurredAt: Date,
        connectionGeneration: UInt64,
        summary: String
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.eventID = eventID
        self.correlationID = correlationID
        self.attemptID = attemptID
        self.sequence = sequence
        self.sourceCursor = sourceCursor
        self.occurredAt = occurredAt
        self.connectionGeneration = connectionGeneration
        self.summary = String(summary.prefix(Self.maximumSummaryCharacters))
    }
}

public enum ExternalSessionOutputAcceptance: String, Codable, Equatable, Sendable {
    case accepted
    case rejectedLateResult
    case rejectedOrphan
    case rejectedDisconnected
    case rejectedPersistenceFailure
}

/// One server-originated request on the already bound stdio connection. The
/// caller receives the runtime identity assigned by this listener, never an
/// identity supplied in the tool's model-controlled arguments.
public struct ExternalCodexToolCallDelivery: Sendable {
    let message: ExternalSessionCodexJSONRPCMessage
    let correlationID: String
    let attemptID: String
    let ownerID: String
    let connectionGeneration: UInt64
    let sequence: UInt64
    let sourceCursor: ExternalSessionCursorV1
    let readGrant: ExternalSessionReadGrantV1
}

/// A local acknowledgement of one delivered event. Codex app-server does not
/// offer a durable notification cursor; this checkpoint fences local duplicate
/// delivery and is never presented as proof that missed events were replayed.
public struct ExternalSessionEventCheckpoint: Codable, Equatable, Sendable {
    public let identity: ExternalAgentInvocationIdentity
    public let threadID: ExternalSessionThreadID
    public let eventID: ExternalSessionEventID
    public let sequence: UInt64
    public let sourceCursor: ExternalSessionCursorV1
}

public struct ExternalSessionPendingApproval: Codable, Equatable, Sendable {
    public let identity: ExternalAgentInvocationIdentity
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    /// JSON-RPC request identity only. No command, file diff or prompt is durable.
    public let requestID: String
    public let responseAttempted: Bool?

    public init(identity: ExternalAgentInvocationIdentity, threadID: ExternalSessionThreadID,
                turnID: ExternalSessionTurnID?, requestID: String, responseAttempted: Bool = false) {
        self.identity = identity
        self.threadID = threadID
        self.turnID = turnID
        self.requestID = requestID
        self.responseAttempted = responseAttempted ? true : nil
    }
}

/// Identity of a control request whose external effect has not been proved.
/// The owner UUID is the original connection lease; no prompt, credential,
/// command body or unrestricted response is stored in the runtime record.
public struct ExternalSessionUnconfirmedControlV1: Codable, Equatable, Sendable {
    public let sourceID: ExternalSessionSourceID
    public let profileID: ExternalSessionProfileID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let operation: ExternalSessionControlOperationV1
    public let controlAuthorizationID: ExternalSessionAuthorizationID
    public let controlRevocationEpoch: UInt64
    public let connectionGeneration: UInt64
    public let connectionOwnerID: String
    /// This is only a fact about the target turn, never an operation receipt.
    public let observedTurnStatus: ExternalSessionTurnStatusV1?
    /// Optional for legacy records; never manufacture a missing original run.
    public let requestIdentity: ExternalSessionLocalRequestIdentity?

    fileprivate init(request: ExternalSessionControlRequestV1, grant: ExternalSessionControlGrantV1,
                     generation: UInt64, ownerID: String,
                     observedTurnStatus: ExternalSessionTurnStatusV1? = nil,
                     requestIdentity: ExternalSessionLocalRequestIdentity? = nil) {
        sourceID = request.sourceID
        profileID = grant.profileID
        threadID = request.threadID
        turnID = request.turnID
        operation = request.operation
        controlAuthorizationID = grant.authorizationID
        controlRevocationEpoch = grant.revocationEpoch
        connectionGeneration = generation
        connectionOwnerID = ownerID
        self.observedTurnStatus = observedTurnStatus
        self.requestIdentity = requestIdentity ?? ExternalSessionLocalRequestIdentity(request: request)
    }

    fileprivate func observing(_ status: ExternalSessionTurnStatusV1) -> Self {
        Self(sourceID: sourceID, profileID: profileID, threadID: threadID,
             turnID: turnID, operation: operation,
             controlAuthorizationID: controlAuthorizationID,
             controlRevocationEpoch: controlRevocationEpoch,
             connectionGeneration: connectionGeneration,
             connectionOwnerID: connectionOwnerID, observedTurnStatus: status,
             requestIdentity: requestIdentity)
    }

    private init(sourceID: ExternalSessionSourceID, profileID: ExternalSessionProfileID,
                 threadID: ExternalSessionThreadID, turnID: ExternalSessionTurnID?,
                 operation: ExternalSessionControlOperationV1,
                 controlAuthorizationID: ExternalSessionAuthorizationID,
                 controlRevocationEpoch: UInt64, connectionGeneration: UInt64,
                 connectionOwnerID: String, observedTurnStatus: ExternalSessionTurnStatusV1?,
                 requestIdentity: ExternalSessionLocalRequestIdentity?) {
        self.sourceID = sourceID
        self.profileID = profileID
        self.threadID = threadID
        self.turnID = turnID
        self.operation = operation
        self.controlAuthorizationID = controlAuthorizationID
        self.controlRevocationEpoch = controlRevocationEpoch
        self.connectionGeneration = connectionGeneration
        self.connectionOwnerID = connectionOwnerID
        self.observedTurnStatus = observedTurnStatus
        self.requestIdentity = requestIdentity
    }
}

public struct ExternalSessionRuntimeSnapshot: Codable, Equatable, Sendable {
    public let state: ExternalSessionRuntimeState
    public let generation: UInt64
    /// Opaque in-memory owner token. It is persisted only to invalidate stale
    /// callbacks after a reopen; it contains no credential or output data.
    public let ownerID: String?
    public let failureMessage: String?
    public let lastOutputBacklink: ExternalSessionOutputBacklink?
    public let eventCheckpoint: ExternalSessionEventCheckpoint?
    public let pendingApproval: ExternalSessionPendingApproval?
    public let unconfirmedControl: ExternalSessionUnconfirmedControlV1?
    /// Optional on the wire for old snapshots; connection status is not an
    /// acknowledgment of an externally visible control operation.
    public let sideEffectReconciliationRequired: Bool?
    public let humanResolutionHistory: [ExternalSessionHumanResolutionReceipt]?
    public let independentCompensationReceipts: [ExternalSessionIndependentCompensationReceipt]?
    public let pendingIndependentCompensationDecisionID: String?
    public var requiresSideEffectReconciliation: Bool { sideEffectReconciliationRequired == true }

    public init(
        state: ExternalSessionRuntimeState,
        generation: UInt64,
        ownerID: String?,
        failureMessage: String?,
        lastOutputBacklink: ExternalSessionOutputBacklink?,
        eventCheckpoint: ExternalSessionEventCheckpoint? = nil,
        pendingApproval: ExternalSessionPendingApproval? = nil,
        unconfirmedControl: ExternalSessionUnconfirmedControlV1? = nil,
        requiresSideEffectReconciliation: Bool = false,
        humanResolutionHistory: [ExternalSessionHumanResolutionReceipt] = [],
        independentCompensationReceipts: [ExternalSessionIndependentCompensationReceipt] = [],
        pendingIndependentCompensationDecisionID: String? = nil
    ) {
        self.sideEffectReconciliationRequired = requiresSideEffectReconciliation ? true : nil
        self.state = state
        self.generation = generation
        self.ownerID = ownerID
        self.failureMessage = failureMessage
        self.lastOutputBacklink = lastOutputBacklink
        self.eventCheckpoint = eventCheckpoint
        self.pendingApproval = pendingApproval
        self.unconfirmedControl = unconfirmedControl
        self.humanResolutionHistory = humanResolutionHistory.isEmpty ? nil : humanResolutionHistory
        self.independentCompensationReceipts = independentCompensationReceipts.isEmpty ? nil : independentCompensationReceipts
        self.pendingIndependentCompensationDecisionID = pendingIndependentCompensationDecisionID
    }

    public var userMessage: String {
        if requiresSideEffectReconciliation {
            return "外部控制结果未知，请检查原操作；重新连接不会确认副作用"
        }
        switch state {
        case .disconnected: return "外部会话未连接，可重新连接"
        case .connecting: return "正在连接外部会话"
        case .connected: return "外部会话已连接"
        case .reconnecting: return "正在恢复外部会话"
        case .waitingApproval: return "外部会话等待单独审批"
        case .cancelling: return "正在取消外部会话操作"
        case .cancelled: return "外部会话操作已取消，可重新连接"
        case .failed: return failureMessage ?? "外部会话操作失败，可重试"
        case .orphaned: return "外部会话结果无法关联，已安全丢弃，可重新连接"
        case .recoveryRequired: return "外部会话状态需要人工确认后恢复"
        }
    }

    public var recoveryActions: [ExternalSessionRecoveryAction] {
        if requiresSideEffectReconciliation { return [.inspect, .reconnect] }
        switch state {
        case .disconnected, .cancelled: return [.reconnect]
        case .failed: return [.retry, .inspect]
        case .orphaned: return [.reconnect, .inspect]
        case .recoveryRequired: return [.inspect, .reconnect]
        case .connecting, .connected, .reconnecting, .waitingApproval, .cancelling: return []
        }
    }
}

/// Lifetime token for the read-only runtime projection. Cancelling it removes
/// the callback and never changes external-session state or authority.
public final class ExternalSessionRuntimeObservation: @unchecked Sendable {
    private let cancelAction: () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    fileprivate init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        cancelAction()
    }

    deinit {
        cancel()
    }
}

private struct PersistedExternalSessionRuntime: Codable {
    let state: ExternalSessionRuntimeState
    let generation: UInt64
    let ownerID: String?
    let failureMessage: String?
    let lastOutputBacklink: ExternalSessionOutputBacklink?
    let lastSequenceByThread: [String: UInt64]
    let lastSequenceByAttempt: [String: UInt64]?
    let acceptedTerminalKeys: [String]?
    /// Explicitly stopped attempts must not be resurrected after an App reopen.
    let retiredAttempts: [ExternalAgentInvocationIdentity]?
    /// Present only while a notification attempt is live. Older files omit it.
    let activeAttemptIdentity: ExternalAgentInvocationIdentity?
    let eventCheckpoint: ExternalSessionEventCheckpoint?
    let pendingApproval: ExternalSessionPendingApproval?
    let unconfirmedControl: ExternalSessionUnconfirmedControlV1?
    let requiresSideEffectReconciliation: Bool?
    let humanResolutionHistory: [ExternalSessionHumanResolutionReceipt]?
    let independentCompensationReceipts: [ExternalSessionIndependentCompensationReceipt]?
    let pendingIndependentCompensation: ExternalSessionPendingIndependentCompensation?
}

private enum ExternalSessionRuntimePersistence {
    static let maximumBytes = 64 * 1024

    static func readData(at url: URL, initialInfo: stat) -> Data? {
        guard isStableRegularFile(initialInfo) else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              isStableRegularFile(initialInfo),
              isStableRegularFile(openedInfo),
              sameFileIdentity(initialInfo, openedInfo),
              openedInfo.st_size >= 0,
              openedInfo.st_size <= Int64(maximumBytes) else {
            return nil
        }

        var data = Data(count: Int(openedInfo.st_size))
        let readAll = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard readAll else { return nil }

        var finalInfo = stat()
        var finalPathInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              Darwin.lstat(url.path, &finalPathInfo) == 0,
              isStableRegularFile(finalInfo),
              isStableRegularFile(finalPathInfo),
              sameFileIdentity(openedInfo, finalInfo),
              sameFileIdentity(initialInfo, finalPathInfo),
              sameFileIdentity(openedInfo, finalPathInfo) else {
            return nil
        }
        return data
    }

    private static func isStableRegularFile(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_nlink == 1
            && info.st_size >= 0
            && info.st_size <= Int64(maximumBytes)
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

private final class ExternalSessionRuntimeLedger: @unchecked Sendable {
    /// An immutable instance token cannot alias a later ledger after retirement.
    let instanceIdentity = UUID()
    private let lock = NSLock()
    private let sourceID: ExternalSessionSourceID
    private let profileID: ExternalSessionProfileID
    private let persistenceURL: URL?
    private var state: ExternalSessionRuntimeState = .connected
    private var generation: UInt64 = 1
    private var ownerID: String? = UUID().uuidString
    private var failureMessage: String?
    private var lastOutputBacklink: ExternalSessionOutputBacklink?
    private var lastSequenceByThread: [String: UInt64] = [:]
    private var lastSequenceByAttempt: [String: UInt64] = [:]
    private var acceptedTerminalKeys: Set<String> = []
    private var retiredAttempts: Set<ExternalAgentInvocationIdentity> = []
    private var eventCheckpoint: ExternalSessionEventCheckpoint?
    private var pendingApproval: ExternalSessionPendingApproval?
    private var unconfirmedControl: ExternalSessionUnconfirmedControlV1?
    private var activeAttemptIdentity: ExternalAgentInvocationIdentity?
    /// In-memory transport lease only; never serialized into runtime or transcript.
    private var boundConnectionID: ObjectIdentifier?
    private var requiresSideEffectReconciliation = false
    private var humanResolutionHistory: [ExternalSessionHumanResolutionReceipt] = []
    private var independentCompensationReceipts: [ExternalSessionIndependentCompensationReceipt] = []
    private var pendingIndependentCompensation: ExternalSessionPendingIndependentCompensation?
    /// Form confirmation only; it grants no authority and never survives reopen.
    private var humanResolutionPreview: ExternalSessionHumanResolutionPreview?
    private let reconnectFence = ExternalAgentReconnectFence()
    private var observers: [UUID: @Sendable (ExternalSessionRuntimeSnapshot) -> Void] = [:]

    init(sourceID: ExternalSessionSourceID, profileID: ExternalSessionProfileID,
         persistenceURL: URL?, requiresConnectionHandshake: Bool = false) {
        self.sourceID = sourceID
        self.profileID = profileID
        self.persistenceURL = persistenceURL
        if requiresConnectionHandshake {
            state = .disconnected
            ownerID = nil
        }
        guard let persistenceURL else {
            return
        }
        var fileInfo = stat()
        guard Darwin.lstat(persistenceURL.path, &fileInfo) == 0 else {
            guard errno == ENOENT else {
                state = .recoveryRequired
                ownerID = nil
                failureMessage = "外部会话恢复记录损坏，请检查后重试"
                return
            }
            return
        }
        guard let data = ExternalSessionRuntimePersistence.readData(
                  at: persistenceURL,
                  initialInfo: fileInfo
              ),
              let persisted = try? JSONDecoder().decode(PersistedExternalSessionRuntime.self, from: data),
              persisted.lastOutputBacklink?.sourceID == nil || persisted.lastOutputBacklink?.sourceID == sourceID,
              persisted.unconfirmedControl?.sourceID == nil || persisted.unconfirmedControl?.sourceID == sourceID,
              persisted.unconfirmedControl?.profileID == nil || persisted.unconfirmedControl?.profileID == profileID,
              (persisted.humanResolutionHistory ?? []).allSatisfy({
                  $0.original.sourceID == sourceID && $0.original.profileID == profileID
                      && $0.caseID == ExternalSessionHumanResolutionDigest.caseID($0.original)
                      && $0.outcome == .localDispositionRecorded && $0.actor == .localUser
                      && $0.decisionSource == .settingsControlConfirmation
              }),
              persisted.pendingIndependentCompensation?.original.sourceID == nil
                  || persisted.pendingIndependentCompensation?.original.sourceID == sourceID,
              persisted.pendingIndependentCompensation?.original.profileID == nil
                  || persisted.pendingIndependentCompensation?.original.profileID == profileID,
              (persisted.independentCompensationReceipts ?? []).allSatisfy({ completion in
                  (persisted.humanResolutionHistory ?? []).contains {
                      $0.decisionID == completion.decisionID && $0.caseID == completion.originalUnknownCaseID
                          && $0.independentIdentity == completion.independentIdentity
                          && $0.controlGrant.authorizationID == completion.controlAuthorizationID
                          && $0.controlGrant.revocationEpoch == completion.controlRevocationEpoch
                          && $0.admissionOwnerID == completion.connectionOwnerID
                          && $0.admissionGeneration == completion.connectionGeneration
                          && $0.independentPlan?.sourceID == completion.providerReceipt.sourceID
                          && $0.independentPlan?.threadID == completion.providerReceipt.threadID
                          && $0.independentPlan?.turnID == completion.providerReceipt.turnID
                          && $0.independentPlan?.operation == completion.providerReceipt.operation
                  }
              }),
              persisted.pendingIndependentCompensation.map({ pending in
                  (persisted.humanResolutionHistory ?? []).contains {
                      $0.decisionID == pending.decisionID && $0.caseID == pending.caseID
                          && $0.original == pending.original && $0.independentIdentity == pending.identity
                          && $0.independentPlan == pending.plan && $0.controlGrant == pending.controlGrant
                          && $0.readGrant == pending.readGrant && $0.admissionOwnerID == pending.ownerID
                          && $0.admissionGeneration == pending.generation
                  }
              }) ?? true else {
            state = .recoveryRequired
            ownerID = nil
            failureMessage = "外部会话恢复记录损坏，请检查后重试"
            return
        }
        state = persisted.state
        generation = max(1, persisted.generation)
        ownerID = persisted.ownerID
        failureMessage = persisted.failureMessage
        lastOutputBacklink = persisted.lastOutputBacklink
        lastSequenceByThread = persisted.lastSequenceByThread
        lastSequenceByAttempt = persisted.lastSequenceByAttempt ?? [:]
        acceptedTerminalKeys = Set(persisted.acceptedTerminalKeys ?? [])
        retiredAttempts = Set(persisted.retiredAttempts ?? [])
        eventCheckpoint = persisted.eventCheckpoint
        pendingApproval = persisted.pendingApproval
        unconfirmedControl = persisted.unconfirmedControl
        requiresSideEffectReconciliation = persisted.requiresSideEffectReconciliation ?? false
        humanResolutionHistory = persisted.humanResolutionHistory ?? []
        independentCompensationReceipts = persisted.independentCompensationReceipts ?? []
        pendingIndependentCompensation = persisted.pendingIndependentCompensation
        // A checkpoint is only a local delivery fact: Codex notifications do
        // not offer a replay cursor. A process lost while this attempt was
        // live cannot safely resume from the next local sequence. Legacy nil
        // retains its previous loading behavior (it may mean a completed turn).
        if let interrupted = persisted.activeAttemptIdentity {
            guard interrupted.isValid else {
                state = .recoveryRequired
                ownerID = nil
                failureMessage = "外部会话恢复记录损坏，请检查后重试"
                return
            }
            requiresSideEffectReconciliation = true
        }
        if unconfirmedControl != nil || pendingIndependentCompensation != nil {
            // An in-flight control may have reached the provider before the
            // previous App lifetime ended. Its absence of a receipt is UNKNOWN.
            requiresSideEffectReconciliation = true
        }
        // A persisted connected owner belongs to the previous App lifetime;
        // invalidate it on reopen and require a fresh status handshake.
        if state == .connected || state == .waitingApproval || state == .cancelling {
            generation &+= 1
            ownerID = nil
            state = .recoveryRequired
            failureMessage = "外部会话已重新打开，请先恢复连接"
            activeAttemptIdentity = nil
        }
        if unconfirmedControl != nil {
            state = .recoveryRequired
            ownerID = nil
            failureMessage = "外部控制结果未知，请检查原操作"
        }
    }

    func snapshot() -> ExternalSessionRuntimeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func observe(
        _ observer: @escaping @Sendable (ExternalSessionRuntimeSnapshot) -> Void
    ) -> ExternalSessionRuntimeObservation {
        let observationID = UUID()
        lock.lock()
        observers[observationID] = observer
        let current = snapshotLocked()
        lock.unlock()
        observer(current)
        return ExternalSessionRuntimeObservation { [weak self] in
            self?.removeObserver(observationID)
        }
    }

    func publishCurrentSnapshot() {
        lock.lock()
        let current = snapshotLocked()
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0(current) }
    }

    private func removeObserver(_ observationID: UUID) {
        lock.lock()
        observers.removeValue(forKey: observationID)
        lock.unlock()
    }

    private var retired = false

    /// A replaced composition generation permanently loses disk-write authority.
    /// The same lock serializes retirement with every existing persistLocked call.
    func retire() {
        lock.lock()
        retired = true
        if activeAttemptIdentity != nil || pendingApproval != nil || unconfirmedControl != nil {
            requiresSideEffectReconciliation = true
        }
        generation &+= 1
        ownerID = nil
        activeAttemptIdentity = nil
        boundConnectionID = nil
        state = requiresSideEffectReconciliation || pendingApproval != nil || unconfirmedControl != nil
            ? .recoveryRequired : .disconnected
        lock.unlock()
    }

    func beginConnect(reconnecting: Bool) throws -> String {
        lock.lock()
        guard !retired else {
            lock.unlock()
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        generation &+= 1
        ownerID = UUID().uuidString
        activeAttemptIdentity = nil
        boundConnectionID = nil
        if unconfirmedControl != nil {
            // A previous control may still be awaiting a response. Rotating
            // its lease cannot establish that the external effect did not run.
            requiresSideEffectReconciliation = true
        }
        state = reconnecting ? .reconnecting : .connecting
        failureMessage = unconfirmedControl == nil ? nil : "外部控制结果未知，请检查原操作"
        persistLocked()
        let value = ownerID!
        lock.unlock()
        return value
    }

    func markConnected(ownerID expectedOwner: String) throws {
        lock.lock()
        guard !retired else {
            lock.unlock()
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        guard ownerID == expectedOwner else {
            lock.unlock()
            return
        }
        state = (requiresSideEffectReconciliation || pendingApproval != nil || unconfirmedControl != nil)
            ? .recoveryRequired : .connected
        if !requiresSideEffectReconciliation { failureMessage = nil }
        persistLocked()
        lock.unlock()
    }

    func markFailed(ownerID expectedOwner: String?, message: String) {
        lock.lock()
        guard expectedOwner == nil || ownerID == expectedOwner else {
            lock.unlock()
            return
        }
        state = requiresSideEffectReconciliation ? .recoveryRequired : .failed
        failureMessage = String(message.prefix(256))
        persistLocked()
        lock.unlock()
    }

    func markOrphaned() {
        lock.lock()
        state = .orphaned
        ownerID = nil
        failureMessage = "外部会话结果无法关联，已安全隔离"
        persistLocked()
        lock.unlock()
    }

    func disconnect(
        ownerID expectedOwner: String? = nil,
        generation expectedGeneration: UInt64? = nil,
        identity expectedIdentity: ExternalAgentInvocationIdentity? = nil,
        connectionID expectedConnection: ObjectIdentifier? = nil
    ) {
        lock.lock()
        // A finished subscription owns only its original lease. Late EOF or
        // failure must not disconnect a reconnected or replacement stream.
        guard (expectedOwner == nil || ownerID == expectedOwner),
              (expectedGeneration == nil || generation == expectedGeneration),
              (expectedConnection == nil || boundConnectionID == expectedConnection),
              (expectedIdentity == nil || activeAttemptIdentity == nil || activeAttemptIdentity == expectedIdentity) else {
            lock.unlock()
            return
        }
        let interruptedAttempt = activeAttemptIdentity != nil
        generation &+= 1
        ownerID = nil
        activeAttemptIdentity = nil
        boundConnectionID = nil
        if pendingApproval != nil || interruptedAttempt || unconfirmedControl != nil {
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            failureMessage = "外部会话断线，原操作结果未知，请检查状态"
        } else {
            state = .disconnected
            failureMessage = nil
        }
        persistLocked()
        lock.unlock()
    }

    func beginCancel() -> String? {
        lock.lock()
        guard ownerID != nil, state != .cancelling, unconfirmedControl == nil else {
            lock.unlock()
            return nil
        }
        state = .cancelling
        let current = ownerID
        persistLocked()
        lock.unlock()
        return current
    }

    func applyCancelResult(_ result: ExternalSessionControlOutcomeV1, ownerID expectedOwner: String?) {
        lock.lock()
        guard expectedOwner == nil || ownerID == expectedOwner else {
            lock.unlock()
            return
        }
        switch result {
        case .accepted:
            // Request admission is not a stopped-turn fact. Keep cancelling
            // until the matching turn terminal arrives; if it raced ahead
            // of the ACK, preserve the state it already established.
            lock.unlock()
            return
        case .completed:
            state = unconfirmedControl == nil ? .cancelled : .recoveryRequired
        case .unknownRequiresRecovery:
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            failureMessage = "取消结果未知，请检查外部会话后恢复"
        case .rejected, .unsupported:
            state = .failed
            failureMessage = "外部会话拒绝了取消请求"
        }
        persistLocked()
        lock.unlock()
    }

    func acceptOutput(_ backlink: ExternalSessionOutputBacklink, ownerID expectedOwner: String) -> ExternalSessionOutputAcceptance {
        lock.lock()
        guard state == .connected, ownerID == expectedOwner,
              backlink.connectionGeneration == generation else {
            lock.unlock()
            return state == .connected ? .rejectedLateResult : .rejectedDisconnected
        }
        guard backlink.sourceID == sourceID else {
            state = .orphaned
            ownerID = nil
            failureMessage = "外部会话结果来源不匹配，已安全隔离"
            persistLocked()
            lock.unlock()
            return .rejectedOrphan
        }
        if backlink.correlationID == nil && backlink.attemptID == nil {
            // Legacy unanchored output is kept only before an attempt has
            // started; it cannot bypass a later attempt's retirement fence.
            guard activeAttemptIdentity == nil, retiredAttempts.isEmpty,
                  eventCheckpoint == nil, lastSequenceByAttempt.isEmpty else {
                lock.unlock()
                return .rejectedLateResult
            }
        } else {
            guard let correlationID = backlink.correlationID,
                  let attemptID = backlink.attemptID else {
                lock.unlock()
                return .rejectedOrphan
            }
            let identity = ExternalAgentInvocationIdentity(
                correlationID: correlationID, attemptID: attemptID
            )
            guard identity.isValid, activeAttemptIdentity == identity,
                  !retiredAttempts.contains(identity) else {
                lock.unlock()
                return .rejectedLateResult
            }
        }
        let key = backlink.threadID.rawValue
        if let previous = lastSequenceByThread[key], backlink.sequence <= previous {
            lock.unlock()
            return .rejectedLateResult
        }
        let previousSequence = lastSequenceByThread[key]
        let previousBacklink = lastOutputBacklink
        lastSequenceByThread[key] = backlink.sequence
        lastOutputBacklink = backlink
        guard persistLocked() else {
            lastSequenceByThread[key] = previousSequence
            lastOutputBacklink = previousBacklink
            state = .recoveryRequired
            ownerID = nil
            failureMessage = "外部会话输出无法持久化，已安全隔离"
            lock.unlock()
            return .rejectedPersistenceFailure
        }
        lock.unlock()
        return .accepted
    }

    @discardableResult
    func beginAttempt(
        identity: ExternalAgentInvocationIdentity,
        ownerID expectedOwner: String
    ) -> Bool {
        lock.lock()
        guard state == .connected, ownerID == expectedOwner,
              !retiredAttempts.contains(identity),
              identity.isValid else {
            lock.unlock()
            return false
        }
        if let previous = activeAttemptIdentity, previous != identity {
            // A new invocation may supersede A, but A must be durably retired
            // before any callback from B can become the current attempt.
            retiredAttempts.insert(previous)
            guard persistLocked() else {
                state = .recoveryRequired
                ownerID = nil
                activeAttemptIdentity = nil
                boundConnectionID = nil
                requiresSideEffectReconciliation = true
                failureMessage = "外部 attempt 更替记录无法持久化，请检查原会话"
                lock.unlock()
                return false
            }
            _ = reconnectFence.stop(identity: previous)
        }
        guard reconnectFence.reconnect(identity: identity) else {
            lock.unlock()
            return false
        }
        activeAttemptIdentity = identity
        guard persistLocked() else {
            activeAttemptIdentity = nil
            boundConnectionID = nil
            ownerID = nil
            state = .recoveryRequired
            requiresSideEffectReconciliation = true
            failureMessage = "外部 attempt 身份无法持久化，请检查原会话"
            _ = reconnectFence.stop(identity: identity)
            lock.unlock()
            return false
        }
        lock.unlock()
        return true
    }

    func bindConnection(
        _ connectionID: ObjectIdentifier,
        identity: ExternalAgentInvocationIdentity,
        ownerID expectedOwner: String,
        generation expectedGeneration: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .connected,
              ownerID == expectedOwner,
              generation == expectedGeneration,
              activeAttemptIdentity == identity,
              boundConnectionID == nil || boundConnectionID == connectionID else { return false }
        boundConnectionID = connectionID
        return true
    }

    func acceptEvent(
        _ event: ExternalSessionEventV1,
        identity: ExternalAgentInvocationIdentity,
        connectionGeneration: UInt64,
        ownerID expectedOwner: String
    ) -> ExternalSessionOutputAcceptance {
        lock.lock()
        defer { lock.unlock() }
        guard (state == .connected || state == .waitingApproval || state == .cancelling
               || (state == .recoveryRequired && ownerID != nil)),
              ownerID == expectedOwner,
              generation == connectionGeneration,
              activeAttemptIdentity == identity else {
            return state == .connected ? .rejectedLateResult : .rejectedDisconnected
        }
        guard event.schemaVersion == ExternalSessionContractV1.schemaVersion,
              event.sourceID == sourceID,
              !event.eventID.rawValue.isEmpty,
              event.sourceRef.count <= 128,
              event.payload.summary.count <= ExternalSessionOutputBacklink.maximumSummaryCharacters else {
            return .rejectedOrphan
        }
        if let previous = eventCheckpoint, previous.identity == identity {
            guard previous.threadID == event.threadID,
                  event.sequence > previous.sequence else {
                return .rejectedLateResult
            }
        }
        let confirmsCancellation = state == .cancelling
            && unconfirmedControl?.operation == .interrupt
        if confirmsCancellation, let control = unconfirmedControl {
            // Keep the submitted cancellation target and lifecycle intact
            // until its terminal. Unsolicited approval cannot replace it.
            guard control.threadID == event.threadID,
                  control.turnID == event.turnID,
                  control.connectionOwnerID == expectedOwner,
                  control.connectionGeneration == connectionGeneration,
                  event.kind != .approvalRequired,
                  event.kind != .inputRequired else {
                return .rejectedOrphan
            }
        }
        let previousCheckpoint = eventCheckpoint
        let previousApproval = pendingApproval
        let previousAttempt = activeAttemptIdentity
        let previousControl = unconfirmedControl
        eventCheckpoint = ExternalSessionEventCheckpoint(
            identity: identity,
            threadID: event.threadID,
            eventID: event.eventID,
            sequence: event.sequence,
            sourceCursor: event.sourceCursor
        )
        if event.kind == .approvalRequired || event.kind == .inputRequired {
            guard !event.sourceRef.isEmpty else {
                eventCheckpoint = previousCheckpoint
                return .rejectedOrphan
            }
            guard pendingApproval == nil || pendingApproval?.requestID == event.sourceRef else {
                eventCheckpoint = previousCheckpoint
                state = .recoveryRequired
                failureMessage = "外部会话出现多个待处理审批，请检查原会话"
                persistLocked()
                return .rejectedOrphan
            }
            pendingApproval = ExternalSessionPendingApproval(
                identity: identity,
                threadID: event.threadID,
                turnID: event.turnID,
                requestID: event.sourceRef
            )
            state = .waitingApproval
        } else if event.kind == .turnCompleted || event.kind == .turnFailed || event.kind == .turnCancelled {
            // A thread subscription can deliver a late terminal for another
            // turn. It cannot settle a pending approval without a matching
            // turn ID or retire its live attempt; keep the accepted checkpoint.
            if let pendingApproval {
                guard let pendingTurnID = pendingApproval.turnID,
                      event.turnID == pendingTurnID else {
                    eventCheckpoint = previousCheckpoint
                    return .rejectedOrphan
                }
            }
            pendingApproval = nil
            if confirmsCancellation { unconfirmedControl = nil }
            if unconfirmedControl == nil {
                requiresSideEffectReconciliation = false
                state = confirmsCancellation && event.kind == .turnCancelled ? .cancelled : .connected
            } else {
                state = .recoveryRequired
            }
            activeAttemptIdentity = nil
        }
        guard persistLocked() else {
            eventCheckpoint = previousCheckpoint
            pendingApproval = previousApproval
            activeAttemptIdentity = previousAttempt
            unconfirmedControl = previousControl
            state = .recoveryRequired
            ownerID = nil
            requiresSideEffectReconciliation = true
            failureMessage = "外部事件检查点无法持久化，已安全隔离"
            return .rejectedPersistenceFailure
        }
        return .accepted
    }

    func resolveApproval(requestID: String, ownerID expectedOwner: String) {
        lock.lock()
        defer { lock.unlock() }
        guard ownerID == expectedOwner,
              let approval = pendingApproval,
              approval.requestID == requestID else { return }
        guard approval.responseAttempted == true else {
            // A matching server request can also be answered outside this
            // connection. Its resolution does not prove which decision ran.
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            ownerID = nil
            activeAttemptIdentity = nil
            boundConnectionID = nil
            failureMessage = "外部审批由未知来源解除，请检查原会话"
            persistLocked()
            return
        }
        requiresSideEffectReconciliation = true
        pendingApproval = nil
        state = .recoveryRequired
        guard persistLocked() else {
            state = .recoveryRequired
            ownerID = nil
            requiresSideEffectReconciliation = true
            failureMessage = "外部审批解除等待状态无法持久化，请检查原会话"
            return
        }
    }

    func clearReconciliation(ownerID expectedOwner: String) {
        lock.lock()
        defer { lock.unlock() }
        guard ownerID == expectedOwner, state == .recoveryRequired,
              pendingApproval == nil, unconfirmedControl == nil else { return }
        requiresSideEffectReconciliation = false
        state = .connected
        failureMessage = nil
        if !persistLocked() {
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            failureMessage = "外部对账状态无法持久化，请检查原会话"
        }
    }

    func hasDurablePersistence() -> Bool { persistenceURL != nil }

    func isRetiredControlRequest(_ request: ExternalSessionControlRequestV1) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return humanResolutionHistory.contains {
            $0.original.sourceID == request.sourceID
                && $0.original.requestIdentity?.idempotencyKey == request.idempotencyKey
        }
    }

    func makeHumanPreview(original: ExternalSessionUnconfirmedControlV1,
                          ownerID expectedOwner: String, generation expectedGeneration: UInt64,
                          readGrant: ExternalSessionReadGrantV1,
                          controlGrant: ExternalSessionControlGrantV1,
                          inspectedAt: Date, cursor: ExternalSessionCursorV1) throws
        -> ExternalSessionHumanResolutionPreview {
        lock.lock()
        defer { lock.unlock() }
        guard pendingApproval == nil else {
            throw ExternalSessionHumanResolutionError.pendingApprovalMustBeHandledSeparately
        }
        guard state == .recoveryRequired, requiresSideEffectReconciliation,
              unconfirmedControl == original, ownerID == expectedOwner,
              generation == expectedGeneration else {
            throw ExternalSessionHumanResolutionError.confirmationStale
        }
        let preview = ExternalSessionHumanResolutionPreview(
            confirmationNonce: UUID().uuidString,
            caseID: ExternalSessionHumanResolutionDigest.caseID(original), original: original,
            currentOwnerID: expectedOwner, currentGeneration: expectedGeneration,
            readGrant: readGrant, controlGrant: controlGrant,
            inspectedAt: inspectedAt, inspectedCursor: cursor)
        humanResolutionPreview = preview
        return preview
    }

    func recordHumanResolution(preview: ExternalSessionHumanResolutionPreview,
                               decision: ExternalSessionHumanDecision, note: String,
                               sourceReference: String,
                               proposal: ExternalSessionIndependentCompensationProposal?,
                               now: Date) throws -> ExternalSessionHumanResolutionReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard persistenceURL != nil else { throw ExternalSessionHumanResolutionError.persistenceUnavailable }
        guard pendingApproval == nil else {
            throw ExternalSessionHumanResolutionError.pendingApprovalMustBeHandledSeparately
        }
        guard humanResolutionPreview == preview, state == .recoveryRequired,
              requiresSideEffectReconciliation, unconfirmedControl == preview.original,
              ownerID == preview.currentOwnerID, generation == preview.currentGeneration else {
            throw ExternalSessionHumanResolutionError.confirmationStale
        }
        // An already confirmed intent cannot be dispatched twice. After a cold
        // connection/grant change, another explicit decision can supersede the
        // old intent; its immutable history remains available for audit.
        if let pending = pendingIndependentCompensation,
           pending.ownerID == preview.currentOwnerID, pending.generation == preview.currentGeneration,
           pending.controlGrant == preview.controlGrant {
            throw ExternalSessionHumanResolutionError.decisionAlreadyConsumed
        }
        let previous = captureHumanTransactionLocked()
        let decisionID = UUID().uuidString
        var independentIdentity: ExternalSessionLocalRequestIdentity?
        if let proposal {
            let request = ExternalSessionControlRequestV1(
                sourceID: sourceID, threadID: proposal.threadID, turnID: proposal.turnID,
                operation: proposal.operation, expectedCursor: preview.inspectedCursor,
                idempotencyKey: "independent-compensation:" + UUID().uuidString,
                boundedInput: proposal.boundedInput,
                parentConversationID: preview.controlGrant.parentConversationID,
                parentTurnID: preview.controlGrant.parentTurnID)
            independentIdentity = ExternalSessionLocalRequestIdentity(request: request)
        }
        let receipt = ExternalSessionHumanResolutionReceipt(
            schemaVersion: 1, decisionID: decisionID, caseID: preview.caseID,
            original: preview.original, decision: decision, actor: .localUser,
            decisionSource: .settingsControlConfirmation, outcome: .localDispositionRecorded,
            redactedNote: String(ContentSecretRedactor.redact(note).prefix(512)),
            redactedSourceReference: String(ContentSecretRedactor.redact(sourceReference).prefix(512)),
            recordedAt: now, admissionOwnerID: preview.currentOwnerID,
            admissionGeneration: preview.currentGeneration,
            readGrant: preview.readGrant, controlGrant: preview.controlGrant,
            inspectedAt: preview.inspectedAt, independentIdentity: independentIdentity,
            independentPlan: proposal?.plan)
        humanResolutionHistory.append(receipt)
        humanResolutionPreview = nil
        if decision == .recordExternalHandlingAndAllowNewControls {
            unconfirmedControl = nil
            pendingIndependentCompensation = nil
            requiresSideEffectReconciliation = false
            generation &+= 1
            ownerID = nil
            activeAttemptIdentity = nil
            boundConnectionID = nil
            state = .disconnected
            failureMessage = nil
        } else if let proposal, let independentIdentity {
            pendingIndependentCompensation = ExternalSessionPendingIndependentCompensation(
                decisionID: decisionID, caseID: preview.caseID, original: preview.original,
                plan: proposal.plan, identity: independentIdentity,
                controlGrant: preview.controlGrant, readGrant: preview.readGrant,
                ownerID: preview.currentOwnerID, generation: preview.currentGeneration)
        } else {
            restoreHumanTransactionLocked(previous)
            throw ExternalSessionHumanResolutionError.invalidExplicitDecision
        }
        do {
            _ = try encodedStateLocked()
            guard persistLocked() else { throw ExternalSessionHumanResolutionError.persistenceFailed }
        } catch {
            restoreHumanTransactionLocked(previous)
            throw error
        }
        return receipt
    }

    func prepareIndependentCompensation(decisionID: String,
        proposal: ExternalSessionIndependentCompensationProposal,
        readGrant: ExternalSessionReadGrantV1, controlGrant: ExternalSessionControlGrantV1) throws
        -> (ExternalSessionPendingIndependentCompensation, ExternalSessionUnconfirmedControlV1,
            ExternalSessionControlRequestV1) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingApproval == nil else {
            throw ExternalSessionHumanResolutionError.pendingApprovalMustBeHandledSeparately
        }
        guard let pending = pendingIndependentCompensation,
              pending.decisionID == decisionID, pending.plan == proposal.plan,
              pending.readGrant == readGrant, pending.controlGrant == controlGrant,
              ownerID == pending.ownerID, generation == pending.generation,
              state == .recoveryRequired, requiresSideEffectReconciliation,
              unconfirmedControl == pending.original else {
            throw ExternalSessionHumanResolutionError.confirmationStale
        }
        let identity = pending.identity
        guard identity.idempotencyKey != pending.original.requestIdentity?.idempotencyKey,
              identity.localOperationID != pending.original.requestIdentity?.localOperationID else {
            throw ExternalSessionHumanResolutionError.compensationIdentityReused
        }
        let request = ExternalSessionControlRequestV1(
            sourceID: proposal.sourceID, threadID: proposal.threadID, turnID: proposal.turnID,
            operation: proposal.operation, expectedCursor: identity.expectedCursor,
            expectedSequence: identity.expectedSequence, idempotencyKey: identity.idempotencyKey,
            boundedInput: proposal.boundedInput, parentConversationID: identity.parentConversationID,
            parentTurnID: identity.parentTurnID)
        let record = ExternalSessionUnconfirmedControlV1(
            request: request, grant: controlGrant, generation: pending.generation,
            ownerID: pending.ownerID, requestIdentity: identity)
        let previous = captureHumanTransactionLocked()
        unconfirmedControl = record
        do {
            _ = try encodedStateLocked()
            guard persistLocked() else { throw ExternalSessionHumanResolutionError.persistenceFailed }
        } catch {
            restoreHumanTransactionLocked(previous)
            throw error
        }
        return (pending, record, request)
    }

    func finishIndependentCompensation(_ pending: ExternalSessionPendingIndependentCompensation,
        record: ExternalSessionUnconfirmedControlV1, receipt: ExternalSessionControlReceiptV1)
        -> ExternalSessionIndependentCompensationReceipt {
        lock.lock()
        defer { lock.unlock() }
        func result(_ persistence: ExternalSessionCompensationAuditState)
            -> ExternalSessionIndependentCompensationReceipt {
            ExternalSessionIndependentCompensationReceipt(decisionID: pending.decisionID,
                originalUnknownCaseID: pending.caseID, independentIdentity: pending.identity,
                controlAuthorizationID: pending.controlGrant.authorizationID,
                controlRevocationEpoch: pending.controlGrant.revocationEpoch,
                connectionOwnerID: pending.ownerID, connectionGeneration: pending.generation,
                providerReceipt: receipt, auditPersistence: persistence)
        }
        guard unconfirmedControl == record, pendingIndependentCompensation == pending,
              ownerID == pending.ownerID, generation == pending.generation else {
            return result(.recoveryRequired)
        }
        let previous = captureHumanTransactionLocked()
        pendingIndependentCompensation = nil
        independentCompensationReceipts.append(result(.recorded))
        if receipt.outcome == .unknownRequiresRecovery {
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            ownerID = nil
            boundConnectionID = nil
            activeAttemptIdentity = nil
        } else {
            unconfirmedControl = nil
            requiresSideEffectReconciliation = false
            state = .connected
            failureMessage = nil
        }
        do {
            _ = try encodedStateLocked()
            guard persistLocked() else { throw ExternalSessionHumanResolutionError.persistenceFailed }
            return result(.recorded)
        } catch {
            restoreHumanTransactionLocked(previous)
            // Provider I/O already happened. Preserve its factual receipt in
            // the return value, but never pretend the audit was persisted.
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            ownerID = nil
            activeAttemptIdentity = nil
            boundConnectionID = nil
            failureMessage = "独立补偿回执无法持久化，原操作结果仍未知"
            return result(.recoveryRequired)
        }
    }

    private struct HumanTransactionState {
        let state: ExternalSessionRuntimeState
        let generation: UInt64
        let ownerID: String?
        let failureMessage: String?
        let activeAttemptIdentity: ExternalAgentInvocationIdentity?
        let boundConnectionID: ObjectIdentifier?
        let unconfirmedControl: ExternalSessionUnconfirmedControlV1?
        let requiresReconciliation: Bool
        let history: [ExternalSessionHumanResolutionReceipt]
        let completions: [ExternalSessionIndependentCompensationReceipt]
        let pending: ExternalSessionPendingIndependentCompensation?
        let preview: ExternalSessionHumanResolutionPreview?
    }

    private func captureHumanTransactionLocked() -> HumanTransactionState {
        HumanTransactionState(state: state, generation: generation, ownerID: ownerID,
            failureMessage: failureMessage, activeAttemptIdentity: activeAttemptIdentity,
            boundConnectionID: boundConnectionID, unconfirmedControl: unconfirmedControl,
            requiresReconciliation: requiresSideEffectReconciliation,
            history: humanResolutionHistory, completions: independentCompensationReceipts,
            pending: pendingIndependentCompensation, preview: humanResolutionPreview)
    }

    private func restoreHumanTransactionLocked(_ previous: HumanTransactionState) {
        state = previous.state; generation = previous.generation; ownerID = previous.ownerID
        failureMessage = previous.failureMessage; activeAttemptIdentity = previous.activeAttemptIdentity
        boundConnectionID = previous.boundConnectionID; unconfirmedControl = previous.unconfirmedControl
        requiresSideEffectReconciliation = previous.requiresReconciliation
        humanResolutionHistory = previous.history; independentCompensationReceipts = previous.completions
        pendingIndependentCompensation = previous.pending; humanResolutionPreview = previous.preview
    }

    /// Persist the exact control identity before provider I/O. A crash between
    /// dispatch and response therefore reopens as UNKNOWN, and a second
    /// concurrent control cannot replace the first request's identity.
    func prepareControl(
        request: ExternalSessionControlRequestV1,
        grant: ExternalSessionControlGrantV1,
        ownerID expectedOwner: String,
        generation expectedGeneration: UInt64
    ) -> ExternalSessionUnconfirmedControlV1? {
        lock.lock()
        defer { lock.unlock() }
        guard (state == .connected || (state == .cancelling && request.operation == .interrupt)),
              ownerID == expectedOwner, generation == expectedGeneration,
              !requiresSideEffectReconciliation, unconfirmedControl == nil,
              request.sourceID == sourceID, grant.sourceID == sourceID,
              grant.profileID == profileID else { return nil }
        let record = ExternalSessionUnconfirmedControlV1(
            request: request, grant: grant, generation: generation, ownerID: expectedOwner
        )
        unconfirmedControl = record
        guard persistLocked() else {
            unconfirmedControl = nil
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            ownerID = nil
            failureMessage = "外部控制身份无法持久化，已停止发送"
            return nil
        }
        return record
    }

    func finishKnownControl(_ record: ExternalSessionUnconfirmedControlV1,
                            awaitingCancelConfirmation: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard unconfirmedControl == record,
              ownerID == record.connectionOwnerID,
              generation == record.connectionGeneration else { return }
        // Preserve the already persisted target through an interrupt ACK.
        // Only its matching terminal can finish the pending cancellation.
        if awaitingCancelConfirmation { return }
        unconfirmedControl = nil
        if !persistLocked() {
            unconfirmedControl = record
            requiresSideEffectReconciliation = true
            state = .recoveryRequired
            ownerID = nil
            failureMessage = "外部控制完成记录无法持久化，请检查原操作"
        }
    }

    func markUnknownControl(_ record: ExternalSessionUnconfirmedControlV1, message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard unconfirmedControl == record else { return }
        if pendingIndependentCompensation?.identity == record.requestIdentity {
            pendingIndependentCompensation = nil
        }
        requiresSideEffectReconciliation = true
        state = .recoveryRequired
        if ownerID == record.connectionOwnerID,
           generation == record.connectionGeneration {
            ownerID = nil
            activeAttemptIdentity = nil
            boundConnectionID = nil
        }
        failureMessage = String(message.prefix(256))
        persistLocked()
    }

    /// Only records a terminal fact for the exact unknown request target.
    /// Status does not carry an operation receipt, so UNKNOWN is never cleared.
    func observeUnknownControlTerminal(
        _ record: ExternalSessionUnconfirmedControlV1,
        status: ExternalSessionTurnStatusV1,
        ownerID expectedOwner: String,
        generation expectedGeneration: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .recoveryRequired,
              ownerID == expectedOwner, generation == expectedGeneration,
              unconfirmedControl == record,
              requiresSideEffectReconciliation else { return false }
        if record.observedTurnStatus == status { return true }
        unconfirmedControl = record.observing(status)
        guard persistLocked() else {
            unconfirmedControl = record
            failureMessage = "外部终态观察无法持久化，请检查原操作"
            return false
        }
        return true
    }

    func matchesUnconfirmedControl(
        _ record: ExternalSessionUnconfirmedControlV1,
        ownerID expectedOwner: String,
        generation expectedGeneration: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .recoveryRequired && ownerID == expectedOwner
            && generation == expectedGeneration && unconfirmedControl == record
            && requiresSideEffectReconciliation
    }

    @discardableResult
    func beginApprovalResponse(
        requestID: String,
        identity: ExternalAgentInvocationIdentity,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID?,
        ownerID expectedOwner: String,
        generation expectedGeneration: UInt64,
        connectionID: ObjectIdentifier
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .waitingApproval,
              ownerID == expectedOwner,
              generation == expectedGeneration,
              boundConnectionID == connectionID,
              activeAttemptIdentity == identity,
              let approval = pendingApproval,
              approval.requestID == requestID,
              approval.identity == identity,
              approval.threadID == threadID,
              approval.turnID == turnID,
              approval.responseAttempted != true else { return false }
        pendingApproval = ExternalSessionPendingApproval(
            identity: approval.identity,
            threadID: approval.threadID,
            turnID: approval.turnID,
            requestID: approval.requestID,
            responseAttempted: true
        )
        guard persistLocked() else {
            pendingApproval = approval
            state = .recoveryRequired
            ownerID = nil
            failureMessage = "外部审批状态无法持久化，已安全隔离"
            return false
        }
        return true
    }

    func requireReconciliation(message: String) {
        lock.lock()
        requiresSideEffectReconciliation = true
        state = .recoveryRequired
        ownerID = nil
        activeAttemptIdentity = nil
        boundConnectionID = nil
        failureMessage = String(message.prefix(256))
        persistLocked()
        lock.unlock()
    }

    func acceptTerminal(
        _ event: ExternalAgentTerminalEventV1,
        ownerID expectedOwner: String
    ) -> ExternalSessionOutputAcceptance {
        lock.lock()
        guard state == .connected, ownerID == expectedOwner,
              activeAttemptIdentity == event.identity,
              event.connectionGeneration == generation else {
            lock.unlock()
            return state == .connected ? .rejectedLateResult : .rejectedDisconnected
        }
        let fenceResult = reconnectFence.accept(event)
        guard fenceResult == .accepted else {
            lock.unlock()
            return .rejectedLateResult
        }
        let key = terminalKey(for: event)
        guard acceptedTerminalKeys.insert(key).inserted else {
            lock.unlock()
            return .rejectedLateResult
        }
        let attemptKey = "\(event.identity.correlationID)\u{1f}\(event.identity.attemptID)"
        // This seam accepts one terminal per correlation/attempt identity;
        // another event ID for the same attempt is still a duplicate terminal.
        let previousSequence = lastSequenceByAttempt[attemptKey]
        guard previousSequence == nil else {
            acceptedTerminalKeys.remove(key)
            lock.unlock()
            return .rejectedLateResult
        }
        let backlink = ExternalSessionOutputBacklink(
            sourceID: event.sourceID,
            threadID: event.threadID,
            turnID: event.turnID,
            eventID: ExternalSessionEventID(rawValue: event.eventID),
            correlationID: event.identity.correlationID,
            attemptID: event.identity.attemptID,
            sequence: event.sequence,
            sourceCursor: event.sourceCursor,
            occurredAt: event.occurredAt,
            connectionGeneration: event.connectionGeneration,
            summary: event.redactedSummary
        )
        guard backlink.sourceID == sourceID else {
            acceptedTerminalKeys.remove(key)
            state = .orphaned
            ownerID = nil
            activeAttemptIdentity = nil
            failureMessage = "外部会话结果来源不匹配，已安全隔离"
            persistLocked()
            lock.unlock()
            return .rejectedOrphan
        }
        let previousBacklink = lastOutputBacklink
        lastSequenceByAttempt[attemptKey] = event.sequence
        lastOutputBacklink = backlink
        activeAttemptIdentity = nil
        guard persistLocked() else {
            lastSequenceByAttempt[attemptKey] = previousSequence
            lastOutputBacklink = previousBacklink
            acceptedTerminalKeys.remove(key)
            state = .recoveryRequired
            ownerID = nil
            activeAttemptIdentity = nil
            requiresSideEffectReconciliation = true
            failureMessage = "外部会话输出无法持久化，已安全隔离"
            lock.unlock()
            return .rejectedPersistenceFailure
        }
        lock.unlock()
        return .accepted
    }

    @discardableResult
    func stopAttempt(
        identity: ExternalAgentInvocationIdentity,
        ownerID expectedOwner: String
    ) -> Bool {
        lock.lock()
        guard state == .connected, ownerID == expectedOwner,
              activeAttemptIdentity == identity else {
            lock.unlock()
            return false
        }
        retiredAttempts.insert(identity)
        activeAttemptIdentity = nil
        guard persistLocked() else {
            // A stop without a durable tombstone cannot safely admit another
            // attempt or claim that a reopened process will reject A.
            state = .recoveryRequired
            ownerID = nil
            boundConnectionID = nil
            requiresSideEffectReconciliation = true
            failureMessage = "外部 attempt 停止记录无法持久化，请检查原会话"
            lock.unlock()
            return false
        }
        _ = reconnectFence.stop(identity: identity)
        lock.unlock()
        return true
    }

    private func terminalKey(for event: ExternalAgentTerminalEventV1) -> String {
        "\(event.identity.correlationID)\u{1f}\(event.identity.attemptID)\u{1f}\(event.eventID)"
    }

    private func snapshotLocked() -> ExternalSessionRuntimeSnapshot {
        ExternalSessionRuntimeSnapshot(
            state: state,
            generation: generation,
            ownerID: ownerID,
            failureMessage: failureMessage,
            lastOutputBacklink: lastOutputBacklink,
            eventCheckpoint: eventCheckpoint,
            pendingApproval: pendingApproval,
            unconfirmedControl: unconfirmedControl,
            requiresSideEffectReconciliation: requiresSideEffectReconciliation,
            humanResolutionHistory: humanResolutionHistory,
            independentCompensationReceipts: independentCompensationReceipts,
            pendingIndependentCompensationDecisionID: pendingIndependentCompensation?.decisionID
        )
    }

    private func encodedStateLocked() throws -> Data {
        let persisted = PersistedExternalSessionRuntime(
            state: state,
            generation: generation,
            ownerID: ownerID,
            failureMessage: failureMessage,
            lastOutputBacklink: lastOutputBacklink,
            lastSequenceByThread: lastSequenceByThread,
            lastSequenceByAttempt: lastSequenceByAttempt,
            acceptedTerminalKeys: Array(acceptedTerminalKeys).sorted(),
            retiredAttempts: Array(retiredAttempts).sorted {
                if $0.correlationID != $1.correlationID {
                return $0.correlationID < $1.correlationID
                }
                return $0.attemptID < $1.attemptID
            },
            activeAttemptIdentity: activeAttemptIdentity,
            eventCheckpoint: eventCheckpoint,
            pendingApproval: pendingApproval,
            unconfirmedControl: unconfirmedControl,
            requiresSideEffectReconciliation: requiresSideEffectReconciliation ? true : nil,
            humanResolutionHistory: humanResolutionHistory.isEmpty ? nil : humanResolutionHistory,
            independentCompensationReceipts: independentCompensationReceipts.isEmpty ? nil : independentCompensationReceipts,
            pendingIndependentCompensation: pendingIndependentCompensation
        )
        let data = try JSONEncoder().encode(persisted)
        guard data.count <= ExternalSessionRuntimePersistence.maximumBytes else {
            throw ExternalSessionHumanResolutionError.historyCapacityReached
        }
        return data
    }

    @discardableResult
    private func persistLocked() -> Bool {
        guard !retired else { return false }
        guard let persistenceURL else { return true }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encodedStateLocked()
            try data.write(to: persistenceURL, options: .atomic)
            return true
        } catch {
            // State remains in-memory and fail-closed; no partial file is kept.
            return false
        }
    }
}

/// App-facing gate for an already-running external agent session.
///
/// The injected implementation owns transport and provider-specific decoding. This
/// layer owns the App boundary: it validates source/profile identity, grant lifetime,
/// target scope, and capability separation before any implementation method is called.
public struct ExternalSessionAppAdapter: Sendable {
    private let implementation: any ExistingAgentSessionAdapter
    private let clock: @Sendable () -> Date
    private let runtime: ExternalSessionRuntimeLedger
    /// When present, every grant-gated operation must additionally carry the
    /// current revocation epoch from this ledger. Absence keeps the previous
    /// lifetime/target behavior; it never loosens it.
    ///
    /// Absence is nevertheless fail-OPEN at the revocation check: with `nil`
    /// the enforcement helper returns before consulting any epoch, so a revoked
    /// grant would still be honored. That is why production construction must
    /// go through `production(_:clock:runtimePersistenceURL:authorizationLedger:)`
    /// below, where the ledger argument is non-optional. The defaulted form of
    /// this initializer exists only for the pre-ledger call sites and must not
    /// be used to build an app-facing gate.
    private let authorizationLedger: ExternalSessionAuthorizationLedgerV1?

    public init(
        implementation: any ExistingAgentSessionAdapter,
        clock: @escaping @Sendable () -> Date = { Date() },
        runtimePersistenceURL: URL? = nil,
        authorizationLedger: ExternalSessionAuthorizationLedgerV1? = nil
    ) {
        self.init(implementation: implementation, clock: clock,
            runtimePersistenceURL: runtimePersistenceURL,
            authorizationLedger: authorizationLedger, requiresConnectionHandshake: false)
    }

    private init(
        implementation: any ExistingAgentSessionAdapter,
        clock: @escaping @Sendable () -> Date,
        runtimePersistenceURL: URL?,
        authorizationLedger: ExternalSessionAuthorizationLedgerV1?,
        requiresConnectionHandshake: Bool
    ) {
        self.implementation = implementation
        self.clock = clock
        self.runtime = ExternalSessionRuntimeLedger(
            sourceID: implementation.source.sourceID,
            profileID: implementation.source.profileID,
            persistenceURL: runtimePersistenceURL,
            requiresConnectionHandshake: requiresConnectionHandshake
        )
        self.authorizationLedger = authorizationLedger
    }

    /// Production construction path: the composition-root authorization ledger
    /// is a required argument, so the returned gate cannot be assembled in the
    /// fail-open, epoch-unchecked shape the optional parameter allows.
    ///
    /// This adds no behavior, capability, scope or lifetime rule of its own —
    /// every check still comes from `validateReadGrant`/`validateControlGrant`
    /// plus `enforceAuthorizationActive`. It only removes the possibility of a
    /// production adapter that skips the revocation check.
    public static func production(
        implementation: any ExistingAgentSessionAdapter,
        clock: @escaping @Sendable () -> Date = { Date() },
        runtimePersistenceURL: URL? = nil,
        authorizationLedger: ExternalSessionAuthorizationLedgerV1
    ) -> ExternalSessionAppAdapter {
        ExternalSessionAppAdapter(
            implementation: implementation,
            clock: clock,
            runtimePersistenceURL: runtimePersistenceURL,
            authorizationLedger: authorizationLedger,
            requiresConnectionHandshake: true
        )
    }

    public var source: ExternalSessionSourceV1 { implementation.source }

    /// Stable identity of the shared ledger, including across adapter value copies.
    /// Revocation joins may suspend while a fresh adapter is registered.
    var runtimeIdentity: UUID { runtime.instanceIdentity }

    /// Product lifecycle operation used by the composition owner when replacing
    /// or revoking this exact generation. Retained value copies share the fence.
    func retireRuntime() {
        runtime.retire()
        runtime.publishCurrentSnapshot()
    }

    public var runtimeSnapshot: ExternalSessionRuntimeSnapshot {
        runtime.snapshot()
    }

    /// Installs a read-only runtime projection. The callback receives the
    /// initial state immediately and every subsequent recovery/state change;
    /// it cannot execute external-session operations.
    @discardableResult
    public func observeRuntime(
        _ observer: @escaping @Sendable (ExternalSessionRuntimeSnapshot) -> Void
    ) -> ExternalSessionRuntimeObservation {
        runtime.observe(observer)
    }

    /// Bind a fresh owner to the already-running external session. The status
    /// read is the recovery handshake; no provider-specific output is stored.
    @discardableResult
    public func connect(
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionRuntimeSnapshot {
        let owner = try runtime.beginConnect(reconnecting: false)
        runtime.publishCurrentSnapshot()
        do {
            _ = try await status(
                target: ExternalSessionStatusTargetV1(sourceID: source.sourceID),
                readGrant: readGrant
            )
            try runtime.markConnected(ownerID: owner)
            runtime.publishCurrentSnapshot()
            return runtime.snapshot()
        } catch {
            runtime.markFailed(ownerID: owner, message: "外部会话连接失败，请检查授权后重试")
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    public func disconnect() {
        runtime.disconnect()
        runtime.publishCurrentSnapshot()
    }

    /// Retire the old owner before re-reading status, so a delayed callback
    /// from the previous connection cannot write into the recovered session.
    @discardableResult
    public func reconnect(
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionRuntimeSnapshot {
        runtime.disconnect()
        runtime.publishCurrentSnapshot()
        let owner = try runtime.beginConnect(reconnecting: true)
        runtime.publishCurrentSnapshot()
        do {
            _ = try await status(
                target: ExternalSessionStatusTargetV1(sourceID: source.sourceID),
                readGrant: readGrant
            )
            try runtime.markConnected(ownerID: owner)
            runtime.publishCurrentSnapshot()
            return runtime.snapshot()
        } catch {
            runtime.markFailed(ownerID: owner, message: "外部会话恢复失败，请检查授权后重试")
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    /// Accept only output carrying the current owner/generation backlink.
    /// Rejected output is never persisted or surfaced as a result.
    public func acceptOutput(
        _ backlink: ExternalSessionOutputBacklink,
        ownerID: String
    ) -> ExternalSessionOutputAcceptance {
        let acceptance = runtime.acceptOutput(backlink, ownerID: ownerID)
        runtime.publishCurrentSnapshot()
        return acceptance
    }

    /// Binds one external collaboration attempt to the current connection.
    /// Callers must retain the returned runtime owner and reuse the exact
    /// correlation/attempt pair for every delivery from that invocation.
    @discardableResult
    public func beginExternalAttempt(
        correlationID: String,
        attemptID: String,
        ownerID: String
    ) -> Bool {
        let accepted = runtime.beginAttempt(
            identity: ExternalAgentInvocationIdentity(
                correlationID: correlationID,
                attemptID: attemptID
            ),
            ownerID: ownerID
        )
        runtime.publishCurrentSnapshot()
        return accepted
    }

    /// Consumes only the bridge's bounded, redacted terminal event. The
    /// adapter converts it into the durable secret-free backlink after the
    /// reconnect/attempt/event fences have all passed.
    public func consumeTerminalEvent(
        _ event: ExternalAgentTerminalEventV1,
        ownerID: String
    ) -> ExternalSessionOutputAcceptance {
        let acceptance = runtime.acceptTerminal(event, ownerID: ownerID)
        runtime.publishCurrentSnapshot()
        return acceptance
    }

    /// Delivers a bounded external event only after an independent event-read
    /// grant, live revocation epoch and optional project membership all hold.
    /// The local cursor records accepted delivery; it is not a server replay
    /// token and cannot close a gap after a transport disconnect.
    public func consumeExternalEvent(
        _ event: ExternalSessionEventV1,
        correlationID: String,
        attemptID: String,
        ownerID: String,
        connectionGeneration: UInt64,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionOutputAcceptance {
        try Task.checkCancellation()
        try validateReadGrant(
            readGrant,
            target: .thread(event.threadID),
            requiredCapability: .stream,
            allowProjectThread: true
        )
        guard event.sourceID == source.sourceID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        try await enforceAuthorizationActive(readGrant)
        try await verifyProjectMembershipIfNeeded(readGrant, threadID: event.threadID)
        try await validateCompletedRead(
            readGrant,
            target: .thread(event.threadID),
            requiredCapability: .stream,
            allowProjectThread: true
        )
        try await verifyProjectMembershipIfNeeded(readGrant, threadID: event.threadID)
        let acceptance = runtime.acceptEvent(
            event,
            identity: ExternalAgentInvocationIdentity(
                correlationID: correlationID,
                attemptID: attemptID
            ),
            connectionGeneration: connectionGeneration,
            ownerID: ownerID
        )
        runtime.publishCurrentSnapshot()
        return acceptance
    }

    private func validateEventStreamGrant(
        _ grant: ExternalSessionReadGrantV1,
        threadID: ExternalSessionThreadID
    ) async throws {
        try Task.checkCancellation()
        try validateReadGrant(
            grant, target: .thread(threadID),
            requiredCapability: .stream, allowProjectThread: true
        )
        try await enforceAuthorizationActive(grant)
        try await verifyProjectMembershipIfNeeded(grant, threadID: threadID)
        try await validateCompletedRead(
            grant, target: .thread(threadID),
            requiredCapability: .stream, allowProjectThread: true
        )
        try await verifyProjectMembershipIfNeeded(grant, threadID: threadID)
    }

    /// Listens to the official Codex JSON-RPC notification stream for one
    /// explicitly selected thread. The stream has no server replay cursor;
    /// completion or disconnect leaves recovery to an authorized status/read
    /// reconciliation instead of claiming all intermediate deltas arrived.
    public func streamCodexNotifications(
        from connection: any ExternalSessionCodexJSONRPCConnection,
        threadID: ExternalSessionThreadID,
        correlationID: String,
        attemptID: String,
        ownerID: String,
        readGrant: ExternalSessionReadGrantV1,
        onEvent: @escaping @Sendable (ExternalSessionEventV1) -> Void,
        onSubscribed: @escaping @Sendable () -> Void = {},
        onToolCall: (@Sendable (ExternalCodexToolCallDelivery) async -> Bool)? = nil
    ) async throws {
        // Admission must precede both the runtime attempt and subscription:
        // an invalid events grant must never attach to the raw transport.
        try await validateEventStreamGrant(readGrant, threadID: threadID)
        let initial = runtime.snapshot()
        guard initial.state == .connected,
              initial.ownerID == ownerID,
              beginExternalAttempt(correlationID: correlationID, attemptID: attemptID, ownerID: ownerID) else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        let identity = ExternalAgentInvocationIdentity(correlationID: correlationID, attemptID: attemptID)
        guard runtime.bindConnection(
            ObjectIdentifier(connection), identity: identity,
            ownerID: ownerID, generation: initial.generation
        ) else {
            runtime.requireReconciliation(message: "外部事件连接身份不匹配，请检查原会话")
            runtime.publishCurrentSnapshot()
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        var sequence: UInt64 = initial.eventCheckpoint?.identity == identity
            ? initial.eventCheckpoint!.sequence : 0
        // Raw partial deltas stay only in this invocation's memory. Publishing
        // each fragment would miss secrets split across notification frames.
        let pendingBudget = 128 * 1024
        var pendingMessageText: [String: String] = [:]
        var pendingMessageBytes = 0
        let notifications = await connection.notifications()
        do {
            // A grant may expire or be revoked while notifications() awaits.
            try await validateEventStreamGrant(readGrant, threadID: threadID)
            onSubscribed()
            for await message in notifications {
                try await validateEventStreamGrant(readGrant, threadID: threadID)
                if message.method == "item/tool/call" {
                    guard let requestID = message.requestID else {
                        runtime.requireReconciliation(message: "外部工具请求缺少请求身份，请检查原会话")
                        runtime.publishCurrentSnapshot()
                        return
                    }
                    let nextSequence = sequence &+ 1
                    let accepted: Bool
                    if message.params["threadId"]?.stringValue == threadID.rawValue,
                       let onToolCall,
                       runtime.snapshot().ownerID == ownerID,
                       runtime.snapshot().generation == initial.generation {
                        accepted = await onToolCall(ExternalCodexToolCallDelivery(
                            message: message,
                            correlationID: correlationID, attemptID: attemptID,
                            ownerID: ownerID, connectionGeneration: initial.generation,
                            sequence: nextSequence,
                            sourceCursor: ExternalSessionCursorV1(rawValue:
                                "local-notification:\(initial.generation):\(nextSequence)"),
                            readGrant: readGrant
                        ))
                    } else {
                        accepted = false
                    }
                    try await connection.respond(to: requestID, result: .object([
                        "contentItems": .array([.object([
                            "type": .string("inputText"),
                            "text": .string(accepted ? "记忆候选已提交，仍需用户逐条批准" : "记忆提案未提交")
                        ])]),
                        "success": .bool(accepted)
                    ]))
                    if accepted { sequence = nextSequence }
                    continue
                }
                guard message.params["threadId"]?.stringValue == threadID.rawValue else { continue }
                if message.method == "item/agentMessage/delta",
                   let itemID = message.params["itemId"]?.stringValue,
                   let delta = message.params["delta"]?.stringValue {
                    let existing = pendingMessageText[itemID]
                    // Count every retained item key plus one byte per entry,
                    // so empty deltas cannot grow the dictionary without bound.
                    let newKeyBytes = existing == nil ? itemID.utf8.count + 1 : 0
                    let addedBytes = delta.utf8.count + newKeyBytes
                    guard addedBytes <= pendingBudget - pendingMessageBytes else {
                        runtime.requireReconciliation(message: "流式消息超出内存预算，请读取原会话对账")
                        runtime.publishCurrentSnapshot()
                        return
                    }
                    pendingMessageText[itemID] = (existing ?? "") + delta
                    pendingMessageBytes += addedBytes
                }
                if message.method == "turn/completed" && !pendingMessageText.isEmpty {
                    runtime.requireReconciliation(message: "外部回合结束但消息片段缺少完成事件，请读取原会话对账")
                    runtime.publishCurrentSnapshot()
                    return
                }
                var events = Self.codexEvents(
                    from: message,
                    sourceID: source.sourceID,
                    threadID: threadID,
                    afterSequence: sequence,
                    generation: initial.generation
                )
                if message.method == "item/completed",
                   let item = message.params["item"]?.objectValue,
                   item["type"]?.stringValue == "agentMessage",
                   let itemID = item["id"]?.stringValue {
                    let rawText = item["text"]?.stringValue ?? pendingMessageText[itemID]
                    if let buffered = pendingMessageText.removeValue(forKey: itemID) {
                        pendingMessageBytes -= buffered.utf8.count + itemID.utf8.count + 1
                    }
                    if let rawText {
                        guard rawText.utf8.count <= pendingBudget else {
                            runtime.requireReconciliation(message: "完整消息超出内存预算，请读取原会话对账")
                            runtime.publishCurrentSnapshot()
                            return
                        }
                        events += Self.codexFinalMessageEvents(
                            rawText,
                            sourceID: source.sourceID,
                            threadID: threadID,
                            turnID: message.params["turnId"]?.stringValue.map(ExternalSessionTurnID.init(rawValue:)),
                            itemID: itemID,
                            afterSequence: sequence &+ UInt64(events.count),
                            generation: initial.generation
                        )
                    }
                }
                for event in events {
                    let result = try await consumeExternalEvent(
                        event,
                        correlationID: correlationID,
                        attemptID: attemptID,
                        ownerID: ownerID,
                        connectionGeneration: initial.generation,
                        readGrant: readGrant
                    )
                    guard result == .accepted else { continue }
                    sequence = event.sequence
                    if message.method == "serverRequest/resolved" {
                        runtime.resolveApproval(requestID: event.sourceRef, ownerID: ownerID)
                        runtime.publishCurrentSnapshot()
                    }
                    onEvent(event)
                    if event.kind == .reconnectRequired {
                        runtime.requireReconciliation(message: "流式事件超出预算，请读取原会话对账")
                        runtime.publishCurrentSnapshot()
                        return
                    }
                }
            }
        } catch {
            runtime.disconnect(ownerID: ownerID, generation: initial.generation,
                               identity: identity, connectionID: ObjectIdentifier(connection))
            runtime.publishCurrentSnapshot()
            throw error
        }
        runtime.disconnect(ownerID: ownerID, generation: initial.generation,
                           identity: identity, connectionID: ObjectIdentifier(connection))
        runtime.publishCurrentSnapshot()
    }

    /// Reply to one pending Codex server request using an independently issued
    /// control grant. A successful write remains pending until the server sends
    /// `serverRequest/resolved`; a failed/ambiguous write becomes UNKNOWN.
    public func respondToCodexApproval(
        on connection: any ExternalSessionCodexJSONRPCConnection,
        decision: ExternalSessionControlOperationV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws {
        guard decision == .approve || decision == .reject else {
            throw ExternalSessionAppAdapterError.invalidRequest
        }
        let snapshot = runtime.snapshot()
        guard snapshot.state == .waitingApproval,
              let ownerID = snapshot.ownerID,
              let pending = snapshot.pendingApproval,
              let requestID = Self.decodeCodexRequestID(pending.requestID) else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        let request = ExternalSessionControlRequestV1(
            sourceID: source.sourceID,
            threadID: pending.threadID,
            turnID: pending.turnID,
            operation: decision,
            expectedCursor: snapshot.eventCheckpoint?.sourceCursor ?? .beginning,
            idempotencyKey: pending.requestID
        )
        try validateControlGrant(controlGrant, request: request)
        try await enforceAuthorizationActive(controlGrant)
        guard runtime.beginApprovalResponse(
            requestID: pending.requestID, identity: pending.identity,
            threadID: pending.threadID, turnID: pending.turnID,
            ownerID: ownerID, generation: snapshot.generation,
            connectionID: ObjectIdentifier(connection)
        ) else {
            runtime.publishCurrentSnapshot()
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        runtime.publishCurrentSnapshot()
        do {
            try await connection.respond(
                to: requestID,
                result: .object(["decision": .string(decision == .approve ? "accept" : "decline")])
            )
        } catch {
            runtime.requireReconciliation(message: "外部审批回应结果未知，请检查原会话")
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    /// Retires the current attempt before stop or reconnect completes. Any
    /// completion arriving after this call is rejected without persistence.
    @discardableResult
    public func stopExternalAttempt(
        correlationID: String,
        attemptID: String,
        ownerID: String
    ) -> Bool {
        let stopped = runtime.stopAttempt(
            identity: ExternalAgentInvocationIdentity(
                correlationID: correlationID,
                attemptID: attemptID
            ),
            ownerID: ownerID
        )
        runtime.publishCurrentSnapshot()
        return stopped
    }

    /// Explicit cancel path maps to the external session interrupt capability.
    @discardableResult
    public func cancel(
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        expectedCursor: ExternalSessionCursorV1,
        expectedSequence: UInt64? = nil,
        idempotencyKey: String,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        guard !runtime.snapshot().requiresSideEffectReconciliation else {
            throw ExternalSessionAppAdapterError.sideEffectReconciliationRequired
        }
        guard let owner = runtime.beginCancel() else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        runtime.publishCurrentSnapshot()
        let request = ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            operation: .interrupt,
            expectedCursor: expectedCursor,
            expectedSequence: expectedSequence,
            idempotencyKey: idempotencyKey
        )
        do {
            let receipt = try await control(request: request, controlGrant: controlGrant)
            runtime.applyCancelResult(receipt.outcome, ownerID: owner)
            runtime.publishCurrentSnapshot()
            return receipt
        } catch {
            if let transportError = error as? ExternalSessionAppServerTransportError {
                switch transportError {
                case .contractSchemaVersionMismatch, .unsupportedOperation, .invalidRequest:
                    runtime.markFailed(ownerID: owner, message: "外部会话取消失败，请检查请求")
                case .timedOut, .cancelled, .protocolVersionMismatch, .sequenceMismatch,
                     .identityMismatch, .malformedResponse, .relayed:
                    // The byte transport may already have sent the side effect.
                    // Never turn an unacknowledged control into an automatic retry.
                    runtime.applyCancelResult(.unknownRequiresRecovery, ownerID: owner)
                }
            } else {
                runtime.markFailed(ownerID: owner, message: "外部会话取消失败，请重试")
            }
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    public func markOrphaned() {
        runtime.markOrphaned()
        runtime.publishCurrentSnapshot()
    }

    public func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        try Task.checkCancellation()
        try requireReadSchemaVersion(query.schemaVersion)
        try validateReadGrant(
            readGrant,
            target: .source(query.sourceID),
            requiredCapability: .readMetadata,
            allowProjectTarget: query.projectID
        )
        guard query.limit > 0 else { throw ExternalSessionAppAdapterError.invalidRequest }
        guard query.sourceID == source.sourceID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        try await enforceAuthorizationActive(readGrant)
        let page = try await implementation.listThreads(query: query, readGrant: readGrant)
        try await validateCompletedRead(
            readGrant,
            target: .source(query.sourceID),
            requiredCapability: .readMetadata,
            allowProjectTarget: query.projectID
        )
        try validateThreadPage(page, for: query)
        return page
    }

    public func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        try Task.checkCancellation()
        try requireReadSchemaVersion(request.schemaVersion)
        try validateReadGrant(
            readGrant,
            target: .thread(request.threadID),
            requiredCapability: .readMessages,
            allowProjectThread: true
        )
        guard request.limit > 0 else { throw ExternalSessionAppAdapterError.invalidRequest }
        guard request.sourceID == source.sourceID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        try await enforceAuthorizationActive(readGrant)
        try await verifyProjectMembershipIfNeeded(readGrant, threadID: request.threadID)
        let page = try await implementation.read(request: request, readGrant: readGrant)
        try await validateCompletedRead(
            readGrant,
            target: .thread(request.threadID),
            requiredCapability: .readMessages,
            allowProjectThread: true
        )
        try await verifyProjectMembershipIfNeeded(readGrant, threadID: request.threadID)
        try validateReadPage(page, for: request)
        return page
    }

    public func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        try Task.checkCancellation()
        try requireReadSchemaVersion(target.schemaVersion)
        let targetID = target.threadID.map(ExternalSessionReadTargetV1.thread)
            ?? .source(target.sourceID)
        try validateReadGrant(
            readGrant,
            target: targetID,
            requiredCapability: .status,
            allowProjectThread: target.threadID != nil
        )
        guard target.sourceID == source.sourceID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        try await enforceAuthorizationActive(readGrant)
        if let threadID = target.threadID {
            try await verifyProjectMembershipIfNeeded(readGrant, threadID: threadID)
        }
        let status = try await implementation.status(target: target, readGrant: readGrant)
        try await validateCompletedRead(
            readGrant,
            target: targetID,
            requiredCapability: .status,
            allowProjectThread: target.threadID != nil
        )
        if let threadID = target.threadID {
            try await verifyProjectMembershipIfNeeded(readGrant, threadID: threadID)
        }
        try validateStatus(status, for: target)
        return status
    }

    public func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        guard !runtime.isRetiredControlRequest(request) else {
            throw ExternalSessionHumanResolutionError.compensationIdentityReused
        }
        let current = runtime.snapshot()
        guard !current.requiresSideEffectReconciliation else {
            throw ExternalSessionAppAdapterError.sideEffectReconciliationRequired
        }
        guard (current.state == .connected
               || (current.state == .cancelling && request.operation == .interrupt)),
              current.ownerID != nil,
              current.pendingApproval == nil else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        try validateControlGrant(controlGrant, request: request)
        guard request.sourceID == source.sourceID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        guard !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExternalSessionAppAdapterError.invalidRequest
        }
        // Control authorizations are enforced at admission. Once the external
        // side effect has been performed, the factual receipt is still
        // delivered; a mid-flight revocation must not hide what already
        // happened to the external session.
        try await enforceAuthorizationActive(controlGrant)
        try Task.checkCancellation()
        try validateControlGrant(controlGrant, request: request)
        guard let originalOwner = current.ownerID,
              let controlIdentity = runtime.prepareControl(
                request: request, grant: controlGrant,
                ownerID: originalOwner, generation: current.generation
              ) else {
            runtime.publishCurrentSnapshot()
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        runtime.publishCurrentSnapshot()
        do {
            let receipt = try await implementation.control(request: request, controlGrant: controlGrant)
            guard receipt.sourceID == request.sourceID,
                  receipt.threadID == request.threadID,
                  receipt.turnID == request.turnID,
                  receipt.operation == request.operation else {
                throw ExternalSessionAppAdapterError.invalidReadResponse
            }
            if receipt.outcome == .unknownRequiresRecovery {
                runtime.markUnknownControl(controlIdentity, message: "外部控制结果未知，请检查原操作")
            } else {
                runtime.finishKnownControl(controlIdentity,
                    awaitingCancelConfirmation: current.state == .cancelling
                        && request.operation == .interrupt && receipt.outcome == .accepted)
            }
            runtime.publishCurrentSnapshot()
            return receipt
        } catch {
            // Once provider I/O begins a timeout, disconnect or malformed
            // response cannot prove that the remote side effect did not run.
            runtime.markUnknownControl(controlIdentity, message: "外部控制回应未确认，请检查原操作")
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    /// Inspect the exact durable UNKNOWN target before presenting an explicit
    /// human decision. This preview is a volatile form token, not a grant.
    public func previewHumanResolution(readGrant: ExternalSessionReadGrantV1,
        controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionHumanResolutionPreview {
        guard authorizationLedger != nil else { throw ExternalSessionHumanResolutionError.productionLedgerRequired }
        guard runtime.hasDurablePersistence() else { throw ExternalSessionHumanResolutionError.persistenceUnavailable }
        let initial = runtime.snapshot()
        guard let original = initial.unconfirmedControl else {
            throw ExternalSessionHumanResolutionError.originalIdentityUnavailable
        }
        let observed = try await reconcileExternalSideEffect(
            threadID: original.threadID, turnID: original.turnID, readGrant: readGrant)
        guard let operation = controlGrant.operations.sorted(by: { $0.rawValue < $1.rawValue }).first else {
            throw ExternalSessionHumanResolutionError.invalidExplicitDecision
        }
        let request = ExternalSessionControlRequestV1(sourceID: source.sourceID,
            threadID: original.threadID, turnID: original.turnID, operation: operation,
            expectedCursor: observed.observedCursor, idempotencyKey: "inspection-only")
        try await validateHumanAuthorization(readGrant: readGrant, controlGrant: controlGrant, request: request)
        let current = runtime.snapshot()
        guard let currentOriginal = current.unconfirmedControl, let ownerID = current.ownerID,
              ownerID == initial.ownerID, current.generation == initial.generation,
              ExternalSessionHumanResolutionDigest.caseID(currentOriginal)
                == ExternalSessionHumanResolutionDigest.caseID(original) else {
            throw ExternalSessionHumanResolutionError.confirmationStale
        }
        return try runtime.makeHumanPreview(original: currentOriginal, ownerID: ownerID,
            generation: current.generation, readGrant: readGrant, controlGrant: controlGrant,
            inspectedAt: clock(), cursor: observed.observedCursor)
    }

    /// Records a local decision only. Neither branch creates an old provider
    /// result. Compensation dispatch is a separate API carrying this decision.
    public func submitHumanResolution(preview: ExternalSessionHumanResolutionPreview,
        decision: ExternalSessionHumanDecision, note: String, sourceReference: String,
        compensationProposal: ExternalSessionIndependentCompensationProposal? = nil,
        controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionHumanResolutionReceipt {
        guard controlGrant == preview.controlGrant,
              preview.original.sourceID == source.sourceID,
              preview.original.profileID == source.profileID,
              !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.count <= 512, sourceReference.count <= 512 else {
            throw ExternalSessionHumanResolutionError.invalidExplicitDecision
        }
        let operation: ExternalSessionControlOperationV1
        switch decision {
        case .recordExternalHandlingAndAllowNewControls:
            guard compensationProposal == nil else { throw ExternalSessionHumanResolutionError.invalidExplicitDecision }
            operation = preview.original.operation
        case .authorizeOneIndependentCompensation:
            guard let compensationProposal else { throw ExternalSessionHumanResolutionError.invalidExplicitDecision }
            try validateCompensationProposal(compensationProposal, original: preview.original)
            operation = compensationProposal.operation
        }
        let request = ExternalSessionControlRequestV1(sourceID: source.sourceID,
            threadID: preview.original.threadID, turnID: preview.original.turnID,
            operation: operation, expectedCursor: preview.inspectedCursor,
            idempotencyKey: "confirmation-only:" + preview.confirmationNonce,
            boundedInput: compensationProposal?.boundedInput)
        try await validateHumanAuthorization(readGrant: preview.readGrant, controlGrant: controlGrant, request: request)
        do {
            let receipt = try runtime.recordHumanResolution(preview: preview, decision: decision,
                note: note, sourceReference: sourceReference, proposal: compensationProposal, now: clock())
            runtime.publishCurrentSnapshot()
            return receipt
        } catch {
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    public func performIndependentCompensation(decisionReceiptID: String,
        proposal: ExternalSessionIndependentCompensationProposal,
        readGrant: ExternalSessionReadGrantV1,
        controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionIndependentCompensationReceipt {
        guard let original = runtime.snapshot().unconfirmedControl else {
            throw ExternalSessionHumanResolutionError.originalIdentityUnavailable
        }
        try validateCompensationProposal(proposal, original: original)
        let validationRequest = ExternalSessionControlRequestV1(sourceID: proposal.sourceID,
            threadID: proposal.threadID, turnID: proposal.turnID, operation: proposal.operation,
            expectedCursor: original.requestIdentity?.expectedCursor
                ?? ExternalSessionCursorV1(rawValue: "legacy-identity-unavailable"),
            idempotencyKey: "admission-only:" + decisionReceiptID, boundedInput: proposal.boundedInput)
        try await validateHumanAuthorization(readGrant: readGrant, controlGrant: controlGrant, request: validationRequest)
        let (pending, record, request) = try runtime.prepareIndependentCompensation(
            decisionID: decisionReceiptID, proposal: proposal, readGrant: readGrant, controlGrant: controlGrant)
        runtime.publishCurrentSnapshot()
        do {
            let received = try await implementation.control(request: request, controlGrant: controlGrant)
            guard received.sourceID == request.sourceID, received.threadID == request.threadID,
                  received.turnID == request.turnID, received.operation == request.operation else {
                throw ExternalSessionAppAdapterError.invalidReadResponse
            }
            let receipt = ExternalSessionControlReceiptV1(schemaVersion: received.schemaVersion,
                sourceID: received.sourceID, threadID: received.threadID, turnID: received.turnID,
                operation: received.operation, outcome: received.outcome,
                operationID: received.operationID, childThreadID: received.childThreadID,
                sourceCursor: received.sourceCursor,
                detail: received.detail.map { String(ContentSecretRedactor.redact($0).prefix(512)) })
            let result = runtime.finishIndependentCompensation(pending, record: record, receipt: receipt)
            runtime.publishCurrentSnapshot()
            return result
        } catch {
            runtime.markUnknownControl(record, message: "独立补偿回应未确认；原操作结果仍未知")
            runtime.publishCurrentSnapshot()
            throw error
        }
    }

    private func validateHumanAuthorization(readGrant: ExternalSessionReadGrantV1,
        controlGrant: ExternalSessionControlGrantV1, request: ExternalSessionControlRequestV1) async throws {
        guard let authorizationLedger else { throw ExternalSessionHumanResolutionError.productionLedgerRequired }
        let issued = await authorizationLedger.authorizationSnapshot()
        guard issued.readGrants.contains(readGrant), issued.controlGrants.contains(controlGrant) else {
            throw ExternalSessionAppAdapterError.grantRevoked
        }
        try validateReadGrant(readGrant, target: .thread(request.threadID), requiredCapability: .status,
                              allowProjectThread: true)
        try validateControlGrant(controlGrant, request: request)
        guard request.sourceID == source.sourceID else { throw ExternalSessionAppAdapterError.sourceMismatch }
        try await verifyProjectMembershipIfNeeded(readGrant, threadID: request.threadID)
        try await enforceAuthorizationActive(readGrant)
        try await enforceAuthorizationActive(controlGrant)
        try Task.checkCancellation()
        // No suspension follows these lifetime checks before the ledger CAS.
        try validateReadGrant(readGrant, target: .thread(request.threadID), requiredCapability: .status,
                              allowProjectThread: true)
        try validateControlGrant(controlGrant, request: request)
    }

    private func validateCompensationProposal(_ proposal: ExternalSessionIndependentCompensationProposal,
        original: ExternalSessionUnconfirmedControlV1) throws {
        guard proposal.sourceID == source.sourceID, proposal.profileID == source.profileID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        guard proposal.threadID == original.threadID, proposal.turnID == original.turnID else {
            throw ExternalSessionAppAdapterError.targetMismatch
        }
        // Approval/input responses belong to the existing pending-request
        // owner. Human resolution never substitutes for that owner.
        guard proposal.operation == .resume || proposal.operation == .fork || proposal.operation == .steer else {
            throw ExternalSessionHumanResolutionError.invalidExplicitDecision
        }
        switch proposal.operation {
        case .resume:
            guard proposal.turnID == nil, proposal.boundedInput == nil else {
                throw ExternalSessionAppAdapterError.invalidRequest
            }
        case .fork:
            guard proposal.boundedInput == nil else { throw ExternalSessionAppAdapterError.invalidRequest }
        case .steer:
            guard proposal.turnID != nil, let input = proposal.boundedInput,
                  !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExternalSessionAppAdapterError.invalidRequest
            }
        case .interrupt, .approve, .reject, .provideInput:
            throw ExternalSessionHumanResolutionError.invalidExplicitDecision
        }
    }

    /// Read status only for the durable UNKNOWN request target. Some controls
    /// (including resume) have no turn ID; their original nil is still part
    /// of the exact target match. A terminal status is only a target fact,
    /// never proof that this control ran or grounds to clear UNKNOWN.
    @discardableResult
    public func reconcileExternalSideEffect(
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID?,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        let initial = runtime.snapshot()
        guard initial.requiresSideEffectReconciliation,
              let original = initial.unconfirmedControl else {
            // Old bool-only recovery records have no target identity. They
            // remain UNKNOWN rather than accepting a caller-chosen target.
            throw ExternalSessionAppAdapterError.sideEffectReconciliationRequired
        }
        guard original.sourceID == source.sourceID,
              original.profileID == source.profileID,
              readGrant.sourceID == original.sourceID,
              readGrant.profileID == original.profileID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        guard original.threadID == threadID,
              original.turnID == turnID else {
            throw ExternalSessionAppAdapterError.targetMismatch
        }
        guard readGrant.revocationEpoch >= original.controlRevocationEpoch else {
            throw ExternalSessionAppAdapterError.grantRevoked
        }
        guard let ownerID = initial.ownerID,
              initial.state == .recoveryRequired else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        let observed = try await status(
            target: ExternalSessionStatusTargetV1(
                sourceID: source.sourceID,
                threadID: threadID,
                turnID: turnID
            ),
            readGrant: readGrant
        )
        guard runtime.matchesUnconfirmedControl(
            original, ownerID: ownerID, generation: initial.generation
        ) else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        if let state = observed.turnStatus,
           state == .succeeded || state == .failed || state == .cancelled {
            guard runtime.observeUnknownControlTerminal(
                original, status: state, ownerID: ownerID, generation: initial.generation
            ) else {
                throw ExternalSessionAppAdapterError.runtimeUnavailable
            }
            runtime.publishCurrentSnapshot()
        }
        return observed
    }
}

public enum ExternalSessionAppAdapterError: Error, Equatable, Sendable {
    case sourceUnavailable
    case runtimeUnavailable
    case projectMembershipUnavailable
    case sideEffectReconciliationRequired
    case sourceMismatch
    case profileMismatch
    case grantNotYetValid
    case grantExpired
    case grantRevoked
    case targetMismatch
    case capabilityUnavailable(ExternalSessionCapabilityV1)
    case scopeNotGranted
    case operationNotGranted(ExternalSessionControlOperationV1)
    case invalidRequest
    case unsupportedReadSchemaVersion(Int)
    case invalidReadResponse
}

private extension ExternalSessionAppAdapter {
    static func codexRequestID(_ id: CodexJSONRPCID) -> String {
        switch id {
        case .integer(let value): return "i:\(value)"
        case .string(let value): return "s:\(value)"
        }
    }

    static func decodeCodexRequestID(_ value: String) -> CodexJSONRPCID? {
        if value.hasPrefix("i:"), let number = Int(value.dropFirst(2)) {
            return .integer(number)
        }
        if value.hasPrefix("s:") {
            return .string(String(value.dropFirst(2)))
        }
        return nil
    }

    static func codexRequestID(_ value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .integer(let number): return codexRequestID(.integer(number))
        case .string(let text): return codexRequestID(.string(text))
        default: return nil
        }
    }

    static func codexEvents(
        from message: ExternalSessionCodexJSONRPCMessage,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        afterSequence: UInt64,
        generation: UInt64
    ) -> [ExternalSessionEventV1] {
        guard message.params["threadId"]?.stringValue == threadID.rawValue else { return [] }
        let turnValue = message.params["turnId"]?.stringValue
            ?? message.params["turn"]?.objectValue?["id"]?.stringValue
        let turnID = turnValue.map(ExternalSessionTurnID.init(rawValue:))
        let itemID = message.params["itemId"]?.stringValue
            ?? message.params["item"]?.objectValue?["id"]?.stringValue
        let requestRef = message.requestID.map(codexRequestID)
            ?? codexRequestID(message.params["requestId"])

        var kind: ExternalSessionEventKindV1
        var summaries: [String]
        var required = false
        var sourceRef = itemID.map { "item:\($0)" } ?? "notification:\(message.method)"
        switch message.method {
        case "turn/started":
            kind = .turnStarted
            summaries = ["外部回合开始"]
            required = true
        case "turn/completed":
            let status = message.params["turn"]?.objectValue?["status"]?.stringValue
            switch status {
            case "completed": kind = .turnCompleted
            case "failed": kind = .turnFailed
            case "interrupted": kind = .turnCancelled
            default: return []
            }
            summaries = ["外部回合结束：\(status ?? "unknown")"]
            required = true
        case "item/agentMessage/delta":
            guard message.params["delta"]?.stringValue != nil else { return [] }
            kind = .progress
            summaries = ["流式片段已接收，内容待完整脱敏"]
        case "item/started", "item/completed":
            kind = .progress
            summaries = [message.method == "item/started" ? "外部项目开始" : "外部项目完成"]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "item/permissions/requestApproval":
            guard let requestRef else { return [] }
            kind = .approvalRequired
            summaries = ["外部操作等待单独审批"]
            sourceRef = requestRef
            required = true
        case "item/tool/requestUserInput":
            guard let requestRef else { return [] }
            kind = .inputRequired
            summaries = ["外部会话等待用户输入"]
            sourceRef = requestRef
            required = true
        case "serverRequest/resolved":
            guard let requestRef else { return [] }
            kind = .progress
            summaries = ["外部请求已解除等待"]
            sourceRef = requestRef
            required = true
        default:
            return []
        }
        return summaries.enumerated().map { index, summary in
            let sequence = afterSequence &+ UInt64(index + 1)
            return ExternalSessionEventV1(
                eventID: ExternalSessionEventID(rawValue: "codex:\(generation):\(sequence)"),
                sourceID: sourceID,
                threadID: threadID,
                turnID: turnID,
                sequence: sequence,
                sourceCursor: ExternalSessionCursorV1(rawValue: "local-notification:\(generation):\(sequence)"),
                occurredAt: Date(),
                required: required,
                kind: kind,
                payload: ExternalSessionRedactedPayloadV1(kind: message.method, summary: summary),
                sourceRef: sourceRef
            )
        }
    }

    static func codexFinalMessageEvents(
        _ rawText: String,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID?,
        itemID: String,
        afterSequence: UInt64,
        generation: UInt64
    ) -> [ExternalSessionEventV1] {
        let redacted = ContentSecretRedactor.redact(rawText)
        let payloadKind = redacted == rawText
            ? "item/agentMessage/delta" : "item/agentMessage/delta:SECRET_REDACTED"
        let characters = Array(redacted)
        guard characters.count <= 128 * 1024 else {
            return [ExternalSessionEventV1(
                eventID: ExternalSessionEventID(rawValue: "codex:\(generation):\(afterSequence &+ 1)"),
                sourceID: sourceID, threadID: threadID, turnID: turnID,
                sequence: afterSequence &+ 1,
                sourceCursor: ExternalSessionCursorV1(rawValue: "local-notification:\(generation):\(afterSequence &+ 1)"),
                occurredAt: Date(), required: true, kind: .reconnectRequired,
                payload: ExternalSessionRedactedPayloadV1(kind: "item/completed", summary: "消息超出预算，需读取原会话对账"),
                sourceRef: "item:\(itemID)"
            )]
        }
        return stride(from: 0, to: characters.count, by: 512).enumerated().map { index, start in
            let sequence = afterSequence &+ UInt64(index + 1)
            return ExternalSessionEventV1(
                eventID: ExternalSessionEventID(rawValue: "codex:\(generation):\(sequence)"),
                sourceID: sourceID, threadID: threadID, turnID: turnID,
                sequence: sequence,
                sourceCursor: ExternalSessionCursorV1(rawValue: "local-notification:\(generation):\(sequence)"),
                occurredAt: Date(), required: false, kind: .itemDelta,
                payload: ExternalSessionRedactedPayloadV1(kind: payloadKind, summary: String(characters[start..<min(start + 512, characters.count)])),
                sourceRef: "item:\(itemID)"
            )
        }
    }

    func requireReadSchemaVersion(_ version: Int) throws {
        guard version == ExternalSessionContractV1.schemaVersion else {
            throw ExternalSessionAppAdapterError.unsupportedReadSchemaVersion(version)
        }
    }

    /// A provider response is data, not authority to switch source, project or
    /// thread. Check every nested V1 value before exposing it to the caller.
    /// Completion-time revocation is deliberately checked first at the call site.
    func validateThreadPage(
        _ page: ExternalSessionThreadPageV1,
        for query: ExternalSessionThreadQueryV1
    ) throws {
        try requireReadSchemaVersion(page.schemaVersion)
        guard page.sourceID == query.sourceID else {
            throw ExternalSessionAppAdapterError.invalidReadResponse
        }
        for thread in page.threads {
            try requireReadSchemaVersion(thread.schemaVersion)
            guard thread.sourceID == query.sourceID,
                  query.projectID == nil || thread.projectID == query.projectID else {
                throw ExternalSessionAppAdapterError.invalidReadResponse
            }
        }
    }

    func validateReadPage(
        _ page: ExternalSessionReadPageV1,
        for request: ExternalSessionReadRequestV1
    ) throws {
        try requireReadSchemaVersion(page.schemaVersion)
        guard page.sourceID == request.sourceID,
              page.threadID == request.threadID else {
            throw ExternalSessionAppAdapterError.invalidReadResponse
        }
        for turn in page.turns {
            try requireReadSchemaVersion(turn.schemaVersion)
            guard turn.sourceID == request.sourceID,
                  turn.threadID == request.threadID else {
                throw ExternalSessionAppAdapterError.invalidReadResponse
            }
        }
        for event in page.events {
            try requireReadSchemaVersion(event.schemaVersion)
            guard event.sourceID == request.sourceID,
                  event.threadID == request.threadID else {
                throw ExternalSessionAppAdapterError.invalidReadResponse
            }
        }
        guard page.messageChunks.count <= 512 else {
            throw ExternalSessionAppAdapterError.invalidReadResponse
        }
        for chunk in page.messageChunks {
            guard chunk.sourceID == request.sourceID,
                  chunk.threadID == request.threadID,
                  !chunk.messageID.isEmpty,
                  ["user", "assistant", "tool", "system"].contains(chunk.role),
                  chunk.text.count <= ExternalSessionMessageChunkV1.maximumCharacters,
                  chunk.text.utf8.count <= ExternalSessionMessageChunkV1.maximumUTF8Bytes else {
                throw ExternalSessionAppAdapterError.invalidReadResponse
            }
        }
    }

    func validateStatus(
        _ status: ExternalSessionStatusV1,
        for target: ExternalSessionStatusTargetV1
    ) throws {
        try requireReadSchemaVersion(status.schemaVersion)
        guard status.sourceID == target.sourceID,
              status.threadID == target.threadID,
              status.turnID == target.turnID else {
            throw ExternalSessionAppAdapterError.invalidReadResponse
        }
    }

    /// Revocation-epoch enforcement against the composition-root ledger.
    /// Without an injected ledger the epoch field stays advisory (unchanged
    /// boundary behavior; note that this is fail-open for revocation, which is
    /// why `ExternalSessionAppAdapter.production(...)` is the required
    /// construction path); with one, a revoked authorization fails at both
    /// admission and completion so no transcript page is delivered post-
    /// revocation and no control operation is admitted post-revocation.
    func enforceAuthorizationActive(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        revocationEpoch: UInt64
    ) async throws {
        guard let authorizationLedger else { return }
        guard await authorizationLedger.isAuthorizationActive(
            sourceID: sourceID,
            profileID: profileID,
            revocationEpoch: revocationEpoch
        ) else {
            throw ExternalSessionAppAdapterError.grantRevoked
        }
    }

    func enforceAuthorizationActive(_ grant: ExternalSessionReadGrantV1) async throws {
        try await enforceAuthorizationActive(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            revocationEpoch: grant.revocationEpoch
        )
    }

    func enforceAuthorizationActive(_ grant: ExternalSessionControlGrantV1) async throws {
        try await enforceAuthorizationActive(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            revocationEpoch: grant.revocationEpoch
        )
    }

    func validateCompletedRead(
        _ grant: ExternalSessionReadGrantV1,
        target requestedTarget: ExternalSessionReadTargetV1,
        requiredCapability: ExternalSessionCapabilityV1,
        allowProjectTarget: ExternalSessionProjectID? = nil,
        allowProjectThread: Bool = false
    ) async throws {
        // The implementation may suspend while the caller's grant expires or
        // the task is cancelled. Recheck both before the result reaches the
        // consumer so a late provider response is never published.
        try Task.checkCancellation()
        try validateReadGrant(
            grant,
            target: requestedTarget,
            requiredCapability: requiredCapability,
            allowProjectTarget: allowProjectTarget,
            allowProjectThread: allowProjectThread
        )
        // A revocation that landed while the provider was responding must
        // also fence delivery: the fetched page is dropped, not surfaced.
        try await enforceAuthorizationActive(grant)
    }

    func validateReadGrant(
        _ grant: ExternalSessionReadGrantV1,
        target requestedTarget: ExternalSessionReadTargetV1,
        requiredCapability: ExternalSessionCapabilityV1,
        allowProjectTarget: ExternalSessionProjectID? = nil,
        allowProjectThread: Bool = false
    ) throws {
        try requireReadSchemaVersion(source.schemaVersion)
        try requireReadSchemaVersion(grant.schemaVersion)
        try validateSourceAndLifetime(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            issuedAt: grant.issuedAt,
            expiresAt: grant.expiresAt
        )
        guard source.capabilities.contains(requiredCapability) else {
            throw ExternalSessionAppAdapterError.capabilityUnavailable(requiredCapability)
        }
        guard grant.scopes.contains(scope(for: requiredCapability)) else {
            throw ExternalSessionAppAdapterError.scopeNotGranted
        }
        guard targetMatches(
            grant.target,
            requestedTarget: requestedTarget,
            projectID: allowProjectTarget,
            allowProjectThread: allowProjectThread
        ) else {
            throw ExternalSessionAppAdapterError.targetMismatch
        }
    }

    func validateControlGrant(
        _ grant: ExternalSessionControlGrantV1,
        request: ExternalSessionControlRequestV1
    ) throws {
        try validateSourceAndLifetime(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            issuedAt: grant.issuedAt,
            expiresAt: grant.expiresAt
        )
        guard source.capabilities.contains(capability(for: request.operation)) else {
            throw ExternalSessionAppAdapterError.capabilityUnavailable(
                capability(for: request.operation)
            )
        }
        guard grant.operations.contains(request.operation) else {
            throw ExternalSessionAppAdapterError.operationNotGranted(request.operation)
        }
        guard grant.target == .thread(request.threadID) else {
            throw ExternalSessionAppAdapterError.targetMismatch
        }
    }

    func validateSourceAndLifetime(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        guard source.authState == .authorized else {
            throw ExternalSessionAppAdapterError.sourceUnavailable
        }
        guard sourceID == source.sourceID else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
        guard profileID == source.profileID else {
            throw ExternalSessionAppAdapterError.profileMismatch
        }
        let now = clock()
        guard issuedAt <= now else {
            throw ExternalSessionAppAdapterError.grantNotYetValid
        }
        guard now < expiresAt else {
            throw ExternalSessionAppAdapterError.grantExpired
        }
    }

    func targetMatches(
        _ grantedTarget: ExternalSessionReadTargetV1,
        requestedTarget: ExternalSessionReadTargetV1,
        projectID: ExternalSessionProjectID?,
        allowProjectThread: Bool
    ) -> Bool {
        switch (grantedTarget, requestedTarget) {
        case let (.source(granted), .source(requested)):
            return granted == requested && granted == source.sourceID
        case let (.source(granted), .thread):
            return granted == source.sourceID
        case let (.project(granted), .source(requested)):
            return projectID != nil && granted == projectID && requested == source.sourceID
        case (.project, .thread):
            // Membership is checked against trusted metadata before body I/O
            // and again before a completed page can leave the gate.
            return allowProjectThread
        case let (.thread(granted), .thread(requested)):
            return granted == requested
        default:
            return false
        }
    }

    func verifyProjectMembershipIfNeeded(
        _ grant: ExternalSessionReadGrantV1,
        threadID: ExternalSessionThreadID
    ) async throws {
        guard case let .project(projectID) = grant.target else { return }
        guard let verifier = implementation as? any ExternalSessionProjectMembershipVerifier else {
            throw ExternalSessionAppAdapterError.projectMembershipUnavailable
        }
        guard try await verifier.contains(threadID: threadID, projectID: projectID) else {
            throw ExternalSessionAppAdapterError.targetMismatch
        }
        try await enforceAuthorizationActive(grant)
    }

    func scope(for capability: ExternalSessionCapabilityV1) -> ExternalSessionReadScopeV1 {
        switch capability {
        case .readMetadata:
            return .metadata
        case .readMessages:
            return .messages
        case .stream:
            return .events
        case .status:
            return .status
        case .resume, .fork, .steer, .interrupt, .approval:
            return .events
        }
    }

    func capability(for operation: ExternalSessionControlOperationV1) -> ExternalSessionCapabilityV1 {
        switch operation {
        case .resume: return .resume
        case .fork: return .fork
        case .steer: return .steer
        case .interrupt: return .interrupt
        case .approve, .reject, .provideInput: return .approval
        }
    }
}
