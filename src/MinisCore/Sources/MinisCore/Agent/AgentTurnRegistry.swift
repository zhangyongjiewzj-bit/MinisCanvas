import Foundation

/// The generation-fenced identity of one registered agent turn.
public struct AgentTurnFact: Hashable, Sendable, Equatable {
    public let identity: AgentTurnIdentity
    public let generation: UInt64
    public let transcriptRevision: UInt64?

    public init(
        identity: AgentTurnIdentity,
        generation: UInt64,
        transcriptRevision: UInt64? = nil
    ) {
        self.identity = identity
        self.generation = generation
        self.transcriptRevision = transcriptRevision
    }
}

/// Per-turn cancellation registry used by the agent child runtime.
///
/// A bare turn number is not globally addressable: child sessions can reuse
/// the same number. Identity registrations therefore use the composite
/// `(sessionID, turnID)` key and publish a monotonic generation. Rebinds are
/// accepted only with a strictly newer transcript revision; duplicate or
/// ambiguous facts fail closed. Completion is generation-fenced so a late
/// event from a terminal turn cannot remove a newer registration.
public actor AgentTurnRegistry {
    private static let metadataCapacity = 512

    private struct TurnKey: Hashable, Sendable {
        let sessionID: String?
        let turnID: Int
    }

    private struct Registration {
        let controller: TurnController
        let controllerTurnID: Int
        let identity: AgentTurnIdentity?
        let fact: AgentTurnFact?
    }

    private var registrationsByKey: [TurnKey: Registration] = [:]
    private var retiredIdentities: Set<AgentTurnIdentity> = []
    private var retiredRevisions: [AgentTurnIdentity: UInt64] = [:]
    private var generations: [TurnKey: UInt64] = [:]
    private var retiredLegacyKeys: Set<TurnKey> = []
    private var exhaustedKeys: Set<TurnKey> = []

    public init() {}

    /// Compatibility registration for callers whose surrounding runtime has
    /// already made a bare turn ID unique. Bare keys are retired on finish or
    /// reset so an old cleanup event cannot clear a later registration.
    public func register(_ controller: TurnController, for turnID: Int) async {
        let key = TurnKey(sessionID: nil, turnID: turnID)
        let controllerTurnID = await resolvedControllerTurnID(
            controller,
            requestedTurnID: turnID
        )
        guard !retiredLegacyKeys.contains(key),
              registrationsByKey[key] == nil,
              let generation = nextGeneration(for: key) else {
            return
        }
        registrationsByKey[key] = makeRegistration(
            controller,
            controllerTurnID: controllerTurnID,
            identity: nil,
            generation: generation,
            transcriptRevision: nil
        )
    }

    public func interrupt(turnID: Int) async {
        await interrupt(key: TurnKey(sessionID: nil, turnID: turnID))
    }

    /// Session-scoped compatibility API for runtimes that carry a session ID
    /// but do not need the user-visible message identity.
    public func register(
        _ controller: TurnController,
        for turnID: Int,
        sessionID: String
    ) async {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let key = TurnKey(sessionID: sessionID, turnID: turnID)
        let controllerTurnID = await resolvedControllerTurnID(
            controller,
            requestedTurnID: turnID
        )
        guard !retiredLegacyKeys.contains(key),
              registrationsByKey[key] == nil,
              let generation = nextGeneration(for: key) else {
            return
        }
        registrationsByKey[key] = makeRegistration(
            controller,
            controllerTurnID: controllerTurnID,
            identity: nil,
            generation: generation,
            transcriptRevision: nil
        )
    }

    public func interrupt(turnID: Int, sessionID: String) async {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        await interrupt(key: TurnKey(sessionID: sessionID, turnID: turnID))
    }

    /// Registers one user-visible turn. A second identity for the same
    /// session/turn is ambiguous unless its revision is strictly newer.
    @discardableResult
    public func register(
        _ controller: TurnController,
        identity: AgentTurnIdentity,
        transcriptRevision: UInt64? = nil
    ) async -> AgentTurnFact? {
        guard identity.isValid else {
            return nil
        }
        let key = TurnKey(sessionID: identity.sessionID, turnID: identity.turnID)
        let controllerTurnID = await resolvedControllerTurnID(
            controller,
            requestedTurnID: identity.turnID
        )
        guard !exhaustedKeys.contains(key) else { return nil }

        if let retiredRevision = retiredRevisions[identity] {
            guard let transcriptRevision, transcriptRevision > retiredRevision else {
                return nil
            }
        } else if retiredIdentities.contains(identity) {
            return nil
        }

        if let current = registrationsByKey[key] {
            guard let currentIdentity = current.identity,
                  let currentFact = current.fact,
                  canReplace(currentFact, revision: transcriptRevision),
                  canRetire(currentIdentity) else {
                return nil
            }
            _ = retire(currentIdentity, revision: currentFact.transcriptRevision)
        }

        guard let generation = nextGeneration(for: key) else { return nil }
        let fact = AgentTurnFact(
            identity: identity,
            generation: generation,
            transcriptRevision: transcriptRevision
        )
        let registration = makeRegistration(
            controller,
            controllerTurnID: controllerTurnID,
            identity: identity,
            generation: generation,
            transcriptRevision: transcriptRevision
        )
        registrationsByKey[key] = registration
        return fact
    }

    public func interrupt(identity: AgentTurnIdentity) async {
        let key = TurnKey(sessionID: identity.sessionID, turnID: identity.turnID)
        guard let registration = registrationsByKey[key],
              registration.identity == identity else {
            return
        }
        await registration.controller.interrupt(turnID: registration.controllerTurnID)
    }

    /// Returns the current fact only when this exact identity is current.
    public func currentFact(identity: AgentTurnIdentity) -> AgentTurnFact? {
        let key = TurnKey(sessionID: identity.sessionID, turnID: identity.turnID)
        guard let fact = registrationsByKey[key]?.fact,
              fact.identity == identity else {
            return nil
        }
        return fact
    }

    /// Accepts only the current composite identity and generation.
    public func accepts(_ fact: AgentTurnFact) -> Bool {
        let key = TurnKey(
            sessionID: fact.identity.sessionID,
            turnID: fact.identity.turnID
        )
        return registrationsByKey[key]?.fact == fact
    }

    public func finish(turnID: Int) {
        finishLegacy(key: TurnKey(sessionID: nil, turnID: turnID))
    }

    public func finish(turnID: Int, sessionID: String) {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        finishLegacy(key: TurnKey(sessionID: sessionID, turnID: turnID))
    }

    /// Finishes only the exact current generation. A late fact is a no-op.
    public func finish(_ fact: AgentTurnFact) {
        let key = TurnKey(
            sessionID: fact.identity.sessionID,
            turnID: fact.identity.turnID
        )
        guard registrationsByKey[key]?.fact == fact else { return }
        guard retire(fact.identity, revision: fact.transcriptRevision) else { return }
        registrationsByKey.removeValue(forKey: key)
    }

    public func finish(identity: AgentTurnIdentity) {
        let key = TurnKey(sessionID: identity.sessionID, turnID: identity.turnID)
        guard let registration = registrationsByKey[key],
              registration.identity == identity else {
            // Preserve a tombstone for a late terminal event without touching
            // a newer registration occupying the same composite key.
            _ = retire(identity, revision: nil)
            return
        }
        guard retire(identity, revision: registration.fact?.transcriptRevision) else {
            return
        }
        registrationsByKey.removeValue(forKey: key)
    }

    public func contains(turnID: Int) -> Bool {
        registrationsByKey[TurnKey(sessionID: nil, turnID: turnID)] != nil
    }

    public func contains(turnID: Int, sessionID: String) -> Bool {
        registrationsByKey[TurnKey(sessionID: sessionID, turnID: turnID)] != nil
    }

    public func contains(identity: AgentTurnIdentity) -> Bool {
        let key = TurnKey(sessionID: identity.sessionID, turnID: identity.turnID)
        return registrationsByKey[key]?.identity == identity
    }

    public func reset() {
        var survivors: [TurnKey: Registration] = [:]
        let orderedRegistrations = registrationsByKey.sorted { left, right in
            let leftSession = left.key.sessionID ?? ""
            let rightSession = right.key.sessionID ?? ""
            if leftSession != rightSession {
                return leftSession < rightSession
            }
            return left.key.turnID < right.key.turnID
        }
        for (key, registration) in orderedRegistrations {
            var retired = false
            if let fact = registration.fact {
                retired = retire(fact.identity, revision: fact.transcriptRevision)
            } else if canRetireLegacy(key) {
                retiredLegacyKeys.insert(key)
                retired = true
            }
            if !retired {
                survivors[key] = registration
            }
        }
        registrationsByKey = survivors
    }

    private func interrupt(key: TurnKey) async {
        // A legacy session-scoped command has no message identity. It must
        // never cancel an identity-bound registration that reused the same
        // `(sessionID, turnID)` slot after a restart or rebind.
        guard let registration = registrationsByKey[key],
              registration.identity == nil else { return }
        await registration.controller.interrupt(turnID: registration.controllerTurnID)
    }

    private func finishLegacy(key: TurnKey) {
        // Late legacy terminal events are ambiguous once the slot is owned by
        // a user-visible identity. Leave that registration untouched and
        // require the generation-fenced finish API instead.
        guard let registration = registrationsByKey[key],
              registration.identity == nil,
              canRetireLegacy(key) else { return }
        registrationsByKey.removeValue(forKey: key)
        retiredLegacyKeys.insert(key)
    }

    private func canReplace(
        _ current: AgentTurnFact,
        revision: UInt64?
    ) -> Bool {
        guard let currentRevision = current.transcriptRevision,
              let revision,
              revision > currentRevision else {
            return false
        }
        // A revision fence is required for both a same-message restart and a
        // new message attempting to reuse the same session/turn slot.
        return true
    }

    private func canRetire(_ identity: AgentTurnIdentity) -> Bool {
        retiredIdentities.contains(identity)
            || retiredIdentities.count < Self.metadataCapacity
    }

    private func retire(_ identity: AgentTurnIdentity, revision: UInt64?) -> Bool {
        guard canRetire(identity) else { return false }
        retiredIdentities.insert(identity)
        if let revision {
            retiredRevisions[identity] = max(retiredRevisions[identity] ?? 0, revision)
        }
        return true
    }

    private func canRetireLegacy(_ key: TurnKey) -> Bool {
        retiredLegacyKeys.contains(key)
            || retiredLegacyKeys.count < Self.metadataCapacity
    }

    private func nextGeneration(for key: TurnKey) -> UInt64? {
        guard !exhaustedKeys.contains(key) else { return nil }
        guard generations[key] != nil || generations.count < Self.metadataCapacity else {
            return nil
        }
        let previous = generations[key] ?? 0
        guard previous < UInt64.max else {
            exhaustedKeys.insert(key)
            return nil
        }
        let generation = previous + 1
        generations[key] = generation
        return generation
    }

    private func resolvedControllerTurnID(
        _ controller: TurnController,
        requestedTurnID: Int
    ) async -> Int {
        let currentTurnID = await controller.turnID
        return currentTurnID == 0
            ? 1
            : min(requestedTurnID, currentTurnID)
    }

    private func makeRegistration(
        _ controller: TurnController,
        controllerTurnID: Int,
        identity: AgentTurnIdentity?,
        generation: UInt64,
        transcriptRevision: UInt64?
    ) -> Registration {
        let fact = identity.map {
            AgentTurnFact(
                identity: $0,
                generation: generation,
                transcriptRevision: transcriptRevision
            )
        }
        return Registration(
            controller: controller,
            controllerTurnID: controllerTurnID,
            identity: identity,
            fact: fact
        )
    }
}
