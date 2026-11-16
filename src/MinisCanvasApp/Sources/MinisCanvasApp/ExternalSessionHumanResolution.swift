import Foundation
import CryptoKit
import MinisCore

/// A local before-I/O identity, never proof of a provider outcome.
public struct ExternalSessionLocalRequestIdentity: Codable, Equatable, Sendable {
    public let localOperationID: String
    public let idempotencyKey: String
    public let expectedCursor: ExternalSessionCursorV1
    public let expectedSequence: UInt64?
    public let parentConversationID: String?
    public let parentTurnID: String?

    init(request: ExternalSessionControlRequestV1, localOperationID: String = UUID().uuidString) {
        self.localOperationID = localOperationID
        idempotencyKey = request.idempotencyKey
        expectedCursor = request.expectedCursor
        expectedSequence = request.expectedSequence
        parentConversationID = request.parentConversationID
        parentTurnID = request.parentTurnID
    }
}

public enum ExternalSessionHumanDecision: String, Codable, Equatable, Sendable {
    case recordExternalHandlingAndAllowNewControls
    case authorizeOneIndependentCompensation
}

public struct ExternalSessionHumanResolutionPreview: Equatable, Sendable {
    public let confirmationNonce: String
    public let caseID: String
    public let original: ExternalSessionUnconfirmedControlV1
    public let currentOwnerID: String
    public let currentGeneration: UInt64
    public let readGrant: ExternalSessionReadGrantV1
    public let controlGrant: ExternalSessionControlGrantV1
    public let inspectedAt: Date
    public let inspectedCursor: ExternalSessionCursorV1
}

public struct ExternalSessionIndependentCompensationProposal: Equatable, Sendable {
    public let sourceID: ExternalSessionSourceID
    public let profileID: ExternalSessionProfileID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let operation: ExternalSessionControlOperationV1
    public let boundedInput: String?

    public init(sourceID: ExternalSessionSourceID, profileID: ExternalSessionProfileID,
                threadID: ExternalSessionThreadID, turnID: ExternalSessionTurnID?,
                operation: ExternalSessionControlOperationV1, boundedInput: String? = nil) {
        self.sourceID = sourceID; self.profileID = profileID
        self.threadID = threadID; self.turnID = turnID
        self.operation = operation; self.boundedInput = boundedInput
    }

    var plan: ExternalSessionIndependentCompensationPlan {
        ExternalSessionIndependentCompensationPlan(
            sourceID: sourceID, profileID: profileID, threadID: threadID,
            turnID: turnID, operation: operation,
            boundedInputDigest: ExternalSessionHumanResolutionDigest.digest(boundedInput)
        )
    }
}

public struct ExternalSessionIndependentCompensationPlan: Codable, Equatable, Sendable {
    public let sourceID: ExternalSessionSourceID
    public let profileID: ExternalSessionProfileID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let operation: ExternalSessionControlOperationV1
    public let boundedInputDigest: String
}

public enum ExternalSessionHumanDecisionActor: String, Codable, Equatable, Sendable { case localUser }
public enum ExternalSessionHumanDecisionSource: String, Codable, Equatable, Sendable { case settingsControlConfirmation }
public enum ExternalSessionHumanDispositionOutcome: String, Codable, Equatable, Sendable { case localDispositionRecorded }

public struct ExternalSessionHumanResolutionReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let decisionID: String
    public let caseID: String
    public let original: ExternalSessionUnconfirmedControlV1
    public let decision: ExternalSessionHumanDecision
    public let actor: ExternalSessionHumanDecisionActor
    public let decisionSource: ExternalSessionHumanDecisionSource
    public let outcome: ExternalSessionHumanDispositionOutcome
    public let redactedNote: String
    public let redactedSourceReference: String
    public let recordedAt: Date
    public let admissionOwnerID: String
    public let admissionGeneration: UInt64
    public let readGrant: ExternalSessionReadGrantV1
    public let controlGrant: ExternalSessionControlGrantV1
    public let inspectedAt: Date
    public let independentIdentity: ExternalSessionLocalRequestIdentity?
    public let independentPlan: ExternalSessionIndependentCompensationPlan?
}

public enum ExternalSessionCompensationAuditState: String, Codable, Equatable, Sendable {
    case recorded
    case recoveryRequired
}

public struct ExternalSessionIndependentCompensationReceipt: Codable, Equatable, Sendable {
    public let decisionID: String
    public let originalUnknownCaseID: String
    public let independentIdentity: ExternalSessionLocalRequestIdentity
    public let controlAuthorizationID: ExternalSessionAuthorizationID
    public let controlRevocationEpoch: UInt64
    public let connectionOwnerID: String
    public let connectionGeneration: UInt64
    public let providerReceipt: ExternalSessionControlReceiptV1
    public let auditPersistence: ExternalSessionCompensationAuditState
}

public enum ExternalSessionHumanResolutionError: Error, Equatable, Sendable {
    case productionLedgerRequired
    case persistenceUnavailable
    case originalIdentityUnavailable
    case confirmationStale
    case decisionAlreadyConsumed
    case pendingApprovalMustBeHandledSeparately
    case invalidExplicitDecision
    case compensationIdentityReused
    case historyCapacityReached
    case persistenceFailed
}

struct ExternalSessionPendingIndependentCompensation: Codable, Equatable, Sendable {
    let decisionID: String
    let caseID: String
    let original: ExternalSessionUnconfirmedControlV1
    let plan: ExternalSessionIndependentCompensationPlan
    let identity: ExternalSessionLocalRequestIdentity
    let controlGrant: ExternalSessionControlGrantV1
    let readGrant: ExternalSessionReadGrantV1
    let ownerID: String
    let generation: UInt64
}

enum ExternalSessionHumanResolutionDigest {
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func caseID(_ original: ExternalSessionUnconfirmedControlV1) -> String {
        // The observed status can change; it is not a control result or identity.
        struct Identity: Encodable {
            let sourceID: ExternalSessionSourceID
            let profileID: ExternalSessionProfileID
            let threadID: ExternalSessionThreadID
            let turnID: ExternalSessionTurnID?
            let operation: ExternalSessionControlOperationV1
            let grantID: ExternalSessionAuthorizationID
            let epoch: UInt64
            let generation: UInt64
            let ownerID: String
            let requestIdentity: ExternalSessionLocalRequestIdentity?
        }
        return digest(Identity(sourceID: original.sourceID, profileID: original.profileID,
            threadID: original.threadID, turnID: original.turnID, operation: original.operation,
            grantID: original.controlAuthorizationID, epoch: original.controlRevocationEpoch,
            generation: original.connectionGeneration, ownerID: original.connectionOwnerID,
            requestIdentity: original.requestIdentity))
    }
}
