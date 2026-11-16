import Foundation

// MARK: - P3-CHILD-40 cross-session global child-concurrency governor
//
// Lane 066 delivered the *per-session* model (ChildConcurrencySelection:
// userSelected / recommended / effective / enabledSessionCount, hardMaximum=40)
// and AgentOrchestrator enforces a *per-orchestration* effective limit through
// the private `OrchestrationGate` FIFO. That half only bounds ONE orchestration
// boundary. The row's CROSS-SESSION half is still open:
//
//   "全局请求按 N*每会话上限 累加，最终由用户选择；系统只建议并解释风险，
//    不静默改值；硬约束下停止新启动、公平排队、checkpoint、降实际并发、
//    恢复续接/Kill Switch"
//
// This file provides that cross-session half as a *pure decision core* wrapped
// by an actor with an injectable clock and NO hidden global mutable state:
// every governor is an explicitly constructed instance that the composition
// root owns and shares across the N enabled sessions. The governor accounts the
// aggregate demand (N * per-session ceiling), queues launches fairly, stops
// *new* launches under a hard global ceiling / Kill Switch, can degrade the
// *actual* concurrency it hands out, checkpoints and resumes its policy, and
// only ever *recommends and explains* risk — it never rewrites the user's
// selected value (that authority stays in ChildConcurrencySelection).

// MARK: - Risk advisory (recommend & explain; never silently change user value)

/// Deterministic risk explanation for the *requested* global child capacity.
/// This is the "系统只建议并解释风险，不静默改值" half: it reports the aggregate
/// `N * perSessionCeiling` request and whether it exceeds the hard global
/// ceiling, but it holds no power to alter any user selection.
public struct ChildConcurrencyRiskAdvisory: Sendable, Equatable {
    public let perSessionCeiling: Int
    public let enabledSessionCount: Int
    /// Aggregate request: `enabledSessionCount * perSessionCeiling` (row: 3×40=120).
    public let globalRequestedCapacity: Int
    public let globalHardCeiling: Int
    public let exceedsGlobalHardCeiling: Bool
    public let recommendation: String

    public init(perSessionCeiling: Int, enabledSessionCount: Int, globalHardCeiling: Int) {
        let perSession = max(0, perSessionCeiling)
        let sessions = max(0, enabledSessionCount)
        let requested = perSession * sessions
        let ceiling = max(1, globalHardCeiling)
        self.perSessionCeiling = perSession
        self.enabledSessionCount = sessions
        self.globalRequestedCapacity = requested
        self.globalHardCeiling = ceiling
        self.exceedsGlobalHardCeiling = requested > ceiling
        if self.exceedsGlobalHardCeiling {
            self.recommendation =
                "全局并发请求 \(requested) 超过硬上限 \(ceiling)（\(sessions) 会话 × 每会话 \(perSession)）。" +
                "建议降低每会话上限或启用会话数；系统仅提示风险，不会修改用户所选值。"
        } else {
            self.recommendation =
                "全局并发请求 \(requested) 在硬上限 \(ceiling) 内（\(sessions) 会话 × 每会话 \(perSession)）。"
        }
    }

    /// Build the advisory directly from a user selection: uses the *user-selected*
    /// per-session value (never the effective/degraded runtime value) so the risk
    /// statement always reflects what the user actually chose.
    public init(selection: ChildConcurrencySelection, globalHardCeiling: Int) {
        self.init(
            perSessionCeiling: selection.userSelected,
            enabledSessionCount: selection.enabledSessionCount,
            globalHardCeiling: globalHardCeiling
        )
    }
}

// MARK: - Admission decision

/// Result of a single cross-session launch admission request.
public enum ChildConcurrencyDecision: Sendable, Equatable {
    /// A global slot was granted. `globalActive` is the running count after the
    /// grant, `queued` the still-waiting sessions, `epoch` the monotonic version.
    case admitted(globalActive: Int, queued: Int, epoch: UInt64)
    /// A *new* launch is refused because the Kill Switch is engaged. Running
    /// children are untouched; this only stops new launches.
    case blockedByKillSwitch(globalActive: Int, queued: Int)
    /// The waiting request was abandoned because the owning task was cancelled.
    case cancelled
    /// No launch occurs when its durable admission checkpoint cannot be committed.
    case checkpointUnavailable
}

// MARK: - Checkpoint

/// Serialisable policy snapshot for the "checkpoint / 恢复续接" acceptance
/// element. Live continuations cannot survive a process restart, so a restored
/// governor resumes the *policy* (Kill Switch, degraded ceiling, epoch) and
/// starts from `globalActive == 0` (no children are running yet in a fresh
/// process). The recorded `globalActive` is retained for audit only.
/// Exact queue facts. The intent is a durable producer identity, not a grant.
public struct ChildLaunchCheckpointRequest: Codable, Sendable, Equatable {
    public let requestID: String
    public let sessionID: String
    public let arrival: TimeInterval
    public let awaitingLocalGate: Bool
    public let intent: ChildLaunchRequestIntent?
    public let queueSequence: UInt64?

    public init(requestID: String, sessionID: String, arrival: TimeInterval,
                awaitingLocalGate: Bool, intent: ChildLaunchRequestIntent?, queueSequence: UInt64? = nil) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.arrival = arrival
        self.awaitingLocalGate = awaitingLocalGate
        self.intent = intent
        self.queueSequence = queueSequence
    }
}

public struct ChildConcurrencyCheckpoint: Codable, Sendable, Equatable {
    public let epoch: UInt64
    public let globalActive: Int
    public let perSessionActive: [String: Int]
    public let queuedSessions: [String]
    public let killSwitchEngaged: Bool
    public let degradedCeiling: Int?
    public let timestamp: TimeInterval
    /// Granted global reservations still awaiting the per-orchestration gate.
    /// This is reporting only: they continue to occupy globalActive permits.
    public let localWaitingRequests: Int
    public let queuedRequests: [ChildLaunchCheckpointRequest]
    public let activeRequests: [ChildLaunchCheckpointRequest]
    /// Reopened facts remain inert until a fresh, verified turn submits again.
    public let recoveredQueuedRequests: [ChildLaunchCheckpointRequest]
    /// A previously admitted call has unknown effects after restart.
    public let unconfirmedRequests: [ChildLaunchCheckpointRequest]

    private enum CodingKeys: String, CodingKey {
        case epoch, globalActive, perSessionActive, queuedSessions
        case killSwitchEngaged, degradedCeiling, timestamp, localWaitingRequests
        case queuedRequests, activeRequests, recoveredQueuedRequests, unconfirmedRequests
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try values.decode(UInt64.self, forKey: .epoch)
        globalActive = try values.decode(Int.self, forKey: .globalActive)
        perSessionActive = try values.decode([String: Int].self, forKey: .perSessionActive)
        queuedSessions = try values.decode([String].self, forKey: .queuedSessions)
        killSwitchEngaged = try values.decode(Bool.self, forKey: .killSwitchEngaged)
        degradedCeiling = try values.decodeIfPresent(Int.self, forKey: .degradedCeiling)
        timestamp = try values.decode(TimeInterval.self, forKey: .timestamp)
        localWaitingRequests = try values.decodeIfPresent(Int.self, forKey: .localWaitingRequests) ?? 0
        queuedRequests = try values.decodeIfPresent([ChildLaunchCheckpointRequest].self, forKey: .queuedRequests) ?? []
        activeRequests = try values.decodeIfPresent([ChildLaunchCheckpointRequest].self, forKey: .activeRequests) ?? []
        recoveredQueuedRequests = try values.decodeIfPresent([ChildLaunchCheckpointRequest].self, forKey: .recoveredQueuedRequests) ?? []
        unconfirmedRequests = try values.decodeIfPresent([ChildLaunchCheckpointRequest].self, forKey: .unconfirmedRequests) ?? []
    }

    public init(
        epoch: UInt64,
        globalActive: Int,
        perSessionActive: [String: Int],
        queuedSessions: [String],
        killSwitchEngaged: Bool,
        degradedCeiling: Int?,
        timestamp: TimeInterval,
        localWaitingRequests: Int = 0,
        queuedRequests: [ChildLaunchCheckpointRequest] = [],
        activeRequests: [ChildLaunchCheckpointRequest] = [],
        recoveredQueuedRequests: [ChildLaunchCheckpointRequest] = [],
        unconfirmedRequests: [ChildLaunchCheckpointRequest] = []
    ) {
        self.epoch = epoch
        self.globalActive = globalActive
        self.perSessionActive = perSessionActive
        self.queuedSessions = queuedSessions
        self.killSwitchEngaged = killSwitchEngaged
        self.degradedCeiling = degradedCeiling
        self.timestamp = timestamp
        self.localWaitingRequests = localWaitingRequests
        self.queuedRequests = queuedRequests
        self.activeRequests = activeRequests
        self.recoveredQueuedRequests = recoveredQueuedRequests
        self.unconfirmedRequests = unconfirmedRequests
    }
}

// MARK: - Launch request identity

/// Unique identity for ONE queued launch request. A session may have several
/// children queued concurrently under the same `sessionID` (AgentOrchestrator
/// registers one cancellation handler per child of a session), so abandoning
/// by session alone can remove the wrong waiter (independent-auditor finding
/// QODER-CN-AUDIT-20260922-027). Each request owns a distinct
/// `ChildLaunchRequestID`; `abandonWaiting(requestID:)` cancels exactly that
/// one queued request and nothing else.
public struct ChildLaunchRequestID: Hashable, Sendable {
    public let rawValue: String
    /// Fresh globally-unique identity (per-request UUID).
    public init() {
        self.rawValue = UUID().uuidString
    }
    /// Deterministic identity for tests and stable call sites.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Governor actor

/// Actor-isolated cross-session ledger wrapping the deterministic decision
/// rules. The clock is injectable so tests reproduce every transition without
/// wall-clock jitter; production passes the default date clock. There is no
/// process-wide singleton: the composition root owns the shared instance and
/// hands the same one to every session's `AgentOrchestrator`.
public actor ChildConcurrencyGovernor {

    public struct Policy: Sendable, Equatable {
        /// Absolute hard ceiling on simultaneously-running children across ALL
        /// enabled sessions. New launches stop (queue) at this bound.
        public let globalHardCeiling: Int
        public init(globalHardCeiling: Int) {
            self.globalHardCeiling = max(1, globalHardCeiling)
        }
        /// Sensible default derived from the child-selection hard ceiling: a
        /// single session may already request `hardMaximum`, so the global
        /// budget is expressed explicitly by the caller for multi-session hosts.
        public static func derived(from selection: ChildConcurrencySelection) -> Policy {
            Policy(globalHardCeiling: selection.globalRequestedCapacity)
        }
    }

    private struct Waiter {
        let requestID: ChildLaunchRequestID
        let sessionID: String
        let arrival: TimeInterval
        let awaitingLocalGate: Bool
        let intent: ChildLaunchRequestIntent?
        let recoveryOrder: Int?
        let queueSequence: UInt64
    }

    /// A revision identifies this actor's current configuration controller.
    /// It is unrelated to resource epochs, permits, or capability grants.
    public struct ControlRevision: Equatable, Sendable {
        private let id: UUID
        public init() { id = UUID() }
    }

    private var policy: Policy
    private var controlRevision: ControlRevision? = nil
    private let clock: @Sendable () -> TimeInterval

    private var globalActive: Int = 0
    private var perSessionActive: [String: Int] = [:]
    private var activeRequestFacts: [ChildLaunchRequestID: ChildLaunchCheckpointRequest] = [:]
    private var reopenedQueuedRequests: [ChildLaunchCheckpointRequest] = []
    private var unconfirmedRequests: [ChildLaunchCheckpointRequest] = []
    private var reopenedQueueOrder: [String: Int] = [:]
    private let checkpointPersistence: (@Sendable (ChildConcurrencyCheckpoint) throws -> Void)?
    private var checkpointPersistenceAvailable = true
    private var activeRequestOwners: [ChildLaunchRequestID: String] = [:]
    private var degradedCeiling: Int?
    private var killSwitchEngaged: Bool = false
    private var epoch: UInt64 = 0
    private var lastTransition: TimeInterval
    private var fairnessQueue: [Waiter] = []
    private var localGateWaiters: [ChildLaunchRequestID: String] = [:]
    private var continuations: [CheckedContinuation<ChildConcurrencyDecision, Never>] = []
    private var checkpointObservers: [UUID: AsyncStream<ChildConcurrencyCheckpoint>.Continuation] = [:]

    public init(
        policy: Policy,
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        managedControlRevision: ControlRevision? = nil,
        stopNewLaunches: Bool = false,
        checkpointPersistence: (@Sendable (ChildConcurrencyCheckpoint) throws -> Void)? = nil
    ) {
        self.policy = policy
        self.checkpointPersistence = checkpointPersistence
        self.controlRevision = managedControlRevision
        self.killSwitchEngaged = stopNewLaunches
        self.clock = clock
        self.lastTransition = clock()
    }

    /// Rebuild a governor from a checkpoint, resuming its policy state.
    /// Restoration happens entirely inside a designated initialisation path:
    /// a synchronous static factory on an actor is nonisolated, so it must not
    /// call an actor-isolated instance method (`#ActorIsolatedCall` under Swift
    /// 6 strict concurrency). Initialisers are nonisolated but own `self`
    /// exclusively while it is being formed, so assigning the four checkpoint
    /// fields there is legal and keeps the external signature synchronous.
    public static func restored(
        from checkpoint: ChildConcurrencyCheckpoint,
        policy: Policy,
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        managedControlRevision: ControlRevision? = nil,
        stopNewLaunches: Bool? = nil,
        checkpointPersistence: (@Sendable (ChildConcurrencyCheckpoint) throws -> Void)? = nil
    ) -> ChildConcurrencyGovernor {
        ChildConcurrencyGovernor(policy: policy, clock: clock, restoring: checkpoint,
            managedControlRevision: managedControlRevision, stopNewLaunches: stopNewLaunches,
            checkpointPersistence: checkpointPersistence)
    }

    private init(
        policy: Policy,
        clock: @escaping @Sendable () -> TimeInterval,
        restoring checkpoint: ChildConcurrencyCheckpoint,
        managedControlRevision: ControlRevision?,
        stopNewLaunches: Bool?,
        checkpointPersistence: (@Sendable (ChildConcurrencyCheckpoint) throws -> Void)?
    ) {
        self.policy = policy
        self.clock = clock
        self.controlRevision = managedControlRevision
        self.checkpointPersistence = checkpointPersistence
        self.epoch = checkpoint.epoch
        // The fresh composition root supplies current safety state. Old state
        // remains a policy snapshot, never a revived controller or authority.
        self.killSwitchEngaged = stopNewLaunches ?? checkpoint.killSwitchEngaged
        self.degradedCeiling = checkpoint.degradedCeiling.map { max(0, min($0, policy.globalHardCeiling)) }
        self.lastTransition = checkpoint.timestamp
        self.reopenedQueuedRequests = (checkpoint.recoveredQueuedRequests + checkpoint.queuedRequests)
            .enumerated().sorted { lhs, rhs in
                let l = lhs.element.queueSequence ?? 0, r = rhs.element.queueSequence ?? 0
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
        self.unconfirmedRequests = checkpoint.unconfirmedRequests + checkpoint.activeRequests
        for (index, request) in reopenedQueuedRequests.enumerated() {
            if let id = request.intent?.intentID, reopenedQueueOrder[id] == nil {
                reopenedQueueOrder[id] = index
            }
        }
    }

    /// Commit a configuration on the existing resource actor. All live permits,
    /// FIFO entries and cancellation identities stay owned by this actor.
    /// No await occurs between the controller check and the complete checkpoint.
    @discardableResult
    public func reconfigure(
        policy: Policy,
        replacing expectedRevision: ControlRevision,
        stopNewLaunches: Bool
    ) -> ControlRevision? {
        guard controlRevision == expectedRevision else { return nil }
        self.policy = policy
        degradedCeiling = degradedCeiling.map { max(0, min($0, policy.globalHardCeiling)) }
        controlRevision = ControlRevision()
        killSwitchEngaged = stopNewLaunches
        if stopNewLaunches {
            while !fairnessQueue.isEmpty {
                fairnessQueue.removeFirst()
                let continuation = continuations.removeFirst()
                continuation.resume(returning: .blockedByKillSwitch(
                    globalActive: globalActive, queued: fairnessQueue.count))
            }
        }
        touchLocked()
        dispatchFairnessLocked()
        publishCheckpointLocked()
        return controlRevision
    }

    // MARK: Read-only views

    public var globalBudget: Int { policy.globalHardCeiling }

    public var remainingBudget: Int {
        max(0, effectiveCeiling - globalActive)
    }

    public var currentGlobalActive: Int { globalActive }

    public var isKillSwitchEngaged: Bool { killSwitchEngaged }

    /// The first value and every later value are snapshots of this actor's
    /// completed state. A slow consumer keeps only the newest checkpoint;
    /// cancelling its stream releases the observer. No polling or second count
    /// source is involved.
    public func checkpointUpdates() -> AsyncStream<ChildConcurrencyCheckpoint> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChildConcurrencyCheckpoint>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        checkpointObservers[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeCheckpointObserver(id) }
        }
        continuation.yield(checkpoint())
        return stream
    }

    /// Focused source tests verify that cancellation releases actor storage.
    internal var checkpointObserverCount: Int { checkpointObservers.count }

    private var effectiveCeiling: Int { degradedCeiling ?? policy.globalHardCeiling }

    private var grantable: Bool {
        checkpointPersistenceAvailable && !killSwitchEngaged && globalActive < effectiveCeiling
    }

    // MARK: Admission (公平排队 / 停止新启动)

    /// Request one global launch slot for `sessionID`. Fair FIFO across all
    /// sessions: if no slot is free the caller suspends behind everyone who
    /// asked earlier. Returns `.blockedByKillSwitch` immediately while the Kill
    /// Switch is engaged (stop-new-launch), and `.cancelled` if the owning task
    /// is cancelled while queued.
    ///
    /// `requestID` is the unique identity of THIS queued request (see
    /// `ChildLaunchRequestID`): two concurrent children of the same session get
    /// two distinct waiters, and cancelling one must not remove the other.
    /// Callers that register a cancellation handler pass an explicitly owned
    /// id; the default argument mints a fresh one per request.
    public func requestLaunch(
        sessionID: String,
        requestID: ChildLaunchRequestID = ChildLaunchRequestID(),
        awaitingLocalGate: Bool = false,
        intent: ChildLaunchRequestIntent? = nil
    ) async -> ChildConcurrencyDecision {
        guard checkpointPersistenceAvailable else { return .checkpointUnavailable }
        if let intent {
            guard intent.isWellFormed, intent.intentID == requestID.rawValue else { return .checkpointUnavailable }
        }
        guard activeRequestOwners[requestID] == nil,
              !fairnessQueue.contains(where: { $0.requestID == requestID }) else {
            return .checkpointUnavailable
        }
        if killSwitchEngaged {
            return .blockedByKillSwitch(globalActive: globalActive, queued: fairnessQueue.count)
        }
        if Task.isCancelled {
            return .cancelled
        }
        let recoveryOrder: Int?
        let queueSequence: UInt64
        let arrival: TimeInterval
        if let recoveredID = intent?.recoveredFromIntentID {
            guard let intent,
                  let index = reopenedQueuedRequests.firstIndex(where: {
                      $0.intent?.intentID == recoveredID
                  }),
                  let previous = reopenedQueuedRequests[index].intent,
                  previous.taskID == intent.taskID,
                  previous.parent.sessionID == intent.parent.sessionID,
                  previous.parent.conversationID == intent.parent.conversationID,
                  previous.parent.actorID == intent.parent.actorID,
                  previous.parentContextSnapshotID == intent.parentContextSnapshotID,
                  previous.intentID != intent.intentID else {
                return .checkpointUnavailable
            }
            recoveryOrder = reopenedQueueOrder[recoveredID] ?? index
            queueSequence = reopenedQueuedRequests[index].queueSequence ?? UInt64(recoveryOrder ?? index)
            arrival = reopenedQueuedRequests[index].arrival
            reopenedQueuedRequests.remove(at: index)
        } else {
            recoveryOrder = nil
            queueSequence = epoch &+ 1
            arrival = clock()
        }
        if grantable && fairnessQueue.isEmpty {
            return grantLocked(sessionID: sessionID, requestID: requestID,
                               awaitingLocalGate: awaitingLocalGate, intent: intent, queueSequence: queueSequence)
        }
        let waiter = Waiter(requestID: requestID, sessionID: sessionID,
            arrival: arrival, awaitingLocalGate: awaitingLocalGate,
            intent: intent, recoveryOrder: recoveryOrder, queueSequence: queueSequence)
        // Only fresh admitted parent requests join this live queue. Inert old
        // records cannot block it; re-submitted records retain their old order.
        let position = fairnessQueue.firstIndex { existing in
            guard let recoveryOrder else { return false }
            return existing.recoveryOrder.map { $0 > recoveryOrder } ?? true
        } ?? fairnessQueue.count
        fairnessQueue.insert(waiter, at: position)
        return await withCheckedContinuation { cont in
            defer { publishCheckpointToObserversLocked() }
            continuations.insert(cont, at: position)
            touchLocked()
            if !publishCheckpointLocked(drainOnFailure: false, publishToObservers: false) {
                fairnessQueue.remove(at: position)
                continuations.remove(at: position)
                cont.resume(returning: .checkpointUnavailable)
                rejectUnavailableQueueLocked()
            }
        }
    }

    /// Release one previously granted slot and hand it to the longest-waiting
    /// session (fairness), unless a stop condition prevents new grants.
    ///
    /// The release is honoured only for a permit owned by this session and,
    /// when supplied, this exact request. A grant increments BOTH
    /// `globalActive` and `perSessionActive[session]` together (see `grantLocked`
    /// and `dispatchFairnessLocked`), so returning a permit must decrement both
    /// together to keep the ledger consistent
    /// (`globalActive == perSessionActive.values.reduce(0, +)`). The previous
    /// unconditional `globalActive -= 1` desynced the two: a release by a session
    /// that holds no permit dropped the global count while a real child was still
    /// running, which let the fair dispatch below hand that live child's permit to
    /// a queued waiter and silently admit MORE children than `globalHardCeiling`
    /// allows — the exact opposite of the row's "硬约束下停止新启动" guarantee.
    /// Checking the request also keeps a late release from an older child of
    /// the same session from returning its replacement child's live permit.
    public func releaseLaunch(sessionID: String, requestID: ChildLaunchRequestID? = nil) {
        guard let current = perSessionActive[sessionID], current > 0 else { return }
        let ownedID: ChildLaunchRequestID
        if let requestID {
            guard activeRequestOwners[requestID] == sessionID else { return }
            ownedID = requestID
        } else {
            // Preserve the session-only API for existing direct callers. The
            // production orchestrator passes its exact request identity.
            guard let first = activeRequestOwners.first(where: { $0.value == sessionID }) else { return }
            ownedID = first.key
        }
        activeRequestOwners.removeValue(forKey: ownedID)
        activeRequestFacts.removeValue(forKey: ownedID)
        localGateWaiters.removeValue(forKey: ownedID)
        perSessionActive[sessionID] = current - 1
        globalActive -= 1
        touchLocked()
        dispatchFairnessLocked()
        publishCheckpointLocked()
    }

    /// The already-reserved child entered its local gate. Keep its global
    /// permit; only the same actor's reporting snapshot changes.
    public func enteredLocalGate(sessionID: String, requestID: ChildLaunchRequestID) {
        guard localGateWaiters[requestID] == sessionID else { return }
        localGateWaiters.removeValue(forKey: requestID)
        touchLocked()
        publishCheckpointLocked()
    }

    /// Abandon ONE queued waiter, addressed by its unique `requestID`
    /// (driven by the caller's cancellation handler). Safe to call when that
    /// request is no longer queued (already granted or never enqueued): it is
    /// then a no-op, so no double-resume is possible. Other queued requests of
    /// the SAME session are untouched (audit-027: session-keyed first-match
    /// removal used to cancel the wrong waiter).
    public func abandonWaiting(requestID: ChildLaunchRequestID) {
        guard let idx = fairnessQueue.firstIndex(where: { $0.requestID == requestID }) else { return }
        fairnessQueue.remove(at: idx)
        let cont = continuations.remove(at: idx)
        touchLocked()
        publishCheckpointLocked()
        cont.resume(returning: .cancelled)
    }

    // MARK: Kill Switch (硬约束下停止新启动 / 恢复)

    /// Engage the Kill Switch: no *new* child may launch; already-running
    /// children keep their slots. Queued waiters are released as blocked so no
    /// orchestration can hang.
    public func engageKillSwitch() {
        guard controlRevision == nil else { return }
        engageKillSwitchLocked()
    }

    @discardableResult
    public func engageKillSwitch(controlRevision revision: ControlRevision) -> Bool {
        guard controlRevision == revision else { return false }
        engageKillSwitchLocked()
        return true
    }

    private func engageKillSwitchLocked() {
        guard !killSwitchEngaged else { return }
        killSwitchEngaged = true
        while !fairnessQueue.isEmpty {
            fairnessQueue.removeFirst()
            let cont = continuations.removeFirst()
            cont.resume(returning: .blockedByKillSwitch(globalActive: globalActive, queued: fairnessQueue.count))
        }
        touchLocked()
        publishCheckpointLocked()
    }

    /// Lift the Kill Switch and resume fair dispatch to any waiters that arrive
    /// after this point (previous waiters were already released when it engaged).
    public func liftKillSwitch() {
        guard controlRevision == nil else { return }
        liftKillSwitchLocked()
    }

    @discardableResult
    public func liftKillSwitch(controlRevision revision: ControlRevision) -> Bool {
        guard controlRevision == revision else { return false }
        liftKillSwitchLocked()
        return true
    }

    private func liftKillSwitchLocked() {
        guard killSwitchEngaged else { return }
        killSwitchEngaged = false
        touchLocked()
        dispatchFairnessLocked()
        publishCheckpointLocked()
    }

    // MARK: Degrade actual concurrency (降实际并发 / 恢复续接)

    /// Reduce the *actual* concurrency handed out to `ceiling` without touching
    /// the user's selection. Running children are never killed; only new grants
    /// are throttled until active drops below the degraded ceiling.
    public func degradeActualConcurrency(to ceiling: Int) {
        guard controlRevision == nil else { return }
        degradeActualConcurrencyLocked(to: ceiling)
    }

    @discardableResult
    public func degradeActualConcurrency(to ceiling: Int, controlRevision revision: ControlRevision) -> Bool {
        guard controlRevision == revision else { return false }
        degradeActualConcurrencyLocked(to: ceiling)
        return true
    }

    private func degradeActualConcurrencyLocked(to ceiling: Int) {
        degradedCeiling = max(0, min(ceiling, policy.globalHardCeiling))
        touchLocked()
        dispatchFairnessLocked()
        publishCheckpointLocked()
    }

    /// Remove the degradation and restore the full policy ceiling.
    public func restoreActualConcurrency() {
        guard controlRevision == nil else { return }
        restoreActualConcurrencyLocked()
    }

    @discardableResult
    public func restoreActualConcurrency(controlRevision revision: ControlRevision) -> Bool {
        guard controlRevision == revision else { return false }
        restoreActualConcurrencyLocked()
        return true
    }

    private func restoreActualConcurrencyLocked() {
        guard degradedCeiling != nil else { return }
        degradedCeiling = nil
        touchLocked()
        dispatchFairnessLocked()
        publishCheckpointLocked()
    }

    // MARK: Checkpoint (checkpoint / 恢复续接)

    public func checkpoint() -> ChildConcurrencyCheckpoint {
        ChildConcurrencyCheckpoint(
            epoch: epoch,
            globalActive: globalActive,
            perSessionActive: perSessionActive,
            queuedSessions: fairnessQueue.map { $0.sessionID },
            killSwitchEngaged: killSwitchEngaged,
            degradedCeiling: degradedCeiling,
            timestamp: lastTransition,
            localWaitingRequests: localGateWaiters.count,
            queuedRequests: fairnessQueue.map { waiter in
                ChildLaunchCheckpointRequest(requestID: waiter.requestID.rawValue,
                    sessionID: waiter.sessionID, arrival: waiter.arrival,
                    awaitingLocalGate: waiter.awaitingLocalGate, intent: waiter.intent,
                    queueSequence: waiter.queueSequence)
            },
            activeRequests: activeRequestFacts.values.sorted { $0.requestID < $1.requestID },
            recoveredQueuedRequests: reopenedQueuedRequests,
            unconfirmedRequests: unconfirmedRequests
        )
    }

    // MARK: Pure advisory (recommend & explain, never mutate)

    /// The only "risk" surface: a deterministic recommendation derived from the
    /// selection and this governor's hard ceiling. It never changes the value.
    public func advisory(for selection: ChildConcurrencySelection) -> ChildConcurrencyRiskAdvisory {
        ChildConcurrencyRiskAdvisory(selection: selection, globalHardCeiling: policy.globalHardCeiling)
    }

    // MARK: Internals

    private func touchLocked() {
        epoch &+= 1
        lastTransition = clock()
    }

    private func removeCheckpointObserver(_ id: UUID) {
        checkpointObservers.removeValue(forKey: id)
    }

    @discardableResult
    private func publishCheckpointLocked(drainOnFailure: Bool = true,
                                         publishToObservers: Bool = true) -> Bool {
        let snapshot = checkpoint()
        do { try checkpointPersistence?(snapshot) }
        catch {
            checkpointPersistenceAvailable = false
            if drainOnFailure { rejectUnavailableQueueLocked() }
        }
        if publishToObservers { publishCheckpointToObserversLocked() }
        return checkpointPersistenceAvailable
    }

    private func publishCheckpointToObserversLocked() {
        // The persistence attempt may have drained the queue, or its caller
        // may have rolled back a provisional grant. Observe completed actor
        // state without retrying the failed writer or reviving admission.
        let snapshot = checkpoint()
        var closed: [UUID] = []
        for (id, observer) in checkpointObservers {
            if case .terminated = observer.yield(snapshot) { closed.append(id) }
        }
        for id in closed { checkpointObservers.removeValue(forKey: id) }
    }

    private func grantLocked(sessionID: String, requestID: ChildLaunchRequestID,
                             awaitingLocalGate: Bool, intent: ChildLaunchRequestIntent?, queueSequence: UInt64) -> ChildConcurrencyDecision {
        defer { publishCheckpointToObserversLocked() }
        if awaitingLocalGate { localGateWaiters[requestID] = sessionID }
        activeRequestOwners[requestID] = sessionID
        activeRequestFacts[requestID] = ChildLaunchCheckpointRequest(requestID: requestID.rawValue,
            sessionID: sessionID, arrival: clock(), awaitingLocalGate: awaitingLocalGate, intent: intent,
            queueSequence: queueSequence)
        globalActive += 1
        perSessionActive[sessionID, default: 0] += 1
        touchLocked()
        guard publishCheckpointLocked(publishToObservers: false) else {
            activeRequestOwners.removeValue(forKey: requestID)
            activeRequestFacts.removeValue(forKey: requestID)
            localGateWaiters.removeValue(forKey: requestID)
            globalActive -= 1
            perSessionActive[sessionID, default: 0] -= 1
            return .checkpointUnavailable
        }
        return .admitted(globalActive: globalActive, queued: fairnessQueue.count, epoch: epoch)
    }

    private func dispatchFairnessLocked() {
        while grantable, !fairnessQueue.isEmpty {
            let waiter = fairnessQueue.removeFirst()
            let cont = continuations.removeFirst()
            let decision = grantLocked(sessionID: waiter.sessionID, requestID: waiter.requestID,
                awaitingLocalGate: waiter.awaitingLocalGate, intent: waiter.intent,
                queueSequence: waiter.queueSequence)
            cont.resume(returning: decision)
        }
        if !checkpointPersistenceAvailable { rejectUnavailableQueueLocked() }
    }

    private func rejectUnavailableQueueLocked() {
        while !fairnessQueue.isEmpty {
            fairnessQueue.removeFirst()
            continuations.removeFirst().resume(returning: .checkpointUnavailable)
        }
    }
}
