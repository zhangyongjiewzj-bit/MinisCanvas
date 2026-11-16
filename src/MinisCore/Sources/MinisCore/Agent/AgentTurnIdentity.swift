import Foundation

/// Stable identity for asynchronous agent output writeback.
///
/// Every field is required for a writeback to be accepted. In particular,
/// `messageID` is supplied by the caller once when the assistant placeholder
/// is created; it must not be regenerated from the current active session.
public struct AgentTurnIdentity: Hashable, Sendable, Equatable, Codable {
    public let sessionID: String
    public let turnID: Int
    public let messageID: String

    public init(sessionID: String, turnID: Int, messageID: String) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.messageID = messageID
    }

    /// A writeback identity is only meaningful when all caller-owned fields
    /// are concrete. Turn IDs are zero-based in the Composer contract, so
    /// zero is valid while negative values remain invalid.
    public var isValid: Bool {
        !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && turnID >= 0
            && !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Identity carried by execution-layer receipts and tool batches.
///
/// `AgentTurnIdentity` identifies the user-visible writeback target. This
/// value adds an operation and attempt so retries cannot reuse a prior result
/// merely because they belong to the same turn.
public struct AgentExecutionIdentity: Hashable, Sendable, Equatable, Codable {
    public let turn: AgentTurnIdentity
    public let operationID: String
    public let attempt: Int

    public init(
        turn: AgentTurnIdentity,
        operationID: String = UUID().uuidString,
        attempt: Int = 0
    ) {
        self.turn = turn
        self.operationID = operationID
        self.attempt = attempt
    }

    public var isValid: Bool {
        turn.isValid
            && !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attempt >= 0
    }
}

/// Gate for async stream/writeback consumers.
///
/// An optional journal makes retired identities durable across app restart, so
/// late chunks from an old turn cannot be re-registered merely because the
/// session ID is unchanged.
public actor AgentTurnWritebackRegistry {
    private struct PersistedState: Codable {
        let schemaVersion: Int
        let retiredIdentities: [AgentTurnIdentity]
    }

    private var activeIdentities: Set<AgentTurnIdentity> = []
    private var retiredIdentities: Set<AgentTurnIdentity> = []
    private let persistenceURL: URL?
    private let persistenceAvailable: Bool

    private static let persistenceSchemaVersion = 1

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL else {
            persistenceAvailable = true
            return
        }
        guard FileManager.default.fileExists(atPath: persistenceURL.path),
              let data = try? Data(contentsOf: persistenceURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.schemaVersion == Self.persistenceSchemaVersion else {
            persistenceAvailable = !FileManager.default.fileExists(atPath: persistenceURL.path)
            return
        }
        retiredIdentities = Set(state.retiredIdentities)
        persistenceAvailable = true
    }

    @discardableResult
    public func begin(_ identity: AgentTurnIdentity) -> Bool {
        guard persistenceAvailable,
              identity.isValid,
              !activeIdentities.contains(identity),
              !retiredIdentities.contains(identity) else {
            return false
        }
        activeIdentities.insert(identity)
        guard persist() else {
            activeIdentities.remove(identity)
            return false
        }
        return true
    }

    public func accepts(_ identity: AgentTurnIdentity) -> Bool {
        activeIdentities.contains(identity)
    }

    @discardableResult
    public func finish(_ identity: AgentTurnIdentity) -> Bool {
        guard activeIdentities.remove(identity) != nil else {
            return retiredIdentities.contains(identity)
        }
        retiredIdentities.insert(identity)
        return persist()
    }

    /// Cancellation is terminal for writeback and leaves the same durable
    /// tombstone as normal completion.
    @discardableResult
    public func cancel(_ identity: AgentTurnIdentity) -> Bool {
        finish(identity)
    }

    public func reset() {
        // Do not overwrite a corrupt or unsupported journal with an incomplete
        // empty state; initialization deliberately fails closed in that case.
        guard persistenceAvailable else { return }
        // Retired identities remain tombstoned across an active-set reset.
        // A fresh turn must receive a fresh message identity.
        activeIdentities.removeAll()
        _ = persist()
    }

    private func persist() -> Bool {
        guard let persistenceURL else { return true }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let state = PersistedState(
                schemaVersion: Self.persistenceSchemaVersion,
                retiredIdentities: retiredIdentities.sorted {
                    if $0.sessionID != $1.sessionID {
                        return $0.sessionID < $1.sessionID
                    }
                    if $0.turnID != $1.turnID {
                        return $0.turnID < $1.turnID
                    }
                    return $0.messageID < $1.messageID
                }
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: persistenceURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
