import Foundation
import CryptoKit

public enum OperationType: String, Codable, Sendable { case delete, permanentDelete, clearTrash }

public struct OperationIntent: Codable, Equatable, Sendable, Hashable {
    public let operationID: UUID
    public let operationType: OperationType
    public let targetID: String
    public let targetType: String
    public let targetName: String
    public let affectedCount: Int
    public let impactSummary: String
    public let reversible: Bool
    public let scopeID: String
    public let revision: Int
    public let fingerprint: String
    public let firstConfirmation: String?
    public let secondConfirmation: String?
    public let expiresAt: Date?

    public init(operationID: UUID = UUID(), operationType: OperationType, targetID: String, targetType: String, targetName: String, affectedCount: Int, impactSummary: String, reversible: Bool, scopeID: String, revision: Int, fingerprint: String, firstConfirmation: String? = nil, secondConfirmation: String? = nil, expiresAt: Date? = nil) {
        self.operationID = operationID; self.operationType = operationType; self.targetID = targetID; self.targetType = targetType; self.targetName = targetName; self.affectedCount = max(0, affectedCount); self.impactSummary = impactSummary; self.reversible = reversible; self.scopeID = scopeID; self.revision = revision; self.fingerprint = fingerprint; self.firstConfirmation = firstConfirmation; self.secondConfirmation = secondConfirmation; self.expiresAt = expiresAt
    }

    /// Construct an unconfirmed, user-facing preview. Confirmation tokens are
    /// deliberately absent until the caller has shown this exact preview.
    public static func preview(
        operationType: OperationType = .delete,
        targetID: String,
        targetType: String,
        targetName: String,
        affectedCount: Int,
        impactSummary: String,
        reversible: Bool = true,
        scopeID: String,
        revision: Int,
        fingerprint: String,
        now: Date = Date(),
        ttl: TimeInterval = 300
    ) -> OperationIntent {
        OperationIntent(
            operationType: operationType,
            targetID: targetID,
            targetType: targetType,
            targetName: targetName,
            affectedCount: affectedCount,
            impactSummary: impactSummary,
            reversible: reversible,
            scopeID: scopeID,
            revision: revision,
            fingerprint: fingerprint,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    public func withFirstConfirmation(_ token: String) -> OperationIntent {
        OperationIntent(operationID: operationID, operationType: operationType, targetID: targetID, targetType: targetType, targetName: targetName, affectedCount: affectedCount, impactSummary: impactSummary, reversible: reversible, scopeID: scopeID, revision: revision, fingerprint: fingerprint, firstConfirmation: token, secondConfirmation: secondConfirmation, expiresAt: expiresAt)
    }

    public func withSecondConfirmation(_ token: String) -> OperationIntent {
        OperationIntent(operationID: operationID, operationType: operationType, targetID: targetID, targetType: targetType, targetName: targetName, affectedCount: affectedCount, impactSummary: impactSummary, reversible: reversible, scopeID: scopeID, revision: revision, fingerprint: fingerprint, firstConfirmation: firstConfirmation, secondConfirmation: token, expiresAt: expiresAt)
    }
}

/// Immutable, non-secret snapshot of the target state used to bind a
/// destructive intent to the exact object the user confirmed.
public struct DeletionStateSnapshot: Equatable, Sendable {
    public let targetID: String
    public let scopeID: String
    public let revision: Int
    public let fingerprint: String

    public init(targetID: String, scopeID: String, revision: Int, fingerprint: String) {
        self.targetID = targetID
        self.scopeID = scopeID
        self.revision = revision
        self.fingerprint = fingerprint
    }
}

/// Production state seam. Implementations return only identity/version facts;
/// they must not expose the deleted payload or any credential value.
public protocol DeletionStateProvider: Sendable {
    func currentDeletionState(for targetID: String) async -> DeletionStateSnapshot?
}

public enum DeletionGateError: String, Error, Codable, Equatable, Sendable {
    case firstConfirmationRequired
    case secondConfirmationRequired
    case targetChanged
    case irreversibleRequiresPhrase
    case invalidScope
    case invalidIntent
    case expired
    case cancelled
    case alreadyExecuting
    case alreadyConsumed
}

public struct DeletionReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let targetID: String
    public let scopeID: String
    public let affectedCount: Int
    public let outcome: String
    public let createdAt: Date
}

public enum DeletionGate {
    private enum LifecycleState {
        case cancelled
        case executing
        case consumed
    }

    private final class LifecycleStore: @unchecked Sendable {
        let lock = NSLock()
        var states: [UUID: LifecycleState] = [:]
    }

    private static let lifecycle = LifecycleStore()

    public static func preview(
        operationType: OperationType = .delete,
        targetID: String,
        targetType: String,
        targetName: String,
        affectedCount: Int,
        impactSummary: String,
        reversible: Bool = true,
        scopeID: String,
        revision: Int,
        fingerprint: String,
        now: Date = Date(),
        ttl: TimeInterval = 300
    ) -> OperationIntent {
        OperationIntent.preview(
            operationType: operationType,
            targetID: targetID,
            targetType: targetType,
            targetName: targetName,
            affectedCount: affectedCount,
            impactSummary: impactSummary,
            reversible: reversible,
            scopeID: scopeID,
            revision: revision,
            fingerprint: fingerprint,
            now: now,
            ttl: ttl
        )
    }

    public static func cancel(_ intent: OperationIntent) throws {
        lifecycle.lock.lock()
        defer { lifecycle.lock.unlock() }
        switch lifecycle.states[intent.operationID] {
        case .consumed:
            throw DeletionGateError.alreadyConsumed
        case .executing:
            throw DeletionGateError.alreadyExecuting
        case .cancelled:
            throw DeletionGateError.cancelled
        case nil:
            lifecycle.states[intent.operationID] = .cancelled
        }
    }

    public static func checkLifecycle(_ intent: OperationIntent) throws {
        lifecycle.lock.lock()
        defer { lifecycle.lock.unlock() }
        switch lifecycle.states[intent.operationID] {
        case .cancelled:
            throw DeletionGateError.cancelled
        case .executing:
            throw DeletionGateError.alreadyExecuting
        case .consumed:
            throw DeletionGateError.alreadyConsumed
        case nil:
            return
        }
    }

    public static func prepare(_ intent: OperationIntent, currentRevision: Int, currentFingerprint: String) -> Result<OperationIntent, DeletionGateError> {
        guard intent.revision == currentRevision, intent.fingerprint == currentFingerprint else { return .failure(.targetChanged) }
        guard !intent.scopeID.isEmpty else { return .failure(.invalidScope) }
        guard !intent.targetID.isEmpty, !intent.targetType.isEmpty, !intent.fingerprint.isEmpty else { return .failure(.invalidIntent) }
        guard let first = intent.firstConfirmation, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.firstConfirmationRequired)
        }
        guard let second = intent.secondConfirmation, !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.secondConfirmationRequired)
        }
        let permanent = !intent.reversible || intent.operationType == .permanentDelete || intent.operationType == .clearTrash
        guard !permanent || second.trimmingCharacters(in: .whitespacesAndNewlines) == "永久删除" else {
            return .failure(.irreversibleRequiresPhrase)
        }
        return .success(intent)
    }

    /// Validate against a complete trusted snapshot so scope and target
    /// identity cannot be accidentally omitted by a caller.
    public static func prepare(
        _ intent: OperationIntent,
        currentState: DeletionStateSnapshot
    ) -> Result<OperationIntent, DeletionGateError> {
        guard intent.targetID == currentState.targetID,
              intent.scopeID == currentState.scopeID else {
            return .failure(.targetChanged)
        }
        return prepare(
            intent,
            currentRevision: currentState.revision,
            currentFingerprint: currentState.fingerprint
        )
    }

    /// Fetch the current identity snapshot at the production effect boundary.
    /// A missing snapshot fails closed and never falls back to the preview.
    public static func prepare(
        _ intent: OperationIntent,
        provider: any DeletionStateProvider
    ) async throws -> OperationIntent {
        guard let currentState = await provider.currentDeletionState(for: intent.targetID) else {
            throw DeletionGateError.targetChanged
        }
        return try prepare(intent, currentState: currentState).get()
    }

    public static func validated(_ intent: OperationIntent, currentRevision: Int, currentFingerprint: String) throws -> OperationIntent {
        try prepare(intent, currentRevision: currentRevision, currentFingerprint: currentFingerprint).get()
    }

    /// Run the irreversible side effect only after all gate checks pass. A
    /// receipt is produced after the side effect succeeds, never before it.
    public static func execute(
        _ intent: OperationIntent,
        currentRevision: Int,
        currentFingerprint: String,
        now: Date = Date(),
        perform: (OperationIntent) throws -> Void
    ) throws -> DeletionReceipt {
        guard let expiresAt = intent.expiresAt, now < expiresAt else {
            throw DeletionGateError.expired
        }
        let confirmed = try validated(intent, currentRevision: currentRevision, currentFingerprint: currentFingerprint)

        lifecycle.lock.lock()
        switch lifecycle.states[intent.operationID] {
        case .cancelled:
            lifecycle.lock.unlock()
            throw DeletionGateError.cancelled
        case .executing:
            lifecycle.lock.unlock()
            throw DeletionGateError.alreadyExecuting
        case .consumed:
            lifecycle.lock.unlock()
            throw DeletionGateError.alreadyConsumed
        case nil:
            lifecycle.states[intent.operationID] = .executing
            lifecycle.lock.unlock()
        }

        do {
            try perform(confirmed)
        } catch {
            lifecycle.lock.lock()
            lifecycle.states[intent.operationID] = nil
            lifecycle.lock.unlock()
            throw error
        }

        lifecycle.lock.lock()
        lifecycle.states[intent.operationID] = .consumed
        lifecycle.lock.unlock()
        return receipt(for: confirmed, now: now)
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func fingerprint(_ value: String) -> String {
        fingerprint(Data(value.utf8))
    }

    public static func receipt(for intent: OperationIntent, now: Date = Date()) -> DeletionReceipt {
        DeletionReceipt(operationID: intent.operationID, targetID: intent.targetID, scopeID: intent.scopeID, affectedCount: intent.affectedCount, outcome: "deleted", createdAt: now)
    }
}
