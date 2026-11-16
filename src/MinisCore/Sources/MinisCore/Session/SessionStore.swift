import Foundation
import os
import Darwin
import CryptoKit

/// Ephemeral user-confirmation anchor, bound to one complete canonical snapshot.
/// This is not a checkpoint file or a persisted history format.
public struct SessionTranscriptRewindAnchor: Identifiable, Equatable, Sendable {
    public let expectedSession: ChatSession
    public let messageIndex: Int
    public let messageDigest: String
    public var id: String {
        "\(expectedSession.id):\(expectedSession.transcriptRevision):\(messageIndex):\(messageDigest)"
    }
}

// MARK: - Codable conformance for LLMMessage (needed for session persistence)
//
// LLMMessage lives in Providers/LLMTypes.swift without Codable. The compiler
// cannot synthesize Codable in a cross-file extension, so the conformance is
// written by hand here (same module). `images`/`audios` decode via
// decodeIfPresent so older payloads without those keys fall back to [].

// Equatable + Hashable are also handwritten (no cross-file synthesis).

extension LLMMessage.ImageAttachment: Equatable, Hashable {
    public static func == (lhs: LLMMessage.ImageAttachment, rhs: LLMMessage.ImageAttachment) -> Bool {
        lhs.mimeType == rhs.mimeType && lhs.data == rhs.data
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(mimeType)
        hasher.combine(data)
    }
}

extension LLMMessage.AudioAttachment: Equatable, Hashable {
    public static func == (lhs: LLMMessage.AudioAttachment, rhs: LLMMessage.AudioAttachment) -> Bool {
        lhs.format == rhs.format && lhs.base64Data == rhs.base64Data
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(format)
        hasher.combine(base64Data)
    }
}

extension LLMMessage: Equatable, Hashable {
    public static func == (lhs: LLMMessage, rhs: LLMMessage) -> Bool {
        lhs.role == rhs.role && lhs.content == rhs.content
            && lhs.images == rhs.images && lhs.audios == rhs.audios
            && lhs.toolCallID == rhs.toolCallID && lhs.toolCalls == rhs.toolCalls
            && lhs.legacyToolOutputSummary == rhs.legacyToolOutputSummary
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(role)
        hasher.combine(content)
        hasher.combine(images)
        hasher.combine(audios)
        hasher.combine(toolCallID)
        hasher.combine(toolCalls)
        hasher.combine(legacyToolOutputSummary)
    }
}

extension LLMMessage.Role: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let role = LLMMessage.Role(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown LLMMessage.Role: \(raw)"
            ))
        }
        self = role
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension LLMMessage.ImageAttachment: Codable {
    private enum CodingKeys: String, CodingKey { case mimeType, data }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mimeType: try c.decode(String.self, forKey: .mimeType),
                  data: try c.decode(Data.self, forKey: .data))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(data, forKey: .data)
    }
}

extension LLMMessage.AudioAttachment: Codable {
    private enum CodingKeys: String, CodingKey { case format, base64Data }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(format: try c.decode(String.self, forKey: .format),
                  base64Data: try c.decode(String.self, forKey: .base64Data))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(base64Data, forKey: .base64Data)
    }
}

extension LLMToolCall: Equatable, Hashable {
    public static func == (lhs: LLMToolCall, rhs: LLMToolCall) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.rawArguments == rhs.rawArguments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(rawArguments)
    }
}

extension LLMToolCall: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, rawArguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawArguments = try c.decode(String.self, forKey: .rawArguments)
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(rawArguments.utf8)
        ) as? [String: Any]) ?? [:]
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            rawArguments: rawArguments,
            arguments: arguments
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rawArguments, forKey: .rawArguments)
    }
}

extension LLMMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case role, content, images, audios, toolCallID, toolCalls, legacyToolOutputSummary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try c.decode(Role.self, forKey: .role),
            content: try c.decode(String.self, forKey: .content),
            images: try c.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? [],
            audios: try c.decodeIfPresent([AudioAttachment].self, forKey: .audios) ?? [],
            toolCallID: try c.decodeIfPresent(String.self, forKey: .toolCallID),
            toolCalls: try c.decodeIfPresent([LLMToolCall].self, forKey: .toolCalls) ?? [],
            legacyToolOutputSummary: try c.decodeIfPresent(ToolOutputSummary.self, forKey: .legacyToolOutputSummary)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(images, forKey: .images)
        try c.encode(audios, forKey: .audios)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(legacyToolOutputSummary, forKey: .legacyToolOutputSummary)
    }
}

/// Stable session lineage metadata carried by the canonical SessionStore.
///
/// The optional fork boundary fields distinguish a root session from a child
/// while remaining backward-compatible with older root payloads.
public struct SessionLineageIdentity: Codable, Equatable, Hashable, Sendable {
    public let lineageVersion: Int
    public let rootSessionID: String
    public let parentSessionID: String?
    public let forkedFromSessionID: String?
    public let forkedThroughTranscriptRevision: UInt64?
    public let forkedThroughMessageID: String?

    public init(
        lineageVersion: Int,
        rootSessionID: String,
        parentSessionID: String?,
        forkedFromSessionID: String?,
        forkedThroughTranscriptRevision: UInt64?,
        forkedThroughMessageID: String?
    ) {
        self.lineageVersion = lineageVersion
        self.rootSessionID = rootSessionID
        self.parentSessionID = parentSessionID
        self.forkedFromSessionID = forkedFromSessionID
        self.forkedThroughTranscriptRevision = forkedThroughTranscriptRevision
        self.forkedThroughMessageID = forkedThroughMessageID
    }

    public static func root(_ sessionID: String) -> SessionLineageIdentity {
        SessionLineageIdentity(
            lineageVersion: ChatSession.currentLineageVersion,
            rootSessionID: sessionID,
            parentSessionID: nil,
            forkedFromSessionID: nil,
            forkedThroughTranscriptRevision: nil,
            forkedThroughMessageID: nil
        )
    }
}

// MARK: - ChatSession

/// A persisted chat session (conversation thread), stored as one JSON file per
/// session under `<root>/sessions/<id>.json`.
/// Identity recorded atomically with a scheduled transcript delivery. It is a
/// target fact, not a claim derived from the scheduler's separate receipt.
public struct ScheduledTranscriptDelivery: Codable, Hashable, Sendable {
    public let occurrenceID: UUID
    public let effectID: String
    public let taskID: UUID
    public let taskVersion: Int
    public let executionTurnID: Int
    public let executionMessageID: String

    public init(occurrenceID: UUID, effectID: String, taskID: UUID, taskVersion: Int,
                executionTurnID: Int, executionMessageID: String) {
        self.occurrenceID = occurrenceID
        self.effectID = effectID
        self.taskID = taskID
        self.taskVersion = taskVersion
        self.executionTurnID = executionTurnID
        self.executionMessageID = executionMessageID
    }
}

public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public static let currentLineageVersion = 1
    private static let goalPersistenceLog = Logger(subsystem: "com.miniscanvas.core", category: "SessionStore")

    public let id: String
    public var goal: ConversationGoalState? = nil
    /// Human-readable title. Empty until auto-generated from the first user
    /// message (see `SessionStore.makeTitle(from:)`).
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [LLMMessage]
    /// Monotonic transcript identity used to reject stale asynchronous writes.
    public var transcriptRevision: UInt64
    /// Durable target-side identities; old sessions decode with an empty list.
    public var scheduledTranscriptDeliveries: [ScheduledTranscriptDelivery]
    /// AJ-29：置顶标记（会话列表置顶展示）。
    public var pinned: Bool
    /// AJ-29：未读标记（会话列表小圆点；打开会话即清除）。
    public var unread: Bool
    /// AJ-30：会话归属的项目标识（nil = 未归属，Codex 对话项目功能）。
    public var projectID: String?
    /// AJ-30：项目名称（展示用，nil = 未归属）。
    public var projectName: String?
    /// AJ-30：项目工作目录绝对路径（nil = 未归属）。供 agent 以该目录为工作根。
    public var workingDirectory: String?
    /// AJ-59：用户自定义会话组 ID（nil = 未归入自定义组）。自定义组为
    /// 用户可新建/重命名/删除的真实实体，与项目分组（AJ-30）并存。
    public var groupID: String?
    /// L1：会话级模型 ID（nil = 继承全局默认模型选择）。
    public var modelID: String?
    /// L1：会话级 Provider 原始值（内置 = ProviderType.rawValue；自定义 =
    /// "custom.<recordName>"；nil = 继承全局默认）。
    public var providerTypeRaw: String?
    /// Versioned persisted lineage metadata. Legacy payloads decode as roots.
    public var lineageVersion: Int
    public var rootSessionID: String
    public var parentSessionID: String?
    public var forkedFromSessionID: String?
    public var forkedThroughTranscriptRevision: UInt64?
    public var forkedThroughMessageID: String?
    public var createdByTaskID: String?
    public var createdByRunID: String?
    /// Source of a separately created task, not transcript-fork ancestry.
    public var taskSourceSessionID: String?

    public var lineageIdentity: SessionLineageIdentity {
        SessionLineageIdentity(
            lineageVersion: lineageVersion,
            rootSessionID: rootSessionID,
            parentSessionID: parentSessionID,
            forkedFromSessionID: forkedFromSessionID,
            forkedThroughTranscriptRevision: forkedThroughTranscriptRevision,
            forkedThroughMessageID: forkedThroughMessageID
        )
    }

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [LLMMessage] = [],
        transcriptRevision: UInt64 = 0,
        scheduledTranscriptDeliveries: [ScheduledTranscriptDelivery] = [],
        pinned: Bool = false,
        unread: Bool = false,
        projectID: String? = nil,
        projectName: String? = nil,
        workingDirectory: String? = nil,
        groupID: String? = nil,
        modelID: String? = nil,
        providerTypeRaw: String? = nil,
        lineageVersion: Int = ChatSession.currentLineageVersion,
        rootSessionID: String? = nil,
        parentSessionID: String? = nil,
        forkedFromSessionID: String? = nil,
        forkedThroughTranscriptRevision: UInt64? = nil,
        forkedThroughMessageID: String? = nil,
        createdByTaskID: String? = nil,
        createdByRunID: String? = nil,
        taskSourceSessionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcriptRevision = transcriptRevision
        self.scheduledTranscriptDeliveries = scheduledTranscriptDeliveries
        self.pinned = pinned
        self.unread = unread
        self.projectID = projectID
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.groupID = groupID
        self.modelID = modelID
        self.providerTypeRaw = providerTypeRaw
        self.lineageVersion = lineageVersion
        self.rootSessionID = rootSessionID ?? id
        self.parentSessionID = parentSessionID
        self.forkedFromSessionID = forkedFromSessionID
        self.forkedThroughTranscriptRevision = forkedThroughTranscriptRevision
        self.forkedThroughMessageID = forkedThroughMessageID
        self.createdByTaskID = createdByTaskID
        self.createdByRunID = createdByRunID
        self.taskSourceSessionID = taskSourceSessionID
    }

    // 手写 Codable：旧持久化 JSON 无 pinned/unread 键时按 false 解码（向后兼容）。
    // AJ-30：projectID/projectName/workingDirectory 为可选键，缺失按 nil 解码。
    // AJ-59：groupID 为可选键，缺失按 nil 解码。
    // L1：modelID/providerTypeRaw 为可选键，缺失按 nil 解码（旧数据继承全局默认）。
    private enum CodingKeys: String, CodingKey {
        case id, goal, title, createdAt, updatedAt, messages, transcriptRevision, scheduledTranscriptDeliveries, pinned, unread,
             projectID, projectName, workingDirectory, groupID,
             modelID, providerTypeRaw,
             lineageVersion, rootSessionID, parentSessionID, forkedFromSessionID,
             forkedThroughTranscriptRevision, forkedThroughMessageID,
             createdByTaskID, createdByRunID, taskSourceSessionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let decodedGoal = try? c.decodeIfPresent(ConversationGoalState.self, forKey: .goal),
           UUID(uuidString: id) == decodedGoal.sessionID {
            goal = decodedGoal
        } else if c.contains(.goal), (try? c.decodeNil(forKey: .goal)) != true {
            Self.goalPersistenceLog.warning("Ignoring invalid conversation goal metadata")
        }
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decode([LLMMessage].self, forKey: .messages)
        transcriptRevision = try c.decodeIfPresent(UInt64.self, forKey: .transcriptRevision) ?? 0
        scheduledTranscriptDeliveries = try c.decodeIfPresent([ScheduledTranscriptDelivery].self,
                                                               forKey: .scheduledTranscriptDeliveries) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        providerTypeRaw = try c.decodeIfPresent(String.self, forKey: .providerTypeRaw)
        lineageVersion = try c.decodeIfPresent(Int.self, forKey: .lineageVersion)
            ?? ChatSession.currentLineageVersion
        rootSessionID = try c.decodeIfPresent(String.self, forKey: .rootSessionID) ?? id
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID)
        forkedFromSessionID = try c.decodeIfPresent(String.self, forKey: .forkedFromSessionID)
        forkedThroughTranscriptRevision = try c.decodeIfPresent(
            UInt64.self,
            forKey: .forkedThroughTranscriptRevision
        )
        forkedThroughMessageID = try c.decodeIfPresent(String.self, forKey: .forkedThroughMessageID)
        createdByTaskID = try c.decodeIfPresent(String.self, forKey: .createdByTaskID)
        createdByRunID = try c.decodeIfPresent(String.self, forKey: .createdByRunID)
        taskSourceSessionID = try c.decodeIfPresent(String.self, forKey: .taskSourceSessionID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let goal {
            if UUID(uuidString: id) == goal.sessionID {
                try c.encode(goal, forKey: .goal)
            } else {
                Self.goalPersistenceLog.warning("Ignoring invalid conversation goal metadata")
            }
        }
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(messages, forKey: .messages)
        try c.encode(transcriptRevision, forKey: .transcriptRevision)
        try c.encode(scheduledTranscriptDeliveries, forKey: .scheduledTranscriptDeliveries)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(unread, forKey: .unread)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(modelID, forKey: .modelID)
        try c.encodeIfPresent(providerTypeRaw, forKey: .providerTypeRaw)
        try c.encode(lineageVersion, forKey: .lineageVersion)
        try c.encode(rootSessionID, forKey: .rootSessionID)
        try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try c.encodeIfPresent(forkedFromSessionID, forKey: .forkedFromSessionID)
        try c.encodeIfPresent(
            forkedThroughTranscriptRevision,
            forKey: .forkedThroughTranscriptRevision
        )
        try c.encodeIfPresent(forkedThroughMessageID, forKey: .forkedThroughMessageID)
        try c.encodeIfPresent(createdByTaskID, forKey: .createdByTaskID)
        try c.encodeIfPresent(createdByRunID, forKey: .createdByRunID)
        try c.encodeIfPresent(taskSourceSessionID, forKey: .taskSourceSessionID)
    }
}

// MARK: - SessionStore

/// JSON-file-backed session store.
///
/// Layout: one file per session at `<directory>/sessions/<id>.json`.
/// Every mutation is serialized under an internal lock and written atomically,
/// so the store is safe to share across tasks.
/// One process-local, reentrant serialization boundary for all supported
/// stores and active/archive/trash movers of a canonical session directory.
/// The registry mutex is released before the domain lock or any file IO.
/// F05 transaction admission must precede entering this domain lock.
final class SessionPersistenceLock: @unchecked Sendable {
    private let primitive = NSRecursiveLock()
    private static let registryMutex = NSLock()
    private static nonisolated(unsafe) var registry: [String: SessionPersistenceLock] = [:]

    static func shared(directory: URL) -> SessionPersistenceLock {
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        registryMutex.lock(); defer { registryMutex.unlock() }
        if let existing = registry[key] { return existing }
        let created = SessionPersistenceLock()
        registry[key] = created
        return created
    }
    func lock() { primitive.lock() }
    func unlock() { primitive.unlock() }
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }

    // Shared by every SessionStore instance for one canonical directory, so a
    // mutation through another owner still invalidates an in-flight recovery.
    fileprivate var sessionRecoveryGenerations: [String: UInt64] = [:]
}

public final class SessionStore: @unchecked Sendable {

    private static let maxCanonicalCheckpointIDBytes = 128
    private static let maxQuarantineEntries = 512
    private static let maxQuarantineBytes: Int64 = 64 * 1024 * 1024
    private static let maxCheckpointChainRecords = 512
    private static let maxCheckpointChainBytes: Int64 = 4 * 1024 * 1024
    private static let maxCleanupHandoffDepth = 64

    private enum QuarantineStage: String, Sendable {
        case beforeQuarantineDirectory
        case afterQuarantineDirectory
        case afterSecureDirectory
        case afterCapacityCheck
        case afterSourceReadback
        case afterTransactionPersist
        case moveDirectoryDescriptor
        case moveSourceIdentity
        case moveRenameOrDestinationIdentity
        case moveDirectorySync
        case afterPayloadMove
        case afterDirectorySync
    }

    private enum CheckpointPersistenceStage: String, Sendable {
        case entryGeneration
        case payloadOrManifest
        case existingCandidates
        case canonicalEncode
        case directoryDescriptor
        case temporaryWriteStatSync
        case hardLinkInstallIdentity
        case directorySyncUnlink
        case canonicalReadback
        case finalGenerationRecheck
    }

    private enum CheckpointSaveStage: String, Sendable {
        case entryValidation
        case existingHistory
        case existingCheckpointRead
        case committedCandidateRead
        case preparedCandidateRead
        case phaseTransactionSelection
        case expectedRecordSelection
        case complete
    }

    private enum CheckpointCandidatePresence: String, Sendable {
        case notObserved
        case none
        case committed
        case prepared
        case both
    }

    private enum CheckpointChainPayloadMismatchGroup: String, Sendable {
        case notObserved
        case identityOrScope
        case revisionsOrEpoch
        case manifestRoot
        case manifestInventorySizesOrAggregate
        case manifestGenerationsOrPredecessors
        case payloadDigest
        case checkpointDigest
        case previousDigest
        case equal
    }

    private enum CheckpointReadStage: String, Sendable {
        case notStarted
        case checkpointDirectory
        case cleanupTombstones
        case visibleCheckpointEnumerationAndDecode
        case canonicalChainEnumerationAndDecode
        case recordShapeOrManifest
        case preparedCommittedPairing
        case transactionOwnership
        case visibleToCommittedMembership
        case generationOrPredecessorLinks
        case activePayloadAgreement
        case predecessorReachability
        case duplicateGeneration
        case complete
    }

    /// Root directory the store persists under (the "project directory").
    public let directory: URL
    public var persistenceDomain: PersistenceTransactionFence.Domain { .sessions(directory) }

    /// Directory holding one `<id>.json` per session.
    public var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    /// Directory holding versioned compaction checkpoint sidecars.
    public var compactionCheckpointsDirectory: URL {
        sessionsDirectory.appendingPathComponent("_compaction-checkpoints", isDirectory: true)
    }

    /// Quarantine for corrupt checkpoint sidecars so restart/resume does not
    /// repeatedly encounter the same invalid file.
    public var compactionCheckpointsQuarantineDirectory: URL {
        sessionsDirectory.appendingPathComponent(
            "_compaction-checkpoints-quarantine",
            isDirectory: true
        )
    }

    private var compactionCheckpointLockURL: URL {
        sessionsDirectory.appendingPathComponent("_compaction-checkpoints.lock")
    }

    let persistenceLock: SessionPersistenceLock
    private var lock: SessionPersistenceLock { persistenceLock }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastQuarantineStage = QuarantineStage.beforeQuarantineDirectory
    private var lastCheckpointPersistenceStage = CheckpointPersistenceStage.entryGeneration
    private var lastCheckpointSaveStage = CheckpointSaveStage.entryValidation
    private var lastCheckpointCandidatePresence = CheckpointCandidatePresence.notObserved
    private var lastCheckpointChainPayloadMismatch = CheckpointChainPayloadMismatchGroup.notObserved
    private var lastCheckpointReadStage = CheckpointReadStage.notStarted

    func quarantineDiagnosticStage() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastQuarantineStage.rawValue
    }

    func checkpointPersistenceDiagnosticStage() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastCheckpointPersistenceStage.rawValue
    }

    func checkpointSaveDiagnosticState() -> (
        stage: String,
        candidatePresence: String,
        payloadMismatch: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            lastCheckpointSaveStage.rawValue,
            lastCheckpointCandidatePresence.rawValue,
            lastCheckpointChainPayloadMismatch.rawValue
        )
    }

    func checkpointReadDiagnosticStage() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastCheckpointReadStage.rawValue
    }

    public init(directory: URL) {
        let admission = PersistenceTransactionFence.read([PersistenceTransactionFence.Domain.sessions(directory)])
        defer { admission.release() }
        self.directory = directory
        self.persistenceLock = .shared(directory: directory)
    }

    /// Default root directory for the MinisCanvas app (Application Support).
    public static var defaultDirectory: URL {
        if let formal = FormalTestIsolationPaths.currentOrFail() {
            return formal.sessionDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MinisCanvas", isDirectory: true)
    }

    // MARK: - Session lifecycle

    /// Capture the current session identity and advance its process-local
    /// recovery generation. The token is valid only until this session is
    /// created, mutated, or deleted again through this store.
    public func beginSessionRecovery(for sessionID: String) -> SessionRecoveryToken {
        PersistenceTransactionFence.withRead([persistenceDomain]) {
            lock.withLock {
                let generation = advanceSessionRecoveryGenerationUnlocked(for: sessionID)
                let preimageExists = FileManager.default.fileExists(
                    atPath: fileURL(for: sessionID).path
                )
                var expectedIdentity: SessionRecoveryIdentity?
                var baselineReadable = true
                do {
                    expectedIdentity = try loadUnlocked(id: sessionID)?.sessionRecoveryIdentity
                    // `loadUnlocked` returns nil for a missing file and also
                    // for an unreadable file; existence distinguishes those
                    // cases so recovery cannot replace unreadable state.
                    baselineReadable = !preimageExists || expectedIdentity != nil
                } catch {
                    // A corrupt preimage must never be treated as an absent
                    // session, otherwise recovery could silently overwrite it.
                    expectedIdentity = nil
                    baselineReadable = false
                }
                return SessionRecoveryToken(
                    sessionID: sessionID,
                    generation: generation,
                    expectedIdentity: expectedIdentity,
                    baselineReadable: baselineReadable
                )
            }
        }
    }

    /// Apply a recovered session only when its admission generation and
    /// immutable identity still match the state observed at begin time.
    /// Returning false is an intentional fail-closed stale-recovery result;
    /// no session bytes are written in that case.
    @discardableResult
    public func applyRecoveredSession(
        _ session: ChatSession,
        token: SessionRecoveryToken
    ) throws -> Bool {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard token.sessionID == session.id,
                      token.baselineReadable,
                      lock.sessionRecoveryGenerations[session.id] == token.generation else {
                    return false
                }
                let current: ChatSession?
                do {
                    current = try loadUnlocked(id: session.id)
                } catch {
                    // Do not replace an unreadable file through the recovery
                    // path. The caller can surface a normal restore failure.
                    return false
                }
                guard current?.sessionRecoveryIdentity == token.expectedIdentity else {
                    return false
                }
                try persistUnlocked(session)
                return true
            }
        }
    }

    /// Create a new empty session and persist it immediately.
    /// AJ-30：可指定会话归属的项目（projectID/name + 工作目录 path）。
    @discardableResult
    public func createSession(
        id: String = UUID().uuidString,
        title: String = "",
        projectID: String? = nil,
        projectName: String? = nil,
        workingDirectory: String? = nil
    ) throws -> ChatSession {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            let session = ChatSession(
                id: id, title: title,
                projectID: projectID, projectName: projectName, workingDirectory: workingDirectory
            )
            try lock.withLock {
                invalidateSessionRecoveryUnlocked(for: session.id)
                try persistUnlocked(session)
            }
            return session

        }
    }

    /// Create a durable child session from a frozen prefix of a source
    /// transcript. The source revision and stable boundary ID are persisted so
    /// later source mutations cannot change the child lineage record.
    @discardableResult
    public func forkSession(
        from sourceSessionID: String,
        id: String = UUID().uuidString,
        title: String? = nil,
        throughMessageIndex: Int? = nil,
        createdByTaskID: String? = nil,
        createdByRunID: String? = nil
    ) throws -> ChatSession {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard let source = try loadUnlocked(id: sourceSessionID) else {
                    throw SessionStoreError.sessionNotFound(sourceSessionID)
                }
                guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      id != sourceSessionID else {
                    throw SessionStoreError.invalidSessionLineage(id)
                }
                guard try loadUnlocked(id: id) == nil else {
                    throw SessionStoreError.sessionAlreadyExists(id)
                }

                let boundary = throughMessageIndex ?? source.messages.count
                guard boundary >= 0, boundary <= source.messages.count else {
                    throw SessionStoreError.invalidSessionLineage(sourceSessionID)
                }
                let copiedMessages = Array(source.messages.prefix(boundary))
                let boundaryMessageID = boundary > 0
                    ? Compactor.stableMessageID(
                        copiedMessages[boundary - 1],
                        transcriptIndex: boundary - 1
                    )
                    : nil
                let child = ChatSession(
                    id: id,
                    title: title ?? (source.title.isEmpty ? "" : "\(source.title) (copy)"),
                    createdAt: Date(),
                    updatedAt: Date(),
                    messages: copiedMessages,
                    transcriptRevision: UInt64(boundary),
                    pinned: false,
                    unread: false,
                    projectID: source.projectID,
                    projectName: source.projectName,
                    workingDirectory: source.workingDirectory,
                    groupID: source.groupID,
                    modelID: source.modelID,
                    providerTypeRaw: source.providerTypeRaw,
                    lineageVersion: ChatSession.currentLineageVersion,
                    rootSessionID: source.rootSessionID,
                    parentSessionID: source.id,
                    forkedFromSessionID: source.id,
                    forkedThroughTranscriptRevision: source.transcriptRevision,
                    forkedThroughMessageID: boundaryMessageID,
                    createdByTaskID: createdByTaskID,
                    createdByRunID: createdByRunID
                )
                invalidateSessionRecoveryUnlocked(for: child.id)
                try persistUnlocked(child)
                return child
            }

        }
    }

    /// Explicit-source alias for callers that do not use the `from:` spelling.
    @discardableResult
    public func forkSession(
        sourceSessionID: String,
        id: String = UUID().uuidString,
        title: String? = nil,
        throughMessageIndex: Int? = nil,
        createdByTaskID: String? = nil,
        createdByRunID: String? = nil
    ) throws -> ChatSession {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try forkSession(
                from: sourceSessionID,
                id: id,
                title: title,
                throughMessageIndex: throughMessageIndex,
                createdByTaskID: createdByTaskID,
                createdByRunID: createdByRunID
            )

        }
    }

    /// Append a message to the session and persist.
    ///
    /// Auto-generates the title from the first user message when the title is
    /// still empty (see `makeTitle(from:)`).
    public func saveMessage(_ message: LLMMessage, sessionID: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard var session = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                session.messages.append(message)
                session.transcriptRevision &+= 1
                if session.title.isEmpty, message.role == .user {
                    session.title = Self.makeTitle(from: message.content)
                }
                session.updatedAt = Date()
                invalidateSessionRecoveryUnlocked(for: session.id)
                try persistUnlocked(session)
            }

        }
    }

    /// Atomically append one child message to an exact lineage-bound session.
    /// The expected session includes its optional project, lineage, revision,
    /// and messages; a concurrent or foreign edit fails before persistence.
    @discardableResult
    func compareAndAppendChildTranscript(
        _ message: LLMMessage,
        expectedSession: ChatSession,
        parentSessionID: String,
        taskID: String,
        runID: String
    ) throws -> ChatSession {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try Task.checkCancellation()
                let sessionID = expectedSession.id
                guard var current = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                guard current == expectedSession,
                      current.projectID == expectedSession.projectID,
                      current.parentSessionID == parentSessionID,
                      current.forkedFromSessionID == parentSessionID,
                      current.createdByTaskID == taskID,
                      current.createdByRunID == runID,
                      current.lineageVersion == ChatSession.currentLineageVersion,
                      current.transcriptRevision < UInt64.max,
                      !FileManager.default.fileExists(
                          atPath: sessionsDirectory.appendingPathComponent("_archive/\(sessionID).json").path
                      ) else {
                    throw SessionStoreError.sessionSnapshotConflict(sessionID)
                }
                current.messages.append(message)
                current.transcriptRevision += 1
                current.updatedAt = Date()
                try Task.checkCancellation()
                invalidateSessionRecoveryUnlocked(for: sessionID)
                do { try persistUnlocked(current) }
                catch {
                    if (try? loadUnlocked(id: sessionID)) == current {
                        throw SessionStoreError.sessionCommitUncertain(sessionID)
                    }
                    throw error
                }
                let fd = Darwin.open(fileURL(for: sessionID).path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw SessionStoreError.sessionCommitUncertain(sessionID) }
                defer { _ = Darwin.close(fd) }
                let parent = Darwin.open(sessionsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard parent >= 0 else { throw SessionStoreError.sessionCommitUncertain(sessionID) }
                defer { _ = Darwin.close(parent) }
                guard Darwin.fsync(fd) == 0, Darwin.fsync(parent) == 0,
                      try loadUnlocked(id: sessionID) == current else {
                    throw SessionStoreError.sessionCommitUncertain(sessionID)
                }
                return current
            }
        }
    }

    public enum ConversationGoalControl: Sendable {
        case pause, resume, stop
    }

    public func recordConversationGoalTurn(
        sessionID: UUID, goalID: UUID, durationSeconds: Double, reportedTokens: Int?,
        outcome: ConversationGoalState.TurnOutcome, interrupting expected: ConversationGoalState? = nil
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            let recorded: Bool
            if let expected {
                guard goal == expected else { throw ConversationGoalError.invalidTransition }
                recorded = goal.recordInterruptedTurn(durationSeconds: durationSeconds,
                                                       reportedTokens: reportedTokens, outcome: outcome)
            } else {
                recorded = goal.recordTurn(durationSeconds: durationSeconds,
                                           reportedTokens: reportedTokens, outcome: outcome)
            }
            guard recorded else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    public func pauseConversationGoalForInterruptedTurn(
        expected: ConversationGoalState, reason: ConversationGoalState.TurnPauseReason
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: expected.sessionID) { existing in
            guard var goal = existing, goal == expected else { throw ConversationGoalError.unavailable }
            guard goal.pauseForInterruptedTurn(reason) else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    public func pauseConversationGoalForSessionTokenLimit(
        sessionID: UUID, goalID: UUID
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            guard goal.pauseForSessionTokenLimit() else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    public func setConversationGoalBudget(
        sessionID: UUID, goalID: UUID, turns: Int, tokens: Int?, durationSeconds: Double?
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            guard goal.setBudgetLimits(turns: turns, tokens: tokens, durationSeconds: durationSeconds)
            else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    /// `expected` lets a running turn switch the preference only on the exact
    /// state it holds, so its own snapshot can be replaced in the same step.
    public func setConversationGoalAutoContinue(
        sessionID: UUID, goalID: UUID, enabled: Bool, expected: ConversationGoalState? = nil
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            guard expected == nil || goal == expected else { throw ConversationGoalError.unavailable }
            guard goal.setAutoContinue(enabled) else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    public enum ConversationGoalError: Error {
        case unavailable, invalidTransition
    }

    public func startConversationGoal(sessionID: UUID, objective: String) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard existing == nil || existing?.status == .stopped || existing?.status == .completed,
                  let goal = ConversationGoalState(sessionID: sessionID, objective: objective) else {
                throw ConversationGoalError.invalidTransition
            }
            return goal
        }
    }

    /// Materialize the owned, never-persisted welcome session and its first goal together.
    public func startBootstrapConversationGoal(
        token: SessionRecoveryToken, title: String, welcomeText: String, objective: String
    ) throws -> ConversationGoalState {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard let id = UUID(uuidString: token.sessionID), id.uuidString == token.sessionID,
                      token.baselineReadable, token.expectedIdentity == nil,
                      lock.sessionRecoveryGenerations[token.sessionID] == token.generation
                else { throw ConversationGoalError.unavailable }
                let candidateIDs = [token.sessionID, token.sessionID.lowercased()]
                let candidateURLs = candidateIDs.flatMap { candidateID in
                    [fileURL(for: candidateID),
                     sessionsDirectory.appendingPathComponent("_archive/\(candidateID).json")]
                }
                for url in candidateURLs {
                    var metadata = stat()
                    guard Darwin.lstat(url.path, &metadata) == -1, errno == ENOENT
                    else { throw ConversationGoalError.unavailable }
                }
                guard let goal = ConversationGoalState(sessionID: id, objective: objective)
                else { throw ConversationGoalError.invalidTransition }
                var session = ChatSession(id: token.sessionID, title: title,
                                          messages: [.init(role: .assistant, content: welcomeText)])
                session.goal = goal
                try persistUnlocked(session)
                invalidateSessionRecoveryUnlocked(for: token.sessionID)
                return goal
            }
        }
    }

    public func controlConversationGoal(
        sessionID: UUID, goalID: UUID, action: ConversationGoalControl
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            let changed: Bool
            switch action {
            case .pause: changed = goal.pause()
            case .resume: changed = goal.resume()
            case .stop: changed = goal.stop()
            }
            guard changed else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    public enum ConversationGoalReport: Sendable {
        case completion(evidence: [String])
        case blocker(ConversationGoalBlocker)
        case allRemainingWorkBlocked(reason: String)
    }

    public func recordConversationGoalReport(
        sessionID: UUID, goalID: UUID, report: ConversationGoalReport, now: Date = Date(),
        expected: ConversationGoalState? = nil
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            guard expected == nil || goal == expected else { throw ConversationGoalError.unavailable }
            let changed: Bool
            switch report {
            case .completion(let evidence): changed = goal.reportCompletion(evidence: evidence) != nil
            case .blocker(let blocker): changed = goal.recordBlocker(blocker, now: now)
            case .allRemainingWorkBlocked(let reason):
                changed = goal.reportBlocked(reason: reason, allRemainingWorkBlocked: true)
            }
            guard changed else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    /// Applies a verdict only to the exact pending report reviewed by the caller.
    public func recordConversationGoalReview(
        expected: ConversationGoalState, reviewID: UUID, accepted: Bool
    ) throws -> ConversationGoalState {
        try recordConversationGoalReview(expected: expected, reviewID: reviewID,
                                         result: .init(outcome: accepted ? .passed : .rejected))
    }

    public func recordConversationGoalReview(
        expected: ConversationGoalState, reviewID: UUID, result: ConversationGoalState.ReviewRecord, usage: LLMUsage? = nil
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: expected.sessionID) { existing in
            if result.outcome == .passed { try Task.checkCancellation() }
            guard var goal = existing, goal == expected,
                  goal.recordReview(id: reviewID, result: result, usage: usage) else {
                throw ConversationGoalError.invalidTransition
            }
            return goal
        }
    }

    private func writeConversationGoal(
        sessionID: UUID, change: (ConversationGoalState?) throws -> ConversationGoalState
    ) throws -> ConversationGoalState {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard var session = try loadUnlocked(id: sessionID.uuidString) else {
                    throw ConversationGoalError.unavailable
                }
                let goal = try change(session.goal)
                session.goal = goal
                try persistUnlocked(session)
                return goal
            }
        }
    }

    public func updateConversationGoalReminder(
        sessionID: UUID, goalID: UUID, expectedDueAt: Date? = nil, now: Date
    ) throws -> ConversationGoalState {
        try writeConversationGoal(sessionID: sessionID) { existing in
            guard var goal = existing, goal.id == goalID else { throw ConversationGoalError.unavailable }
            if let expectedDueAt, goal.reminderDueAt != expectedDueAt {
                throw ConversationGoalError.invalidTransition
            }
            let changed = expectedDueAt == nil
                ? goal.resetBlockerReminder(now: now)
                : goal.consumeBlockerReminder(now: now)
            guard changed else { throw ConversationGoalError.invalidTransition }
            return goal
        }
    }

    /// Replace the whole session (messages and metadata) and persist.
    public func updateSession(_ session: ChatSession) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                // Preserve the exact existing bytes for an unchanged session.
                // Broad UI upserts must not rewrite an unrelated transcript.
                if let current = try? loadUnlocked(id: session.id), current == session { return }
                invalidateSessionRecoveryUnlocked(for: session.id)
                try persistUnlocked(session)
            }

        }
    }

    /// Persist a UI projection only when it cannot roll back a newer transcript.
    /// The comparison and replacement share the compaction writer's canonical
    /// directory lock. Equal-generation metadata updates remain supported;
    /// explicit restore/import callers keep using unconditional updateSession.
    @discardableResult
    public func updateSessionUnlessTranscriptIsNewer(_ session: ChatSession) throws -> Bool {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                let current = try loadUnlocked(id: session.id)
                if let current, current.transcriptRevision > session.transcriptRevision { return false }
                var candidate = session
                candidate.scheduledTranscriptDeliveries = current?.scheduledTranscriptDeliveries ?? []
                candidate.goal = current?.goal
                if current == candidate { return true }
                invalidateSessionRecoveryUnlocked(for: session.id)
                try persistUnlocked(candidate)
                return true
            }
        }
    }

    /// Clear a membership proven absent from a decoded App group catalog.
    /// Re-read under the canonical lock: the observed group is a metadata CAS,
    /// never authority to replace an older transcript or recreate a removed file.
    /// A membership changed by another supported writer is retained unchanged.
    @discardableResult
    public func clearOrphanedGroupMembership(
        sessionID: String,
        expectedGroupID: String,
        knownGroupIDs: Set<UUID>
    ) throws -> ChatSession {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard var current = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                guard current.id == sessionID else {
                    throw SessionStoreError.sessionTargetMismatch(sessionID)
                }
                try validateLineageUnlocked(current)
                guard current.groupID == expectedGroupID,
                      UUID(uuidString: expectedGroupID).map(knownGroupIDs.contains) != true else {
                    return current
                }
                current.groupID = nil
                invalidateSessionRecoveryUnlocked(for: sessionID)
                try persistUnlocked(current)
                return current
            }
        }
    }

    /// Replace only the transcript of the exact active target. Validation and
    /// persistence share the same lock as all SessionStore instances and the
    /// supported archive/trash movers. This is not a cross-process transaction.
    @discardableResult
    public func compareAndCommitTranscript(
        sessionID: String,
        projectID: String,
        expectedRevision: UInt64,
        expectedMessages: [LLMMessage],
        replacementMessages: [LLMMessage],
        scheduledDelivery: ScheduledTranscriptDelivery? = nil
    ) throws -> ChatSession {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try Task.checkCancellation()
                guard var current = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                guard current.projectID == projectID else {
                    throw SessionStoreError.sessionTargetMismatch(sessionID)
                }
                let archive = sessionsDirectory.appendingPathComponent("_archive/\(sessionID).json")
                guard !FileManager.default.fileExists(atPath: archive.path),
                      current.transcriptRevision == expectedRevision,
                      current.messages == expectedMessages,
                      expectedRevision < UInt64.max else {
                    throw SessionStoreError.sessionSnapshotConflict(sessionID)
                }
                if let scheduledDelivery {
                    guard scheduledDelivery.taskVersion > 0,
                          scheduledDelivery.executionTurnID > 0,
                          !scheduledDelivery.effectID.isEmpty,
                          !scheduledDelivery.executionMessageID.isEmpty,
                          !current.scheduledTranscriptDeliveries.contains(where: {
                              $0.occurrenceID == scheduledDelivery.occurrenceID
                                  || $0.effectID == scheduledDelivery.effectID
                          }) else {
                        throw SessionStoreError.sessionSnapshotConflict(sessionID)
                    }
                    current.scheduledTranscriptDeliveries.append(scheduledDelivery)
                }
                current.messages = replacementMessages
                current.transcriptRevision = expectedRevision + 1
                current.updatedAt = Date()
                try Task.checkCancellation()
                return try commitTranscriptUnlocked(current)
            }

        }
    }

    /// Offer only complete assistant boundaries; never split tool call/result groups.
    public func conversationRewindAnchors(sessionID: String) throws -> [SessionTranscriptRewindAnchor] {
        try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try lock.withLock {
                guard let current = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                try validateLineageUnlocked(current)
                return try Self.rewindAnchors(in: current)
            }
        }
    }

    /// Commit only the selected canonical prefix of the exact observed owner/version.
    @discardableResult
    public func rewindConversation(to anchor: SessionTranscriptRewindAnchor) throws -> ChatSession {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try Task.checkCancellation()
                let sessionID = anchor.expectedSession.id
                guard var current = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                guard current == anchor.expectedSession,
                      current.transcriptRevision < UInt64.max,
                      !FileManager.default.fileExists(atPath:
                        sessionsDirectory.appendingPathComponent("_archive/\(sessionID).json").path),
                      try Self.rewindAnchors(in: current).contains(anchor) else {
                    throw SessionStoreError.sessionSnapshotConflict(sessionID)
                }
                try validateLineageUnlocked(current)
                current.messages = Array(current.messages.prefix(anchor.messageIndex + 1))
                current.transcriptRevision += 1
                current.updatedAt = Date()
                return try commitTranscriptUnlocked(current)
            }
        }
    }

    private static func rewindAnchors(in session: ChatSession) throws -> [SessionTranscriptRewindAnchor] {
        var pending = Set<String>()
        var anchors: [SessionTranscriptRewindAnchor] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (index, message) in session.messages.enumerated() {
            if message.role == .user, !pending.isEmpty { break }
            if message.role == .tool {
                guard let callID = message.toolCallID, pending.remove(callID) != nil else { break }
            }
            for call in message.toolCalls {
                guard pending.insert(call.id).inserted else { return anchors }
            }
            guard message.role == .assistant, message.toolCalls.isEmpty, pending.isEmpty,
                  !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  index + 1 < session.messages.count else { continue }
            let digest = SHA256.hash(data: try encoder.encode(message))
                .map { String(format: "%02x", $0) }.joined()
            anchors.append(SessionTranscriptRewindAnchor(expectedSession: session,
                messageIndex: index, messageDigest: digest))
        }
        return anchors
    }

    /// Caller holds the canonical lock after validating its purpose-specific CAS.
    private func commitTranscriptUnlocked(_ current: ChatSession) throws -> ChatSession {
        let sessionID = current.id
        try Task.checkCancellation()
        invalidateSessionRecoveryUnlocked(for: sessionID)
        do { try persistUnlocked(current) }
        catch {
            if (try? loadUnlocked(id: sessionID)) == current {
                throw SessionStoreError.sessionCommitUncertain(sessionID)
            }
            throw error
        }
        // A successful return means the actual canonical file and its
        // directory have been synchronized, not merely a UI mutation.
        let fd = Darwin.open(fileURL(for: sessionID).path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SessionStoreError.sessionCommitUncertain(sessionID) }
        defer { _ = Darwin.close(fd) }
        let parent = Darwin.open(sessionsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw SessionStoreError.sessionCommitUncertain(sessionID) }
        defer { _ = Darwin.close(parent) }
        guard Darwin.fsync(fd) == 0, Darwin.fsync(parent) == 0,
              try loadUnlocked(id: sessionID) == current else {
            throw SessionStoreError.sessionCommitUncertain(sessionID)
        }
        return current
    }

    /// The scheduled variant preserves the same checkpoint format and
    /// saveCompactionCheckpoint transaction, while checking project and source
    /// inside its shared writer boundary rather than before acquiring it.
    public func compareAndSaveCompaction(
        sessionID: String, projectID: String, expectedRevision: UInt64,
        expectedMessages: [LLMMessage], result: CompactionResult
    ) throws -> CompactionCheckpoint? {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try Task.checkCancellation()
                guard let current = try loadUnlocked(id: sessionID) else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                guard current.projectID == projectID else { throw SessionStoreError.sessionTargetMismatch(sessionID) }
                guard current.transcriptRevision == expectedRevision, current.messages == expectedMessages,
                      !FileManager.default.fileExists(atPath: sessionsDirectory.appendingPathComponent("_archive/\(sessionID).json").path) else {
                    throw SessionStoreError.sessionSnapshotConflict(sessionID)
                }
                guard result.compactedCount > 0 else { return nil }
                let checkpoint = try CompactionCheckpoint.makeProjection(sessionID: sessionID,
                    sourceTranscriptRevision: expectedRevision, sourceMessages: expectedMessages,
                    result: result, lineage: current.lineageIdentity)
                return try saveCompactionCheckpoint(checkpoint)
            }

        }
    }

    // MARK: - Durable compaction

    /// Compact a closed prefix while retaining an unprojected live suffix.
    /// The complete canonical snapshot, including that suffix, is compared
    /// under the writer fence. Exact-tail validation still applies to the
    /// closed prefix; the ordinary checkpoint writer is not relaxed.
    public func compareAndSaveCompactionPrefix(
        expectedSession: ChatSession, closedPrefixCount: Int, result: CompactionResult
    ) throws -> CompactionCheckpoint? {
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try Task.checkCancellation()
                guard let current = try loadUnlocked(id: expectedSession.id) else {
                    throw SessionStoreError.sessionNotFound(expectedSession.id)
                }
                guard current == expectedSession, closedPrefixCount > 0,
                      closedPrefixCount <= current.messages.count,
                      !FileManager.default.fileExists(atPath: sessionsDirectory
                        .appendingPathComponent("_archive/\(current.id).json").path) else {
                    throw SessionStoreError.sessionSnapshotConflict(expectedSession.id)
                }
                guard result.compactedCount > 0 else { return nil }
                var closed = current
                closed.messages = Array(current.messages.prefix(closedPrefixCount))
                let checkpoint = try CompactionCheckpoint.makeProjection(
                    sessionID: current.id, sourceTranscriptRevision: current.transcriptRevision,
                    sourceMessages: closed.messages, result: result, lineage: current.lineageIdentity)
                guard checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion
                        || checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion else {
                    throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
                }
                return try saveCompactionCheckpoint(checkpoint, closedSource: closed)
            }
        }
    }

    /// Persist a compaction checkpoint. Schema 1 replaces the transcript;
    /// schema 2 retains it and records a model-request projection. Repeating is
    /// idempotent; reusing its ID for another payload is rejected.
    @discardableResult
    public func saveCompactionCheckpoint(_ checkpoint: CompactionCheckpoint) throws -> CompactionCheckpoint {
        try saveCompactionCheckpoint(checkpoint, closedSource: nil)
    }

    private func saveCompactionCheckpoint(
        _ checkpoint: CompactionCheckpoint, closedSource: ChatSession?
    ) throws -> CompactionCheckpoint {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try withCheckpointFileLock {
                    lastCheckpointPersistenceStage = .entryGeneration
                    lastCheckpointSaveStage = .entryValidation
                    lastCheckpointCandidatePresence = .notObserved
                    lastCheckpointChainPayloadMismatch = .notObserved
                    try validateCheckpointShape(checkpoint)
                    lastCheckpointSaveStage = .existingHistory
                    let previousDigest = try validateCheckpointHistoryBeforeSaveUnlocked(checkpoint)
                    lastCheckpointSaveStage = .existingCheckpointRead
                    if let existing = try loadCheckpointUnlocked(id: checkpoint.checkpointID) {
                        guard existing == checkpoint else {
                            throw SessionStoreError.compactionCheckpointConflict(checkpoint.checkpointID)
                        }
                        guard let session = try loadUnlocked(id: checkpoint.sessionID) else {
                            throw SessionStoreError.sessionNotFound(checkpoint.sessionID)
                        }
                        try validateCheckpointLineage(checkpoint, session: session)
                        guard session.transcriptRevision == checkpoint.sourceTranscriptRevision
                            || session.transcriptRevision == checkpoint.resultTranscriptRevision else {
                            throw SessionStoreError.compactionCheckpointRecoveryRequired(
                                checkpoint.checkpointID
                            )
                        }
                        if checkpoint.retainsCanonicalTranscript,
                           session.transcriptRevision == checkpoint.resultTranscriptRevision {
                            try validateProjectionSource(checkpoint, messages: session.messages,
                                requiresExactTail: false)
                        }
                        let transactionID = try persistCheckpointChainUnlocked(
                            existing,
                            previousDigest: previousDigest,
                            phase: .prepared,
                            expectedSessionGeneration: session.transcriptRevision
                        )
                        if session.transcriptRevision == checkpoint.sourceTranscriptRevision {
                            var repaired = session
                            if checkpoint.schemaVersion == CompactionCheckpoint.currentSchemaVersion {
                                repaired.messages = checkpoint.replacementHistory
                            } else {
                                try validateProjectionSource(checkpoint, messages: closedSource?.messages ?? repaired.messages,
                                    requiresExactTail: true)
                            }
                            repaired.transcriptRevision = checkpoint.resultTranscriptRevision
                            repaired.updatedAt = Date()
                            invalidateSessionRecoveryUnlocked(for: repaired.id)
                            try persistUnlocked(repaired)
                        }
                        _ = try persistCheckpointChainUnlocked(
                            existing,
                            previousDigest: previousDigest,
                            phase: .committed,
                            transactionID: transactionID,
                            expectedSessionGeneration: existing.resultTranscriptRevision
                        )
                        lastCheckpointSaveStage = .complete
                        return existing
                    }

                    guard var session = try loadUnlocked(id: checkpoint.sessionID) else {
                        throw SessionStoreError.sessionNotFound(checkpoint.sessionID)
                    }
                    try validateCheckpointAgainstSession(checkpoint, session: closedSource ?? session)

                    if checkpoint.schemaVersion == CompactionCheckpoint.currentSchemaVersion {
                        session.messages = checkpoint.replacementHistory
                    }
                    session.transcriptRevision = checkpoint.resultTranscriptRevision
                    session.updatedAt = Date()
                    try ensureSecureCheckpointDirectoryUnlocked()
                    let transactionID = try persistCheckpointChainUnlocked(
                        checkpoint,
                        previousDigest: previousDigest,
                        phase: .prepared,
                        expectedSessionGeneration: checkpoint.sourceTranscriptRevision
                    )
                    // Write the checkpoint atomically before the session update so a
                    // restart can recover the replacement after a partial write.
                    do {
                        try persistCheckpointUnlocked(checkpoint)
                        invalidateSessionRecoveryUnlocked(for: session.id)
                        try persistUnlocked(session)
                    } catch {
                        // A recoverable process error (for example, a session
                        // directory becoming read-only) is not a committed
                        // compaction. Remove only the exact sidecar we just
                        // installed; a crash before this handler still leaves the
                        // durable sidecar for restart recovery.
                        removePersistedCheckpointUnlocked(checkpoint)
                        throw error
                    }
                    _ = try persistCheckpointChainUnlocked(
                        checkpoint,
                        previousDigest: previousDigest,
                        phase: .committed,
                        transactionID: transactionID,
                        expectedSessionGeneration: checkpoint.resultTranscriptRevision
                    )
                    lastCheckpointSaveStage = .complete
                    return checkpoint
                }
            }

        }
    }

    /// Display-only checkpoint state, attributed through the session's
    /// validated committed chain rather than unrelated directory entries.
    public enum CompactionCheckpointAvailability: Sendable {
        case absent
        case quarantined
        case available(CompactionCheckpoint)
    }

    public func compactionCheckpointAvailability(
        sessionID: String
    ) throws -> CompactionCheckpointAvailability {
        try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try lock.withLock {
                try withCheckpointFileLock(sessionID: sessionID) {
                    guard let session = try loadUnlocked(id: sessionID), session.id == sessionID else {
                        throw SessionStoreError.sessionNotFound(sessionID)
                    }
                    let selection = try checkpointSelectionUnlocked(session: session)
                    if let checkpoint = selection.checkpoint { return .available(checkpoint) }
                    return selection.latestCommittedRevision == nil ? .absent : .quarantined
                }
            }
        }
    }

    /// Revalidate the selected checkpoint for a user-requested preview.
    /// Returns nil when the selected checkpoint is no longer the current one.
    public func compactionCheckpointForPreview(
        sessionID: String,
        expectedCheckpointID: String,
        expectedResultRevision: UInt64
    ) throws -> CompactionCheckpoint? {
        try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try lock.withLock {
                // Writers acquire the checkpoint lock before creating the
                // directory. There is nothing to preview before that point.
                var directoryInfo = stat()
                if Darwin.lstat(compactionCheckpointsDirectory.path, &directoryInfo) != 0 {
                    guard errno == ENOENT else {
                        throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
                    }
                    return nil
                }
                return try withCheckpointFileLock(sessionID: sessionID, repair: false) {
                    guard let session = try loadUnlocked(id: sessionID), session.id == sessionID else {
                        throw SessionStoreError.sessionNotFound(sessionID)
                    }
                    guard let checkpoint = try checkpointSelectionUnlocked(session: session, repair: false).checkpoint,
                          checkpoint.checkpointID == expectedCheckpointID,
                          checkpoint.resultTranscriptRevision == expectedResultRevision else {
                        return nil
                    }
                    try validateCheckpointForResume(checkpoint, session: session)
                    return checkpoint
                }
            }
        }
    }

    /// Suppress the selected projection and older projections without rewriting
    /// the canonical session or removing checkpoint history.
    public func undoCompactionProjection(
        expectedSession: ChatSession,
        expectedCheckpoint: CompactionCheckpoint
    ) throws {
        let sessionID = expectedSession.id
        try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                try withCheckpointFileLock(sessionID: sessionID, repair: false, exclusive: true) {
                    try Task.checkCancellation()
                    guard let session = try loadUnlocked(id: sessionID), session.id == sessionID else {
                        throw SessionStoreError.sessionNotFound(sessionID)
                    }
                    guard session == expectedSession,
                          session.id == expectedCheckpoint.sessionID,
                          expectedCheckpoint.lineage == session.lineageIdentity,
                          expectedCheckpoint.retainsCanonicalTranscript,
                          !FileManager.default.fileExists(atPath: sessionsDirectory
                            .appendingPathComponent("_archive/\(sessionID).json").path) else {
                        throw SessionStoreError.sessionSnapshotConflict(sessionID)
                    }
                    try validateLineageUnlocked(session)
                    let selection = try checkpointSelectionUnlocked(session: session, repair: false)
                    guard selection.checkpoint == expectedCheckpoint,
                          selection.latestCommittedRevision == expectedCheckpoint.resultTranscriptRevision else {
                        throw SessionStoreError.sessionSnapshotConflict(sessionID)
                    }
                    try validateCheckpointForResume(expectedCheckpoint, session: session)
                    let cutoff = CheckpointProjectionCutoff(
                        schemaVersion: 1, sessionID: sessionID, sessionCreatedAt: session.createdAt,
                        lineage: session.lineageIdentity, checkpointID: expectedCheckpoint.checkpointID,
                        resultRevision: expectedCheckpoint.resultTranscriptRevision,
                        checkpointDigest: expectedCheckpoint.contentDigest
                    )
                    let url = checkpointProjectionCutoffURL(sessionID: sessionID)
                    guard let data = canonicalCheckpointIntegrityData(cutoff) else {
                        throw SessionStoreError.invalidCompactionCheckpoint(expectedCheckpoint.checkpointID)
                    }
                    try Task.checkCancellation()
                    guard try loadUnlocked(id: sessionID) == session else {
                        throw SessionStoreError.sessionSnapshotConflict(sessionID)
                    }
                    guard persistCheckpointSidecarDataUnlocked(data, at: url, id: sessionID,
                            atomicRename: true) else {
                        throw SessionStoreError.sessionCommitUncertain(sessionID)
                    }
                }
            }
        }
    }

    /// Load the newest valid checkpoint for a session, or nil for legacy
    /// sessions that have never been compacted.
    public func loadLatestCompactionCheckpoint(sessionID: String) throws -> CompactionCheckpoint? {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try lock.withLock {
                try withCheckpointFileLock(sessionID: sessionID) {
                    guard let session = try loadUnlocked(id: sessionID), session.id == sessionID else {
                        throw SessionStoreError.sessionNotFound(sessionID)
                    }
                    return try checkpointSelectionUnlocked(session: session).checkpoint
                }
            }

            }()
        }
    }

    /// Recover the model-visible history after a restart. A checkpoint that
    /// still targets the session's current source revision is an orphan from
    /// an incomplete replacement commit: quarantine it and keep the durable
    /// session untouched, so a summary is never replayed twice.
    public func resumeMessages(sessionID: String) throws -> [LLMMessage] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try lock.withLock {
                try withCheckpointFileLock(sessionID: sessionID) {
                    guard let session = try loadUnlocked(id: sessionID), session.id == sessionID else {
                        throw SessionStoreError.sessionNotFound(sessionID)
                    }
                    guard let checkpoint = try checkpointSelectionUnlocked(session: session).checkpoint else {
                        return session.messages
                    }

                    // `saveCompactionCheckpoint` installs the sidecar before
                    // replacing the session file. A process restart after a
                    // failed session commit cannot distinguish that orphan from a
                    // crash window. Keep the old revision authoritative and
                    // quarantine the sidecar instead of replaying its summary.
                    if session.transcriptRevision == checkpoint.sourceTranscriptRevision {
                        do {
                            try validateCheckpointAgainstSession(checkpoint, session: session)
                        } catch {
                            // A source-revision checkpoint whose boundary no
                            // longer matches this session is stale or foreign
                            // state. Keep the session untouched and quarantine the
                            // sidecar so every later restart remains fail-closed
                            // without replaying it.
                            _ = quarantineCheckpointUnlocked(
                                at: checkpointURL(for: checkpoint.checkpointID)
                            )
                            throw error
                        }
                        guard quarantineCheckpointUnlocked(
                            at: checkpointURL(for: checkpoint.checkpointID),
                            expectedCheckpoint: checkpoint
                        ) else {
                            // Do not report a successful cleanup when the
                            // quarantine rename could not be persisted. Leave the
                            // sidecar in place so a later restart can retry it;
                            // the old session remains authoritative either way.
                            throw SessionStoreError.invalidCompactionCheckpoint(
                                checkpoint.checkpointID
                            )
                        }
                        return session.messages
                    }
                    do {
                        try validateCheckpointForResume(checkpoint, session: session)
                    } catch {
                        // A validly encoded checkpoint can still be stale
                        // relative to a newer session transcript. Do not apply it
                        // or leave it to fail repeatedly on every restart.
                        _ = quarantineCheckpointUnlocked(
                            at: checkpointURL(for: checkpoint.checkpointID)
                        )
                        throw error
                    }
                    if checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion
                        || checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion {
                        let committedCount = checkpoint.compactedMessageRange.upperBound
                            + (checkpoint.projectionRecentCount ?? 0)
                        return checkpoint.replacementHistory
                            + Array(session.messages.dropFirst(committedCount))
                    }
                    if checkpoint.schemaVersion == CompactionCheckpoint.projectionSchemaVersion {
                        return [checkpoint.summaryMessage]
                            + Array(session.messages.dropFirst(checkpoint.compactedMessageRange.upperBound))
                    }
                    return session.messages
                }
            }

            }()
        }
    }

    /// Compact a persisted session through the canonical `Compactor` path and
    /// durably install the resulting checkpoint. A short history is a no-op.
    /// By default, histories whose full earlier context cannot be transcribed
    /// without loss are refused before any checkpoint is written. Legacy
    /// summarization must be requested explicitly by its caller.
    @discardableResult
    public func compactSession(
        sessionID: String,
        using compactor: Compactor = Compactor(),
        summarizeUsing provider: (any LLMProvider)? = nil,
        systemPrompt: String? = nil,
        safetyMode: CompactionSafetyMode = .requireVerbatimText
    ) async throws -> CompactionCheckpoint? {
        try Task.checkCancellation()
        guard let session = loadSession(id: sessionID) else {
            throw SessionStoreError.sessionNotFound(sessionID)
        }
        let result = try await compactor.compact(
            messages: session.messages,
            summarizeUsing: provider,
            systemPrompt: systemPrompt,
            safetyMode: safetyMode
        )
        try Task.checkCancellation()
        if result.refusalReason != nil {
            throw SessionStoreError.compactionRefused(sessionID)
        }
        guard result.compactedCount > 0 else { return nil }
        let checkpoint = try CompactionCheckpoint.make(
            sessionID: session.id,
            sourceTranscriptRevision: session.transcriptRevision,
            sourceMessages: session.messages,
            result: result,
            lineage: session.lineageIdentity
        )
        return try saveCompactionCheckpoint(checkpoint)
    }

    /// Load a session by id. Returns `nil` when the session file does not exist.
    public func loadSession(id: String) -> ChatSession? {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            lock.withLock {
                guard let session = try? loadUnlocked(id: id),
                      (try? validateLineageUnlocked(session)) != nil else {
                    return nil
                }
                return session
            }

        }
    }

    /// List all sessions, most recently updated first. Unreadable/corrupt
    /// files are skipped.
    public func listSessions() -> [ChatSession] {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            lock.withLock {
                guard let files = try? PersistenceTransactionFence.children(at: sessionsDirectory, domain: persistenceDomain).filter({ !$0.lastPathComponent.hasPrefix(".") }) else { return [] }
                return files
                    .filter { $0.pathExtension == "json" }
                    .compactMap { url in
                        guard let data = try? PersistenceTransactionFence.data(at: url, domain: persistenceDomain),
                              let session = try? decoder.decode(ChatSession.self, from: data),
                              (try? validateLineageUnlocked(session)) != nil
                        else { return nil }
                        return session
                    }
                    .sorted { $0.updatedAt > $1.updatedAt }
            }

        }
    }

    /// Return direct children from the canonical persisted session graph.
    public func children(of sessionID: String) throws -> [ChatSession] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try lock.withLock {
                guard try loadUnlocked(id: sessionID) != nil else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                return try loadAllSessionsUnlocked()
                    .filter { $0.parentSessionID == sessionID }
                    .sorted(by: Self.lineageOrder)
            }

        }
    }

    /// Return descendants breadth-first with deterministic sibling ordering.
    /// `maxDepth` is one-based; nil means unlimited.
    public func descendants(of sessionID: String, maxDepth: Int? = nil) throws -> [ChatSession] {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try lock.withLock {
                guard try loadUnlocked(id: sessionID) != nil else {
                    throw SessionStoreError.sessionNotFound(sessionID)
                }
                if let maxDepth, maxDepth < 0 {
                    throw SessionStoreError.invalidSessionLineage(sessionID)
                }

                let sessions = try loadAllSessionsUnlocked()
                var byParent: [String: [ChatSession]] = [:]
                for session in sessions {
                    if let parentID = session.parentSessionID {
                        byParent[parentID, default: []].append(session)
                    }
                }
                for key in byParent.keys {
                    byParent[key]?.sort(by: Self.lineageOrder)
                }

                var result: [ChatSession] = []
                var queue: [(session: ChatSession, depth: Int)] = (byParent[sessionID] ?? [])
                    .map { ($0, 1) }
                var visited: Set<String> = [sessionID]
                while !queue.isEmpty {
                    let next = queue.removeFirst()
                    guard visited.insert(next.session.id).inserted else {
                        throw SessionStoreError.sessionLineageCycle(next.session.id)
                    }
                    if maxDepth == nil || next.depth <= maxDepth! {
                        result.append(next.session)
                    }
                    if maxDepth == nil || next.depth < maxDepth! {
                        queue.append(contentsOf: (byParent[next.session.id] ?? []).map {
                            ($0, next.depth + 1)
                        })
                    }
                }
                return result
            }

        }
    }

    /// Legacy deletion entry point. User-facing deletion must use a preview and
    /// a caller-supplied, twice-confirmed intent.
    public func deleteSession(id: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            throw DeletionGateError.firstConfirmationRequired

        }
    }

    public func previewDeletion(id: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        return try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(persistenceDomain)
            return try {
            try lock.withLock {
                guard let session = try loadUnlocked(id: id) else {
                    throw SessionStoreError.sessionNotFound(id)
                }
                return OperationIntent(
                    operationType: .permanentDelete,
                    targetID: id,
                    targetType: "session",
                    targetName: session.title.isEmpty ? "未命名会话" : session.title,
                    affectedCount: 1,
                    impactSummary: "删除此会话及其本地对话记录",
                    reversible: false,
                    scopeID: "session:\(id):active",
                    revision: Self.revision(for: session),
                    fingerprint: Self.fingerprint(for: session),
                    expiresAt: now.addingTimeInterval(ttl)
                )
            }

            }()
        }
    }

    @discardableResult
    public func deleteSession(id: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try DeletionGate.checkLifecycle(intent)
            guard intent.targetID == id, intent.targetType == "session" else {
                throw DeletionGateError.targetChanged
            }
            // SessionStore is the confirmed permanent primitive: it removes
            // the transcript without a trash move. A reversible ("移入回收站")
            // intent must never be executed here, otherwise the exact phrase
            // that guards irreversible deletion could be bypassed by routing
            // a recoverable preview into the permanent path.
            guard !intent.reversible, intent.operationType == .permanentDelete else {
                throw DeletionGateError.invalidIntent
            }
            return try lock.withLock {
                guard let session = try loadUnlocked(id: id) else {
                    throw SessionStoreError.sessionNotFound(id)
                }
                return try DeletionGate.execute(
                    intent,
                    currentRevision: Self.revision(for: session),
                    currentFingerprint: Self.fingerprint(for: session),
                    now: now
                ) { _ in
                    let url = fileURL(for: id)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw SessionStoreError.sessionNotFound(id)
                    }
                    invalidateSessionRecoveryUnlocked(for: id)
                    try FileManager.default.removeItem(at: url)
                }
            }

        }
    }

    /// Internal maintenance cleanup used by retention and persistence repair.
    /// It is intentionally separate from the user deletion entry point.
    public func deleteSessionForMaintenance(id: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                let url = fileURL(for: id)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                invalidateSessionRecoveryUnlocked(for: id)
                try FileManager.default.removeItem(at: url)
            }

        }
    }

    /// Rename a session (updates `title` and `updatedAt`).
    public func renameSession(id: String, title: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try lock.withLock {
                guard var session = try loadUnlocked(id: id) else {
                    throw SessionStoreError.sessionNotFound(id)
                }
                session.title = title
                session.updatedAt = Date()
                invalidateSessionRecoveryUnlocked(for: session.id)
                try persistUnlocked(session)
            }

        }
    }

    // MARK: - Title generation

    /// Build a title from a message: first line, trimmed, truncated to 30
    /// characters with an ellipsis. Falls back to "New Session" for empty text.
    public static func makeTitle(from message: String) -> String {
        let firstLine = message
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "New Session" }
        if firstLine.count > 30 {
            return String(firstLine.prefix(30)) + "…"
        }
        return firstLine
    }

    // MARK: - Internals

    private func fileURL(for id: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(id).json")
    }

    private func checkpointURL(for id: String) -> URL {
        compactionCheckpointsDirectory.appendingPathComponent("\(id).json")
    }

    private func checkpointChainURL(for id: String) -> URL {
        compactionCheckpointsDirectory.appendingPathComponent(".\(id).chain.json")
    }

    private func checkpointChainPreparedURL(for id: String) -> URL {
        compactionCheckpointsDirectory.appendingPathComponent(".\(id).chain.prepared.json")
    }

    private func checkpointChainCandidateURL(
        for id: String,
        phase: CheckpointChainPhase
    ) -> URL {
        switch phase {
        case .prepared:
            return checkpointChainPreparedURL(for: id)
        case .committed:
            return checkpointChainURL(for: id)
        }
    }

    @discardableResult
    private func quarantineCheckpointUnlocked(
        at url: URL,
        expectedCheckpoint: CompactionCheckpoint? = nil
    ) -> Bool {
        lastQuarantineStage = .beforeQuarantineDirectory
        let fileManager = FileManager.default
        var fileInfo = stat()
        guard Darwin.lstat(url.path, &fileInfo) == 0 else { return false }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileInfo.st_uid == getuid(),
              fileInfo.st_nlink == 1,
              (fileInfo.st_mode & mode_t(0o022)) == 0,
              fileInfo.st_size >= 0,
              fileInfo.st_size <= off_t(CompactionCheckpoint.maxPersistedBytes) else {
            return false
        }
        let checkpointID = url.deletingPathExtension().lastPathComponent
        guard let observedData = try? readCheckpointDataUnlocked(
            at: url,
            id: checkpointID,
            quarantineOnFailure: false
        ) else {
            return false
        }
        let observedDigest = SHA256.hash(data: observedData)
            .map { String(format: "%02x", $0) }
            .joined()
        if let expectedCheckpoint {
            guard let data = try? readCheckpointDataUnlocked(
                at: url,
                id: expectedCheckpoint.checkpointID,
                quarantineOnFailure: false
            ), let actual = try? decodeDurableCheckpoint(data, id: expectedCheckpoint.checkpointID),
            actual == expectedCheckpoint else {
                return false
            }
        }
        do {
            try fileManager.createDirectory(
                at: compactionCheckpointsQuarantineDirectory,
                withIntermediateDirectories: true
            )
            lastQuarantineStage = .afterQuarantineDirectory
            // Quarantined checkpoint payloads contain user transcript text.
            // Keep the evidence private even when the process umask is
            // permissive or a directory was created by an older build.
            let quarantineDirectoryDescriptor = try openSecureCheckpointQuarantineDirectoryDescriptor()
            defer { _ = Darwin.close(quarantineDirectoryDescriptor) }
            guard Darwin.fchmod(quarantineDirectoryDescriptor, mode_t(0o700)) == 0 else {
                return false
            }
            var quarantineDirectoryInfo = stat()
            guard Darwin.fstat(quarantineDirectoryDescriptor, &quarantineDirectoryInfo) == 0,
                  (quarantineDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  quarantineDirectoryInfo.st_uid == getuid(),
                  (quarantineDirectoryInfo.st_mode & mode_t(0o022)) == 0 else {
                return false
            }
            lastQuarantineStage = .afterSecureDirectory
            guard quarantineDirectoryWithinLimits(
                additionalEntries: 1,
                additionalBytes: fileInfo.st_size
            ) else {
                return false
            }
            lastQuarantineStage = .afterCapacityCheck
            var currentFileInfo = stat()
            guard Darwin.lstat(url.path, &currentFileInfo) == 0,
                  currentFileInfo.st_dev == fileInfo.st_dev,
                  currentFileInfo.st_ino == fileInfo.st_ino,
                  currentFileInfo.st_size == fileInfo.st_size,
                  currentFileInfo.st_nlink == fileInfo.st_nlink else {
                return false
            }
            guard let currentData = try? readCheckpointDataUnlocked(
                at: url,
                id: checkpointID,
                quarantineOnFailure: false
            ),
                  SHA256.hash(data: currentData)
                    .map({ String(format: "%02x", $0) })
                    .joined() == observedDigest else {
                return false
            }
            if let expectedCheckpoint {
                guard let data = try? readCheckpointDataUnlocked(
                    at: url,
                    id: expectedCheckpoint.checkpointID,
                    quarantineOnFailure: false
                ), let actual = try? decodeDurableCheckpoint(data, id: expectedCheckpoint.checkpointID),
                actual == expectedCheckpoint else {
                    return false
                }
            }
            lastQuarantineStage = .afterSourceReadback
            let name = "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json"
            let transaction = CheckpointQuarantineTransaction(
                checkpointID: url.deletingPathExtension().lastPathComponent,
                sessionID: expectedCheckpoint?.sessionID
                    ?? (try? decoder.decode(CheckpointIdentityEnvelope.self, from: observedData))?.sessionID,
                sessionGeneration: currentSessionGenerationUnlocked(
                    sessionID: expectedCheckpoint?.sessionID
                        ?? (try? decoder.decode(CheckpointIdentityEnvelope.self, from: observedData))?.sessionID
                ),
                sourceTranscriptRevision: expectedCheckpoint?.sourceTranscriptRevision
                    ?? (try? decodeDurableCheckpoint(observedData, id: checkpointID))?.sourceTranscriptRevision,
                resultTranscriptRevision: expectedCheckpoint?.resultTranscriptRevision
                    ?? (try? decodeDurableCheckpoint(observedData, id: checkpointID))?.resultTranscriptRevision,
                contentDigest: expectedCheckpoint?.contentDigest
                    ?? (try? decodeDurableCheckpoint(observedData, id: checkpointID))?.contentDigest,
                payloadDigest: observedDigest,
                sourceDevice: UInt64(fileInfo.st_dev),
                sourceInode: UInt64(fileInfo.st_ino),
                sourceSize: fileInfo.st_size,
                destinationName: name
            )
            guard persistQuarantineTransactionUnlocked(transaction) else {
                return false
            }
            lastQuarantineStage = .afterTransactionPersist
            guard moveCheckpointPayloadUnlocked(
                from: url,
                to: compactionCheckpointsQuarantineDirectory.appendingPathComponent(name),
                expectedDevice: UInt64(fileInfo.st_dev),
                expectedInode: UInt64(fileInfo.st_ino),
                expectedSize: fileInfo.st_size
            ) else {
                return false
            }
            lastQuarantineStage = .afterPayloadMove
            // The rename removes the active sidecar and creates the
            // quarantine receipt. Persist both directory entries before
            // reporting cleanup success; if either fsync fails, the caller
            // must fail closed and retry from whichever file fact survives a
            // restart.
            guard fsyncSecureDirectory(compactionCheckpointsDirectory),
                  fsyncSecureDirectory(compactionCheckpointsQuarantineDirectory) else {
                return false
            }
            lastQuarantineStage = .afterDirectorySync
            let successorDigest = checkpointChainSuccessorDigestUnlocked(
                checkpointID: transaction.checkpointID
            )
            let checkpointPredecessorDigest = checkpointChainPredecessorDigestUnlocked(
                checkpointID: transaction.checkpointID
            )
            let checkpointManifestRootDigest = checkpointChainManifestRootDigestUnlocked(
                checkpointID: transaction.checkpointID
            )
            let predecessor: (epoch: UInt64, digest: String)?
            do {
                predecessor = try cleanupTombstonePredecessorUnlocked(
                    sessionID: transaction.sessionID,
                    excludingCheckpointID: transaction.checkpointID
                )
            } catch {
                return false
            }
            guard transaction.resultTranscriptRevision == nil
                || predecessor == nil
                || transaction.resultTranscriptRevision! > predecessor!.epoch else {
                return false
            }
            guard persistCleanupTombstoneUnlocked(
                CheckpointCleanupTombstone(
                    transaction: transaction,
                    checkpointChainDigest: successorDigest,
                    compactionEpoch: transaction.resultTranscriptRevision,
                    previousRootDigest: predecessor?.digest,
                    checkpointPredecessorDigest: checkpointPredecessorDigest,
                    checkpointManifestRootDigest: checkpointManifestRootDigest
                )
            ) else {
                return false
            }
            guard removeItemIfExists(at: quarantineTransactionURL(for: transaction)) else {
                return false
            }
            guard fsyncSecureDirectory(compactionCheckpointsDirectory) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func moveCheckpointPayloadUnlocked(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedDevice: UInt64,
        expectedInode: UInt64,
        expectedSize: Int64
    ) -> Bool {
        do {
            lastQuarantineStage = .moveDirectoryDescriptor
            let sourceDirectoryDescriptor = try openSecureCheckpointPayloadDirectoryDescriptor(
                at: sourceURL.deletingLastPathComponent()
            )
            defer { _ = Darwin.close(sourceDirectoryDescriptor) }
            let destinationDirectoryDescriptor = try openSecureCheckpointPayloadDirectoryDescriptor(
                at: destinationURL.deletingLastPathComponent()
            )
            defer { _ = Darwin.close(destinationDirectoryDescriptor) }
            lastQuarantineStage = .moveSourceIdentity
            let sourceName = sourceURL.lastPathComponent
            let destinationName = destinationURL.lastPathComponent
            let sourceDescriptor = Darwin.openat(
                sourceDirectoryDescriptor,
                sourceName,
                O_RDONLY | O_NOFOLLOW
            )
            guard sourceDescriptor >= 0 else { return false }
            defer { _ = Darwin.close(sourceDescriptor) }
            var sourceInfo = stat()
            guard Darwin.fstat(sourceDescriptor, &sourceInfo) == 0,
                  (sourceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  sourceInfo.st_uid == getuid(),
                  sourceInfo.st_nlink == 1,
                  (sourceInfo.st_mode & mode_t(0o022)) == 0,
                  UInt64(sourceInfo.st_dev) == expectedDevice,
                  UInt64(sourceInfo.st_ino) == expectedInode,
                  Int64(sourceInfo.st_size) == expectedSize else {
                return false
            }
            lastQuarantineStage = .moveRenameOrDestinationIdentity
            let existingDestination = Darwin.openat(
                destinationDirectoryDescriptor,
                destinationName,
                O_RDONLY | O_NOFOLLOW
            )
            guard existingDestination < 0 else {
                _ = Darwin.close(existingDestination)
                return false
            }
            guard errno == ENOENT,
                  Darwin.renameat(
                      sourceDirectoryDescriptor,
                      sourceName,
                      destinationDirectoryDescriptor,
                      destinationName
                  ) == 0 else {
                return false
            }
            let destinationDescriptor = Darwin.openat(
                destinationDirectoryDescriptor,
                destinationName,
                O_RDONLY | O_NOFOLLOW
            )
            guard destinationDescriptor >= 0 else { return false }
            var destinationInfo = stat()
            let destinationStable = Darwin.fstat(destinationDescriptor, &destinationInfo) == 0
                && (destinationInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                && destinationInfo.st_uid == getuid()
                && destinationInfo.st_nlink == 1
                && (destinationInfo.st_mode & mode_t(0o022)) == 0
                && UInt64(destinationInfo.st_dev) == expectedDevice
                && UInt64(destinationInfo.st_ino) == expectedInode
                && destinationInfo.st_size == sourceInfo.st_size
            _ = Darwin.close(destinationDescriptor)
            guard destinationStable else {
                return false
            }
            lastQuarantineStage = .moveDirectorySync
            guard Darwin.fsync(sourceDirectoryDescriptor) == 0,
                  Darwin.fsync(destinationDirectoryDescriptor) == 0 else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    func openSecureCheckpointPayloadDirectoryDescriptor(at url: URL) throws -> Int32 {
        let candidateDescriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard candidateDescriptor >= 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
        }
        var candidateInfo = stat()
        guard Darwin.fstat(candidateDescriptor, &candidateInfo) == 0,
              (candidateInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              candidateInfo.st_uid == getuid(),
              (candidateInfo.st_mode & mode_t(0o022)) == 0 else {
            _ = Darwin.close(candidateDescriptor)
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
        }

        func matchesTrustedDescriptor(_ trustedDescriptor: Int32) -> Bool {
            defer { _ = Darwin.close(trustedDescriptor) }
            var trustedInfo = stat()
            return Darwin.fstat(trustedDescriptor, &trustedInfo) == 0
                && candidateInfo.st_dev == trustedInfo.st_dev
                && candidateInfo.st_ino == trustedInfo.st_ino
                && candidateInfo.st_mode == trustedInfo.st_mode
                && candidateInfo.st_uid == trustedInfo.st_uid
                && candidateInfo.st_nlink == trustedInfo.st_nlink
        }

        if let trustedDescriptor = try? openSecureCheckpointDirectoryDescriptor(),
           matchesTrustedDescriptor(trustedDescriptor) {
            return candidateDescriptor
        }
        if let trustedDescriptor = try? openSecureCheckpointQuarantineDirectoryDescriptor(),
           matchesTrustedDescriptor(trustedDescriptor) {
            return candidateDescriptor
        }
        _ = Darwin.close(candidateDescriptor)
        throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
    }

    private struct CheckpointCleanupTombstone: Codable, Equatable {
        static let currentSchemaVersion = 1
        static let expectedRecordType = "checkpoint-cleanup-tombstone"

        let schemaVersion: Int
        let recordType: String
        let checkpointID: String
        let sessionID: String?
        let sessionGeneration: UInt64?
        let sourceTranscriptRevision: UInt64?
        let resultTranscriptRevision: UInt64?
        let contentDigest: String?
        let payloadDigest: String
        let sourceDevice: UInt64
        let sourceInode: UInt64
        let sourceSize: Int64
        let destinationName: String
        let checkpointChainDigest: String?
        let compactionEpoch: UInt64?
        let previousRootDigest: String?
        let checkpointPredecessorDigest: String?
        let checkpointManifestRootDigest: String?
        let handoffSeal: String

        init(
            transaction: CheckpointQuarantineTransaction,
            checkpointChainDigest: String?,
            compactionEpoch: UInt64?,
            previousRootDigest: String?,
            checkpointPredecessorDigest: String?,
            checkpointManifestRootDigest: String?
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.recordType = Self.expectedRecordType
            self.checkpointID = transaction.checkpointID
            self.sessionID = transaction.sessionID
            self.sessionGeneration = transaction.sessionGeneration
            self.sourceTranscriptRevision = transaction.sourceTranscriptRevision
            self.resultTranscriptRevision = transaction.resultTranscriptRevision
            self.contentDigest = transaction.contentDigest
            self.payloadDigest = transaction.payloadDigest
            self.sourceDevice = transaction.sourceDevice
            self.sourceInode = transaction.sourceInode
            self.sourceSize = transaction.sourceSize
            self.destinationName = transaction.destinationName
            self.checkpointChainDigest = checkpointChainDigest
            self.compactionEpoch = compactionEpoch
            self.previousRootDigest = previousRootDigest
            self.checkpointPredecessorDigest = checkpointPredecessorDigest
            self.checkpointManifestRootDigest = checkpointManifestRootDigest
            self.handoffSeal = Self.makeHandoffSeal(
                checkpointID: transaction.checkpointID,
                sessionID: transaction.sessionID,
                compactionEpoch: transaction.resultTranscriptRevision,
                payloadDigest: transaction.payloadDigest,
                checkpointChainDigest: checkpointChainDigest,
                checkpointPredecessorDigest: checkpointPredecessorDigest,
                checkpointManifestRootDigest: checkpointManifestRootDigest,
                previousRootDigest: previousRootDigest,
                sourceDevice: transaction.sourceDevice,
                sourceInode: transaction.sourceInode,
                sourceSize: transaction.sourceSize,
                destinationName: transaction.destinationName
            ) ?? ""
        }

        func hasValidHandoffSeal() -> Bool {
            guard let expected = Self.makeHandoffSeal(
                checkpointID: checkpointID,
                sessionID: sessionID,
                compactionEpoch: compactionEpoch,
                payloadDigest: payloadDigest,
                checkpointChainDigest: checkpointChainDigest,
                checkpointPredecessorDigest: checkpointPredecessorDigest,
                checkpointManifestRootDigest: checkpointManifestRootDigest,
                previousRootDigest: previousRootDigest,
                sourceDevice: sourceDevice,
                sourceInode: sourceInode,
                sourceSize: sourceSize,
                destinationName: destinationName
            ) else {
                return false
            }
            return handoffSeal == expected
        }

        private static func makeHandoffSeal(
            checkpointID: String,
            sessionID: String?,
            compactionEpoch: UInt64?,
            payloadDigest: String,
            checkpointChainDigest: String?,
            checkpointPredecessorDigest: String?,
            checkpointManifestRootDigest: String?,
            previousRootDigest: String?,
            sourceDevice: UInt64,
            sourceInode: UInt64,
            sourceSize: Int64,
            destinationName: String
        ) -> String? {
            let payload = CheckpointCleanupHandoffPayload(
                checkpointID: checkpointID,
                sessionID: sessionID,
                compactionEpoch: compactionEpoch,
                payloadDigest: payloadDigest,
                checkpointChainDigest: checkpointChainDigest,
                checkpointPredecessorDigest: checkpointPredecessorDigest,
                checkpointManifestRootDigest: checkpointManifestRootDigest,
                previousRootDigest: previousRootDigest,
                sourceDevice: sourceDevice,
                sourceInode: sourceInode,
                sourceSize: sourceSize,
                destinationName: destinationName
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(payload) else { return nil }
            return SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private struct CheckpointCleanupHandoffPayload: Codable {
        let checkpointID: String
        let sessionID: String?
        let compactionEpoch: UInt64?
        let payloadDigest: String
        let checkpointChainDigest: String?
        let checkpointPredecessorDigest: String?
        let checkpointManifestRootDigest: String?
        let previousRootDigest: String?
        let sourceDevice: UInt64
        let sourceInode: UInt64
        let sourceSize: Int64
        let destinationName: String
    }

    private func cleanupTombstoneURL(for checkpointID: String) -> URL {
        compactionCheckpointsDirectory.appendingPathComponent(
            ".\(checkpointID).cleanup.tombstone.json"
        )
    }

    private func canonicalCleanupTombstoneData(
        _ tombstone: CheckpointCleanupTombstone
    ) throws -> Data {
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        return try canonicalEncoder.encode(tombstone)
    }

    private func checkpointChainSuccessorDigestUnlocked(checkpointID: String) -> String? {
        guard let data = try? readCheckpointChainDataUnlocked(
            at: checkpointChainURL(for: checkpointID),
            id: checkpointID
        ) else {
            return nil
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func checkpointChainPredecessorDigestUnlocked(checkpointID: String) -> String? {
        guard let record = try? loadCheckpointChainRecordUnlocked(
            for: checkpointID,
            phase: .committed
        ) else {
            return nil
        }
        return record.previousDigest
    }

    private func checkpointChainManifestRootDigestUnlocked(checkpointID: String) -> String? {
        guard let record = try? loadCheckpointChainRecordUnlocked(
            for: checkpointID,
            phase: .committed
        ) else {
            return nil
        }
        return record.manifestRootDigest
    }

    private func cleanupTombstonePredecessorUnlocked(
        sessionID: String?,
        excludingCheckpointID: String
    ) throws -> (epoch: UInt64, digest: String)? {
        guard let sessionID else { return nil }
        var directoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsDirectory.path, &directoryInfo) == 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
            }
            return nil
        }
        guard isSecureCheckpointDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            // A predecessor lookup must not turn an unreadable checkpoint
            // directory into a fabricated "no predecessor" result. The
            // caller will retain the transaction for recovery and retry.
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        var candidates: [(epoch: UInt64, digest: String)] = []
        let suffix = ".cleanup.tombstone.json"
        for url in files where url.lastPathComponent.hasPrefix(".") &&
            url.lastPathComponent.hasSuffix(suffix) {
            let markerID = String(url.lastPathComponent.dropFirst().dropLast(suffix.count))
            guard markerID != excludingCheckpointID else { continue }
            guard isCanonicalCheckpointIdentifier(markerID),
                  let data = try readCheckpointChainDataUnlocked(at: url, id: markerID),
                  let tombstone = try? decoder.decode(
                      CheckpointCleanupTombstone.self,
                      from: data
                  ),
                  (try? canonicalCleanupTombstoneData(tombstone)) == data else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
            }
            guard tombstone.sessionID == sessionID else { continue }
            guard let epoch = tombstone.compactionEpoch else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            candidates.append((epoch, digest))
        }
        guard let latest = candidates.max(by: { $0.epoch < $1.epoch }) else {
            return nil
        }
        guard candidates.filter({ $0.epoch == latest.epoch }).count == 1 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        return latest
    }

    private func persistCleanupTombstoneUnlocked(
        _ tombstone: CheckpointCleanupTombstone
    ) -> Bool {
        let url = cleanupTombstoneURL(for: tombstone.checkpointID)
        do {
            if let existing = try readCheckpointChainDataUnlocked(
                at: url,
                id: tombstone.checkpointID
            ) {
                guard let existingTombstone = try? decoder.decode(
                    CheckpointCleanupTombstone.self,
                    from: existing
                ), existingTombstone == tombstone,
                (try? canonicalCleanupTombstoneData(existingTombstone)) == existing else {
                    return false
                }
                return fsyncSecureDirectory(compactionCheckpointsDirectory)
            }
            guard (tombstone.contentDigest == nil && tombstone.resultTranscriptRevision == nil)
                || (tombstone.checkpointChainDigest != nil
                    && tombstone.checkpointManifestRootDigest != nil) else {
                return false
            }
            let data = try canonicalCleanupTombstoneData(tombstone)
            guard data.count <= 64 * 1024 else { return false }
            return persistCheckpointSidecarDataUnlocked(
                data,
                at: url,
                id: tombstone.checkpointID
            )
        } catch {
            return false
        }
    }

    private func validateCleanupTombstonesUnlocked() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: compactionCheckpointsDirectory.path) else {
            return []
        }
        guard isSecureCheckpointDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw SessionStoreError.invalidCompactionCheckpoint("_cleanup-tombstones")
        }
        let suffix = ".cleanup.tombstone.json"
        let tombstoneFiles = files.filter {
            $0.lastPathComponent.hasPrefix(".") &&
                $0.lastPathComponent.hasSuffix(suffix)
        }
        guard tombstoneFiles.count <= Self.maxCheckpointChainRecords else {
            throw SessionStoreError.invalidCompactionCheckpoint("_cleanup-tombstones")
        }
        var totalTombstoneBytes: Int64 = 0
        var validatedTombstones: [(tombstone: CheckpointCleanupTombstone, digest: String)] = []
        for url in tombstoneFiles {
            var markerInfo = stat()
            guard Darwin.lstat(url.path, &markerInfo) == 0,
                  markerInfo.st_size >= 0,
                  markerInfo.st_size <= 64 * 1024,
                  totalTombstoneBytes <= Self.maxCheckpointChainBytes - markerInfo.st_size else {
                throw SessionStoreError.invalidCompactionCheckpoint(
                    url.lastPathComponent
                )
            }
            totalTombstoneBytes += markerInfo.st_size
            let markerID = String(
                url.lastPathComponent.dropFirst().dropLast(suffix.count)
            )
            guard isCanonicalCheckpointIdentifier(markerID),
                  let data = try readCheckpointChainDataUnlocked(at: url, id: markerID),
                  let tombstone = try? decoder.decode(
                      CheckpointCleanupTombstone.self,
                      from: data
                  ),
                  (try? canonicalCleanupTombstoneData(tombstone)) == data,
                  tombstone.schemaVersion == CheckpointCleanupTombstone.currentSchemaVersion,
                  tombstone.recordType == CheckpointCleanupTombstone.expectedRecordType,
                  tombstone.checkpointID == markerID,
                  tombstone.sessionID == nil || CompactionCheckpoint.isSafePathComponent(tombstone.sessionID!),
                  tombstone.sessionID == nil || tombstone.sessionGeneration != nil,
                  tombstone.destinationName.hasPrefix("\(markerID)-"),
                  isCanonicalCheckpointPathComponent(tombstone.destinationName),
                  tombstone.destinationName.hasSuffix(".json"),
                  tombstone.sourceDevice > 0,
                  tombstone.sourceInode > 0,
                  tombstone.sourceSize >= 0,
                  isCanonicalCheckpointDigest(tombstone.payloadDigest),
                  tombstone.contentDigest == nil || isCanonicalCheckpointDigest(tombstone.contentDigest!),
                  tombstone.checkpointChainDigest == nil
                      || isCanonicalCheckpointDigest(tombstone.checkpointChainDigest!),
                  tombstone.checkpointManifestRootDigest == nil
                      || isCanonicalCheckpointDigest(tombstone.checkpointManifestRootDigest!) else {
                throw SessionStoreError.invalidCompactionCheckpoint(markerID)
            }
            guard tombstone.compactionEpoch == tombstone.resultTranscriptRevision,
                  tombstone.compactionEpoch == nil || tombstone.sessionID != nil,
                  tombstone.previousRootDigest == nil
                      || isCanonicalCheckpointDigest(tombstone.previousRootDigest!) else {
                throw SessionStoreError.invalidCompactionCheckpoint(markerID)
            }
            guard isCanonicalCheckpointDigest(tombstone.handoffSeal),
                  tombstone.hasValidHandoffSeal() else {
                throw SessionStoreError.invalidCompactionCheckpoint(markerID)
            }

            if let sessionID = tombstone.sessionID,
               let tombstoneGeneration = tombstone.sessionGeneration,
               let currentGeneration = currentSessionGenerationUnlocked(sessionID: sessionID),
               currentGeneration < tombstoneGeneration {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(markerID)
            }

            var activeInfo = stat()
            guard Darwin.lstat(checkpointURL(for: markerID).path, &activeInfo) != 0 else {
                // A tombstoned path must stay absent. Any recreation, even a
                // byte-identical copy, is a resurrection and is not safe to
                // classify without the original post-unlink identity.
                throw SessionStoreError.compactionCheckpointRecoveryRequired(markerID)
            }
            guard errno == ENOENT else {
                throw SessionStoreError.invalidCompactionCheckpoint(markerID)
            }
            let destinationURL = compactionCheckpointsQuarantineDirectory
                .appendingPathComponent(tombstone.destinationName)
            guard quarantinePayloadIdentityMatches(destinationURL, tombstone: tombstone) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(markerID)
            }
            if tombstone.contentDigest != nil || tombstone.resultTranscriptRevision != nil {
                guard let checkpointChainDigest = tombstone.checkpointChainDigest,
                      let checkpointManifestRootDigest = tombstone.checkpointManifestRootDigest,
                      let chainData = try? readCheckpointChainDataUnlocked(
                          at: checkpointChainURL(for: markerID),
                          id: markerID
                      ),
                      let chainRecord = try? decodeCanonicalCheckpointChainRecord(
                          chainData,
                          checkpointID: markerID
                      ),
                      chainRecord.phase == .committed,
                      chainRecord.sessionID == tombstone.sessionID,
                      chainRecord.sourceTranscriptRevision == tombstone.sourceTranscriptRevision,
                      chainRecord.resultTranscriptRevision == tombstone.resultTranscriptRevision,
                      chainRecord.compactionEpoch == tombstone.compactionEpoch,
                      chainRecord.checkpointDigest == tombstone.contentDigest,
                      chainRecord.previousDigest == tombstone.checkpointPredecessorDigest,
                      chainRecord.manifestRootDigest == checkpointManifestRootDigest,
                      SHA256.hash(data: chainData)
                          .map({ String(format: "%02x", $0) })
                          .joined() == checkpointChainDigest else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(markerID)
                }
            }
            let tombstoneDigest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            validatedTombstones.append((tombstone, tombstoneDigest))
        }

        for (_, entries) in Dictionary(grouping: validatedTombstones, by: {
            $0.tombstone.sessionID ?? ""
        }) {
            let ordered = entries.sorted {
                ($0.tombstone.compactionEpoch ?? 0) < ($1.tombstone.compactionEpoch ?? 0)
            }
            guard ordered.count <= Self.maxCleanupHandoffDepth else {
                throw SessionStoreError.invalidCompactionCheckpoint("_cleanup-tombstone-chain")
            }
            guard ordered.allSatisfy({ $0.tombstone.compactionEpoch != nil }) else {
                guard ordered.count == 1, ordered[0].tombstone.previousRootDigest == nil else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(
                        ordered[0].tombstone.checkpointID
                    )
                }
                continue
            }
            for index in ordered.indices {
                let current = ordered[index]
                if index == ordered.startIndex {
                    guard current.tombstone.previousRootDigest == nil else {
                        throw SessionStoreError.compactionCheckpointRecoveryRequired(
                            current.tombstone.checkpointID
                        )
                    }
                } else {
                    let predecessor = ordered[index - 1]
                    guard current.tombstone.compactionEpoch! > predecessor.tombstone.compactionEpoch!,
                          current.tombstone.previousRootDigest == predecessor.digest else {
                        throw SessionStoreError.compactionCheckpointRecoveryRequired(
                            current.tombstone.checkpointID
                        )
                    }
                }
            }
        }
        return Set(validatedTombstones.map { $0.tombstone.checkpointID })
    }

    private struct CheckpointQuarantineTransaction: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let checkpointID: String
        let sessionID: String?
        let sessionGeneration: UInt64?
        let sourceTranscriptRevision: UInt64?
        let resultTranscriptRevision: UInt64?
        let contentDigest: String?
        let payloadDigest: String
        let sourceDevice: UInt64
        let sourceInode: UInt64
        let sourceSize: Int64
        let destinationName: String

        init(
            checkpointID: String,
            sessionID: String?,
            sessionGeneration: UInt64?,
            sourceTranscriptRevision: UInt64?,
            resultTranscriptRevision: UInt64?,
            contentDigest: String?,
            payloadDigest: String,
            sourceDevice: UInt64,
            sourceInode: UInt64,
            sourceSize: Int64,
            destinationName: String
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.checkpointID = checkpointID
            self.sessionID = sessionID
            self.sessionGeneration = sessionGeneration
            self.sourceTranscriptRevision = sourceTranscriptRevision
            self.resultTranscriptRevision = resultTranscriptRevision
            self.contentDigest = contentDigest
            self.payloadDigest = payloadDigest
            self.sourceDevice = sourceDevice
            self.sourceInode = sourceInode
            self.sourceSize = sourceSize
            self.destinationName = destinationName
        }
    }

    private func quarantineTransactionURL(for transaction: CheckpointQuarantineTransaction) -> URL {
        compactionCheckpointsDirectory.appendingPathComponent(
            ".\(transaction.checkpointID).quarantine.txn.json"
        )
    }

    private func currentSessionGenerationUnlocked(sessionID: String?) -> UInt64? {
        guard let sessionID,
              let session = try? loadUnlocked(id: sessionID) else { return nil }
        return session.transcriptRevision
    }

    private enum CheckpointChainPhase: String, Codable {
        case prepared
        case committed
    }

    private struct CheckpointProjectionCutoff: Codable {
        let schemaVersion: Int
        let sessionID: String
        let sessionCreatedAt: Date
        let lineage: SessionLineageIdentity
        let checkpointID: String
        let resultRevision: UInt64
        let checkpointDigest: String
    }

    private func checkpointProjectionCutoffURL(sessionID: String) -> URL {
        let key = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return compactionCheckpointsDirectory.appendingPathComponent(".\(key).projection-cutoff.json")
    }

    private struct CheckpointChainRecord: Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let phase: CheckpointChainPhase
        let transactionID: String
        let checkpointID: String
        let sessionID: String
        let scopeCheckpointID: String
        let scopeSessionID: String
        let sourceTranscriptRevision: UInt64
        let resultTranscriptRevision: UInt64
        let compactionEpoch: UInt64
        let epochPredecessorDigest: String?
        let manifestRootDigest: String
        let segmentInventory: [String]
        let segmentSizes: [Int]
        let segmentAggregateBytes: Int
        let segmentGenerations: [UInt64]
        let segmentPredecessorDigests: [String?]
        let payloadDigest: String
        let checkpointDigest: String
        let previousDigest: String?

        init(
            checkpoint: CompactionCheckpoint,
            previousDigest: String?,
            phase: CheckpointChainPhase,
            transactionID: String,
            payloadDigest: String,
            manifestRootDigest: String,
            segmentInventory: [String],
            segmentSizes: [Int],
            segmentAggregateBytes: Int,
            segmentGenerations: [UInt64],
            segmentPredecessorDigests: [String?]
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.phase = phase
            self.transactionID = transactionID
            self.checkpointID = checkpoint.checkpointID
            self.sessionID = checkpoint.sessionID
            self.scopeCheckpointID = checkpoint.checkpointID
            self.scopeSessionID = checkpoint.sessionID
            self.sourceTranscriptRevision = checkpoint.sourceTranscriptRevision
            self.resultTranscriptRevision = checkpoint.resultTranscriptRevision
            self.compactionEpoch = checkpoint.resultTranscriptRevision
            self.epochPredecessorDigest = previousDigest
            self.manifestRootDigest = manifestRootDigest
            self.segmentInventory = segmentInventory
            self.segmentSizes = segmentSizes
            self.segmentAggregateBytes = segmentAggregateBytes
            self.segmentGenerations = segmentGenerations
            self.segmentPredecessorDigests = segmentPredecessorDigests
            self.payloadDigest = payloadDigest
            self.checkpointDigest = checkpoint.contentDigest
            self.previousDigest = previousDigest
        }
    }

    private func checkpointChainPayloadMismatchGroup(
        _ lhs: CheckpointChainRecord,
        _ rhs: CheckpointChainRecord
    ) -> CheckpointChainPayloadMismatchGroup {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.checkpointID == rhs.checkpointID,
              lhs.sessionID == rhs.sessionID,
              lhs.scopeCheckpointID == rhs.scopeCheckpointID,
              lhs.scopeSessionID == rhs.scopeSessionID else {
            return .identityOrScope
        }
        guard lhs.sourceTranscriptRevision == rhs.sourceTranscriptRevision,
              lhs.resultTranscriptRevision == rhs.resultTranscriptRevision,
              lhs.compactionEpoch == rhs.compactionEpoch,
              lhs.epochPredecessorDigest == rhs.epochPredecessorDigest else {
            return .revisionsOrEpoch
        }
        guard lhs.manifestRootDigest == rhs.manifestRootDigest else {
            return .manifestRoot
        }
        guard lhs.segmentInventory == rhs.segmentInventory,
              lhs.segmentSizes == rhs.segmentSizes,
              lhs.segmentAggregateBytes == rhs.segmentAggregateBytes else {
            return .manifestInventorySizesOrAggregate
        }
        guard lhs.segmentGenerations == rhs.segmentGenerations,
              lhs.segmentPredecessorDigests == rhs.segmentPredecessorDigests else {
            return .manifestGenerationsOrPredecessors
        }
        guard lhs.payloadDigest == rhs.payloadDigest else { return .payloadDigest }
        guard lhs.checkpointDigest == rhs.checkpointDigest else { return .checkpointDigest }
        guard lhs.previousDigest == rhs.previousDigest else { return .previousDigest }
        return .equal
    }

    private func checkpointChainPayloadMatches(
        _ lhs: CheckpointChainRecord,
        _ rhs: CheckpointChainRecord
    ) -> Bool {
        checkpointChainPayloadMismatchGroup(lhs, rhs) == .equal
    }

    private func isCanonicalCheckpointTransactionID(_ transactionID: String) -> Bool {
        guard let uuid = UUID(uuidString: transactionID) else { return false }
        return uuid.uuidString.lowercased() == transactionID
    }

    private func isCanonicalCheckpointDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64
            && digest.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private func canonicalCheckpointIntegrityData<T: Encodable>(_ value: T) -> Data? {
        let integrityEncoder = JSONEncoder()
        integrityEncoder.outputFormatting = [.sortedKeys]
        return try? integrityEncoder.encode(value)
    }

    private func checkpointPayloadDigest(_ checkpoint: CompactionCheckpoint) -> String? {
        guard let data = canonicalCheckpointIntegrityData(checkpoint) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func checkpointManifest(
        _ checkpoint: CompactionCheckpoint
    ) -> (
        rootDigest: String,
        segmentInventory: [String],
        segmentSizes: [Int],
        aggregateBytes: Int,
        segmentGenerations: [UInt64],
        segmentPredecessorDigests: [String?]
    )? {
        guard checkpoint.replacementHistory.count <= CompactionCheckpoint.maxReplacementHistoryCount else {
            return nil
        }
        var inventory: [String] = []
        var sizes: [Int] = []
        var aggregateBytes = 0
        inventory.reserveCapacity(checkpoint.replacementHistory.count)
        sizes.reserveCapacity(checkpoint.replacementHistory.count)
        for message in checkpoint.replacementHistory {
            guard let data = canonicalCheckpointIntegrityData(message) else { return nil }
            guard data.count <= CompactionCheckpoint.maxMessageContentBytes,
                  aggregateBytes <= CompactionCheckpoint.maxPersistedBytes - data.count else {
                return nil
            }
            aggregateBytes += data.count
            sizes.append(data.count)
            inventory.append(
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
        let generations = Array(
            repeating: checkpoint.resultTranscriptRevision,
            count: inventory.count
        )
        let predecessors = inventory.indices.map { index in
            index == 0 ? nil : inventory[index - 1]
        }
        let manifestPayload = CheckpointManifestPayload(
            segmentInventory: inventory,
            segmentSizes: sizes,
            aggregateBytes: aggregateBytes,
            segmentGenerations: generations,
            segmentPredecessorDigests: predecessors
        )
        guard let manifestData = canonicalCheckpointIntegrityData(manifestPayload) else { return nil }
        let rootDigest = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined()
        return (rootDigest, inventory, sizes, aggregateBytes, generations, predecessors)
    }

    private struct CheckpointManifestPayload: Codable {
        let segmentInventory: [String]
        let segmentSizes: [Int]
        let aggregateBytes: Int
        let segmentGenerations: [UInt64]
        let segmentPredecessorDigests: [String?]
    }

    private func isCanonicalCheckpointManifest(
        rootDigest: String,
        segmentInventory: [String],
        segmentSizes: [Int],
        aggregateBytes: Int,
        segmentGenerations: [UInt64],
        segmentPredecessorDigests: [String?],
        expectedGeneration: UInt64
    ) -> Bool {
        guard segmentInventory.count <= CompactionCheckpoint.maxReplacementHistoryCount,
              segmentSizes.count == segmentInventory.count,
              segmentGenerations.count == segmentInventory.count,
              segmentPredecessorDigests.count == segmentInventory.count,
              segmentGenerations.allSatisfy({ $0 == expectedGeneration }),
              isCanonicalCheckpointDigest(rootDigest),
              segmentInventory.allSatisfy(isCanonicalCheckpointDigest),
              segmentSizes.allSatisfy({
                  $0 >= 0 && $0 <= CompactionCheckpoint.maxMessageContentBytes
              }),
              aggregateBytes >= 0,
              aggregateBytes <= CompactionCheckpoint.maxPersistedBytes,
              segmentSizes.reduce(0, +) == aggregateBytes else {
            return false
        }
        guard segmentPredecessorDigests.isEmpty
                || segmentPredecessorDigests[0] == nil else {
            return false
        }
        for (index, digest) in segmentPredecessorDigests.dropFirst().enumerated() {
            guard let digest,
                  digest == segmentInventory[index],
                  isCanonicalCheckpointDigest(digest) else {
                return false
            }
        }
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.sortedKeys]
        let manifestPayload = CheckpointManifestPayload(
            segmentInventory: segmentInventory,
            segmentSizes: segmentSizes,
            aggregateBytes: aggregateBytes,
            segmentGenerations: segmentGenerations,
            segmentPredecessorDigests: segmentPredecessorDigests
        )
        guard let manifestData = try? manifestEncoder.encode(manifestPayload) else {
            return false
        }
        return SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined() == rootDigest
    }

    private func canonicalCheckpointChainData(
        _ record: CheckpointChainRecord
    ) throws -> Data {
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        return try canonicalEncoder.encode(record)
    }

    private func decodeCanonicalCheckpointChainRecord(
        _ data: Data,
        checkpointID: String
    ) throws -> CheckpointChainRecord {
        guard data.count <= 64 * 1024 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
        }
        let record = try decoder.decode(CheckpointChainRecord.self, from: data)
        guard try canonicalCheckpointChainData(record) == data else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
        }
        return record
    }

    private func validateCheckpointHistoryBeforeSaveUnlocked(
        _ checkpoint: CompactionCheckpoint
    ) throws -> String? {
        let history = try scanCheckpointHistoryUnlocked(sessionID: checkpoint.sessionID)
        if history.contains(where: {
            $0.checkpointID == checkpoint.checkpointID
                && $0.contentDigest != checkpoint.contentDigest
        }) {
            throw SessionStoreError.compactionCheckpointConflict(checkpoint.checkpointID)
        }
        let sameGeneration = history.filter {
            $0.resultTranscriptRevision == checkpoint.resultTranscriptRevision
        }
        guard sameGeneration.allSatisfy({
            $0.checkpointID == checkpoint.checkpointID && $0.contentDigest == checkpoint.contentDigest
        }) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        let previous = history.filter {
            $0.resultTranscriptRevision == checkpoint.sourceTranscriptRevision
        }
        guard previous.count <= 1 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        return previous.first?.contentDigest
    }

    private func scanCheckpointHistoryUnlocked(
        sessionID: String
    ) throws -> [CompactionCheckpoint] {
        guard FileManager.default.fileExists(atPath: compactionCheckpointsDirectory.path) else {
            return []
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        let candidates = files.filter { $0.pathExtension == "json" }
        guard candidates.count <= Self.maxCheckpointChainRecords else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        var totalBytes: Int64 = 0
        var history: [CompactionCheckpoint] = []
        for url in candidates {
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0,
                  info.st_size >= 0,
                  info.st_size <= off_t(CompactionCheckpoint.maxPersistedBytes) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
            }
            totalBytes += Int64(info.st_size)
            guard totalBytes <= Self.maxCheckpointChainBytes else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
            }
            let checkpointID = url.deletingPathExtension().lastPathComponent
            guard isCanonicalCheckpointIdentifier(checkpointID) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
            }
            guard let data = try readCheckpointDataUnlocked(at: url, id: checkpointID),
                  let identity = try? decoder.decode(CheckpointIdentityEnvelope.self, from: data) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
            }
            guard identity.sessionID == sessionID else { continue }
            guard let checkpoint = try? decodeDurableCheckpoint(data, id: checkpointID) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
            }
            do {
                try validateCheckpointShape(checkpoint)
            } catch {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
            }
            history.append(checkpoint)
        }
        return history
    }

    private func loadCheckpointChainRecordUnlocked(
        for checkpointID: String,
        phase: CheckpointChainPhase = .committed
    ) throws -> CheckpointChainRecord? {
        let url = checkpointChainCandidateURL(for: checkpointID, phase: phase)
        guard let data = try readCheckpointChainDataUnlocked(at: url, id: checkpointID) else {
            return nil
        }
        guard let record = try? decodeCanonicalCheckpointChainRecord(data, checkpointID: checkpointID),
              record.phase == phase,
              record.schemaVersion == CheckpointChainRecord.currentSchemaVersion,
              isCanonicalCheckpointTransactionID(record.transactionID),
              record.checkpointID == checkpointID,
              record.scopeCheckpointID == record.checkpointID,
              record.scopeSessionID == record.sessionID,
              CompactionCheckpoint.isSafePathComponent(record.sessionID),
              record.compactionEpoch == record.resultTranscriptRevision,
              record.epochPredecessorDigest == record.previousDigest,
              isCanonicalCheckpointManifest(
                  rootDigest: record.manifestRootDigest,
                  segmentInventory: record.segmentInventory,
                  segmentSizes: record.segmentSizes,
                  aggregateBytes: record.segmentAggregateBytes,
                  segmentGenerations: record.segmentGenerations,
                  segmentPredecessorDigests: record.segmentPredecessorDigests,
                  expectedGeneration: record.compactionEpoch
              ),
              isCanonicalCheckpointDigest(record.payloadDigest),
              isCanonicalCheckpointDigest(record.checkpointDigest),
              record.previousDigest == nil || isCanonicalCheckpointDigest(record.previousDigest!) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
        }
        return record
    }

    private func readCheckpointChainDataUnlocked(at url: URL, id: String) throws -> Data? {
        var fileInfo = stat()
        guard Darwin.lstat(url.path, &fileInfo) == 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(id)
            }
            return nil
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileInfo.st_uid == getuid(),
              fileInfo.st_nlink == 1,
              (fileInfo.st_mode & mode_t(0o022)) == 0,
              fileInfo.st_size >= 0,
              fileInfo.st_size <= 64 * 1024 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(id)
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(id)
        }
        defer { _ = Darwin.close(descriptor) }
        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_dev == fileInfo.st_dev,
              openedInfo.st_ino == fileInfo.st_ino,
              (openedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              openedInfo.st_uid == getuid(),
              openedInfo.st_nlink == 1,
              openedInfo.st_mode == fileInfo.st_mode,
              openedInfo.st_uid == fileInfo.st_uid,
              openedInfo.st_nlink == fileInfo.st_nlink,
              (openedInfo.st_mode & mode_t(0o022)) == 0,
              openedInfo.st_size == fileInfo.st_size,
              openedInfo.st_size <= 64 * 1024 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(id)
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
        guard readAll else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(id)
        }
        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == fileInfo.st_dev,
              finalInfo.st_ino == fileInfo.st_ino,
              (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              finalInfo.st_uid == getuid(),
              finalInfo.st_nlink == 1,
              finalInfo.st_mode == openedInfo.st_mode,
              finalInfo.st_uid == openedInfo.st_uid,
              finalInfo.st_nlink == openedInfo.st_nlink,
              (finalInfo.st_mode & mode_t(0o022)) == 0,
              finalInfo.st_size == openedInfo.st_size else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(id)
        }
        return data
    }

    private func removePreparedCheckpointChainUnlocked(for checkpointID: String) throws {
        let url = checkpointChainPreparedURL(for: checkpointID)
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
            }
            return
        }
        let directoryDescriptor = try openSecureCheckpointDirectoryDescriptor()
        defer { _ = Darwin.close(directoryDescriptor) }
        let name = url.lastPathComponent
        let descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
        }
        var openedInfo = stat()
        let trustedFile = Darwin.fstat(descriptor, &openedInfo) == 0
            && (openedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && openedInfo.st_uid == getuid()
            && openedInfo.st_nlink == 1
            && (openedInfo.st_mode & mode_t(0o022)) == 0
            && openedInfo.st_dev == info.st_dev
            && openedInfo.st_ino == info.st_ino
            && openedInfo.st_size == info.st_size
            && openedInfo.st_mode == info.st_mode
        _ = Darwin.close(descriptor)
        guard trustedFile else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
        }
        guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 || errno == ENOENT,
              fsyncSecureDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpointID)
        }
    }

    private func persistCheckpointChainUnlocked(
        _ checkpoint: CompactionCheckpoint,
        previousDigest: String?,
        phase: CheckpointChainPhase,
        transactionID: String? = nil,
        expectedSessionGeneration: UInt64? = nil
    ) throws -> String {
        lastCheckpointPersistenceStage = .entryGeneration
        if let expectedSessionGeneration {
            guard currentSessionGenerationUnlocked(sessionID: checkpoint.sessionID)
                == expectedSessionGeneration else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
        }
        lastCheckpointPersistenceStage = .payloadOrManifest
        guard let payloadDigest = checkpointPayloadDigest(checkpoint),
              isCanonicalCheckpointDigest(payloadDigest),
              let manifest = checkpointManifest(checkpoint),
              isCanonicalCheckpointManifest(
                  rootDigest: manifest.rootDigest,
                  segmentInventory: manifest.segmentInventory,
                  segmentSizes: manifest.segmentSizes,
                  aggregateBytes: manifest.aggregateBytes,
                  segmentGenerations: manifest.segmentGenerations,
                  segmentPredecessorDigests: manifest.segmentPredecessorDigests,
                  expectedGeneration: checkpoint.resultTranscriptRevision
              ) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        lastCheckpointPersistenceStage = .existingCandidates
        lastCheckpointSaveStage = .committedCandidateRead
        let committed = try loadCheckpointChainRecordUnlocked(
            for: checkpoint.checkpointID,
            phase: .committed
        )
        lastCheckpointSaveStage = .preparedCandidateRead
        let prepared = try loadCheckpointChainRecordUnlocked(
            for: checkpoint.checkpointID,
            phase: .prepared
        )
        switch (committed != nil, prepared != nil) {
        case (false, false):
            lastCheckpointCandidatePresence = .none
        case (true, false):
            lastCheckpointCandidatePresence = .committed
        case (false, true):
            lastCheckpointCandidatePresence = .prepared
        case (true, true):
            lastCheckpointCandidatePresence = .both
        }
        let resolvedTransactionID: String
        lastCheckpointSaveStage = .phaseTransactionSelection
        if let committed {
            guard checkpointChainPayloadMatches(
                committed,
                CheckpointChainRecord(
                    checkpoint: checkpoint,
                    previousDigest: previousDigest,
                    phase: .committed,
                    transactionID: committed.transactionID,
                    payloadDigest: payloadDigest,
                    manifestRootDigest: manifest.rootDigest,
                    segmentInventory: manifest.segmentInventory,
                    segmentSizes: manifest.segmentSizes,
                    segmentAggregateBytes: manifest.aggregateBytes,
                    segmentGenerations: manifest.segmentGenerations,
                    segmentPredecessorDigests: manifest.segmentPredecessorDigests
                )
            ) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
            resolvedTransactionID = committed.transactionID
        } else if let prepared {
            let expectedPrepared = CheckpointChainRecord(
                checkpoint: checkpoint,
                previousDigest: previousDigest,
                phase: .prepared,
                transactionID: prepared.transactionID,
                payloadDigest: payloadDigest,
                manifestRootDigest: manifest.rootDigest,
                segmentInventory: manifest.segmentInventory,
                segmentSizes: manifest.segmentSizes,
                segmentAggregateBytes: manifest.aggregateBytes,
                segmentGenerations: manifest.segmentGenerations,
                segmentPredecessorDigests: manifest.segmentPredecessorDigests
            )
            let payloadMatch = checkpointChainPayloadMismatchGroup(prepared, expectedPrepared)
            guard payloadMatch == .equal else {
                lastCheckpointChainPayloadMismatch = payloadMatch
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
            resolvedTransactionID = prepared.transactionID
        } else {
            guard phase == .prepared else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
            resolvedTransactionID = transactionID ?? UUID().uuidString.lowercased()
            guard isCanonicalCheckpointTransactionID(resolvedTransactionID) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
        }
        if let transactionID,
           (committed != nil || prepared != nil),
           transactionID != resolvedTransactionID {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        lastCheckpointSaveStage = .expectedRecordSelection
        let expected = CheckpointChainRecord(
            checkpoint: checkpoint,
            previousDigest: previousDigest,
            phase: phase,
            transactionID: resolvedTransactionID,
            payloadDigest: payloadDigest,
            manifestRootDigest: manifest.rootDigest,
            segmentInventory: manifest.segmentInventory,
            segmentSizes: manifest.segmentSizes,
            segmentAggregateBytes: manifest.aggregateBytes,
            segmentGenerations: manifest.segmentGenerations,
            segmentPredecessorDigests: manifest.segmentPredecessorDigests
        )
        if phase == .prepared, let committed {
            guard checkpointChainPayloadMatches(expected, committed),
                  committed.transactionID == resolvedTransactionID else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
            if let prepared {
                guard prepared.transactionID == committed.transactionID,
                      checkpointChainPayloadMatches(prepared, expected) else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(
                        checkpoint.checkpointID
                    )
                }
            }
            guard fsyncSecureDirectory(compactionCheckpointsDirectory) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(
                    checkpoint.checkpointID
                )
            }
            return resolvedTransactionID
        }
        if phase == .committed {
            if let prepared {
                guard prepared.transactionID == resolvedTransactionID,
                      checkpointChainPayloadMatches(
                          prepared,
                          CheckpointChainRecord(
                              checkpoint: checkpoint,
                              previousDigest: previousDigest,
                              phase: .prepared,
                              transactionID: resolvedTransactionID,
                              payloadDigest: payloadDigest,
                              manifestRootDigest: manifest.rootDigest,
                              segmentInventory: manifest.segmentInventory,
                              segmentSizes: manifest.segmentSizes,
                              segmentAggregateBytes: manifest.aggregateBytes,
                              segmentGenerations: manifest.segmentGenerations,
                              segmentPredecessorDigests: manifest.segmentPredecessorDigests
                          )
                      ) else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
                }
            } else if committed == nil {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
        }
        if let existing = (phase == .committed ? committed : prepared) {
            guard existing == expected else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
            if let expectedSessionGeneration {
                guard currentSessionGenerationUnlocked(sessionID: checkpoint.sessionID)
                    == expectedSessionGeneration else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
                }
            }
            if phase == .committed {
                try removePreparedCheckpointChainUnlocked(for: checkpoint.checkpointID)
            }
            guard fsyncSecureDirectory(compactionCheckpointsDirectory) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(
                    checkpoint.checkpointID
                )
            }
            return resolvedTransactionID
        }
        lastCheckpointPersistenceStage = .canonicalEncode
        let canonicalData: Data
        do {
            canonicalData = try canonicalCheckpointChainData(expected)
        } catch {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        guard canonicalData.count <= 64 * 1024 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        lastCheckpointPersistenceStage = .directoryDescriptor
        let directoryDescriptor = try openSecureCheckpointDirectoryDescriptor()
        defer { _ = Darwin.close(directoryDescriptor) }
        let temporaryName = "." + checkpoint.checkpointID + ".chain." + UUID().uuidString + ".tmp"
        let destinationName = checkpointChainCandidateURL(
            for: checkpoint.checkpointID,
            phase: phase
        ).lastPathComponent
        lastCheckpointPersistenceStage = .temporaryWriteStatSync
        var descriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
        }
        let wroteAll = canonicalData.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return canonicalData.isEmpty }
            var offset = 0
            while offset < canonicalData.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    canonicalData.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            descriptor = -1
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        var temporaryInfo = stat()
        guard Darwin.fstat(descriptor, &temporaryInfo) == 0,
              (temporaryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              temporaryInfo.st_uid == getuid(),
              temporaryInfo.st_nlink == 1,
              (temporaryInfo.st_mode & mode_t(0o022)) == 0,
              temporaryInfo.st_size == off_t(canonicalData.count) else {
            descriptor = -1
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        descriptor = -1
        lastCheckpointPersistenceStage = .hardLinkInstallIdentity
        if Darwin.linkat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            destinationName,
            0
        ) != 0 {
            let linkError = errno
            guard linkError == EEXIST,
                  let existing = try loadCheckpointChainRecordUnlocked(
                      for: checkpoint.checkpointID,
                      phase: phase
                  ),
                  existing == expected else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
            if phase == .committed {
                try removePreparedCheckpointChainUnlocked(for: checkpoint.checkpointID)
            }
            return resolvedTransactionID
        }
        var installedInfo = stat()
        guard Darwin.lstat(
            checkpointChainCandidateURL(for: checkpoint.checkpointID, phase: phase).path,
            &installedInfo
        ) == 0,
              installedInfo.st_dev == temporaryInfo.st_dev,
              installedInfo.st_ino == temporaryInfo.st_ino,
              (installedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              installedInfo.st_uid == getuid(),
              installedInfo.st_nlink == 2,
              installedInfo.st_mode == temporaryInfo.st_mode,
              installedInfo.st_uid == temporaryInfo.st_uid,
              installedInfo.st_size == temporaryInfo.st_size else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        lastCheckpointPersistenceStage = .directorySyncUnlink
        guard Darwin.unlinkat(directoryDescriptor, temporaryName, 0) == 0,
              fsyncSecureDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        var finalInfo = stat()
        guard Darwin.lstat(
            checkpointChainCandidateURL(for: checkpoint.checkpointID, phase: phase).path,
            &finalInfo
        ) == 0,
              finalInfo.st_dev == temporaryInfo.st_dev,
              finalInfo.st_ino == temporaryInfo.st_ino,
              (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              finalInfo.st_uid == getuid(),
              finalInfo.st_nlink == 1,
              finalInfo.st_mode == temporaryInfo.st_mode,
              finalInfo.st_uid == temporaryInfo.st_uid,
              finalInfo.st_size == temporaryInfo.st_size else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        lastCheckpointPersistenceStage = .canonicalReadback
        guard let installedRecord = try loadCheckpointChainRecordUnlocked(
            for: checkpoint.checkpointID,
            phase: phase
        ), installedRecord == expected else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
        }
        if phase == .committed {
            try removePreparedCheckpointChainUnlocked(for: checkpoint.checkpointID)
        }
        lastCheckpointPersistenceStage = .finalGenerationRecheck
        if let expectedSessionGeneration {
            guard currentSessionGenerationUnlocked(sessionID: checkpoint.sessionID)
                == expectedSessionGeneration else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(checkpoint.checkpointID)
            }
        }
        return resolvedTransactionID
    }

    private func scanCheckpointChainRecordsUnlocked(
        _ checkpoints: [CompactionCheckpoint],
        sessionID: String,
        repair: Bool = true
    ) throws -> [CheckpointChainRecord] {
        lastCheckpointReadStage = .canonicalChainEnumerationAndDecode
        guard FileManager.default.fileExists(atPath: compactionCheckpointsDirectory.path) else {
            return []
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        let chainFiles = files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(".")
                && (name.hasSuffix(".chain.json") || name.hasSuffix(".chain.prepared.json"))
        }
        guard chainFiles.count <= Self.maxCheckpointChainRecords else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        var totalBytes: Int64 = 0
        var candidatesByID: [String: [CheckpointChainRecord]] = [:]
        for url in chainFiles {
            lastCheckpointReadStage = .canonicalChainEnumerationAndDecode
            let name = url.lastPathComponent
            let phase: CheckpointChainPhase
            let recordID: String
            if name.hasSuffix(".chain.prepared.json") {
                phase = .prepared
                recordID = String(name.dropFirst().dropLast(".chain.prepared.json".count))
            } else {
                phase = .committed
                recordID = String(name.dropFirst().dropLast(".chain.json".count))
            }
            guard isCanonicalCheckpointIdentifier(recordID) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
            }
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == getuid(),
                  info.st_nlink == 1,
                  (info.st_mode & mode_t(0o022)) == 0,
                  info.st_size >= 0,
                  info.st_size <= 64 * 1024 else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
            }
            totalBytes += Int64(info.st_size)
            guard totalBytes <= Self.maxCheckpointChainBytes,
                  let data = try? readCheckpointChainDataUnlocked(at: url, id: recordID),
                  let record = try? decodeCanonicalCheckpointChainRecord(data, checkpointID: recordID),
                  record.phase == phase,
                  record.checkpointID == recordID else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
            }
            if record.sessionID != sessionID { continue }
            lastCheckpointReadStage = .recordShapeOrManifest
            guard record.schemaVersion == CheckpointChainRecord.currentSchemaVersion,
                  isCanonicalCheckpointTransactionID(record.transactionID),
                  record.scopeCheckpointID == record.checkpointID,
                  record.scopeSessionID == record.sessionID,
                  CompactionCheckpoint.isSafePathComponent(record.sessionID),
                  record.sourceTranscriptRevision < record.resultTranscriptRevision,
                  record.resultTranscriptRevision == record.sourceTranscriptRevision + 1,
                  record.compactionEpoch == record.resultTranscriptRevision,
                  record.epochPredecessorDigest == record.previousDigest,
                  isCanonicalCheckpointManifest(
                      rootDigest: record.manifestRootDigest,
                      segmentInventory: record.segmentInventory,
                      segmentSizes: record.segmentSizes,
                      aggregateBytes: record.segmentAggregateBytes,
                      segmentGenerations: record.segmentGenerations,
                      segmentPredecessorDigests: record.segmentPredecessorDigests,
                      expectedGeneration: record.compactionEpoch
                  ),
                  isCanonicalCheckpointDigest(record.payloadDigest),
                  isCanonicalCheckpointDigest(record.checkpointDigest),
                  record.previousDigest == nil || isCanonicalCheckpointDigest(record.previousDigest!) else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
            }
            candidatesByID[recordID, default: []].append(record)
        }
        var records: [CheckpointChainRecord] = []
        lastCheckpointReadStage = .preparedCommittedPairing
        for (recordID, candidates) in candidatesByID {
            guard candidates.count <= 2 else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
            }
            let committed = candidates.filter { $0.phase == .committed }
            let prepared = candidates.filter { $0.phase == .prepared }
            guard committed.count <= 1,
                  prepared.count <= 1,
                  let committedRecord = committed.first else {
                // A prepared record without a committed successor is never
                // publishable after restart.
                throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
            }
            if let preparedRecord = prepared.first {
                guard preparedRecord.schemaVersion == committedRecord.schemaVersion,
                      preparedRecord.transactionID == committedRecord.transactionID,
                      preparedRecord.checkpointID == committedRecord.checkpointID,
                      preparedRecord.sessionID == committedRecord.sessionID,
                      preparedRecord.scopeCheckpointID == committedRecord.scopeCheckpointID,
                      preparedRecord.scopeSessionID == committedRecord.scopeSessionID,
                      preparedRecord.sourceTranscriptRevision == committedRecord.sourceTranscriptRevision,
                      preparedRecord.resultTranscriptRevision == committedRecord.resultTranscriptRevision,
                      preparedRecord.compactionEpoch == committedRecord.compactionEpoch,
                      preparedRecord.epochPredecessorDigest == committedRecord.epochPredecessorDigest,
                      preparedRecord.manifestRootDigest == committedRecord.manifestRootDigest,
                      preparedRecord.segmentInventory == committedRecord.segmentInventory,
                      preparedRecord.segmentSizes == committedRecord.segmentSizes,
                      preparedRecord.segmentAggregateBytes == committedRecord.segmentAggregateBytes,
                      preparedRecord.payloadDigest == committedRecord.payloadDigest,
                      preparedRecord.checkpointDigest == committedRecord.checkpointDigest,
                      preparedRecord.previousDigest == committedRecord.previousDigest else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(recordID)
                }
                if repair { try removePreparedCheckpointChainUnlocked(for: recordID) }
            }
            records.append(committedRecord)
        }
        var transactionOwners: [String: String] = [:]
        lastCheckpointReadStage = .transactionOwnership
        for record in records {
            if let owner = transactionOwners[record.transactionID], owner != record.checkpointID {
                // A transaction UUID is a single-install capability. Reusing
                // it for another checkpoint would make a copied/forked
                // successor indistinguishable from the original commit.
                throw SessionStoreError.compactionCheckpointRecoveryRequired(
                    record.checkpointID
                )
            }
            transactionOwners[record.transactionID] = record.checkpointID
        }
        let committedByID = Dictionary(uniqueKeysWithValues: records.map {
            ($0.checkpointID, $0)
        })
        lastCheckpointReadStage = .visibleToCommittedMembership
        for checkpoint in checkpoints {
            guard committedByID[checkpoint.checkpointID] != nil else {
                // A visible checkpoint without a committed chain successor is
                // not safe to publish after a crash window.
                throw SessionStoreError.compactionCheckpointRecoveryRequired(
                    checkpoint.checkpointID
                )
            }
        }
        return records
    }

    private func validateCheckpointChainUnlocked(
        _ checkpoints: [CompactionCheckpoint],
        sessionID: String,
        validatedCleanupTombstoneIDs: Set<String>,
        repair: Bool
    ) throws -> [CheckpointChainRecord] {
        let records = try scanCheckpointChainRecordsUnlocked(checkpoints, sessionID: sessionID, repair: repair)
        let activeByID = Dictionary(uniqueKeysWithValues: checkpoints.map { ($0.checkpointID, $0) })
        var generations: [UInt64: CheckpointChainRecord] = [:]
        for record in records {
            lastCheckpointReadStage = .generationOrPredecessorLinks
            if let previous = generations[record.resultTranscriptRevision],
               previous.checkpointID != record.checkpointID {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(record.checkpointID)
            }
            generations[record.resultTranscriptRevision] = record
            let previousRecords = records.filter {
                $0.resultTranscriptRevision == record.sourceTranscriptRevision
                    && $0.checkpointID != record.checkpointID
            }
            guard previousRecords.count <= 1 else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(record.checkpointID)
            }
            if let expectedPrevious = previousRecords.first {
                guard record.previousDigest == expectedPrevious.checkpointDigest else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(record.checkpointID)
                }
            } else {
                guard record.previousDigest == nil else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(record.checkpointID)
                }
            }
            guard let checkpoint = activeByID[record.checkpointID] else {
                // A committed chain without an active payload is only
                // legitimate after the payload was durably quarantined and
                // its cleanup tombstone was fully validated. A missing
                // payload without that evidence is incomplete state.
                guard validatedCleanupTombstoneIDs.contains(record.checkpointID) else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(
                        record.checkpointID
                    )
                }
                continue
            }
            lastCheckpointReadStage = .activePayloadAgreement
            guard record.sessionID == checkpoint.sessionID,
                  record.scopeCheckpointID == checkpoint.checkpointID,
                  record.scopeSessionID == checkpoint.sessionID,
                  record.sourceTranscriptRevision == checkpoint.sourceTranscriptRevision,
                  record.resultTranscriptRevision == checkpoint.resultTranscriptRevision,
                  record.compactionEpoch == checkpoint.resultTranscriptRevision,
                  record.epochPredecessorDigest == record.previousDigest,
                  let manifest = checkpointManifest(checkpoint),
                  manifest.rootDigest == record.manifestRootDigest,
                  manifest.segmentInventory == record.segmentInventory,
                  manifest.segmentSizes == record.segmentSizes,
                  manifest.aggregateBytes == record.segmentAggregateBytes,
                  manifest.segmentGenerations == record.segmentGenerations,
                  manifest.segmentPredecessorDigests == record.segmentPredecessorDigests,
                  checkpointPayloadDigest(checkpoint) == record.payloadDigest,
                  record.checkpointDigest == checkpoint.contentDigest else {
                throw SessionStoreError.compactionCheckpointRecoveryRequired(record.checkpointID)
            }
            if let previousDigest = record.previousDigest {
                lastCheckpointReadStage = .predecessorReachability
                let activePrevious = checkpoints.contains {
                    $0.resultTranscriptRevision == checkpoint.sourceTranscriptRevision
                        && $0.contentDigest == previousDigest
                }
                let historicalPrevious = records.contains {
                    $0.resultTranscriptRevision == checkpoint.sourceTranscriptRevision
                        && $0.checkpointDigest == previousDigest
                }
                guard activePrevious || historicalPrevious else {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(record.checkpointID)
                }
            }
        }
        lastCheckpointReadStage = .duplicateGeneration
        let duplicateGeneration = Dictionary(grouping: checkpoints, by: { $0.resultTranscriptRevision })
            .first(where: { $0.value.count > 1 })
        if let duplicateGeneration {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(
                duplicateGeneration.value[0].checkpointID
            )
        }
        lastCheckpointReadStage = .complete
        return records
    }

    private func persistQuarantineTransactionUnlocked(
        _ transaction: CheckpointQuarantineTransaction
    ) -> Bool {
        let url = quarantineTransactionURL(for: transaction)
        guard let data = try? encoder.encode(transaction) else { return false }
        return persistCheckpointSidecarDataUnlocked(
            data,
            at: url,
            id: transaction.checkpointID
        )
    }

    private func persistCheckpointSidecarDataUnlocked(
        _ data: Data,
        at url: URL,
        id: String,
        atomicRename: Bool = false
    ) -> Bool {
        guard data.count <= 64 * 1024 else { return false }
        do {
            let directoryDescriptor = try openSecureCheckpointDirectoryDescriptor()
            defer { _ = Darwin.close(directoryDescriptor) }
            let destinationName = url.lastPathComponent
            let temporaryName = "." + destinationName + "." + UUID().uuidString + ".tmp"
            var descriptor = Darwin.openat(
                directoryDescriptor,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { return false }
            defer {
                if descriptor >= 0 { _ = Darwin.close(descriptor) }
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
            let wroteAll = data.withUnsafeBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        data.count - offset
                    )
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard wroteAll,
                  Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
                  Darwin.fsync(descriptor) == 0 else {
                descriptor = -1
                return false
            }
            var temporaryInfo = stat()
            guard Darwin.fstat(descriptor, &temporaryInfo) == 0,
                  (temporaryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  temporaryInfo.st_uid == getuid(),
                  temporaryInfo.st_nlink == 1,
                  (temporaryInfo.st_mode & mode_t(0o022)) == 0,
                  temporaryInfo.st_size == off_t(data.count),
                  Darwin.close(descriptor) == 0 else {
                descriptor = -1
                return false
            }
            descriptor = -1
            // The mutable cutoff is published with one rename under the
            // exclusive lock, including its first installation. Existing
            // metadata stays create-only.
            if atomicRename {
                guard Darwin.renameat(directoryDescriptor, temporaryName,
                                      directoryDescriptor, destinationName) == 0,
                      Darwin.fsync(directoryDescriptor) == 0,
                      try readCheckpointChainDataUnlocked(at: url, id: id) == data else { return false }
                return true
            }
            if Darwin.linkat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                destinationName,
                0
            ) != 0 {
                guard errno == EEXIST,
                      let existing = try? readCheckpointChainDataUnlocked(
                          at: url,
                          id: id
                      ), existing == data else {
                    return false
                }
                guard Darwin.unlinkat(directoryDescriptor, temporaryName, 0) == 0,
                      Darwin.fsync(directoryDescriptor) == 0 else {
                    return false
                }
                return true
            }
            var installedInfo = stat()
            guard Darwin.lstat(url.path, &installedInfo) == 0,
                  installedInfo.st_dev == temporaryInfo.st_dev,
                  installedInfo.st_ino == temporaryInfo.st_ino,
                  (installedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  installedInfo.st_uid == temporaryInfo.st_uid,
                  installedInfo.st_nlink == 2,
                  installedInfo.st_mode == temporaryInfo.st_mode,
                  installedInfo.st_size == temporaryInfo.st_size else {
                return false
            }
            guard Darwin.unlinkat(directoryDescriptor, temporaryName, 0) == 0,
                  Darwin.fsync(directoryDescriptor) == 0 else {
                return false
            }
            var finalInfo = stat()
            guard Darwin.lstat(url.path, &finalInfo) == 0,
                  finalInfo.st_dev == temporaryInfo.st_dev,
                  finalInfo.st_ino == temporaryInfo.st_ino,
                  (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  finalInfo.st_uid == temporaryInfo.st_uid,
                  finalInfo.st_nlink == 1,
                  finalInfo.st_mode == temporaryInfo.st_mode,
                  finalInfo.st_size == temporaryInfo.st_size else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private struct PendingQuarantineRecovery {
        let checkpointID: String
        let sessionID: String
    }

    private func reapQuarantineTransactionsUnlocked(
        readOnlySessionID: String? = nil
    ) throws -> [PendingQuarantineRecovery] {
        var pendingRecoveries: [PendingQuarantineRecovery] = []
        guard FileManager.default.fileExists(atPath: compactionCheckpointsDirectory.path) else {
            return pendingRecoveries
        }
        var directoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsDirectory.path, &directoryInfo) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }
        guard isSecureCheckpointDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }
        var rereadDirectoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsDirectory.path, &rereadDirectoryInfo) == 0,
              rereadDirectoryInfo.st_dev == directoryInfo.st_dev,
              rereadDirectoryInfo.st_ino == directoryInfo.st_ino,
              rereadDirectoryInfo.st_mode == directoryInfo.st_mode,
              rereadDirectoryInfo.st_uid == directoryInfo.st_uid,
              (rereadDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (rereadDirectoryInfo.st_mode & mode_t(0o022)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }
        guard quarantineDirectoryWithinLimits() else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints-quarantine")
        }
        for url in files where url.lastPathComponent.hasPrefix(".") &&
            url.lastPathComponent.hasSuffix(".quarantine.txn.json") {
            let markerID = String(
                url.lastPathComponent.dropFirst()
                    .dropLast(".quarantine.txn.json".count)
            )
            var markerInfo = stat()
            guard isCanonicalCheckpointIdentifier(markerID),
                  Darwin.lstat(url.path, &markerInfo) == 0,
                  (markerInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  markerInfo.st_uid == getuid(),
                  markerInfo.st_nlink == 1,
                  (markerInfo.st_mode & mode_t(0o022)) == 0,
                  markerInfo.st_size >= 0,
                  markerInfo.st_size <= 64 * 1024,
                  let data = try? readCheckpointChainDataUnlocked(
                      at: url,
                      id: markerID
                  ),
                  let transaction = try? decoder.decode(
                      CheckpointQuarantineTransaction.self,
                      from: data
                  ),
                  transaction.schemaVersion == CheckpointQuarantineTransaction.currentSchemaVersion,
                  transaction.checkpointID == markerID,
                  isCanonicalCheckpointIdentifier(transaction.checkpointID),
                  isCanonicalCheckpointPathComponent(transaction.destinationName),
                  transaction.destinationName.hasPrefix("\(transaction.checkpointID)-"),
                  transaction.destinationName.hasSuffix(".json"),
                  transaction.sourceSize >= 0,
                  transaction.sourceInode > 0,
                  transaction.sourceDevice > 0,
                  (transaction.sessionID == nil && transaction.sessionGeneration == nil)
                      || (transaction.sessionID != nil && transaction.sessionGeneration != nil),
                  transaction.payloadDigest.count == 64,
                  transaction.sessionID == nil || CompactionCheckpoint.isSafePathComponent(transaction.sessionID!),
                  transaction.contentDigest == nil || transaction.contentDigest!.count == 64 else {
                throw SessionStoreError.invalidCompactionCheckpoint(markerID)
            }

            if let readOnlySessionID {
                // No recovery in a display read. An unattributed transaction
                // may affect this session, so fail closed on it as well.
                if transaction.sessionID == nil || transaction.sessionID == readOnlySessionID {
                    throw SessionStoreError.compactionCheckpointRecoveryRequired(markerID)
                }
                continue
            }
            let sourceURL = checkpointURL(for: transaction.checkpointID)
            let destinationURL = compactionCheckpointsQuarantineDirectory
                .appendingPathComponent(transaction.destinationName)
            let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
            let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
            guard sourceExists || destinationExists, !(sourceExists && destinationExists) else {
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
            if let sessionID = transaction.sessionID,
               let sessionGeneration = transaction.sessionGeneration,
               currentSessionGenerationUnlocked(sessionID: sessionID) != sessionGeneration {
                pendingRecoveries.append(
                    PendingQuarantineRecovery(
                        checkpointID: transaction.checkpointID,
                        sessionID: sessionID
                    )
                )
                continue
            }
            let payloadURL = sourceExists ? sourceURL : destinationURL
            guard quarantinePayloadMatches(payloadURL, transaction: transaction) else {
                if transaction.sessionID != nil {
                    pendingRecoveries.append(
                        PendingQuarantineRecovery(
                            checkpointID: transaction.checkpointID,
                            sessionID: transaction.sessionID!
                        )
                    )
                    continue
                }
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
            if let sessionID = transaction.sessionID,
               let payload = try? readCheckpointDataUnlocked(
                   at: payloadURL,
                   id: transaction.checkpointID,
                   quarantineOnFailure: false
               ),
               let identity = try? decoder.decode(CheckpointIdentityEnvelope.self, from: payload),
               identity.sessionID != sessionID {
                if transaction.sessionID != nil {
                    pendingRecoveries.append(
                        PendingQuarantineRecovery(
                            checkpointID: transaction.checkpointID,
                            sessionID: transaction.sessionID!
                        )
                    )
                    continue
                }
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
            if let payload = try? readCheckpointDataUnlocked(
                at: payloadURL,
                id: transaction.checkpointID,
                quarantineOnFailure: false
            ),
               let checkpoint = try? decodeDurableCheckpoint(payload, id: transaction.checkpointID) {
                guard transaction.checkpointID == checkpoint.checkpointID,
                      transaction.sessionID == checkpoint.sessionID,
                      transaction.sourceTranscriptRevision == checkpoint.sourceTranscriptRevision,
                      transaction.resultTranscriptRevision == checkpoint.resultTranscriptRevision,
                      transaction.contentDigest == checkpoint.contentDigest else {
                    if transaction.sessionID != nil {
                        pendingRecoveries.append(
                            PendingQuarantineRecovery(
                                checkpointID: transaction.checkpointID,
                                sessionID: transaction.sessionID!
                            )
                        )
                        continue
                    }
                    throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
                }
            } else {
                guard transaction.sourceTranscriptRevision == nil,
                      transaction.resultTranscriptRevision == nil,
                      transaction.contentDigest == nil else {
                    if transaction.sessionID != nil {
                        pendingRecoveries.append(
                            PendingQuarantineRecovery(
                                checkpointID: transaction.checkpointID,
                                sessionID: transaction.sessionID!
                            )
                        )
                        continue
                    }
                    throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
                }
            }

            if sourceExists {
                guard quarantineDirectoryWithinLimits(
                    additionalEntries: 1,
                    additionalBytes: transaction.sourceSize
                ),
                quarantinePayloadMatches(sourceURL, transaction: transaction),
                isSecureCheckpointDirectory(compactionCheckpointsQuarantineDirectory) else {
                    throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
                }
                guard moveCheckpointPayloadUnlocked(
                    from: sourceURL,
                    to: destinationURL,
                    expectedDevice: transaction.sourceDevice,
                    expectedInode: transaction.sourceInode,
                    expectedSize: transaction.sourceSize
                ) else {
                    throw SessionStoreError.invalidCompactionCheckpoint(
                        transaction.checkpointID
                    )
                }
                guard quarantinePayloadMatches(destinationURL, transaction: transaction) else {
                    // The rename may have completed even when the receipt
                    // validation raced with a target replacement or mode
                    // change. Roll back only when the destination still
                    // proves the original inode/digest and remains owned by
                    // this user; otherwise retain destination + marker as a
                    // recoveryRequired pair rather than risking data loss.
                    _ = rollbackQuarantineMoveUnlocked(
                        from: destinationURL,
                        to: sourceURL,
                        transaction: transaction
                    )
                    if let sessionID = transaction.sessionID {
                        pendingRecoveries.append(
                            PendingQuarantineRecovery(
                                checkpointID: transaction.checkpointID,
                                sessionID: sessionID
                            )
                        )
                        continue
                    }
                    throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
                }
                guard fsyncSecureDirectory(compactionCheckpointsDirectory),
                      fsyncSecureDirectory(compactionCheckpointsQuarantineDirectory) else {
                    if let sessionID = transaction.sessionID {
                        pendingRecoveries.append(
                            PendingQuarantineRecovery(
                                checkpointID: transaction.checkpointID,
                                sessionID: sessionID
                            )
                        )
                        continue
                    }
                    throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
                }
            } else {
                // The destination receipt already survived the move. A
                // leftover marker can only be cleanup work after a parent
                // directory fsync/crash boundary; never move or duplicate it.
                guard destinationExists else {
                    throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
                }
            }
            let successorDigest = checkpointChainSuccessorDigestUnlocked(
                checkpointID: transaction.checkpointID
            )
            let checkpointPredecessorDigest = checkpointChainPredecessorDigestUnlocked(
                checkpointID: transaction.checkpointID
            )
            let checkpointManifestRootDigest = checkpointChainManifestRootDigestUnlocked(
                checkpointID: transaction.checkpointID
            )
            let predecessor: (epoch: UInt64, digest: String)?
            do {
                predecessor = try cleanupTombstonePredecessorUnlocked(
                    sessionID: transaction.sessionID,
                    excludingCheckpointID: transaction.checkpointID
                )
            } catch {
                if let sessionID = transaction.sessionID {
                    pendingRecoveries.append(
                        PendingQuarantineRecovery(
                            checkpointID: transaction.checkpointID,
                            sessionID: sessionID
                        )
                    )
                    continue
                }
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
            guard transaction.resultTranscriptRevision == nil
                || predecessor == nil
                || transaction.resultTranscriptRevision! > predecessor!.epoch else {
                if let sessionID = transaction.sessionID {
                    pendingRecoveries.append(
                        PendingQuarantineRecovery(
                            checkpointID: transaction.checkpointID,
                            sessionID: sessionID
                        )
                    )
                    continue
                }
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
            guard persistCleanupTombstoneUnlocked(
                CheckpointCleanupTombstone(
                    transaction: transaction,
                    checkpointChainDigest: successorDigest,
                    compactionEpoch: transaction.resultTranscriptRevision,
                    previousRootDigest: predecessor?.digest,
                    checkpointPredecessorDigest: checkpointPredecessorDigest,
                    checkpointManifestRootDigest: checkpointManifestRootDigest
                )
            ) else {
                if let sessionID = transaction.sessionID {
                    pendingRecoveries.append(
                        PendingQuarantineRecovery(
                            checkpointID: transaction.checkpointID,
                            sessionID: sessionID
                        )
                    )
                    continue
                }
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
            guard removeItemIfExists(at: url),
                  fsyncSecureDirectory(compactionCheckpointsDirectory) else {
                if let sessionID = transaction.sessionID {
                    pendingRecoveries.append(
                        PendingQuarantineRecovery(
                            checkpointID: transaction.checkpointID,
                            sessionID: sessionID
                        )
                    )
                    continue
                }
                throw SessionStoreError.invalidCompactionCheckpoint(transaction.checkpointID)
            }
        }
        return pendingRecoveries
    }

    private func quarantinePayloadMatches(
        _ url: URL,
        transaction: CheckpointQuarantineTransaction
    ) -> Bool {
        guard quarantinePayloadIdentityMatches(url, transaction: transaction) else {
            return false
        }
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(0o022)) == 0 else {
            return false
        }
        return true
    }

    private func quarantinePayloadIdentityMatches(
        _ url: URL,
        transaction: CheckpointQuarantineTransaction
    ) -> Bool {
        quarantinePayloadIdentityMatches(
            url,
            sourceDevice: transaction.sourceDevice,
            sourceInode: transaction.sourceInode,
            sourceSize: transaction.sourceSize,
            payloadDigest: transaction.payloadDigest
        )
    }

    private func quarantinePayloadIdentityMatches(
        _ url: URL,
        tombstone: CheckpointCleanupTombstone
    ) -> Bool {
        quarantinePayloadIdentityMatches(
            url,
            sourceDevice: tombstone.sourceDevice,
            sourceInode: tombstone.sourceInode,
            sourceSize: tombstone.sourceSize,
            payloadDigest: tombstone.payloadDigest
        )
    }

    private func quarantinePayloadIdentityMatches(
        _ url: URL,
        sourceDevice: UInt64,
        sourceInode: UInt64,
        sourceSize: Int64,
        payloadDigest: String
    ) -> Bool {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o022)) == 0,
              info.st_size == off_t(sourceSize),
              UInt64(info.st_dev) == sourceDevice,
              UInt64(info.st_ino) == sourceInode,
              let data = try? readCheckpointDataUnlocked(
                  at: url,
                  id: url.deletingPathExtension().lastPathComponent,
                  quarantineOnFailure: false
              ),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == payloadDigest else {
            return false
        }
        var rereadInfo = stat()
        return Darwin.lstat(url.path, &rereadInfo) == 0
            && rereadInfo.st_dev == info.st_dev
            && rereadInfo.st_ino == info.st_ino
            && rereadInfo.st_size == info.st_size
            && rereadInfo.st_nlink == info.st_nlink
            && rereadInfo.st_uid == info.st_uid
            && rereadInfo.st_mode == info.st_mode
            && (rereadInfo.st_mode & mode_t(0o022)) == 0
            && (rereadInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private func rollbackQuarantineMoveUnlocked(
        from destinationURL: URL,
        to sourceURL: URL,
        transaction: CheckpointQuarantineTransaction
    ) -> Bool {
        guard !FileManager.default.fileExists(atPath: sourceURL.path),
              isSecureCheckpointDirectory(compactionCheckpointsDirectory),
              isSecureCheckpointDirectory(compactionCheckpointsQuarantineDirectory),
              quarantinePayloadIdentityMatches(destinationURL, transaction: transaction) else {
            return false
        }
        return moveCheckpointPayloadUnlocked(
            from: destinationURL,
            to: sourceURL,
            expectedDevice: transaction.sourceDevice,
            expectedInode: transaction.sourceInode,
            expectedSize: transaction.sourceSize
        )
    }

    /// Checkpoint receipt names are filesystem identities, not user-facing
    /// text. Keep them in one canonical ASCII alphabet so normalization
    /// variants, hidden names, and path-like spellings cannot alias a receipt
    /// or escape the checkpoint directory.
    private func isCanonicalCheckpointPathComponent(_ value: String) -> Bool {
        guard CompactionCheckpoint.isSafePathComponent(value),
              value == value.precomposedStringWithCanonicalMapping,
              !value.hasPrefix(".") else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F:
                return true
            default:
                return false
            }
        }
    }

    private func isCanonicalCheckpointIdentifier(_ value: String) -> Bool {
        isCanonicalCheckpointPathComponent(value)
            && value.utf8.count <= Self.maxCanonicalCheckpointIDBytes
    }

    private func quarantineDirectoryWithinLimits(
        additionalEntries: Int = 0,
        additionalBytes: Int64 = 0
    ) -> Bool {
        guard additionalEntries >= 0,
              additionalBytes >= 0,
              FileManager.default.fileExists(atPath: compactionCheckpointsQuarantineDirectory.path) else {
            return additionalEntries == 0 && additionalBytes == 0
        }
        var directoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsQuarantineDirectory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              (directoryInfo.st_mode & mode_t(0o022)) == 0 else {
            return false
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsQuarantineDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ), entries.count <= Self.maxQuarantineEntries - additionalEntries else {
            return false
        }
        var totalBytes: Int64 = 0
        for entry in entries {
            var info = stat()
            guard Darwin.lstat(entry.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == getuid(),
                  info.st_nlink == 1,
                  (info.st_mode & mode_t(0o022)) == 0,
                  info.st_size >= 0,
                  totalBytes <= Self.maxQuarantineBytes - info.st_size else {
                return false
            }
            totalBytes += info.st_size
            var rereadInfo = stat()
            guard Darwin.lstat(entry.path, &rereadInfo) == 0,
                  rereadInfo.st_dev == info.st_dev,
                  rereadInfo.st_ino == info.st_ino,
                  rereadInfo.st_size == info.st_size,
                  rereadInfo.st_nlink == info.st_nlink,
                  rereadInfo.st_uid == info.st_uid,
                  rereadInfo.st_mode == info.st_mode,
                  (rereadInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (rereadInfo.st_mode & mode_t(0o022)) == 0 else {
                return false
            }
        }
        var rereadDirectoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsQuarantineDirectory.path, &rereadDirectoryInfo) == 0,
              rereadDirectoryInfo.st_dev == directoryInfo.st_dev,
              rereadDirectoryInfo.st_ino == directoryInfo.st_ino,
              rereadDirectoryInfo.st_uid == directoryInfo.st_uid,
              rereadDirectoryInfo.st_mode == directoryInfo.st_mode,
              (rereadDirectoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (rereadDirectoryInfo.st_mode & mode_t(0o022)) == 0 else {
            return false
        }
        return totalBytes <= Self.maxQuarantineBytes - additionalBytes
    }

    private func removeItemIfExists(at url: URL) -> Bool {
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0 else {
            return errno == ENOENT
        }
        guard let directoryDescriptor = try? openSecureCheckpointDirectoryDescriptor() else {
            return false
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        let name = url.lastPathComponent
        let descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return false }
        var info = stat()
        let trustedFile = Darwin.fstat(descriptor, &info) == 0
            && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && (info.st_mode & mode_t(0o022)) == 0
            && info.st_dev == pathInfo.st_dev
            && info.st_ino == pathInfo.st_ino
            && info.st_size == pathInfo.st_size
            && info.st_mode == pathInfo.st_mode
        _ = Darwin.close(descriptor)
        guard trustedFile else { return false }
        guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 || errno == ENOENT else {
            return false
        }
        var removedInfo = stat()
        guard Darwin.lstat(url.path, &removedInfo) != 0, errno == ENOENT else {
            return false
        }
        return fsyncSecureDirectory(compactionCheckpointsDirectory)
    }

    private func fsyncSecureDirectory(_ url: URL) -> Bool {
        var expected = stat()
        guard Darwin.lstat(url.path, &expected) == 0,
              (expected.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              expected.st_uid == getuid(),
              (expected.st_mode & mode_t(0o022)) == 0 else {
            return false
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              opened.st_uid == getuid(),
              (opened.st_mode & mode_t(0o022)) == 0 else {
            return false
        }
        return Darwin.fsync(descriptor) == 0
    }

    private func advanceSessionRecoveryGenerationUnlocked(for sessionID: String) -> UInt64 {
        let current = lock.sessionRecoveryGenerations[sessionID] ?? 0
        let next = current == UInt64.max ? 1 : current + 1
        lock.sessionRecoveryGenerations[sessionID] = next
        return next
    }

    func invalidateSessionRecoveryUnlocked(for sessionID: String) {
        _ = advanceSessionRecoveryGenerationUnlocked(for: sessionID)
    }

    private func loadUnlocked(id: String) throws -> ChatSession? {
        let url = fileURL(for: id)
        guard let data = try? PersistenceTransactionFence.data(at: url, domain: persistenceDomain) else {
            return nil
        }
        return try decoder.decode(ChatSession.self, from: data)
    }

    private func persist(_ session: ChatSession) throws {
        try lock.withLock {
            try persistUnlocked(session)
        }
    }

    private func persistUnlocked(_ session: ChatSession) throws {
        let fm = FileManager.default
        try validateLineageUnlocked(session)
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: fileURL(for: session.id), options: .atomic)
    }

    private func loadAllSessionsUnlocked() throws -> [ChatSession] {
        guard let files = try? PersistenceTransactionFence.children(at: sessionsDirectory, domain: persistenceDomain).filter({ !$0.lastPathComponent.hasPrefix(".") }) else { return [] }
        return try files
            .filter { $0.pathExtension == "json" }
            .map { url in
                guard let data = try? PersistenceTransactionFence.data(at: url, domain: persistenceDomain) else {
                    throw SessionStoreError.invalidSessionLineage(
                        url.deletingPathExtension().lastPathComponent
                    )
                }
                do {
                    let session = try decoder.decode(ChatSession.self, from: data)
                    try validateLineageUnlocked(session)
                    return session
                } catch let error as SessionStoreError {
                    throw error
                } catch {
                    throw SessionStoreError.invalidSessionLineage(
                        url.deletingPathExtension().lastPathComponent
                    )
                }
            }
    }

    private func validateLineageUnlocked(_ session: ChatSession) throws {
        guard !session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.lineageVersion == ChatSession.currentLineageVersion,
              !session.rootSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionStoreError.invalidSessionLineage(session.id)
        }

        guard let parentID = session.parentSessionID else {
            guard session.rootSessionID == session.id,
                  session.forkedFromSessionID == nil,
                  session.forkedThroughTranscriptRevision == nil,
                  session.forkedThroughMessageID == nil else {
                throw SessionStoreError.invalidSessionLineage(session.id)
            }
            return
        }

        guard !parentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              parentID != session.id,
              let parent = try loadUnlocked(id: parentID) else {
            throw SessionStoreError.invalidSessionLineage(session.id)
        }
        guard session.rootSessionID == parent.rootSessionID,
              session.forkedFromSessionID == parentID,
              session.projectID == parent.projectID,
              session.workingDirectory == parent.workingDirectory,
              let sourceRevision = session.forkedThroughTranscriptRevision,
              sourceRevision <= parent.transcriptRevision else {
            throw SessionStoreError.invalidSessionLineage(session.id)
        }
        if let messageID = session.forkedThroughMessageID,
           messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SessionStoreError.invalidSessionLineage(session.id)
        }

        var seen: Set<String> = [session.id]
        var cursor: ChatSession? = parent
        while let current = cursor {
            guard seen.insert(current.id).inserted else {
                throw SessionStoreError.sessionLineageCycle(session.id)
            }
            guard current.lineageVersion == ChatSession.currentLineageVersion,
                  !current.rootSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionStoreError.invalidSessionLineage(session.id)
            }
            guard let nextID = current.parentSessionID else {
                guard current.rootSessionID == current.id,
                      current.forkedFromSessionID == nil,
                      current.forkedThroughTranscriptRevision == nil,
                      current.forkedThroughMessageID == nil else {
                    throw SessionStoreError.invalidSessionLineage(session.id)
                }
                break
            }
            guard !nextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let next = try loadUnlocked(id: nextID),
                  current.forkedFromSessionID == nextID,
                  current.rootSessionID == next.rootSessionID,
                  current.projectID == next.projectID,
                  current.workingDirectory == next.workingDirectory else {
                throw SessionStoreError.invalidSessionLineage(session.id)
            }
            cursor = next
        }
    }

    private static func lineageOrder(_ lhs: ChatSession, _ rhs: ChatSession) -> Bool {
        lhs.id < rhs.id
    }

    private func withCheckpointFileLock<Result>(
        sessionID: String? = nil,
        repair: Bool = true,
        exclusive: Bool = false,
        _ body: () throws -> Result
    ) throws -> Result {
        if repair {
            try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
        var sessionsInfo = stat()
        guard Darwin.lstat(sessionsDirectory.path, &sessionsInfo) == 0,
              (sessionsInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              sessionsInfo.st_uid == getuid(),
              (sessionsInfo.st_mode & mode_t(0o022)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints.lock")
        }

        let descriptor = Darwin.open(
            compactionCheckpointLockURL.path,
            (repair ? O_CREAT : 0) | (repair || exclusive ? O_RDWR : O_RDONLY) | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints.lock")
        }
        defer { _ = Darwin.close(descriptor) }
        var lockInfo = stat()
        guard Darwin.fstat(descriptor, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == getuid(),
              lockInfo.st_nlink == 1,
              (lockInfo.st_mode & mode_t(0o022)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints.lock")
        }
        guard (!repair || Darwin.fchmod(descriptor, mode_t(0o600)) == 0),
              flock(descriptor, repair || exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints.lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        if repair { try reapOrphanCheckpointTempsUnlocked() }
        let pendingRecoveries = try reapQuarantineTransactionsUnlocked(
            readOnlySessionID: repair ? nil : sessionID
        )
        if let sessionID,
           let pending = pendingRecoveries.first(where: { $0.sessionID == sessionID }) {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(pending.checkpointID)
        }
        _ = try validateCleanupTombstonesUnlocked()
        return try body()
    }

    private func reapOrphanCheckpointTempsUnlocked() throws {
        var directoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsDirectory.path, &directoryInfo) == 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
            }
            return
        }
        let directoryDescriptor = try openSecureCheckpointDirectoryDescriptor()
        defer { _ = Darwin.close(directoryDescriptor) }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            // An unreadable checkpoint directory is not equivalent to an
            // empty one. Continuing would let resume silently skip durable
            // checkpoint state after an I/O or permission failure.
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }
        var removedAny = false
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp") else { continue }
            let descriptor = Darwin.openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_NOFOLLOW
            )
            guard descriptor >= 0 else { continue }
            var fileInfo = stat()
            let trustedFile = Darwin.fstat(descriptor, &fileInfo) == 0
                && (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                && fileInfo.st_uid == getuid()
                && fileInfo.st_nlink == 1
                && (fileInfo.st_mode & mode_t(0o022)) == 0
            _ = Darwin.close(descriptor)
            guard trustedFile else { continue }
            guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 else {
                guard errno == ENOENT else {
                    throw SessionStoreError.invalidCompactionCheckpoint(
                        "_compaction-checkpoints"
                    )
                }
                continue
            }
            removedAny = true
        }
        if removedAny {
            guard fsyncSecureDirectory(compactionCheckpointsDirectory) else {
                throw SessionStoreError.invalidCompactionCheckpoint(
                    "_compaction-checkpoints"
                )
            }
        }
    }

    private func persistCheckpointUnlocked(_ checkpoint: CompactionCheckpoint) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: compactionCheckpointsDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(checkpoint)
        guard data.count <= CompactionCheckpoint.maxPersistedBytes else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        guard isSecureCheckpointDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        let directoryDescriptor = try openSecureCheckpointDirectoryDescriptor()
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        var directoryInfo = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              (directoryInfo.st_mode & mode_t(0o022)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        let temporaryName = "." + checkpoint.checkpointID + "." + UUID().uuidString + ".tmp"
        let destinationName = checkpoint.checkpointID + ".json"
        var descriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
        }

        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            descriptor = -1
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        var temporaryInfo = stat()
        guard Darwin.fstat(descriptor, &temporaryInfo) == 0,
              (temporaryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              temporaryInfo.st_uid == getuid(),
              temporaryInfo.st_nlink == 1,
              (temporaryInfo.st_mode & mode_t(0o022)) == 0,
              temporaryInfo.st_size == off_t(data.count),
              Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        descriptor = -1

        var installedNew = false
        if Darwin.linkat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            destinationName,
            0
        ) != 0 {
            let linkError = errno
            guard linkError == EEXIST else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
            guard let existing = try readCheckpointDataUnlocked(
                at: checkpointURL(for: checkpoint.checkpointID),
                id: checkpoint.checkpointID
            ), existing == data else {
                throw SessionStoreError.compactionCheckpointConflict(checkpoint.checkpointID)
            }
        } else {
            installedNew = true
            var installedInfo = stat()
            guard Darwin.lstat(
                checkpointURL(for: checkpoint.checkpointID).path,
                &installedInfo
            ) == 0,
                  installedInfo.st_dev == temporaryInfo.st_dev,
                  installedInfo.st_ino == temporaryInfo.st_ino,
                  (installedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  installedInfo.st_uid == temporaryInfo.st_uid,
                  installedInfo.st_nlink == 2,
                  installedInfo.st_mode == temporaryInfo.st_mode,
                  installedInfo.st_size == temporaryInfo.st_size else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
        }
        // Persist the destination link before retiring the temporary name,
        // then persist that unlink as well.  The latter is part of the
        // successful install: a crash between the two fsyncs must leave a
        // bounded, recoverable temp fact rather than an unreported tail.
        guard Darwin.fsync(directoryDescriptor) == 0,
              Darwin.unlinkat(directoryDescriptor, temporaryName, 0) == 0,
              Darwin.fsync(directoryDescriptor) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        if installedNew {
            var finalInfo = stat()
            guard Darwin.lstat(
                checkpointURL(for: checkpoint.checkpointID).path,
                &finalInfo
            ) == 0,
                  finalInfo.st_dev == temporaryInfo.st_dev,
                  finalInfo.st_ino == temporaryInfo.st_ino,
                  (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  finalInfo.st_uid == temporaryInfo.st_uid,
                  finalInfo.st_nlink == 1,
                  finalInfo.st_mode == temporaryInfo.st_mode,
                  finalInfo.st_size == temporaryInfo.st_size else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
        }
    }

    private func ensureSecureCheckpointDirectoryUnlocked() throws {
        try FileManager.default.createDirectory(
            at: compactionCheckpointsDirectory,
            withIntermediateDirectories: true
        )
        let descriptor = try openSecureCheckpointDirectoryDescriptor()
        _ = Darwin.close(descriptor)
    }

    private func removePersistedCheckpointUnlocked(_ checkpoint: CompactionCheckpoint) {
        let url = checkpointURL(for: checkpoint.checkpointID)
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0,
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              pathInfo.st_uid == getuid(),
              pathInfo.st_nlink == 1,
              (pathInfo.st_mode & mode_t(0o022)) == 0 else {
            return
        }
        guard let data = try? readCheckpointDataUnlocked(
            at: url,
            id: checkpoint.checkpointID
        ), let expected = try? encoder.encode(checkpoint), data == expected else {
            return
        }
        guard let directoryDescriptor = try? openSecureCheckpointDirectoryDescriptor() else {
            return
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        let name = url.lastPathComponent
        let descriptor = Darwin.openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o022)) == 0,
              info.st_dev == pathInfo.st_dev,
              info.st_ino == pathInfo.st_ino,
              info.st_mode == pathInfo.st_mode,
              info.st_uid == pathInfo.st_uid,
              info.st_nlink == pathInfo.st_nlink,
              info.st_size == off_t(expected.count) else {
            _ = Darwin.close(descriptor)
            return
        }
        var currentData = Data(count: Int(info.st_size))
        let readAll = currentData.withUnsafeMutableBytes { bytes -> Bool in
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
        var finalInfo = stat()
        let identityStable = Darwin.fstat(descriptor, &finalInfo) == 0
            && finalInfo.st_dev == info.st_dev
            && finalInfo.st_ino == info.st_ino
            && finalInfo.st_size == info.st_size
            && finalInfo.st_nlink == info.st_nlink
            && (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && finalInfo.st_uid == info.st_uid
            && (finalInfo.st_mode & mode_t(0o022)) == 0
        _ = Darwin.close(descriptor)
        guard readAll, identityStable, currentData == expected else { return }
        guard Darwin.unlinkat(directoryDescriptor, name, 0) == 0 || errno == ENOENT else {
            return
        }
        _ = fsyncSecureDirectory(compactionCheckpointsDirectory)
    }

    private func loadCheckpointUnlocked(id: String) throws -> CompactionCheckpoint? {
        let url = checkpointURL(for: id)
        guard let data = try readCheckpointDataUnlocked(at: url, id: id) else { return nil }
        do {
            return try decodeDurableCheckpoint(data, id: id)
        } catch {
            _ = quarantineCheckpointUnlocked(at: url)
            throw SessionStoreError.invalidCompactionCheckpoint(id)
        }
    }

    private func decodeDurableCheckpoint(
        _ data: Data,
        id: String
    ) throws -> CompactionCheckpoint {
        let checkpoint = try decoder.decode(CompactionCheckpoint.self, from: data)
        // LLMToolCall intentionally keeps rawArguments verbatim while its
        // general decoder falls back to an empty dictionary for malformed or
        // non-object JSON. A durable checkpoint must reject that ambiguity so
        // recovery cannot resume a different tool-call dictionary from the
        // same persisted bytes.
        for message in checkpoint.replacementHistory {
            for toolCall in message.toolCalls {
                guard let rawArgumentsData = toolCall.rawArguments.data(using: .utf8),
                      let rawObject = try? JSONSerialization.jsonObject(
                          with: rawArgumentsData
                      ),
                      rawObject is [String: Any],
                      !hasDuplicateTopLevelJSONObjectKeys(rawArgumentsData) else {
                    throw SessionStoreError.invalidCompactionCheckpoint(id)
                }
            }
        }
        return checkpoint
    }

    private func hasDuplicateTopLevelJSONObjectKeys(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0

        func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09
                    || bytes[index] == 0x0a || bytes[index] == 0x0d {
                index += 1
            }
        }

        func readString() -> String? {
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    index += 1
                    return try? JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start..<index])
                    )
                }
                index += 1
            }
            return nil
        }

        func skipValue() {
            var depth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5c {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7b || byte == 0x5b {
                    depth += 1
                } else if byte == 0x7d || byte == 0x5d {
                    if depth == 0 { return }
                    depth -= 1
                } else if depth == 0 && byte == 0x2c {
                    return
                }
                index += 1
            }
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7b else { return false }
        index += 1
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x7d { return false }

        var keys = Set<String>()
        while index < bytes.count {
            guard let key = readString() else { return false }
            guard keys.insert(key).inserted else { return true }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3a else { return false }
            index += 1
            skipWhitespace()
            skipValue()
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x2c {
                index += 1
                skipWhitespace()
                continue
            }
            return false
        }
        return false
    }

    private func checkpointSelectionUnlocked(
        session: ChatSession, repair: Bool = true
    ) throws -> (checkpoint: CompactionCheckpoint?, latestCommittedRevision: UInt64?) {
        let sessionID = session.id
        let fm = FileManager.default
        lastCheckpointReadStage = .checkpointDirectory
        var directoryInfo = stat()
        guard Darwin.lstat(compactionCheckpointsDirectory.path, &directoryInfo) == 0 else {
            guard errno == ENOENT else {
                throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
            }
            return (nil, nil)
        }
        guard isSecureCheckpointDirectory(compactionCheckpointsDirectory) else {
            throw SessionStoreError.invalidCompactionCheckpoint(sessionID)
        }
        lastCheckpointReadStage = .cleanupTombstones
        let validatedCleanupTombstoneIDs = try validateCleanupTombstonesUnlocked()
        lastCheckpointReadStage = .visibleCheckpointEnumerationAndDecode
        guard let files = try? fm.contentsOfDirectory(
            at: compactionCheckpointsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            // The directory was valid when lstat/validation ran, but a
            // concurrent permission, replacement, or I/O failure can still
            // make enumeration fail. That is not an empty checkpoint set:
            // returning nil would let resume silently skip durable state.
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints"
            )
        }

        let checkpoints = try files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CompactionCheckpoint? in
                let checkpointID = url.deletingPathExtension().lastPathComponent
                guard isCanonicalCheckpointIdentifier(checkpointID) else {
                    throw SessionStoreError.invalidCompactionCheckpoint(checkpointID)
                }
                guard let data = try readCheckpointDataUnlocked(at: url, id: checkpointID, quarantineOnFailure: repair) else {
                    throw SessionStoreError.invalidCompactionCheckpoint(checkpointID)
                }
                guard let identity = try? decoder.decode(
                    CheckpointIdentityEnvelope.self,
                    from: data
                ) else {
                    // A truncated sidecar cannot be attributed safely. Quarantine
                    // it and fail closed instead of silently replaying history.
                    if repair { _ = quarantineCheckpointUnlocked(at: url) }
                    throw SessionStoreError.invalidCompactionCheckpoint(checkpointID)
                }
                guard let identitySessionID = identity.sessionID else {
                    // A decoded envelope with no session identity is just as
                    // un-attributable as a truncated one. Do not treat it as
                    // foreign: quarantine it and fail closed.
                    if repair { _ = quarantineCheckpointUnlocked(at: url) }
                    throw SessionStoreError.invalidCompactionCheckpoint(checkpointID)
                }
                guard identitySessionID == sessionID else {
                    // A valid sidecar for another session must not block or be
                    // quarantined during this session's recovery.
                    return nil
                }

                if let encodedCheckpointID = identity.checkpointID,
                   encodedCheckpointID != checkpointID {
                    if repair { _ = quarantineCheckpointUnlocked(at: url) }
                    throw SessionStoreError.invalidCompactionCheckpoint(checkpointID)
                }

                do {
                    let checkpoint = try decodeDurableCheckpoint(data, id: checkpointID)
                    try validateCheckpointShape(checkpoint)
                    return checkpoint
                } catch let error as SessionStoreError {
                    if repair { _ = quarantineCheckpointUnlocked(at: url) }
                    throw error
                } catch {
                    if repair { _ = quarantineCheckpointUnlocked(at: url) }
                    throw SessionStoreError.invalidCompactionCheckpoint(
                        url.deletingPathExtension().lastPathComponent
                    )
                }
            }
            .sorted {
                if $0.resultTranscriptRevision != $1.resultTranscriptRevision {
                    return $0.resultTranscriptRevision > $1.resultTranscriptRevision
                }
                return $0.createdAt > $1.createdAt
            }
        lastCheckpointReadStage = .canonicalChainEnumerationAndDecode
        let records = try validateCheckpointChainUnlocked(
            checkpoints,
            sessionID: sessionID,
            validatedCleanupTombstoneIDs: validatedCleanupTombstoneIDs,
            repair: repair
        )
        let cutoffURL = checkpointProjectionCutoffURL(sessionID: sessionID)
        guard let data = try readCheckpointChainDataUnlocked(at: cutoffURL, id: sessionID) else {
            return (checkpoints.first, records.map(\.resultTranscriptRevision).max())
        }
        guard let cutoff = try? JSONDecoder().decode(CheckpointProjectionCutoff.self, from: data),
              canonicalCheckpointIntegrityData(cutoff) == data,
              cutoff.schemaVersion == 1,
              cutoff.sessionID == sessionID,
              cutoff.sessionCreatedAt == session.createdAt,
              cutoff.lineage == session.lineageIdentity,
              cutoff.resultRevision <= session.transcriptRevision,
              records.contains(where: {
                  $0.checkpointID == cutoff.checkpointID
                      && $0.resultTranscriptRevision == cutoff.resultRevision
                      && $0.checkpointDigest == cutoff.checkpointDigest
              }) else {
            throw SessionStoreError.compactionCheckpointRecoveryRequired(sessionID)
        }
        return (
            checkpoints.first { $0.resultTranscriptRevision > cutoff.resultRevision },
            records.map(\.resultTranscriptRevision).filter { $0 > cutoff.resultRevision }.max()
        )
    }

    private func readCheckpointDataUnlocked(
        at url: URL,
        id: String,
        quarantineOnFailure: Bool = true
    ) throws -> Data? {
        var fileInfo = stat()
        guard Darwin.lstat(url.path, &fileInfo) == 0 else {
            guard errno == ENOENT else {
                if quarantineOnFailure { _ = quarantineCheckpointUnlocked(at: url) }
                throw SessionStoreError.invalidCompactionCheckpoint(id)
            }
            return nil
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileInfo.st_uid == getuid(),
              fileInfo.st_nlink == 1,
              (fileInfo.st_mode & mode_t(0o022)) == 0,
              fileInfo.st_size >= 0,
              fileInfo.st_size <= off_t(CompactionCheckpoint.maxPersistedBytes) else {
            if quarantineOnFailure { _ = quarantineCheckpointUnlocked(at: url) }
            throw SessionStoreError.invalidCompactionCheckpoint(id)
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if quarantineOnFailure { _ = quarantineCheckpointUnlocked(at: url) }
            throw SessionStoreError.invalidCompactionCheckpoint(id)
        }
        defer { _ = Darwin.close(descriptor) }
        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_dev == fileInfo.st_dev,
              openedInfo.st_ino == fileInfo.st_ino,
              (openedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              openedInfo.st_uid == getuid(),
              openedInfo.st_nlink == 1,
              openedInfo.st_mode == fileInfo.st_mode,
              openedInfo.st_uid == fileInfo.st_uid,
              openedInfo.st_nlink == fileInfo.st_nlink,
              (openedInfo.st_mode & mode_t(0o022)) == 0,
              openedInfo.st_size == fileInfo.st_size else {
            if quarantineOnFailure { _ = quarantineCheckpointUnlocked(at: url) }
            throw SessionStoreError.invalidCompactionCheckpoint(id)
        }

        var data = Data(count: Int(openedInfo.st_size))
        let readAll = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard readAll else {
            if quarantineOnFailure { _ = quarantineCheckpointUnlocked(at: url) }
            throw SessionStoreError.invalidCompactionCheckpoint(id)
        }
        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_dev == openedInfo.st_dev,
              finalInfo.st_ino == openedInfo.st_ino,
              (finalInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              finalInfo.st_uid == getuid(),
              finalInfo.st_nlink == 1,
              (finalInfo.st_mode & mode_t(0o022)) == 0,
              finalInfo.st_size == openedInfo.st_size else {
            if quarantineOnFailure { _ = quarantineCheckpointUnlocked(at: url) }
            throw SessionStoreError.invalidCompactionCheckpoint(id)
        }
        return data
    }

    private func openSecureCheckpointDirectoryDescriptor() throws -> Int32 {
        var expected = stat()
        guard Darwin.lstat(compactionCheckpointsDirectory.path, &expected) == 0,
              (expected.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              expected.st_uid == getuid(),
              (expected.st_mode & mode_t(0o022)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
        }
        let descriptor = Darwin.open(
            compactionCheckpointsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              opened.st_uid == getuid(),
              (opened.st_mode & mode_t(0o022)) == 0 else {
            _ = Darwin.close(descriptor)
            throw SessionStoreError.invalidCompactionCheckpoint("_compaction-checkpoints")
        }
        return descriptor
    }

    private func openSecureCheckpointQuarantineDirectoryDescriptor() throws -> Int32 {
        var expected = stat()
        guard Darwin.lstat(compactionCheckpointsQuarantineDirectory.path, &expected) == 0,
              (expected.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              expected.st_uid == getuid(),
              (expected.st_mode & mode_t(0o022)) == 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints-quarantine"
            )
        }
        let descriptor = Darwin.open(
            compactionCheckpointsQuarantineDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints-quarantine"
            )
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              opened.st_uid == getuid(),
              (opened.st_mode & mode_t(0o022)) == 0 else {
            _ = Darwin.close(descriptor)
            throw SessionStoreError.invalidCompactionCheckpoint(
                "_compaction-checkpoints-quarantine"
            )
        }
        return descriptor
    }

    private func isSecureCheckpointDirectory(_ url: URL) -> Bool {
        var directoryInfo = stat()
        guard Darwin.lstat(url.path, &directoryInfo) == 0 else { return false }
        return (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && directoryInfo.st_uid == getuid()
            && (directoryInfo.st_mode & mode_t(0o022)) == 0
    }

    private struct CheckpointIdentityEnvelope: Decodable {
        let sessionID: String?
        let checkpointID: String?
    }

    private func validateCheckpointShape(_ checkpoint: CompactionCheckpoint) throws {
        guard (checkpoint.schemaVersion == CompactionCheckpoint.currentSchemaVersion
                || checkpoint.schemaVersion == CompactionCheckpoint.projectionSchemaVersion
                || checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion
                || checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion),
              isCanonicalCheckpointIdentifier(checkpoint.checkpointID),
              CompactionCheckpoint.isSafePathComponent(checkpoint.sessionID),
              CompactionCheckpoint.isSafePathComponent(checkpoint.compactedThroughMessageID),
              checkpoint.sourceTranscriptRevision < checkpoint.resultTranscriptRevision,
              checkpoint.sourceTranscriptRevision < UInt64.max - 1,
              checkpoint.resultTranscriptRevision < UInt64.max,
              checkpoint.resultTranscriptRevision == checkpoint.sourceTranscriptRevision + 1,
              checkpoint.compactedMessageRange.lowerBound == 0,
              checkpoint.compactedMessageRange.upperBound > checkpoint.compactedMessageRange.lowerBound,
              !checkpoint.replacementHistory.isEmpty,
              checkpoint.replacementHistory.first == checkpoint.summaryMessage,
              checkpoint.hasValidDigest else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
    }

    private func validateCheckpointAgainstSession(
        _ checkpoint: CompactionCheckpoint,
        session: ChatSession
    ) throws {
        guard session.id == checkpoint.sessionID else {
            throw SessionStoreError.compactionCheckpointSessionMismatch(checkpoint.checkpointID)
        }
        try validateCheckpointLineage(checkpoint, session: session)
        guard session.transcriptRevision == checkpoint.sourceTranscriptRevision else {
            throw SessionStoreError.compactionCheckpointRevisionMismatch(checkpoint.checkpointID)
        }
        let range = checkpoint.compactedMessageRange
        guard range.upperBound <= session.messages.count,
              Compactor.stableMessageID(
                session.messages[range.upperBound - 1],
                transcriptIndex: range.upperBound - 1
            ) == checkpoint.compactedThroughMessageID else {
            throw SessionStoreError.compactionCheckpointBoundaryMismatch(checkpoint.checkpointID)
        }
        if checkpoint.retainsCanonicalTranscript {
            try validateProjectionSource(checkpoint, messages: session.messages, requiresExactTail: true)
        }
    }

    private func validateCheckpointLineage(
        _ checkpoint: CompactionCheckpoint,
        session: ChatSession
    ) throws {
        guard checkpoint.lineage == nil || checkpoint.lineage == session.lineageIdentity else {
            throw SessionStoreError.compactionCheckpointLineageMismatch(checkpoint.checkpointID)
        }
    }

    private func validateCheckpointForResume(
        _ checkpoint: CompactionCheckpoint,
        session: ChatSession
    ) throws {
        guard session.id == checkpoint.sessionID else {
            throw SessionStoreError.compactionCheckpointSessionMismatch(checkpoint.checkpointID)
        }
        try validateCheckpointLineage(checkpoint, session: session)
        guard checkpoint.hasValidDigest else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        guard session.transcriptRevision >= checkpoint.resultTranscriptRevision else {
            throw SessionStoreError.compactionCheckpointRevisionMismatch(checkpoint.checkpointID)
        }
        if checkpoint.retainsCanonicalTranscript {
            try validateProjectionSource(checkpoint, messages: session.messages, requiresExactTail: false)
        } else {
            guard session.messages.count >= checkpoint.replacementHistory.count,
                  Array(session.messages.prefix(checkpoint.replacementHistory.count))
                    == checkpoint.replacementHistory else {
                throw SessionStoreError.compactionCheckpointBoundaryMismatch(checkpoint.checkpointID)
            }
        }
    }

    private func validateProjectionSource(
        _ checkpoint: CompactionCheckpoint,
        messages: [LLMMessage],
        requiresExactTail: Bool
    ) throws {
        let count = checkpoint.compactedMessageRange.upperBound
        let recentCount = checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion
            || checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion
            ? (checkpoint.projectionRecentCount ?? -1)
            : checkpoint.replacementHistory.count - 1
        guard recentCount >= 0, recentCount <= checkpoint.replacementHistory.count else {
            throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
        }
        let retained = Array(checkpoint.replacementHistory.suffix(recentCount))
        guard count > 0, count <= messages.count,
              checkpoint.sourcePrefixDigest
                == CompactionCheckpoint.digestOfSourcePrefix(Array(messages.prefix(count))),
              Compactor.stableMessageID(messages[count - 1], transcriptIndex: count - 1)
                == checkpoint.compactedThroughMessageID,
              messages.count - count >= retained.count,
              Array(messages.dropFirst(count).prefix(retained.count)) == retained,
              (!requiresExactTail || messages.count - count == retained.count) else {
            throw SessionStoreError.compactionCheckpointBoundaryMismatch(checkpoint.checkpointID)
        }
        let sourceAtCommit = Array(messages.prefix(count + retained.count))
        if checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion {
            guard let spans = checkpoint.projectionSpans,
                  let facts = checkpoint.retentionFacts,
                  facts.allSatisfy({ $0.source.map {
                      $0.sessionID == checkpoint.sessionID
                          && $0.transcriptRevision == checkpoint.sourceTranscriptRevision
                          && $0.matchesTranscript(sourceAtCommit)
                  } ?? true }),
                  Compactor.isSourceAnchoredProjection(from: sourceAtCommit,
                      to: checkpoint.replacementHistory, spans: spans,
                      keepRecentMessages: recentCount, requiredFacts: facts) else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
        } else if checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion {
            // The summary is model-written and cannot be reconstructed from the
            // source. The prefix digest and exact tail above are its proof; the
            // store facts are verified against the source like schema 3's.
            guard let facts = checkpoint.retentionFacts,
                  facts.allSatisfy({ $0.source.map {
                      $0.sessionID == checkpoint.sessionID
                          && $0.transcriptRevision == checkpoint.sourceTranscriptRevision
                          && $0.matchesTranscript(sourceAtCommit)
                  } ?? true }),
                  let summary = checkpoint.replacementHistory.first, summary.role == .user,
                  summary.content.contains("<context-summary>"),
                  summary.content.contains("</context-summary>") else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
            let background = CompactionFactCapture.backgroundMessage(facts)
            guard checkpoint.replacementHistory.count == 1 + (background == nil ? 0 : 1) + recentCount,
                  background == nil || checkpoint.replacementHistory[1] == background else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
        } else {
            guard Compactor.isVerifiedLosslessProjection(from: sourceAtCommit,
                    compactedCount: count, messages: checkpoint.replacementHistory),
                  Compactor.hasMaterialRequestReduction(
                    from: sourceAtCommit, to: checkpoint.replacementHistory
                  ) else {
                throw SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)
            }
        }
    }

    private static func revision(for session: ChatSession) -> Int {
        Int((session.updatedAt.timeIntervalSince1970 * 1_000_000).rounded())
    }

    private static func fingerprint(for session: ChatSession) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(session)) ?? Data()
        return DeletionGate.fingerprint(data)
    }
}

// MARK: - Errors

public enum SessionStoreError: Error, Equatable, Sendable {
    case sessionNotFound(String)
    case sessionAlreadyExists(String)
    case sessionSnapshotConflict(String)
    case sessionTargetMismatch(String)
    case sessionCommitUncertain(String)
    case invalidSessionLineage(String)
    case sessionLineageCycle(String)
    case compactionCheckpointConflict(String)
    case invalidCompactionCheckpoint(String)
    case compactionCheckpointRecoveryRequired(String)
    case compactionCheckpointSessionMismatch(String)
    case compactionCheckpointLineageMismatch(String)
    case compactionCheckpointRevisionMismatch(String)
    case compactionCheckpointBoundaryMismatch(String)
    case compactionRefused(String)
}

// MARK: - Lock helper

extension NSLock {
    /// Run `body` while holding the lock.
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
