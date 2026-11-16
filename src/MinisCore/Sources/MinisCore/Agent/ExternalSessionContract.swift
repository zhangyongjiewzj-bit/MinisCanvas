import Foundation

// MARK: - Existing external-session contract (Stage 0)

/// Versioned value-only contract for already-running Codex/Claude Code/Hermes sessions.
///
/// This seam is intentionally separate from `ExternalAgentRunner`: that runner starts a
/// one-shot CLI child and returns text, while this contract describes a future adapter for
/// reading and controlling an existing session. No transport or production registration is
/// implied by these types.
public enum ExternalSessionContractV1 {
    public static let schemaVersion = 1
}

// MARK: Stable identities

public struct ExternalSessionSourceID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionProjectID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionThreadID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionTurnID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionEventID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionAuthorizationID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionProfileID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ExternalSessionOperationID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Adapter-owned opaque cursor. The value must be persisted and compared opaquely by MinisCore;
/// it must not be parsed into a provider-specific offset by the domain owner.
public struct ExternalSessionCursorV1: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let beginning = ExternalSessionCursorV1(rawValue: "beginning")
}

// MARK: Source, thread, turn and event values

@frozen public enum ExternalSessionSourceKindV1: String, Codable, Equatable, Sendable {
    case codex
    case claudeCode
    case hermes
    case other
}

@frozen public enum ExternalSessionCapabilityV1: String, Codable, Hashable, Sendable {
    case readMetadata
    case readMessages
    case status
    case stream
    case resume
    case fork
    case steer
    case interrupt
    case approval
}

@frozen public enum ExternalSessionAuthStateV1: String, Codable, Equatable, Sendable {
    case authorized
    case expired
    case revoked
    case unavailable
}

public struct ExternalSessionSourceV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let kind: ExternalSessionSourceKindV1
    public let adapterVersion: String
    public let profileID: ExternalSessionProfileID
    public let hostID: String
    public let capabilities: Set<ExternalSessionCapabilityV1>
    public let authState: ExternalSessionAuthStateV1

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        kind: ExternalSessionSourceKindV1,
        adapterVersion: String,
        profileID: ExternalSessionProfileID,
        hostID: String,
        capabilities: Set<ExternalSessionCapabilityV1>,
        authState: ExternalSessionAuthStateV1
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.kind = kind
        self.adapterVersion = adapterVersion
        self.profileID = profileID
        self.hostID = hostID
        self.capabilities = capabilities
        self.authState = authState
    }
}

@frozen public enum ExternalSessionThreadStatusV1: String, Codable, Equatable, Sendable {
    case discovered
    case active
    case waiting
    case completed
    case failed
    case interrupted
    case unknown
}

public struct ExternalSessionThreadV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let projectID: ExternalSessionProjectID?
    public let title: String
    public let status: ExternalSessionThreadStatusV1
    public let updatedAt: Date
    public let sourceCursor: ExternalSessionCursorV1
    public let readable: Bool

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        projectID: ExternalSessionProjectID? = nil,
        title: String,
        status: ExternalSessionThreadStatusV1,
        updatedAt: Date,
        sourceCursor: ExternalSessionCursorV1,
        readable: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.projectID = projectID
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.sourceCursor = sourceCursor
        self.readable = readable
    }
}

@frozen public enum ExternalSessionTurnStatusV1: String, Codable, Equatable, Sendable {
    case queued
    case running
    case waitingApproval
    case waitingInput
    case succeeded
    case failed
    case cancelled
    case unknown
}

public struct ExternalSessionTurnV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID
    public let parentTurnID: ExternalSessionTurnID?
    public let status: ExternalSessionTurnStatusV1
    public let startedAt: Date?
    public let finishedAt: Date?
    public let providerID: String?
    public let modelID: String?
    public let sourceCursor: ExternalSessionCursorV1

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID,
        parentTurnID: ExternalSessionTurnID? = nil,
        status: ExternalSessionTurnStatusV1,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        sourceCursor: ExternalSessionCursorV1
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.parentTurnID = parentTurnID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.providerID = providerID
        self.modelID = modelID
        self.sourceCursor = sourceCursor
    }
}

@frozen public enum ExternalSessionEventKindV1: String, Codable, Equatable, Sendable {
    case threadDiscovered
    case threadUpdated
    case turnStarted
    case itemDelta
    case progress
    case approvalRequired
    case inputRequired
    case turnCompleted
    case turnFailed
    case turnCancelled
    case controlRevoked
    case reconnectRequired
}

/// Payload is deliberately redacted and bounded at the contract boundary. Raw prompts,
/// credentials, cookies, remote bodies and unrestricted filesystem paths do not belong here.
public struct ExternalSessionRedactedPayloadV1: Codable, Equatable, Sendable {
    public let kind: String
    public let summary: String

    public init(kind: String, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public struct ExternalSessionEventV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: ExternalSessionEventID
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let sequence: UInt64
    public let sourceCursor: ExternalSessionCursorV1
    public let occurredAt: Date
    public let required: Bool
    public let kind: ExternalSessionEventKindV1
    public let payload: ExternalSessionRedactedPayloadV1
    public let sourceRef: String

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        eventID: ExternalSessionEventID,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        sequence: UInt64,
        sourceCursor: ExternalSessionCursorV1,
        occurredAt: Date,
        required: Bool,
        kind: ExternalSessionEventKindV1,
        payload: ExternalSessionRedactedPayloadV1,
        sourceRef: String
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.sequence = sequence
        self.sourceCursor = sourceCursor
        self.occurredAt = occurredAt
        self.required = required
        self.kind = kind
        self.payload = payload
        self.sourceRef = sourceRef
    }
}

// MARK: Read authorization

@frozen public enum ExternalSessionReadScopeV1: String, Codable, Hashable, Sendable {
    case metadata
    case messages
    case status
    case events
}

@frozen public enum ExternalSessionReadTargetV1: Codable, Equatable, Sendable {
    case source(ExternalSessionSourceID)
    case project(ExternalSessionProjectID)
    case thread(ExternalSessionThreadID)
}

public struct ExternalSessionReadGrantV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorizationID: ExternalSessionAuthorizationID
    public let sourceID: ExternalSessionSourceID
    public let profileID: ExternalSessionProfileID
    public let target: ExternalSessionReadTargetV1
    public let scopes: Set<ExternalSessionReadScopeV1>
    public let issuedAt: Date
    public let expiresAt: Date
    public let revocationEpoch: UInt64
    public let parentConversationID: String?
    public let parentTurnID: String?

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        authorizationID: ExternalSessionAuthorizationID,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        target: ExternalSessionReadTargetV1,
        scopes: Set<ExternalSessionReadScopeV1>,
        issuedAt: Date,
        expiresAt: Date,
        revocationEpoch: UInt64,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.authorizationID = authorizationID
        self.sourceID = sourceID
        self.profileID = profileID
        self.target = target
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revocationEpoch = revocationEpoch
        self.parentConversationID = parentConversationID
        self.parentTurnID = parentTurnID
    }
}

// MARK: Control authorization and outcomes

@frozen public enum ExternalSessionControlOperationV1: String, Codable, Hashable, Sendable {
    case resume
    case fork
    case steer
    case interrupt
    case approve
    case reject
    case provideInput
}

@frozen public enum ExternalSessionControlTargetV1: Codable, Equatable, Sendable {
    case source(ExternalSessionSourceID)
    case project(ExternalSessionProjectID)
    case thread(ExternalSessionThreadID)
}

public struct ExternalSessionControlGrantV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorizationID: ExternalSessionAuthorizationID
    public let sourceID: ExternalSessionSourceID
    public let profileID: ExternalSessionProfileID
    public let target: ExternalSessionControlTargetV1
    public let operations: Set<ExternalSessionControlOperationV1>
    public let issuedAt: Date
    public let expiresAt: Date
    public let revocationEpoch: UInt64
    public let parentConversationID: String?
    public let parentTurnID: String?

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        authorizationID: ExternalSessionAuthorizationID,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        target: ExternalSessionControlTargetV1,
        operations: Set<ExternalSessionControlOperationV1>,
        issuedAt: Date,
        expiresAt: Date,
        revocationEpoch: UInt64,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.authorizationID = authorizationID
        self.sourceID = sourceID
        self.profileID = profileID
        self.target = target
        self.operations = operations
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revocationEpoch = revocationEpoch
        self.parentConversationID = parentConversationID
        self.parentTurnID = parentTurnID
    }
}

@frozen public enum ExternalSessionControlOutcomeV1: String, Codable, Equatable, Sendable {
    case accepted
    case completed
    case rejected
    case unsupported
    case unknownRequiresRecovery
}

public struct ExternalSessionControlRequestV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let operation: ExternalSessionControlOperationV1
    public let expectedCursor: ExternalSessionCursorV1
    public let expectedSequence: UInt64?
    public let idempotencyKey: String
    public let boundedInput: String?
    public let parentConversationID: String?
    public let parentTurnID: String?

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        operation: ExternalSessionControlOperationV1,
        expectedCursor: ExternalSessionCursorV1,
        expectedSequence: UInt64? = nil,
        idempotencyKey: String,
        boundedInput: String? = nil,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.operation = operation
        self.expectedCursor = expectedCursor
        self.expectedSequence = expectedSequence
        self.idempotencyKey = idempotencyKey
        self.boundedInput = boundedInput
        self.parentConversationID = parentConversationID
        self.parentTurnID = parentTurnID
    }
}

public struct ExternalSessionControlReceiptV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let operation: ExternalSessionControlOperationV1
    public let outcome: ExternalSessionControlOutcomeV1
    public let operationID: ExternalSessionOperationID?
    /// The new thread returned by a successful fork. The authorized threadID
    /// above remains the source thread, never the child identity.
    public let childThreadID: ExternalSessionThreadID?
    public let sourceCursor: ExternalSessionCursorV1
    public let detail: String?

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        operation: ExternalSessionControlOperationV1,
        outcome: ExternalSessionControlOutcomeV1,
        operationID: ExternalSessionOperationID? = nil,
        childThreadID: ExternalSessionThreadID? = nil,
        sourceCursor: ExternalSessionCursorV1,
        detail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.operation = operation
        self.outcome = outcome
        self.operationID = operationID
        self.childThreadID = childThreadID
        self.sourceCursor = sourceCursor
        self.detail = detail
    }
}

/// A bounded, redacted piece of actual external message text. The producer
/// splits long messages into ordered chunks; a summary cannot stand in for it.
public struct ExternalSessionMessageChunkV1: Codable, Equatable, Sendable {
    public static let maximumCharacters = 512
    public static let maximumUTF8Bytes = 2_048

    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let messageID: String
    public let role: String
    public let chunkIndex: UInt32
    public let text: String
    public let isLastChunk: Bool
    public let sourceRef: String

    public init(
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        messageID: String,
        role: String,
        chunkIndex: UInt32,
        text: String,
        isLastChunk: Bool,
        sourceRef: String
    ) {
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.messageID = messageID
        self.role = role
        self.chunkIndex = chunkIndex
        self.text = text
        self.isLastChunk = isLastChunk
        self.sourceRef = sourceRef
    }
}

// MARK: Read pages and status

public struct ExternalSessionThreadQueryV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let projectID: ExternalSessionProjectID?
    public let cursor: ExternalSessionCursorV1
    public let limit: UInt16

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        projectID: ExternalSessionProjectID? = nil,
        cursor: ExternalSessionCursorV1 = .beginning,
        limit: UInt16
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.projectID = projectID
        self.cursor = cursor
        self.limit = limit
    }
}

public struct ExternalSessionReadRequestV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let cursor: ExternalSessionCursorV1
    public let limit: UInt16

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        cursor: ExternalSessionCursorV1 = .beginning,
        limit: UInt16
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.cursor = cursor
        self.limit = limit
    }
}

public struct ExternalSessionStatusTargetV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID?
    public let turnID: ExternalSessionTurnID?

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID? = nil,
        turnID: ExternalSessionTurnID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct ExternalSessionThreadPageV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threads: [ExternalSessionThreadV1]
    public let nextCursor: ExternalSessionCursorV1?
    public let observedCursor: ExternalSessionCursorV1

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threads: [ExternalSessionThreadV1],
        nextCursor: ExternalSessionCursorV1? = nil,
        observedCursor: ExternalSessionCursorV1
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threads = threads
        self.nextCursor = nextCursor
        self.observedCursor = observedCursor
    }
}

public struct ExternalSessionReadPageV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turns: [ExternalSessionTurnV1]
    public let events: [ExternalSessionEventV1]
    public let messageChunks: [ExternalSessionMessageChunkV1]
    public let nextCursor: ExternalSessionCursorV1?
    public let observedCursor: ExternalSessionCursorV1

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turns: [ExternalSessionTurnV1],
        events: [ExternalSessionEventV1],
        messageChunks: [ExternalSessionMessageChunkV1] = [],
        nextCursor: ExternalSessionCursorV1? = nil,
        observedCursor: ExternalSessionCursorV1
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turns = turns
        self.events = events
        self.messageChunks = messageChunks
        self.nextCursor = nextCursor
        self.observedCursor = observedCursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceID, threadID, turns, events, messageChunks, nextCursor, observedCursor
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        sourceID = try values.decode(ExternalSessionSourceID.self, forKey: .sourceID)
        threadID = try values.decode(ExternalSessionThreadID.self, forKey: .threadID)
        turns = try values.decode([ExternalSessionTurnV1].self, forKey: .turns)
        events = try values.decode([ExternalSessionEventV1].self, forKey: .events)
        messageChunks = try values.decodeIfPresent([ExternalSessionMessageChunkV1].self, forKey: .messageChunks) ?? []
        nextCursor = try values.decodeIfPresent(ExternalSessionCursorV1.self, forKey: .nextCursor)
        observedCursor = try values.decode(ExternalSessionCursorV1.self, forKey: .observedCursor)
    }
}

public struct ExternalSessionStatusV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID?
    public let turnID: ExternalSessionTurnID?
    public let threadStatus: ExternalSessionThreadStatusV1?
    public let turnStatus: ExternalSessionTurnStatusV1?
    public let observedCursor: ExternalSessionCursorV1
    public let latestSequence: UInt64?

    public init(
        schemaVersion: Int = ExternalSessionContractV1.schemaVersion,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID? = nil,
        turnID: ExternalSessionTurnID? = nil,
        threadStatus: ExternalSessionThreadStatusV1? = nil,
        turnStatus: ExternalSessionTurnStatusV1? = nil,
        observedCursor: ExternalSessionCursorV1,
        latestSequence: UInt64? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.threadStatus = threadStatus
        self.turnStatus = turnStatus
        self.observedCursor = observedCursor
        self.latestSequence = latestSequence
    }
}

// MARK: Adapter seam

/// Existing-session adapter seam only. Implementations and production registration belong to
/// later stages and must enforce the read/control capability split before transport I/O.
public protocol ExistingAgentSessionAdapter: Sendable {
    var source: ExternalSessionSourceV1 { get }

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1
}

/// Metadata-only proof for a project-scoped read grant. The App gate calls
/// this before transcript I/O and again before releasing a completed page.
/// Providers without trustworthy membership metadata do not implement it.
public protocol ExternalSessionProjectMembershipVerifier: Sendable {
    func contains(
        threadID: ExternalSessionThreadID,
        projectID: ExternalSessionProjectID
    ) async throws -> Bool
}
