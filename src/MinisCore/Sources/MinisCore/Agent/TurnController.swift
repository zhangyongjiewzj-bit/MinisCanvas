import Foundation

/// Thrown when an `AgentLoop` turn is interrupted via `TurnController`.
///
/// Distinct from `CancellationError` (task cancellation): this is a
/// user-initiated turn interruption.
public struct InterruptedError: Error, Equatable, Sendable {
    public init() {}
}

/// Conversation-level turn control with per-turn cancellation isolation.
///
/// A controller can be shared by an orchestrator, but each `beginTurn()` call
/// returns a handle bound to one monotonic `turnID`. Interrupting that handle
/// cannot cancel a sibling handle. The legacy `start()/finish()/isCancelled()`
/// methods remain for callers that have one active turn; `AgentLoop` uses the
/// handle API so concurrent turns do not share a boolean cancellation flag.
public actor TurnController {

    /// Isolated control for one active turn.
    public struct TurnHandle: Sendable {
        public let turnID: Int
        public let loopIdentity: ToolLoopLifecycle.Identity
        private let controller: TurnController

        fileprivate init(
            turnID: Int,
            loopIdentity: ToolLoopLifecycle.Identity,
            controller: TurnController
        ) {
            self.turnID = turnID
            self.loopIdentity = loopIdentity
            self.controller = controller
        }

        public func isCancelled() async -> Bool {
            await controller.isCancelled(turnID: turnID)
        }

        public func isActive() async -> Bool {
            await controller.isActive(turnID: turnID)
        }

        public func acceptsToolEvent() async -> Bool {
            await controller.acceptsToolEvent(loopIdentity)
        }

        public func interrupt() async {
            await controller.interrupt(turnID: turnID)
        }

        public func revoke() async {
            await controller.revoke(turnID: turnID)
        }

        public func finish() async {
            await controller.finish(turnID: turnID)
        }

        /// O-04: keep this exact turn's cancellation scope alive after its
        /// foreground loop finishes, while a background child still runs.
        /// Fails (false) for an inactive or already cancelled turn.
        public func retainForBackground() async -> Bool {
            await controller.retainForBackground(turnID: turnID)
        }

        /// Pairs with a successful `retainForBackground()`. The last release
        /// performs a `finish()` that was deferred while a child was running.
        public func releaseBackground() async {
            await controller.releaseBackground(turnID: turnID)
        }

        public func issueSessionReadAuthorization(
            currentConversationID: String,
            authorizedSessionID: String,
            issuedAt: Date = Date(),
            expiresAt: Date? = nil,
            lifetime: TimeInterval = 60,
            scope: SessionReadScope = .metadata
        ) async -> CrossSessionReadAuthorization {
            await controller.issueSessionReadAuthorization(
                for: turnID,
                currentConversationID: currentConversationID,
                authorizedSessionID: authorizedSessionID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                lifetime: lifetime,
                scope: scope
            )
        }
    }

    /// True while at least one turn is active.
    public var isRunning: Bool { !activeTurnIDs.isEmpty }

    /// Monotonic sequence number; incremented by every `start()`/`beginTurn()`.
    public private(set) var turnID: Int = 0

    /// Active turns are kept in start order so the legacy no-argument methods
    /// operate on the most recently started turn.
    private var activeTurnIDs: [Int] = []
    private var cancelledTurnIDs: Set<Int> = []
    private var loopIdentities: [Int: ToolLoopLifecycle.Identity] = [:]
    private var authorizationsByTurn: [Int: [CrossSessionReadAuthorization]] = [:]
    /// O-04 background retention: a turn with retained children is not removed
    /// by `finish`; the last release completes the deferred finish. This adds
    /// no capability, it only postpones the existing terminal transition.
    private var backgroundRetainCounts: [Int: Int] = [:]
    private var deferredFinishTurnIDs: Set<Int> = []
    public let toolLoopLifecycle: ToolLoopLifecycle

    public init(toolLoopLifecycle: ToolLoopLifecycle = ToolLoopLifecycle()) {
        self.toolLoopLifecycle = toolLoopLifecycle
    }

    /// Start one turn and return its monotonic ID. Existing callers may ignore
    /// the return value; `AgentLoop` uses `beginTurn()` for isolation.
    @discardableResult
    public func start() -> Int {
        let wasIdle = activeTurnIDs.isEmpty
        turnID += 1
        if wasIdle {
            // Preserve a stop queued exactly for this new turn, while dropping
            // stale stops from older completed turns.
            cancelledTurnIDs = Set(cancelledTurnIDs.filter { $0 >= turnID })
        }
        activeTurnIDs.append(turnID)
        loopIdentities[turnID] = toolLoopLifecycle.begin(turnID: turnID)
        return turnID
    }

    /// Begin one isolated turn.
    public func beginTurn() -> TurnHandle {
        let id = start()
        return TurnHandle(
            turnID: id,
            loopIdentity: loopIdentities[id]!,
            controller: self
        )
    }

    /// Finish the most recently started active turn (legacy API).
    public func finish() {
        guard let id = activeTurnIDs.last else { return }
        finish(turnID: id)
    }

    /// Finish one exact turn. This is idempotent for late cleanup calls.
    public func finish(turnID: Int) {
        guard let index = activeTurnIDs.lastIndex(of: turnID) else { return }
        if backgroundRetainCounts[turnID, default: 0] > 0 {
            // A background child still depends on this exact turn. Keep it
            // active (and cancellable) until the last child releases it.
            deferredFinishTurnIDs.insert(turnID)
            return
        }
        activeTurnIDs.remove(at: index)
        loopIdentities.removeValue(forKey: turnID)
        toolLoopLifecycle.finish(turnID: turnID)
        invalidateAuthorizations(for: turnID, reason: .turnEnded)
    }

    /// Retain one active, not-yet-cancelled turn for a background child.
    public func retainForBackground(turnID target: Int) -> Bool {
        guard activeTurnIDs.contains(target), !cancelledTurnIDs.contains(target) else { return false }
        backgroundRetainCounts[target, default: 0] += 1
        return true
    }

    /// Release one background retention; completes a deferred `finish`.
    public func releaseBackground(turnID target: Int) {
        guard let count = backgroundRetainCounts[target], count > 0 else { return }
        if count > 1 {
            backgroundRetainCounts[target] = count - 1
            return
        }
        backgroundRetainCounts.removeValue(forKey: target)
        if deferredFinishTurnIDs.remove(target) != nil {
            finish(turnID: target)
        }
    }

    /// Number of live background retentions for a turn (diagnostics/tests).
    public func backgroundRetainCount(turnID target: Int) -> Int {
        backgroundRetainCounts[target, default: 0]
    }

    /// Request interruption of the current/latest turn. If idle, queue it for
    /// the next turn to preserve the stop-before-start race semantics.
    public func interrupt() {
        let target = activeTurnIDs.last ?? (turnID + 1)
        interrupt(turnID: target)
    }

    /// Request interruption of one exact turn. Sibling turns are untouched.
    public func interrupt(turnID target: Int) {
        guard activeTurnIDs.contains(target) || (activeTurnIDs.isEmpty && target == turnID + 1) else {
            return
        }
        cancelledTurnIDs.insert(target)
        _ = toolLoopLifecycle.stop(turnID: target)
        invalidateAuthorizations(for: target, reason: .stopped)
    }

    /// Revoke one turn's capabilities without changing sibling turns. This is
    /// used by composition roots that cancel a task for a reason other than a
    /// user stop (for example, a scope switch or policy revocation).
    public func revoke(turnID target: Int) {
        guard activeTurnIDs.contains(target) || cancelledTurnIDs.contains(target) else { return }
        cancelledTurnIDs.insert(target)
        _ = toolLoopLifecycle.stop(turnID: target)
        invalidateAuthorizations(for: target, reason: .revoked)
    }

    /// Expire one turn's generation. Late tool events are rejected exactly as
    /// they are after an interrupt or policy revocation.
    public func timeout(turnID target: Int) {
        guard activeTurnIDs.contains(target) else { return }
        cancelledTurnIDs.insert(target)
        _ = toolLoopLifecycle.stop(turnID: target)
        invalidateAuthorizations(for: target, reason: .revoked)
    }

    /// Whether the latest/legacy turn is cancelled.
    public func isCancelled() -> Bool {
        let target = activeTurnIDs.last ?? turnID
        return cancelledTurnIDs.contains(target)
    }

    /// Whether a specific turn is cancelled.
    public func isCancelled(turnID target: Int) -> Bool {
        cancelledTurnIDs.contains(target)
    }

    /// Whether this exact handle still owns an active turn.
    public func isActive(turnID target: Int) -> Bool {
        activeTurnIDs.contains(target)
    }

    public func acceptsToolEvent(_ identity: ToolLoopLifecycle.Identity) -> Bool {
        activeTurnIDs.contains(identity.turnID)
            && !cancelledTurnIDs.contains(identity.turnID)
            && toolLoopLifecycle.isCurrent(identity)
    }

    /// Issue a typed, in-memory session-read capability for one active turn.
    /// A late call after the turn finished returns an already-ended capability.
    private func issueSessionReadAuthorization(
        for turnID: Int,
        currentConversationID: String,
        authorizedSessionID: String,
        issuedAt: Date,
        expiresAt: Date?,
        lifetime: TimeInterval,
        scope: SessionReadScope
    ) -> CrossSessionReadAuthorization {
        let capability: CrossSessionReadAuthorization
        if let expiresAt {
            capability = CrossSessionReadAuthorization(
                currentConversationID: currentConversationID,
                authorizedSessionID: authorizedSessionID,
                turnID: turnID,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                scope: scope
            )
        } else {
            capability = .issue(
                currentConversationID: currentConversationID,
                authorizedSessionID: authorizedSessionID,
                turnID: turnID,
                issuedAt: issuedAt,
                lifetime: lifetime,
                scope: scope
            )
        }
        let validIdentifiers = !currentConversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !authorizedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validWindow = issuedAt.timeIntervalSinceReferenceDate.isFinite
            && capability.expiresAt.timeIntervalSinceReferenceDate.isFinite
            && capability.expiresAt > issuedAt
        guard validIdentifiers, validWindow else {
            capability.invalidate(reason: .revoked)
            return capability
        }
        guard activeTurnIDs.contains(turnID) else {
            capability.invalidate(reason: .turnEnded)
            return capability
        }
        authorizationsByTurn[turnID, default: []].append(capability)
        return capability
    }

    /// Explicitly clear all queued stop signals and active capabilities.
    public func reset() {
        cancelledTurnIDs.removeAll()
        for id in activeTurnIDs {
            _ = toolLoopLifecycle.stop(turnID: id)
        }
        // Copy the keys before invalidateAuthorizations removes each bucket.
        // Iterating a dictionary while mutating it can trap at runtime.
        let authorizationTurnIDs = Array(authorizationsByTurn.keys)
        for id in authorizationTurnIDs {
            invalidateAuthorizations(for: id, reason: .revoked)
        }
        authorizationsByTurn.removeAll()
    }

    private func invalidateAuthorizations(
        for turnID: Int,
        reason: CrossSessionReadAuthorization.InvalidationReason
    ) {
        for authorization in authorizationsByTurn.removeValue(forKey: turnID) ?? [] {
            authorization.invalidate(reason: reason)
        }
    }
}
