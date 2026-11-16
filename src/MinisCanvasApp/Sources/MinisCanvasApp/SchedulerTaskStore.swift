import Foundation
import SwiftUI
import Darwin
import CryptoKit
import MinisCore

// MARK: - 波4 定时任务管理：SchedulerTaskStore
//
// cron/scheduler 能力参照 OpenMinis；本工程的任务存储与执行记录支持：用户可定义「定时任务」（名称 + 分钟级 cron
// 表达式 + 启用状态 + 命令或提示词），UserDefaults 持久化 + CRUD + 启用开关 + 基础校验。
// 调度执行由同模块的 SchedulerTaskRuntime 统一消费，避免设置页 Store 自己持有第二个 timer。

enum SchedulerSourceAnchor {
    /// Version 2 binds a one-based user ordinal and its complete canonical
    /// prefix, so repeated messages at different positions cannot alias.
    static func digest(sessionID: String, projectID: String, userOrdinal: Int,
                       messages: [LLMMessage]) -> String? {
        guard userOrdinal > 0 else { return nil }
        var seen = 0
        guard let index = messages.indices.first(where: { index in
            if messages[index].role == .user { seen += 1 }
            return messages[index].role == .user && seen == userOrdinal
        }) else { return nil }
        struct Payload: Encodable {
            let version: Int
            let sessionID: String
            let projectID: String
            let userOrdinal: Int
            let prefix: [LLMMessage]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(version: 2, sessionID: sessionID,
            projectID: projectID, userOrdinal: userOrdinal, prefix: Array(messages.prefix(index + 1)))) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 从会话预填定时任务目标的三项（会话 UUID、项目 ID、用户轮次序号）。
struct SchedulerTaskTargetPrefill: Equatable, Sendable {
    let sessionID: UUID
    let projectID: String
    let turnID: Int
}

/// 会话右键菜单与设置页「定时任务」新建表单之间的一次性预填传递。
@MainActor
@Observable
final class SchedulerTaskPrefillInbox {
    static let shared = SchedulerTaskPrefillInbox()
    private init() {}
    var pending: SchedulerTaskTargetPrefill?
}

// MARK: - 任务模型

/// 一条定时任务。
struct SchedulerTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 任务名称（用户可读）。
    var name: String
    /// 分钟级 cron 表达式（5 字段：分 时 日 月 周）。
    var cronExpression: String
    /// Authorized wall-clock zone. Legacy rows without this field require a
    /// fresh preview/confirmation before they can dispatch.
    var timeZoneIdentifier: String?
    /// 启用开关（false = 暂停，不参与调度）。
    var isEnabled: Bool
    /// 命令或提示词（调度触发时执行的内容）。
    var command: String
    /// 创建时间（列表排序用）。
    var createdAt: Date
    /// Immutable schedule definition version captured by each occurrence.
    var version: Int
    /// Durable control revision; pause/resume CAS must reject pre-toggle and ABA snapshots.
    /// Separate from the definition/authorization version used by already leased effects.
    var enablementRevision: Int
    /// Authorization is explicit; enabling a task never auto-approves it.
    var isAuthorized: Bool
    /// Authorization epoch is advanced only when an edit changes the
    /// execution scope (or an explicit revocation occurs).
    var authorizationVersion: Int
    /// Every occurrence at or below this authorization version was revoked.
    /// A later explicit authorization cannot revive its pinned grant.
    var revokedAuthorizationThroughVersion: Int
    /// Durable authorization context; revocation/expiry must fence dispatch.
    var authorizationActorID: String
    var authorizationScopeID: String
    var authorizationPolicyRevision: String
    var authorizationExpiresAt: Date?
    var authorizationRevoked: Bool
    /// Tombstone retained so old occurrences remain auditable after deletion.
    var isDeleted: Bool
    /// Explicit Composer destination. Missing target data is never inferred
    /// from the currently focused chat session.
    var targetSessionID: UUID?
    var targetProjectID: String?
    var targetTurnID: Int?
    /// 2 means an explicitly confirmed fixed source anchor, not an execution turn.
    var sourceAnchorVersion: Int
    var sourceAnchorDigest: String?

    var hasValidTarget: Bool {
        guard targetSessionID != nil,
              let targetProjectID,
              let targetTurnID,
              targetTurnID > 0 else { return false }
        return !targetProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        id: UUID = UUID(),
        name: String,
        cronExpression: String,
        timeZoneIdentifier: String? = TimeZone.current.identifier,
        isEnabled: Bool = true,
        command: String,
        createdAt: Date = Date(),
        version: Int = 1,
        enablementRevision: Int = 1,
        isAuthorized: Bool = false,
        authorizationVersion: Int = 1,
        revokedAuthorizationThroughVersion: Int = 0,
        authorizationActorID: String = "local-user",
        authorizationScopeID: String = "scheduler",
        authorizationPolicyRevision: String = "scheduler-policy-v1",
        authorizationExpiresAt: Date? = nil,
        authorizationRevoked: Bool = false,
        isDeleted: Bool = false,
        targetSessionID: UUID? = nil,
        targetProjectID: String? = nil,
        targetTurnID: Int? = nil,
        sourceAnchorVersion: Int = 2,
        sourceAnchorDigest: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cronExpression = cronExpression
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isEnabled = isEnabled
        self.command = command
        self.createdAt = createdAt
        self.version = max(1, version)
        self.enablementRevision = enablementRevision
        self.isAuthorized = isAuthorized
        self.authorizationVersion = max(1, authorizationVersion)
        self.revokedAuthorizationThroughVersion = revokedAuthorizationThroughVersion
        self.authorizationActorID = authorizationActorID
        self.authorizationScopeID = authorizationScopeID
        self.authorizationPolicyRevision = authorizationPolicyRevision
        self.authorizationExpiresAt = authorizationExpiresAt
        self.authorizationRevoked = authorizationRevoked
        self.isDeleted = isDeleted
        self.targetSessionID = targetSessionID
        self.targetProjectID = targetProjectID
        self.targetTurnID = targetTurnID
        self.sourceAnchorVersion = sourceAnchorVersion
        self.sourceAnchorDigest = sourceAnchorDigest
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cronExpression, timeZoneIdentifier, isEnabled, command, createdAt, version, enablementRevision, isAuthorized,
             authorizationVersion, revokedAuthorizationThroughVersion, authorizationActorID, authorizationScopeID, authorizationPolicyRevision,
             authorizationExpiresAt, authorizationRevoked, isDeleted,
             targetSessionID, targetProjectID, targetTurnID, sourceAnchorVersion, sourceAnchorDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Only a missing legacy key defaults to 1. Present null, non-integer,
        // or non-positive revisions cannot become a fresh control identity.
        let enablementRevision: Int
        if container.contains(.enablementRevision) {
            enablementRevision = try container.decode(Int.self, forKey: .enablementRevision)
        } else {
            enablementRevision = 1
        }
        guard enablementRevision > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .enablementRevision, in: container,
                debugDescription: "enablement revision must be positive"
            )
        }
        let authorizationVersion = try container.decodeIfPresent(Int.self, forKey: .authorizationVersion) ?? 1
        let authorizationRevoked = try container.decodeIfPresent(Bool.self, forKey: .authorizationRevoked) ?? false
        // A legacy revoked row had no watermark. Treat every version it had
        // already issued as revoked rather than reviving it after an edit.
        let revokedThrough = try container.decodeIfPresent(Int.self, forKey: .revokedAuthorizationThroughVersion)
            ?? (authorizationRevoked ? authorizationVersion : 0)
        guard authorizationVersion > 0, revokedThrough >= 0,
              revokedThrough <= authorizationVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .revokedAuthorizationThroughVersion, in: container,
                debugDescription: "revocation watermark must be within the authorization version"
            )
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            cronExpression: try container.decode(String.self, forKey: .cronExpression),
            timeZoneIdentifier: try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier),
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            command: try container.decode(String.self, forKey: .command),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            enablementRevision: enablementRevision,
            isAuthorized: try container.decodeIfPresent(Bool.self, forKey: .isAuthorized) ?? false,
            authorizationVersion: authorizationVersion,
            revokedAuthorizationThroughVersion: revokedThrough,
            authorizationActorID: try container.decodeIfPresent(String.self, forKey: .authorizationActorID) ?? "local-user",
            authorizationScopeID: try container.decodeIfPresent(String.self, forKey: .authorizationScopeID) ?? "scheduler",
            authorizationPolicyRevision: try container.decodeIfPresent(String.self, forKey: .authorizationPolicyRevision) ?? "scheduler-policy-v1",
            authorizationExpiresAt: try container.decodeIfPresent(Date.self, forKey: .authorizationExpiresAt),
            authorizationRevoked: authorizationRevoked,
            isDeleted: try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false,
            targetSessionID: try container.decodeIfPresent(UUID.self, forKey: .targetSessionID),
            targetProjectID: try container.decodeIfPresent(String.self, forKey: .targetProjectID),
            targetTurnID: try container.decodeIfPresent(Int.self, forKey: .targetTurnID),
            sourceAnchorVersion: try container.decodeIfPresent(Int.self, forKey: .sourceAnchorVersion) ?? 0,
            sourceAnchorDigest: try container.decodeIfPresent(String.self, forKey: .sourceAnchorDigest)
        )
        if isAuthorized && (
            authorizationActorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || authorizationScopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || authorizationPolicyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            throw DecodingError.dataCorruptedError(
                forKey: .isAuthorized,
                in: container,
                debugDescription: "authorized task requires actor, scope, and policy revision"
            )
        }
    }
}

enum SchedulerPreviewAuthorizationState: String, Codable, Equatable, Sendable {
    case waiting
    case authorized
    case expired
    case revoked
}

/// Ephemeral, secret-free provider/model facts carried by the scheduler
/// preview and execution fences. It deliberately never enters task or
/// occurrence persistence; the opaque credential version only makes a
/// settings change invalidate an old preview.
enum SchedulerProviderPreflightStatus: String, Equatable, Sendable {
    case ready
    case targetUnavailable
    case missingProvider
    case missingModel
    case missingCredential
    case staleReadiness
    case incompatibleSelection

    var displayLabel: String {
        switch self {
        case .ready: return "已验证"
        case .targetUnavailable: return "目标不可用"
        case .missingProvider: return "未选 Provider"
        case .missingModel: return "未选模型"
        case .missingCredential: return "凭据不可用"
        case .staleReadiness: return "就绪事实已过期"
        case .incompatibleSelection: return "选择未通过门禁"
        }
    }
}

struct SchedulerProviderPreflight: Equatable, Sendable {
    let providerID: String?
    let modelID: String?
    /// An opaque binding/apply revision. Never a credential or credential
    /// source value, and never persisted with a scheduler request/receipt.
    let credentialVersion: String?
    let status: SchedulerProviderPreflightStatus
    let detail: String

    var isReadyForExecution: Bool { status == .ready }

    static func unavailable(_ detail: String = "调度目标的 Provider/model 无法解析") -> Self {
        Self(providerID: nil, modelID: nil, credentialVersion: nil,
             status: .targetUnavailable, detail: detail)
    }
}

/// Read-only snapshot used by the settings consumer. The fingerprint binds
/// every mutable task field, target scope, version and visible timezone.
struct SchedulerTaskPreview: Equatable, Sendable {
    let taskID: UUID
    let taskVersion: Int
    let name: String
    let cronExpression: String
    let command: String
    let targetSessionID: UUID?
    let targetProjectID: String?
    let targetTurnID: Int?
    var sourceAnchorVersion: Int? = nil
    var observedSourceAnchorDigest: String? = nil
    var observedPolicyRevision: String? = nil
    let isEnabled: Bool
    let authorizationActorID: String
    let authorizationScopeID: String
    let authorizationPolicyRevision: String
    let authorizationExpiresAt: Date?
    let authorizationRevoked: Bool
    let authorizationState: SchedulerPreviewAuthorizationState
    let timeZoneIdentifier: String
    let predictedTriggers: [Date]
    let fingerprint: String
    let expiresAt: Date
    /// Current provider/model readiness is transient and must be revalidated
    /// through the same resolver before confirmation and execution.
    let providerPreflight: SchedulerProviderPreflight?

    init(
        taskID: UUID,
        taskVersion: Int,
        name: String,
        cronExpression: String,
        command: String,
        targetSessionID: UUID?,
        targetProjectID: String?,
        targetTurnID: Int?,
        sourceAnchorVersion: Int? = nil,
        observedSourceAnchorDigest: String? = nil,
        observedPolicyRevision: String? = nil,
        isEnabled: Bool,
        authorizationActorID: String,
        authorizationScopeID: String,
        authorizationPolicyRevision: String,
        authorizationExpiresAt: Date?,
        authorizationRevoked: Bool,
        authorizationState: SchedulerPreviewAuthorizationState,
        timeZoneIdentifier: String,
        predictedTriggers: [Date],
        fingerprint: String,
        expiresAt: Date,
        providerPreflight: SchedulerProviderPreflight? = nil
    ) {
        self.taskID = taskID
        self.taskVersion = taskVersion
        self.name = name
        self.cronExpression = cronExpression
        self.command = command
        self.targetSessionID = targetSessionID
        self.targetProjectID = targetProjectID
        self.targetTurnID = targetTurnID
        self.sourceAnchorVersion = sourceAnchorVersion
        self.observedSourceAnchorDigest = observedSourceAnchorDigest
        self.observedPolicyRevision = observedPolicyRevision
        self.isEnabled = isEnabled
        self.authorizationActorID = authorizationActorID
        self.authorizationScopeID = authorizationScopeID
        self.authorizationPolicyRevision = authorizationPolicyRevision
        self.authorizationExpiresAt = authorizationExpiresAt
        self.authorizationRevoked = authorizationRevoked
        self.authorizationState = authorizationState
        self.timeZoneIdentifier = timeZoneIdentifier
        self.predictedTriggers = predictedTriggers
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
        self.providerPreflight = providerPreflight
    }

    var hasValidTarget: Bool {
        targetSessionID != nil
            && targetProjectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && (targetTurnID ?? 0) > 0
    }
}

enum SchedulerOccurrenceState: String, Codable, Equatable, Sendable {
    case triggered
    case waitingApproval
    case authorized
    case admitted
    case dispatched
    case leased
    case running
    case succeeded
    case failed
    case cancelled
    case unknown
    case unknownReconciled
    case retryRequested
    case aborted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .unknown, .unknownReconciled, .retryRequested, .aborted: return true
        case .triggered, .waitingApproval, .authorized, .admitted, .dispatched, .leased, .running: return false
        }
    }
}

struct SchedulerDeliveryReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case delivered
        case failed
        case unknown
    }

    let status: Status
    let recordedAt: Date
    let detail: String?
}

/// Identity carried across the external Composer boundary. The command is
/// payload; the remaining fields are the durable effect identity.
struct SchedulerSubmissionRequest: Codable, Equatable, Sendable {
    let occurrenceID: UUID
    let effectID: String
    let taskID: UUID
    let taskVersion: Int
    let idempotencyKey: String
    let command: String
    let targetSessionID: UUID?
    let targetProjectID: String?
    let targetTurnID: Int?
    let sourceTaskID: UUID?

    init(
        occurrenceID: UUID,
        effectID: String,
        taskID: UUID,
        taskVersion: Int,
        idempotencyKey: String,
        command: String,
        targetSessionID: UUID? = nil,
        targetProjectID: String? = nil,
        targetTurnID: Int? = nil,
        sourceTaskID: UUID? = nil
    ) {
        self.occurrenceID = occurrenceID
        self.effectID = effectID
        self.taskID = taskID
        self.taskVersion = taskVersion
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.targetSessionID = targetSessionID
        self.targetProjectID = targetProjectID
        self.targetTurnID = targetTurnID
        self.sourceTaskID = sourceTaskID
    }

    var hasValidTarget: Bool {
        guard targetSessionID != nil,
              let targetProjectID,
              let targetTurnID,
              let sourceTaskID,
              targetTurnID > 0,
              sourceTaskID == taskID,
              !targetProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}

struct SchedulerComposerSubmissionReceipt: Codable, Equatable, Sendable {
    let request: SchedulerSubmissionRequest
    let status: SchedulerDeliveryReceipt.Status
    let recordedAt: Date
    var executionTurnID: Int? = nil
    var executionMessageID: String? = nil
}

struct SchedulerOccurrence: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let taskID: UUID
    let scheduledMinute: Date
    let taskVersion: Int
    /// Command pinned at trigger time; later task edits never relabel history.
    let command: String
    let idempotencyKey: String
    /// Non-nil only for an explicitly reconciled retry attempt. This keeps
    /// the original trigger identity while distinguishing a legal reopen
    /// from a corrupt duplicate occurrence.
    let retryOfOccurrenceID: UUID?
    let targetSessionID: UUID?
    let targetProjectID: String?
    let targetTurnID: Int?
    let sourceAnchorVersion: Int
    /// Exact approved source binding, fixed with the occurrence target.
    let sourceAnchorDigest: String?
    private(set) var authorizationVersion: Int
    private(set) var authorizationActorID: String
    private(set) var authorizationScopeID: String
    private(set) var authorizationPolicyRevision: String
    private(set) var authorizationExpiresAt: Date?
    private(set) var authorizationRevoked: Bool
    var executionTurnID: Int?
    var executionMessageID: String?
    var state: SchedulerOccurrenceState
    var controlRevision: Int
    var leaseOwner: String?
    var leaseToken: String?
    var leaseExpiresAt: Date?
    var deliveryReceipt: SchedulerDeliveryReceipt?
    /// Full Composer identity receipt, persisted with the occurrence ledger.
    var submissionReceipt: SchedulerComposerSubmissionReceipt?
    /// Set only by persisted inspect/reconcile; retry/abort require this proof.
    var reconciliationProof: String?
    let createdAt: Date
    /// A startup/wake replay of the latest missed occurrence.
    var isCatchUp: Bool

    var effectID: String { "scheduler-effect:\(id.uuidString.lowercased())" }

    /// Bind a newly confirmed grant only before this occurrence owns execution.
    fileprivate mutating func authorizeWaiting(
        with task: SchedulerTask,
        confirmedSourceAnchorDigest: String?
    ) -> Bool {
        guard state == .waitingApproval, taskID == task.id, taskVersion == task.version else {
            return false
        }
        // Preserve the existing transition for unbound legacy rows.
        if sourceAnchorDigest == nil && task.sourceAnchorDigest == nil {
            state = .authorized
            return true
        }
        guard sourceAnchorVersion == 2, task.sourceAnchorVersion == 2,
              let digest = sourceAnchorDigest,
              digest == task.sourceAnchorDigest, digest == confirmedSourceAnchorDigest,
              controlRevision == taskVersion, command == task.command,
              targetSessionID == task.targetSessionID, targetProjectID == task.targetProjectID,
              targetTurnID == task.targetTurnID, task.hasValidTarget,
              task.authorizationScopeID == task.targetProjectID,
              task.authorizationVersion > task.revokedAuthorizationThroughVersion,
              retryOfOccurrenceID == nil, executionTurnID == nil, executionMessageID == nil,
              leaseOwner == nil, leaseToken == nil, leaseExpiresAt == nil,
              deliveryReceipt == nil, submissionReceipt == nil, reconciliationProof == nil else {
            return false
        }
        authorizationVersion = task.authorizationVersion
        authorizationActorID = task.authorizationActorID
        authorizationScopeID = task.authorizationScopeID
        authorizationPolicyRevision = task.authorizationPolicyRevision
        authorizationExpiresAt = task.authorizationExpiresAt
        authorizationRevoked = task.authorizationRevoked
        state = .authorized
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, scheduledMinute, taskVersion, command, idempotencyKey,
             retryOfOccurrenceID, targetSessionID, targetProjectID, targetTurnID, sourceAnchorVersion, sourceAnchorDigest,
             authorizationVersion, authorizationActorID, authorizationScopeID, authorizationPolicyRevision,
             authorizationExpiresAt, authorizationRevoked,
             state, controlRevision, leaseOwner, leaseToken, leaseExpiresAt,
             deliveryReceipt, submissionReceipt, reconciliationProof, createdAt,
             executionTurnID, executionMessageID, isCatchUp
    }

    init(
        id: UUID,
        taskID: UUID,
        scheduledMinute: Date,
        taskVersion: Int,
        command: String,
        idempotencyKey: String,
        retryOfOccurrenceID: UUID?,
        targetSessionID: UUID?,
        targetProjectID: String?,
        targetTurnID: Int?,
        state: SchedulerOccurrenceState,
        controlRevision: Int,
        leaseOwner: String?,
        leaseToken: String?,
        leaseExpiresAt: Date?,
        deliveryReceipt: SchedulerDeliveryReceipt?,
        submissionReceipt: SchedulerComposerSubmissionReceipt?,
        reconciliationProof: String?,
        createdAt: Date,
        sourceAnchorVersion: Int = 2,
        sourceAnchorDigest: String? = nil,
        authorizationVersion: Int = 1,
        authorizationActorID: String = "local-user",
        authorizationScopeID: String = "scheduler",
        authorizationPolicyRevision: String = "scheduler-policy-v1",
        authorizationExpiresAt: Date? = nil,
        authorizationRevoked: Bool = false,
        executionTurnID: Int? = nil,
        executionMessageID: String? = nil,
        isCatchUp: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.scheduledMinute = scheduledMinute
        self.taskVersion = taskVersion
        self.command = command
        self.idempotencyKey = idempotencyKey
        self.retryOfOccurrenceID = retryOfOccurrenceID
        self.targetSessionID = targetSessionID
        self.targetProjectID = targetProjectID
        self.targetTurnID = targetTurnID
        self.sourceAnchorVersion = sourceAnchorVersion
        self.sourceAnchorDigest = sourceAnchorDigest
        self.authorizationVersion = max(1, authorizationVersion)
        self.authorizationActorID = authorizationActorID
        self.authorizationScopeID = authorizationScopeID
        self.authorizationPolicyRevision = authorizationPolicyRevision
        self.authorizationExpiresAt = authorizationExpiresAt
        self.authorizationRevoked = authorizationRevoked
        self.executionTurnID = executionTurnID
        self.executionMessageID = executionMessageID
        self.isCatchUp = isCatchUp
        self.state = state
        self.controlRevision = controlRevision
        self.leaseOwner = leaseOwner
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.deliveryReceipt = deliveryReceipt
        self.submissionReceipt = submissionReceipt
        self.reconciliationProof = reconciliationProof
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            taskID: try c.decode(UUID.self, forKey: .taskID),
            scheduledMinute: try c.decode(Date.self, forKey: .scheduledMinute),
            taskVersion: try c.decode(Int.self, forKey: .taskVersion),
            command: try c.decodeIfPresent(String.self, forKey: .command) ?? "",
            idempotencyKey: try c.decode(String.self, forKey: .idempotencyKey),
            retryOfOccurrenceID: try c.decodeIfPresent(UUID.self, forKey: .retryOfOccurrenceID),
            targetSessionID: try c.decodeIfPresent(UUID.self, forKey: .targetSessionID),
            targetProjectID: try c.decodeIfPresent(String.self, forKey: .targetProjectID),
            targetTurnID: try c.decodeIfPresent(Int.self, forKey: .targetTurnID),
            state: try c.decode(SchedulerOccurrenceState.self, forKey: .state),
            controlRevision: try c.decode(Int.self, forKey: .controlRevision),
            leaseOwner: try c.decodeIfPresent(String.self, forKey: .leaseOwner),
            leaseToken: try c.decodeIfPresent(String.self, forKey: .leaseToken),
            leaseExpiresAt: try c.decodeIfPresent(Date.self, forKey: .leaseExpiresAt),
            deliveryReceipt: try c.decodeIfPresent(SchedulerDeliveryReceipt.self, forKey: .deliveryReceipt),
            submissionReceipt: try c.decodeIfPresent(SchedulerComposerSubmissionReceipt.self, forKey: .submissionReceipt),
            reconciliationProof: try c.decodeIfPresent(String.self, forKey: .reconciliationProof),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            sourceAnchorVersion: try c.decodeIfPresent(Int.self, forKey: .sourceAnchorVersion) ?? 0,
            sourceAnchorDigest: try c.decodeIfPresent(String.self, forKey: .sourceAnchorDigest),
            authorizationVersion: try c.decodeIfPresent(Int.self, forKey: .authorizationVersion) ?? 1,
            authorizationActorID: try c.decodeIfPresent(String.self, forKey: .authorizationActorID) ?? "local-user",
            authorizationScopeID: try c.decodeIfPresent(String.self, forKey: .authorizationScopeID) ?? "scheduler",
            authorizationPolicyRevision: try c.decodeIfPresent(String.self, forKey: .authorizationPolicyRevision) ?? "scheduler-policy-v1",
            authorizationExpiresAt: try c.decodeIfPresent(Date.self, forKey: .authorizationExpiresAt),
            authorizationRevoked: try c.decodeIfPresent(Bool.self, forKey: .authorizationRevoked) ?? false,
            executionTurnID: try c.decodeIfPresent(Int.self, forKey: .executionTurnID),
            executionMessageID: try c.decodeIfPresent(String.self, forKey: .executionMessageID),
            isCatchUp: try c.decodeIfPresent(Bool.self, forKey: .isCatchUp) ?? false
        )
    }
}

/// Immutable identity carried by every scheduler execution boundary.
struct SchedulerOccurrenceExecutionIdentity: Codable, Equatable, Hashable, Sendable {
    let occurrenceID: UUID
    let taskID: UUID
    let taskVersion: Int
    let controlRevision: Int
    let effectID: String
    let idempotencyKey: String

    init(occurrence: SchedulerOccurrence) {
        occurrenceID = occurrence.id
        taskID = occurrence.taskID
        taskVersion = occurrence.taskVersion
        controlRevision = occurrence.controlRevision
        effectID = occurrence.effectID
        idempotencyKey = occurrence.idempotencyKey
    }
}

/// Append-only durable lifecycle facts for restart/reconcile and audit.
/// The command and credentials are deliberately absent from this journal.
struct SchedulerOccurrenceJournalEntry: Codable, Equatable, Sendable {
    let sequence: Int
    let occurrenceID: UUID
    let idempotencyKey: String
    let effectID: String
    let state: SchedulerOccurrenceState
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case sequence, occurrenceID, idempotencyKey, effectID, state, recordedAt
    }

    init(sequence: Int, occurrenceID: UUID, idempotencyKey: String, effectID: String, state: SchedulerOccurrenceState, recordedAt: Date) {
        self.sequence = sequence
        self.occurrenceID = occurrenceID
        self.idempotencyKey = idempotencyKey
        self.effectID = effectID
        self.state = state
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let occurrenceID = try container.decode(UUID.self, forKey: .occurrenceID)
        self.init(
            sequence: try container.decode(Int.self, forKey: .sequence),
            occurrenceID: occurrenceID,
            idempotencyKey: try container.decode(String.self, forKey: .idempotencyKey),
            effectID: try container.decodeIfPresent(String.self, forKey: .effectID)
                ?? "scheduler-effect:\(occurrenceID.uuidString.lowercased())",
            state: try container.decode(SchedulerOccurrenceState.self, forKey: .state),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt)
        )
    }
}

// MARK: - Cron 校验（纯逻辑，可单测）

/// 分钟级 cron 表达式校验器。
enum CronValidator {

    /// 每个字段允许的取值域（minute/hour/dayOfMonth/month/dayOfWeek）。
    static let fieldRanges: [(min: Int, max: Int)] = [
        (0, 59),   // minute
        (0, 23),   // hour
        (1, 31),   // day of month
        (1, 12),   // month
        (0, 7),    // day of week（0/7 均表示周日）
    ]

    /// 校验 5 字段 cron 表达式。合法返回 nil；非法返回人类可读错误信息。
    static func validate(_ expression: String) -> String? {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else {
            return "cron 表达式需为 5 段（分 时 日 月 周），当前为 \(fields.count) 段。"
        }
        for (index, field) in fields.enumerated() {
            let range = fieldRanges[index]
            if let error = validateField(field, range: range, fieldName: Self.fieldNames[index]) {
                return error
            }
        }
        return nil
    }

    /// 将当前分钟与已校验的 5 段表达式匹配。调度器每分钟轮询一次，
    /// 因而不把 cron 任务错误地转换成固定间隔（例如每周一 9 点不能等同为 24 小时）。
    static func matches(_ expression: String, date: Date, calendar: Calendar = .current) -> Bool {
        guard validate(expression) == nil else { return false }
        let components = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday], from: date
        )
        let values = [
            components.minute,
            components.hour,
            components.day,
            components.month,
            components.weekday.map { ($0 + 6) % 7 }
        ]
        guard values.allSatisfy({ $0 != nil }) else { return false }
        let fields = expression.split(separator: " ").map(String.init)
        let matches = zip(fields, values.compactMap { $0 }).enumerated().map { index, pair in
            matchesField(
                pair.0,
                value: pair.1,
                range: fieldRanges[index],
                sundayAlias: index == 4
            )
        }
        guard matches.count == 5 else { return false }
        let clockAndMonthMatch = matches[0] && matches[1] && matches[3]
        let dayMatch: Bool
        let dayOfMonthWildcard = isWildcard(fields[2], range: fieldRanges[2], sundayAlias: false)
        let dayOfWeekWildcard = isWildcard(fields[4], range: fieldRanges[4], sundayAlias: true)
        if dayOfMonthWildcard || dayOfWeekWildcard {
            dayMatch = matches[2] && matches[4]
        } else {
            // POSIX cron uses OR when both day-of-month and day-of-week are restricted.
            dayMatch = matches[2] || matches[4]
        }
        return clockAndMonthMatch && dayMatch
    }

    private static let fieldNames = ["分", "时", "日", "月", "周"]

    /// 校验单个字段。支持 `*`、`*/n`、`a-b`、`a-b/n`、`a`、逗号列表。
    private static func validateField(_ field: String, range: (min: Int, max: Int), fieldName: String) -> String? {
        let parts = field.split(separator: ",").map(String.init)
        for part in parts {
            if let error = validateOne(part, range: range, fieldName: fieldName) {
                return error
            }
        }
        return nil
    }

    private static func validateOne(_ part: String, range: (min: Int, max: Int), fieldName: String) -> String? {
        // 拆出 /step
        let stepSplit = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch stepSplit.count {
        case 1:
            break
        case 2:
            guard let s = Int(stepSplit[1]), s >= 1 else {
                return "“\(fieldName)”字段步进 /\(stepSplit[1]) 非法（需 ≥1 的整数）。"
            }
        default:
            return "“\(fieldName)”字段 “\(part)” 非法（/ 过多）。"
        }

        let base = stepSplit[0]
        // 通配
        if base == "*" {
            return nil
        }
        // a-b 范围
        if base.contains("-") {
            let bounds = base.split(separator: "-").map(String.init)
            guard bounds.count == 2,
                  let lo = Int(bounds[0]), let hi = Int(bounds[1]) else {
                return "“\(fieldName)”字段 “\(part)” 范围非法。"
            }
            guard lo >= range.min && hi <= range.max && lo <= hi else {
                return "“\(fieldName)”字段 “\(part)” 超出取值域（\(range.min)-\(range.max)）。"
            }
            return nil
        }
        // 单个值
        guard let v = Int(base) else {
            return "“\(fieldName)”字段 “\(part)” 非法（无法解析）。"
        }
        guard v >= range.min && v <= range.max else {
            return "“\(fieldName)”字段 “\(part)” 超出取值域（\(range.min)-\(range.max)）。"
        }
        return nil
    }

    private static func matchesField(
        _ field: String,
        value: Int,
        range: (min: Int, max: Int),
        sundayAlias: Bool
    ) -> Bool {
        let values = sundayAlias && value == 0 ? [0, 7] : [value]
        return field.split(separator: ",").contains { part in
            let split = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let base = split[0]
            let step = split.count == 2 ? (Int(split[1]) ?? 0) : 1
            guard step > 0 else { return false }
            let bounds: (Int, Int)
            if base == "*" {
                bounds = (range.min, range.max)
            } else if base.contains("-") {
                let pieces = base.split(separator: "-").compactMap { Int($0) }
                guard pieces.count == 2 else { return false }
                bounds = (pieces[0], pieces[1])
            } else if let single = Int(base) {
                bounds = (single, single)
            } else {
                return false
            }
            return values.contains { candidate in
                candidate >= bounds.0
                    && candidate <= bounds.1
                    && (candidate - bounds.0) % step == 0
            }
        }
    }

    private static func isWildcard(
        _ field: String,
        range: (min: Int, max: Int),
        sundayAlias: Bool
    ) -> Bool {
        // A stepped star such as */2 is restricted, not a wildcard. Match
        // the core canonical set semantics for day-of-month/day-of-week OR.
        (range.min...(sundayAlias ? 6 : range.max)).allSatisfy { value in
            matchesField(field, value: value, range: range, sundayAlias: sundayAlias)
        }
    }
}

// MARK: - Store

enum SchedulerTaskStoreError: Error, Equatable, Sendable {
    case invalidTaskDefinitions(defaultsKey: String)
    case taskDefinitionsWriteFailed(defaultsKey: String)
    case corruptLedger(quarantinePath: String)
    case ledgerReadFailed(path: String)
    case ledgerWriteFailed(path: String)
}

/// 定时任务存储：任务数组 UserDefaults 持久化；occurrence ledger 使用原子文件。
/// @Observable 让设置页在增删改/切换启用时自动刷新列表。
@MainActor
@Observable
final class SchedulerTaskStore {

    typealias ProviderPreflightResolver = @MainActor @Sendable
        (SchedulerTask, Date) -> SchedulerProviderPreflight

    private static let defaultsKey = "miniscanvas.scheduler.tasks.v1"
    private static let processLeaseOwnerPrefix = "scheduler-runtime:proc-v1:"
    /// A production runtime's existing leaseOwner records the OS process
    /// incarnation. If this observation is unavailable, an empty owner makes
    /// claimLease fail closed; no caller-supplied owner is rewritten.
    static func currentProcessLeaseOwnerID() -> String {
        processLeaseOwnerID(pid: getpid()) ?? ""
    }

    static func processLeaseOwnerID(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size),
              info.pbi_pid == UInt32(pid), info.pbi_uid == geteuid(),
              info.pbi_status != 5 else { return nil }
        return "\(processLeaseOwnerPrefix)\(pid):\(info.pbi_uid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    /// True means the exact PID/UID/birth tuple is still alive; false means
    /// legacy owner or proven dead/mismatched incarnation. Nil means the OS
    /// could not establish liveness, so an unexpired lease must not be stolen.
    static func processLeaseOwnerLiveness(_ owner: String) -> Bool? {
        guard owner.hasPrefix(processLeaseOwnerPrefix) else { return false }
        let fields = owner.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 6, fields[0] == "scheduler-runtime", fields[1] == "proc-v1",
              let pid = Int32(fields[2]), pid > 0,
              let uid = UInt32(fields[3]), uid == geteuid(),
              let startSeconds = UInt64(fields[4]),
              let startMicroseconds = UInt64(fields[5]) else { return false }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        if size == Int32(MemoryLayout<proc_bsdinfo>.size) {
            return info.pbi_pid == UInt32(pid) && info.pbi_uid == uid
                && info.pbi_status != 5
                && UInt64(info.pbi_start_tvsec) == startSeconds
                && UInt64(info.pbi_start_tvusec) == startMicroseconds
        }
        if kill(pid, 0) == -1 && errno == ESRCH { return false }
        return nil
    }
    /// One retry chain may contain at most eight ledger rows (the original
    /// occurrence plus seven explicit retry attempts). Runtime retry fences
    /// and decoded-ledger validation must use this same row-count rule.
    private static let maxRetryChainLength = 8
    let defaults: UserDefaults
    /// Every occurrence ledger uses the durable atomic file protocol. Tests
    /// may inject a temporary URL; formal tests use the Core root, while
    /// production resolves the app-support path below. There is deliberately
    /// no UserDefaults fallback.
    let occurrenceLedgerURL: URL
    /// 全部任务（按创建时间倒序，最新在前）。
    private(set) var tasks: [SchedulerTask] = []
    /// Durable occurrence ledger. It is the scheduler's idempotency/CAS owner.
    private(set) var occurrences: [SchedulerOccurrence] = []
    /// Durable append-only lifecycle journal paired with the occurrence ledger.
    private(set) var occurrenceJournal: [SchedulerOccurrenceJournalEntry] = []
    private(set) var persistenceError: SchedulerTaskStoreError?
    @ObservationIgnored private var lastObservedLedgerData: Data?
    @ObservationIgnored private var heldLedgerLockFD: Int32?
    /// Installed by the composition root; tests and legacy adapters may leave
    /// it nil to preserve their existing store-only authorization contract.
    var providerPreflightResolver: ProviderPreflightResolver?
    /// Lease ownership is process-local. Every persisted active lease is
    /// stale on the first recovery pass after opening this store, even when
    /// its wall-clock TTL has not elapsed.
    private var restartRecoveryPending = true

    private struct OccurrenceLedger: Codable {
        let schemaVersion: Int
        let occurrences: [SchedulerOccurrence]
        let journal: [SchedulerOccurrenceJournalEntry]
    }

    init(defaults: UserDefaults? = nil, occurrenceLedgerURL: URL? = nil) {
        // Resolve omitted defaults before .standard or the production ledger.
        // The App boundary also keeps an invalid non-test field launch on its
        // disposable blocker path instead of constructing a durable store.
        let profile: RuntimeIsolationProfile?
        if defaults == nil || occurrenceLedgerURL == nil {
            profile = RuntimeIsolationProfile.formalTestProfileForDefaultConsumer()
        } else {
            profile = nil
        }
        if let defaults {
            self.defaults = defaults
        } else if let profile {
            self.defaults = profile.makeUserDefaults()
        } else {
            self.defaults = .standard
        }
        self.occurrenceLedgerURL = occurrenceLedgerURL
            ?? profile?.minisCanvasDirectory.appendingPathComponent(
                "scheduler-occurrences-v1.json"
            )
            ?? Self.defaultOccurrenceLedgerURL()
        load()
        loadOccurrences()
    }

    private static func defaultOccurrenceLedgerURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MinisCanvas", isDirectory: true)
            .appendingPathComponent("scheduler-occurrences-v1.json")
    }

    /// 所有任务（按创建时间倒序）。
    func allTasks() -> [SchedulerTask] {
        tasks.filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 仅启用的任务（由 SchedulerTaskRuntime 消费）。
    func enabledTasks() -> [SchedulerTask] {
        allTasks().filter(\.isEnabled)
    }

    func task(id: UUID) -> SchedulerTask? {
        tasks.first(where: { $0.id == id })
    }

    /// Compute a bounded, read-only preview using the same cron matcher as
    /// the production runtime. No task, ledger, journal, lease or timer is
    /// touched by this method.
    func preview(
        taskID: UUID,
        now: Date = Date(),
        timeZone: TimeZone? = nil,
        triggerLimit: Int = 5,
        previewTTL: TimeInterval = 60
    ) -> SchedulerTaskPreview? {
        guard let task = task(id: taskID), !task.isDeleted,
              CronValidator.validate(task.cronExpression) == nil,
              triggerLimit > 0, previewTTL > 0 else { return nil }
        // An explicit zone is useful for a new confirmation or a controlled
        // test. Normal UI previews reuse the already authorized zone, even if
        // the device's current zone has changed since confirmation.
        let selectedZone: TimeZone
        if let timeZone {
            selectedZone = timeZone
        } else if let identifier = task.timeZoneIdentifier {
            guard let bound = TimeZone(identifier: identifier) else { return nil }
            selectedZone = bound
        } else {
            selectedZone = .current
        }
        guard let definition = try? TaskScheduleDefinition(
            taskID: task.id.uuidString,
            cronExpression: task.cronExpression,
            timeZoneIdentifier: selectedZone.identifier,
            pinnedVersion: task.version
        ) else { return nil }
        var predicted: [Date] = []
        var after = now
        for _ in 0..<min(triggerLimit, 5) {
            // The same core boundary used by production rejects nonexistent or
            // ambiguous DST minutes and schedules without a safe next fire.
            guard let occurrence = try? TaskScheduler.nextOccurrence(for: definition, after: after) else {
                return nil
            }
            predicted.append(occurrence.scheduledDate)
            after = occurrence.scheduledDate
        }
        let state: SchedulerPreviewAuthorizationState
        if task.timeZoneIdentifier == nil || task.sourceAnchorVersion != 2 || task.sourceAnchorDigest == nil {
            state = .waiting
        } else if task.authorizationRevoked {
            state = .revoked
        } else if let expiry = task.authorizationExpiresAt, expiry <= now {
            state = .expired
        } else if task.isAuthorized {
            state = .authorized
        } else {
            state = .waiting
        }
        return SchedulerTaskPreview(
            taskID: task.id,
            taskVersion: task.version,
            name: task.name,
            cronExpression: task.cronExpression,
            command: task.command,
            targetSessionID: task.targetSessionID,
            targetProjectID: task.targetProjectID,
            targetTurnID: task.targetTurnID,
            sourceAnchorVersion: task.sourceAnchorVersion,
            isEnabled: task.isEnabled,
            authorizationActorID: task.authorizationActorID,
            authorizationScopeID: task.authorizationScopeID,
            authorizationPolicyRevision: task.authorizationPolicyRevision,
            authorizationExpiresAt: task.authorizationExpiresAt,
            authorizationRevoked: task.authorizationRevoked,
            authorizationState: state,
            timeZoneIdentifier: selectedZone.identifier,
            predictedTriggers: predicted,
            fingerprint: Self.previewFingerprint(task: task, timeZoneIdentifier: selectedZone.identifier),
            expiresAt: now.addingTimeInterval(previewTTL),
            providerPreflight: providerPreflightResolver?(task, now)
        )
    }

    /// Confirm an exact read-only preview through the existing durable
    /// authorization/CAS owner. Enabling a task alone never authorizes it.
    @discardableResult
    func confirmPreview(
        _ preview: SchedulerTaskPreview,
        actorID: String,
        scopeID: String,
        policyRevision: String,
        now: Date = Date(),
        authorizationExpiresAt: Date? = nil,
        sourceAnchorConfirmed: Bool = false,
        currentSourceAnchorDigest: String? = nil,
        currentPolicyRevision: String? = nil
    ) -> Bool {
        guard preview.expiresAt > now,
              let current = task(id: preview.taskID),
              !current.isDeleted,
              current.version == preview.taskVersion,
              current.name == preview.name,
              current.cronExpression == preview.cronExpression,
              current.command == preview.command,
              current.isEnabled == preview.isEnabled,
              current.targetSessionID == preview.targetSessionID,
              current.targetProjectID == preview.targetProjectID,
              current.targetTurnID == preview.targetTurnID,
              current.sourceAnchorVersion == preview.sourceAnchorVersion,
              current.sourceAnchorVersion == 2 || sourceAnchorConfirmed,
              current.authorizationActorID == preview.authorizationActorID,
              current.authorizationScopeID == preview.authorizationScopeID,
              current.authorizationPolicyRevision == preview.authorizationPolicyRevision,
              current.authorizationExpiresAt == preview.authorizationExpiresAt,
              current.authorizationRevoked == preview.authorizationRevoked,
              TimeZone(identifier: preview.timeZoneIdentifier) != nil,
              Self.previewFingerprint(task: current, timeZoneIdentifier: preview.timeZoneIdentifier) == preview.fingerprint,
              current.hasValidTarget,
              !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !policyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              authorizationExpiresAt.map({ $0 > now }) ?? true else { return false }
        if let providerPreflightResolver {
            guard let previewPreflight = preview.providerPreflight,
                  previewPreflight.isReadyForExecution,
                  providerPreflightResolver(current, now) == previewPreflight else {
                return false
            }
        }
        if sourceAnchorConfirmed {
            guard let digest = currentSourceAnchorDigest,
                  digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
                  preview.observedSourceAnchorDigest == digest,
                  let currentPolicyRevision, !currentPolicyRevision.isEmpty,
                  preview.observedPolicyRevision == currentPolicyRevision,
                  policyRevision == currentPolicyRevision,
                  scopeID == current.targetProjectID else { return false }
        }
        if current.sourceAnchorVersion != 2 || (sourceAnchorConfirmed && current.sourceAnchorDigest != currentSourceAnchorDigest) {
            var upgraded = current
            upgraded.sourceAnchorVersion = 2
            upgraded.sourceAnchorDigest = currentSourceAnchorDigest
            guard update(upgraded, expectedVersion: current.version) == nil,
                  persistenceError == nil else { return false }
        }
        return authorize(
            preview.taskID,
            actorID: actorID,
            scopeID: scopeID,
            policyRevision: policyRevision,
            expiresAt: authorizationExpiresAt,
            boundTimeZoneIdentifier: preview.timeZoneIdentifier,
            confirmedSourceAnchorDigest: sourceAnchorConfirmed ? currentSourceAnchorDigest : nil
        )
    }

    private static func previewFingerprint(task: SchedulerTask, timeZoneIdentifier: String) -> String {
        let canonical = [
            task.id.uuidString.lowercased(), String(task.version), task.name,
            task.cronExpression, task.command,
            task.targetSessionID?.uuidString.lowercased() ?? "",
            task.targetProjectID ?? "", String(task.targetTurnID ?? 0),
            String(task.isEnabled), String(task.enablementRevision),
            String(task.sourceAnchorVersion), task.sourceAnchorDigest ?? "unbound",
            task.authorizationActorID, task.authorizationScopeID,
            task.authorizationPolicyRevision,
            String(task.authorizationVersion),
            String(task.revokedAuthorizationThroughVersion),
            String(task.authorizationExpiresAt?.timeIntervalSinceReferenceDate ?? -1),
            String(task.authorizationRevoked),
            task.timeZoneIdentifier ?? "unbound",
            timeZoneIdentifier,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func resumableOccurrences() -> [SchedulerOccurrence] {
        guard persistenceError == nil else { return [] }
        return occurrences.filter { occurrence in
            // Restart is a new admission boundary. A row whose task was
            // paused, deleted, or persisted with an invalid control revision
            // remains visible history but cannot re-enter runtime. An edit
            // does not erase a previously due occurrence's pinned authorization.
            guard let task = task(id: occurrence.taskID),
                  !task.isDeleted,
                  task.isEnabled,
                  let zoneID = task.timeZoneIdentifier,
                  TimeZone(identifier: zoneID) != nil,
                  CronValidator.validate(task.cronExpression) == nil,
                  occurrence.controlRevision > 0,
                  occurrence.controlRevision == occurrence.taskVersion else {
                return false
            }
            switch occurrence.state {
            case .triggered, .authorized, .admitted, .dispatched: return true
            case .waitingApproval, .leased, .running, .succeeded, .failed, .cancelled, .unknown, .unknownReconciled, .retryRequested, .aborted: return false
            }
        }
    }

    /// 新增任务。cron 非法时返回错误信息且不写入。
    @discardableResult
    func add(
        name: String,
        cronExpression: String,
        command: String,
        isEnabled: Bool = true,
        targetSessionID: UUID? = nil,
        targetProjectID: String? = nil,
        targetTurnID: Int? = nil
    ) -> String? {
        guard persistenceError == nil else {
            return "任务存储不可用，请处理存储错误后重新打开。"
        }
        if let error = CronValidator.validate(cronExpression) {
            return error
        }
        let previousTasks = tasks
        tasks.append(SchedulerTask(
            name: name,
            cronExpression: cronExpression,
            isEnabled: isEnabled,
            command: command,
            targetSessionID: targetSessionID,
            targetProjectID: targetProjectID,
            targetTurnID: targetTurnID
        ))
        guard persistConfirmedDefinitions() else {
            tasks = previousTasks
            return "任务未保存：任务定义写入失败，请处理存储错误后重新打开。"
        }
        return nil
    }

    /// 更新任务（名称/表达式/命令/启用）。cron 非法时返回错误信息且不写入。
    @discardableResult
    func update(_ task: SchedulerTask, expectedVersion: Int? = nil,
                expectedEnablementRevision: Int? = nil) -> String? {
        guard persistenceError == nil else {
            return "任务存储不可用，请处理存储错误后重新打开。"
        }
        guard let error = CronValidator.validate(task.cronExpression) else {
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                let current = tasks[idx]
                guard !current.isDeleted else { return "任务已删除，请创建新任务" }
                let expected = expectedVersion ?? task.version
                guard current.version == expected else {
                    return "任务版本已变化，请刷新后重试"
                }
                let expectedControl = expectedEnablementRevision ?? task.enablementRevision
                guard current.enablementRevision > 0,
                      current.enablementRevision == expectedControl else {
                    return "任务控制版本已变化，请刷新后重试"
                }
                let enabledChanged = task.isEnabled != current.isEnabled
                guard !enabledChanged || current.enablementRevision < Int.max else {
                    return "任务控制版本已耗尽，启用状态未改变"
                }
                let scopeExpanded = task.command != current.command
                    || task.targetSessionID != current.targetSessionID
                    || task.targetProjectID != current.targetProjectID
                    || task.targetTurnID != current.targetTurnID
                    || task.authorizationScopeID != current.authorizationScopeID
                    || task.authorizationPolicyRevision != current.authorizationPolicyRevision
                var next = task
                next.version = current.version + 1
                // Editor saves also carry the original control snapshot. A
                // rename preserves the counter; an actual toggle advances it.
                next.enablementRevision = current.enablementRevision + (enabledChanged ? 1 : 0)
                // Editing the schedule keeps the existing grant. An edit
                // that expands command/target/policy scope creates a new
                // authorization epoch and waits for explicit approval; the
                // old occurrence keeps its pinned v1 facts.
                if scopeExpanded {
                    guard current.authorizationVersion < Int.max else {
                        return "任务授权版本已耗尽，编辑未保存"
                    }
                    next.authorizationVersion = current.authorizationVersion + 1
                    next.isAuthorized = false
                    next.authorizationRevoked = current.authorizationRevoked
                    next.authorizationExpiresAt = nil
                } else {
                    next.authorizationVersion = current.authorizationVersion
                    next.isAuthorized = current.isAuthorized
                    next.authorizationActorID = current.authorizationActorID
                    next.authorizationScopeID = current.authorizationScopeID
                    next.authorizationPolicyRevision = current.authorizationPolicyRevision
                    next.authorizationExpiresAt = current.authorizationExpiresAt
                    next.authorizationRevoked = current.authorizationRevoked
                }
                next.revokedAuthorizationThroughVersion = current.revokedAuthorizationThroughVersion
                tasks[idx] = next
                guard persistConfirmedDefinitions() else {
                    tasks[idx] = current
                    return "任务未保存：任务定义写入失败，请处理存储错误后重新打开。"
                }
            }
            return nil
        }
        return error
    }

    /// 删除任务时保留 tombstone，并把未开始 occurrence 置为 cancelled；
    /// 已持有 lease 的 occurrence 只转 UNKNOWN，等待显式 reconcile。
    func delete(id: UUID) {
        guard persistenceError == nil else { return }
        guard let taskIndex = tasks.firstIndex(where: { $0.id == id }), !tasks[taskIndex].isDeleted else { return }
        let previousTasks = tasks
        let previousPersistedTasks = defaults.data(forKey: Self.defaultsKey)
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        tasks[taskIndex].isEnabled = false
        tasks[taskIndex].isAuthorized = false
        tasks[taskIndex].authorizationRevoked = true
        tasks[taskIndex].isDeleted = true
        tasks[taskIndex].version += 1
        let now = Date()
        for index in occurrences.indices where occurrences[index].taskID == id && !occurrences[index].state.isTerminal {
            if occurrences[index].state == .leased || occurrences[index].state == .running {
                occurrences[index].state = .unknown
                occurrences[index].deliveryReceipt = SchedulerDeliveryReceipt(
                    status: .unknown,
                    recordedAt: now,
                    detail: "task tombstoned; explicit reconcile required"
                )
                occurrences[index].submissionReceipt = nil
                occurrences[index].leaseOwner = nil
                occurrences[index].leaseToken = nil
                occurrences[index].leaseExpiresAt = nil
            } else if Self.validTransition(from: occurrences[index].state, to: .cancelled) {
                occurrences[index].state = .cancelled
                occurrences[index].leaseOwner = nil
                occurrences[index].leaseToken = nil
                occurrences[index].leaseExpiresAt = nil
            }
            appendJournal(for: occurrences[index], at: now)
        }
        persist()
        guard persistOccurrences() else {
            tasks = previousTasks
            // Re-encoding the same tasks need not reproduce their original bytes.
            // Roll back the before-image, including an originally absent key.
            if let previousPersistedTasks {
                defaults.set(previousPersistedTasks, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return
        }
    }

    /// 切换启用状态。
    ///
    /// Captured definition and enablement revisions are checked together at
    /// this synchronous write boundary. Legacy callers may omit them; settings
    /// controls supply both. A real toggle advances only enablementRevision,
    /// leaving the authorized definition and already leased effects unchanged.
    /// Pausing is a durable admission fence for work that has not acquired a
    /// lease. Already leased/running work is left alone so its existing effect
    /// can finish; its capability remains fenced only by deletion, revision,
    /// authorization, and lease identity.
    @discardableResult
    func setEnabled(_ id: UUID, enabled: Bool, expectedVersion: Int? = nil,
                    expectedEnablementRevision: Int? = nil) -> Bool {
        guard persistenceError == nil,
              let idx = tasks.firstIndex(where: { $0.id == id }),
              !tasks[idx].isDeleted,
              expectedVersion.map({ tasks[idx].version == $0 }) ?? true,
              expectedEnablementRevision.map({ tasks[idx].enablementRevision == $0 }) ?? true,
              tasks[idx].enablementRevision > 0 else { return false }
        let wasEnabled = tasks[idx].isEnabled
        let stateChanged = wasEnabled != enabled
        // Check before any task, ledger, journal or persistence mutation.
        // A matching no-op does not consume a revision, even at Int.max.
        guard !stateChanged || tasks[idx].enablementRevision < Int.max else { return false }
        let previousTasks = tasks
        let previousPersistedTasks = defaults.data(forKey: Self.defaultsKey)
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        if stateChanged {
            tasks[idx].isEnabled = enabled
            tasks[idx].enablementRevision += 1
        }

        // A pre-existing disabled task may have been persisted by an older
        // version before queued-history fencing existed. Fence such rows both
        // when pausing now and before a later re-enable can expose them.
        let shouldFenceQueued = !enabled || !wasEnabled
        var changedOccurrences = false
        if shouldFenceQueued {
            let now = Date()
            for index in occurrences.indices where occurrences[index].taskID == id && !occurrences[index].state.isTerminal {
                switch occurrences[index].state {
                case .triggered, .waitingApproval, .authorized, .admitted, .dispatched:
                    guard Self.validTransition(from: occurrences[index].state, to: .cancelled) else { continue }
                    occurrences[index].state = .cancelled
                    occurrences[index].leaseOwner = nil
                    occurrences[index].leaseToken = nil
                    occurrences[index].leaseExpiresAt = nil
                    appendJournal(for: occurrences[index], at: now)
                    changedOccurrences = true
                case .leased, .running:
                    // Do not kill an effect that has already acquired a lease.
                    continue
                default:
                    continue
                }
            }
        }

        if stateChanged { persist() }
        guard changedOccurrences else { return true }
        guard persistOccurrences() else {
            tasks = previousTasks
            if let previousPersistedTasks {
                defaults.set(previousPersistedTasks, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Explicit authorization boundary. Enabling a schedule never authorizes it.
    @discardableResult
    func authorize(
        _ id: UUID,
        actorID: String = "local-user",
        scopeID: String = "scheduler",
        policyRevision: String = "scheduler-policy-v1",
        expiresAt: Date? = nil,
        boundTimeZoneIdentifier: String? = nil,
        confirmedSourceAnchorDigest: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard persistenceError == nil else { return false }
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              !tasks[idx].isDeleted,
              tasks[idx].sourceAnchorVersion == 2,
              let selectedZone = boundTimeZoneIdentifier ?? tasks[idx].timeZoneIdentifier,
              let definition = try? TaskScheduleDefinition(
                taskID: id.uuidString,
                cronExpression: tasks[idx].cronExpression,
                timeZoneIdentifier: selectedZone,
                pinnedVersion: tasks[idx].version
              ),
              (try? TaskScheduler.nextOccurrence(for: definition, after: now)) != nil,
              !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !policyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expiresAt.map({ $0 > now }) ?? true else { return false }
        let previousTasks = tasks
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        if tasks[idx].authorizationRevoked,
           tasks[idx].authorizationVersion <= tasks[idx].revokedAuthorizationThroughVersion {
            guard tasks[idx].authorizationVersion < Int.max else { return false }
            tasks[idx].authorizationVersion += 1
        }
        if tasks[idx].timeZoneIdentifier != selectedZone {
            // A changed wall-clock zone is a new schedule definition. The
            // version fence makes every queued row from the old zone stale.
            tasks[idx].version += 1
            tasks[idx].timeZoneIdentifier = selectedZone
        }
        tasks[idx].isAuthorized = true
        tasks[idx].authorizationActorID = actorID
        tasks[idx].authorizationScopeID = scopeID
        tasks[idx].authorizationPolicyRevision = policyRevision
        tasks[idx].authorizationExpiresAt = expiresAt
        tasks[idx].authorizationRevoked = false
        let grant = tasks[idx]
        for occurrenceIndex in occurrences.indices where occurrences[occurrenceIndex].taskID == id {
            guard occurrences[occurrenceIndex].authorizeWaiting(
                with: grant, confirmedSourceAnchorDigest: confirmedSourceAnchorDigest
            ) else { continue }
            appendJournal(for: occurrences[occurrenceIndex])
        }
        guard persistConfirmedDefinitions() else {
            tasks = previousTasks
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        guard persistOccurrences() else {
            tasks = previousTasks
            persist()
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Revocation is durable and immediately fences new dispatches.
    @discardableResult
    func revokeAuthorization(_ id: UUID, expectedVersion: Int? = nil,
                             expectedAuthorizationVersion: Int? = nil) -> Bool {
        guard persistenceError == nil, let idx = tasks.firstIndex(where: { $0.id == id }), !tasks[idx].isDeleted,
              expectedVersion.map({ $0 == tasks[idx].version }) ?? true,
              expectedAuthorizationVersion.map({ $0 == tasks[idx].authorizationVersion }) ?? true,
              tasks[idx].authorizationVersion < Int.max else { return false }
        tasks[idx].revokedAuthorizationThroughVersion = tasks[idx].authorizationVersion
        tasks[idx].authorizationVersion += 1
        tasks[idx].isAuthorized = false
        tasks[idx].authorizationRevoked = true
        persist()
        return true
    }

    /// Reserve one deterministic occurrence. Repeated triggers return the same row.
    func reserveOccurrence(taskID: UUID, at date: Date, calendar: Calendar = .current,
                           isCatchUp: Bool = false, recordedAt: Date? = nil) -> SchedulerOccurrence? {
        var result: SchedulerOccurrence?
        guard withLockedLedger({
            // Another production composition may have advanced this same
            // ledger since this store opened. Admit the canonical row before
            // checking the task/minute identity or writing a new trigger.
            loadOccurrences()
            if persistenceError == nil {
                result = reserveOccurrenceLocked(taskID: taskID, at: date, calendar: calendar,
                    isCatchUp: isCatchUp, recordedAt: recordedAt)
            }
        }) else {
            persistenceError = .ledgerWriteFailed(path: occurrenceLedgerURL.path)
            return nil
        }
        return result
    }

    private func reserveOccurrenceLocked(taskID: UUID, at date: Date, calendar: Calendar,
                                         isCatchUp: Bool, recordedAt: Date?) -> SchedulerOccurrence? {
        guard persistenceError == nil else { return nil }
        guard let task = tasks.first(where: { $0.id == taskID }),
              !task.isDeleted,
              task.isEnabled,
              CronValidator.validate(task.cronExpression) == nil else { return nil }
        let minute = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        // A definition edit does not make an uncertain effect from this same
        // scheduled minute safe to send again. A new version is a new intent
        // only at a new minute; retrying this minute requires the explicit
        // reconcile/attempt path instead of creating a second root row.
        if let existing = occurrences.first(where: {
            $0.taskID == taskID && $0.scheduledMinute == minute
        }) {
            return !isCatchUp && existing.taskVersion == task.version ? existing : nil
        }
        let occurrence = SchedulerOccurrence(
            id: UUID(),
            taskID: task.id,
            scheduledMinute: minute,
            taskVersion: task.version,
            command: task.command,
            idempotencyKey: "scheduler:\(task.id.uuidString.lowercased()):\(Int(minute.timeIntervalSince1970)):\(task.version)",
            retryOfOccurrenceID: nil,
            targetSessionID: task.targetSessionID,
            targetProjectID: task.targetProjectID,
            targetTurnID: task.targetTurnID,
            state: .triggered,
            controlRevision: task.version,
            leaseOwner: nil,
            leaseToken: nil,
            leaseExpiresAt: nil,
            deliveryReceipt: nil,
            submissionReceipt: nil,
            reconciliationProof: nil,
            createdAt: recordedAt ?? date,
            sourceAnchorVersion: task.sourceAnchorVersion,
            sourceAnchorDigest: task.sourceAnchorDigest,
            authorizationVersion: task.authorizationVersion,
            authorizationActorID: task.authorizationActorID,
            authorizationScopeID: task.authorizationScopeID,
            authorizationPolicyRevision: task.authorizationPolicyRevision,
            authorizationExpiresAt: task.authorizationExpiresAt,
            authorizationRevoked: task.authorizationRevoked,
            isCatchUp: isCatchUp
        )
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences.append(occurrence)
        appendJournal(for: occurrence)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return nil
        }
        return occurrence
    }

    func occurrence(id: UUID) -> SchedulerOccurrence? {
        occurrences.first(where: { $0.id == id })
    }

    func executionIdentity(id: UUID) -> SchedulerOccurrenceExecutionIdentity? {
        occurrence(id: id).map(SchedulerOccurrenceExecutionIdentity.init(occurrence:))
    }

    func latestOccurrence(for taskID: UUID) -> SchedulerOccurrence? {
        occurrences.filter { $0.taskID == taskID }.max { $0.createdAt < $1.createdAt }
    }

    /// Single-writer compare-and-swap for lifecycle transitions.
    @discardableResult
    func compareAndSwapOccurrence(
        id: UUID,
        expected: SchedulerOccurrenceState,
        next: SchedulerOccurrenceState,
        expectedControlRevision: Int? = nil,
        now: Date = Date()
    ) -> Bool {
        guard persistenceError == nil else { return false }
        guard let idx = occurrences.firstIndex(where: { $0.id == id }) else { return false }
        guard occurrences[idx].state == expected else { return false }
        guard occurrences[idx].controlRevision > 0,
              occurrences[idx].controlRevision == occurrences[idx].taskVersion else { return false }
        if let expectedControlRevision, occurrences[idx].controlRevision != expectedControlRevision {
            return false
        }
        guard Self.validTransition(from: expected, to: next) else { return false }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[idx].state = next
        appendJournal(for: occurrences[idx], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Validate the grant attached to this occurrence. When the task has
    /// advanced to a new authorization epoch, the old occurrence continues
    /// with its pinned grant; an explicit current revocation still fences it.
    func isOccurrenceAuthorized(_ occurrence: SchedulerOccurrence, now: Date) -> Bool {
        guard let task = task(id: occurrence.taskID), !task.isDeleted,
              !task.authorizationRevoked,
              occurrence.authorizationVersion > task.revokedAuthorizationThroughVersion else { return false }
        if occurrence.authorizationVersion != task.authorizationVersion {
            return !occurrence.authorizationRevoked
                && !occurrence.authorizationActorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !occurrence.authorizationScopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !occurrence.authorizationPolicyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (occurrence.authorizationExpiresAt.map { $0 > now } ?? true)
        }
        return task.isAuthorized
            && !task.authorizationActorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.authorizationScopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.authorizationPolicyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (task.authorizationExpiresAt.map { $0 > now } ?? true)
    }

    /// Claim a lease with a fencing token. Only an admitted/dispatched occurrence can run.
    @discardableResult
    func claimLease(
        id: UUID,
        owner: String,
        expectedControlRevision: Int? = nil,
        now: Date = Date(),
        ttl: TimeInterval = 300
    ) -> String? {
        guard persistenceError == nil,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let idx = occurrences.firstIndex(where: { $0.id == id }),
              let currentTask = task(id: occurrences[idx].taskID),
              !currentTask.isDeleted,
              isOccurrenceAuthorized(occurrences[idx], now: now),
              occurrences[idx].controlRevision > 0,
              occurrences[idx].controlRevision == occurrences[idx].taskVersion,
              expectedControlRevision == nil || occurrences[idx].controlRevision == expectedControlRevision,
              occurrences[idx].state == .dispatched,
              occurrences[idx].leaseOwner == nil,
              ttl > 0 else { return nil }
        let token = UUID().uuidString
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[idx].leaseOwner = owner
        occurrences[idx].leaseToken = token
        occurrences[idx].leaseExpiresAt = now.addingTimeInterval(ttl)
        occurrences[idx].state = .leased
        appendJournal(for: occurrences[idx], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return nil
        }
        return token
    }

    /// Renew a live lease and optionally move leased -> running.
    @discardableResult
    func heartbeat(id: UUID, owner: String, token: String, now: Date = Date(), ttl: TimeInterval = 300) -> Bool {
        guard persistenceError == nil else { return false }
        guard let idx = occurrences.firstIndex(where: { $0.id == id }),
              occurrences[idx].controlRevision > 0,
              occurrences[idx].controlRevision == occurrences[idx].taskVersion,
              isOccurrenceAuthorized(occurrences[idx], now: now),
              occurrences[idx].leaseOwner == owner,
              occurrences[idx].leaseToken == token,
              occurrences[idx].leaseExpiresAt.map({ $0 > now }) == true,
              occurrences[idx].state == .leased || occurrences[idx].state == .running,
              ttl > 0 else {
            return false
        }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[idx].leaseExpiresAt = now.addingTimeInterval(ttl)
        occurrences[idx].state = .running
        appendJournal(for: occurrences[idx], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Read-only revalidation for the real asynchronous effect consumer.
    /// This checks the persisted ledger identity, never a caller's Boolean.
    /// A task toggle fences new admission, while an existing leased/running
    /// effect may finish under its pinned revision and lease identity after a
    /// definition edit, unless the original grant is explicitly revoked.
    func isSubmissionCurrent(_ request: SchedulerSubmissionRequest, owner: String, token: String,
                             now: Date = Date()) -> Bool {
        guard persistenceError == nil, request.hasValidTarget,
              let occurrence = occurrence(id: request.occurrenceID),
              let task = task(id: request.taskID), !task.isDeleted,
              occurrence.sourceAnchorVersion == 2,
              occurrence.taskVersion == request.taskVersion,
              occurrence.controlRevision == request.taskVersion,
              occurrence.effectID == request.effectID, occurrence.idempotencyKey == request.idempotencyKey,
              occurrence.command == request.command,
              occurrence.targetSessionID == request.targetSessionID,
              occurrence.targetProjectID == request.targetProjectID,
              occurrence.targetTurnID == request.targetTurnID,
              isOccurrenceAuthorized(occurrence, now: now),
              occurrence.state == .running,
              occurrence.leaseOwner == owner, occurrence.leaseToken == token,
              occurrence.leaseExpiresAt.map({ $0 > now }) == true else { return false }
        return true
    }

    /// Persist a unique effect execution identity before invoking its
    /// consumer. Restart/duplicate callers cannot allocate it a second time.
    func beginExecutionIdentity(_ request: SchedulerSubmissionRequest, owner: String, token: String,
                                minimumTurn: Int, now: Date = Date()) -> (turn: Int, messageID: String)? {
        guard isSubmissionCurrent(request, owner: owner, token: token, now: now), minimumTurn > 0, minimumTurn < Int.max,
              let index = occurrences.firstIndex(where: { $0.id == request.occurrenceID }),
              occurrences[index].executionTurnID == nil else { return nil }
        let previousMaximum = occurrences.filter { $0.targetSessionID == request.targetSessionID }
            .compactMap(\.executionTurnID).max() ?? 0
        guard previousMaximum < Int.max - 1 else { return nil }
        let turn = max(minimumTurn, previousMaximum + 1)
        let messageID = UUID().uuidString
        let before = occurrences
        let beforeJournal = occurrenceJournal
        occurrences[index].executionTurnID = turn
        occurrences[index].executionMessageID = messageID
        appendJournal(for: occurrences[index], at: now)
        guard persistOccurrences() else { restoreOccurrenceSnapshot(before, beforeJournal); return nil }
        return (turn, messageID)
    }

    /// Record delivery and close a lease only when the same fence owns it.
    @discardableResult
    func recordDelivery(
        id: UUID,
        owner: String,
        token: String,
        status: SchedulerDeliveryReceipt.Status,
        detail: String? = nil,
        now: Date = Date(),
        expectedTaskVersion: Int,
        expectedControlRevision: Int,
        executionTurnID: Int? = nil,
        executionMessageID: String? = nil
    ) -> Bool {
        guard persistenceError == nil else { return false }
        guard let idx = occurrences.firstIndex(where: { $0.id == id }),
              let currentTask = task(id: occurrences[idx].taskID),
              occurrences[idx].controlRevision > 0,
              occurrences[idx].controlRevision == occurrences[idx].taskVersion,
              isOccurrenceAuthorized(occurrences[idx], now: now),
              occurrences[idx].leaseOwner == owner,
              occurrences[idx].leaseToken == token,
              occurrences[idx].taskVersion == expectedTaskVersion,
              occurrences[idx].controlRevision == expectedControlRevision,
              occurrences[idx].leaseExpiresAt.map({ $0 > now }) == true,
              occurrences[idx].state == .running || occurrences[idx].state == .leased else {
            return false
        }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[idx].deliveryReceipt = SchedulerDeliveryReceipt(status: status, recordedAt: now, detail: detail)
        occurrences[idx].submissionReceipt = SchedulerComposerSubmissionReceipt(
            request: SchedulerSubmissionRequest(
                occurrenceID: occurrences[idx].id,
                effectID: occurrences[idx].effectID,
                taskID: currentTask.id,
                taskVersion: occurrences[idx].taskVersion,
                idempotencyKey: occurrences[idx].idempotencyKey,
                command: occurrences[idx].command,
                targetSessionID: occurrences[idx].targetSessionID,
                targetProjectID: occurrences[idx].targetProjectID,
                targetTurnID: occurrences[idx].targetTurnID,
                sourceTaskID: currentTask.id
            ),
            status: status,
            recordedAt: now,
            executionTurnID: executionTurnID,
            executionMessageID: executionMessageID
        )
        occurrences[idx].leaseOwner = nil
        occurrences[idx].leaseToken = nil
        occurrences[idx].leaseExpiresAt = nil
        occurrences[idx].state = status == .delivered ? .succeeded : (status == .failed ? .failed : .unknown)
        appendJournal(for: occurrences[idx], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// A former lease owner may report uncertainty about its own effect even
    /// after authorization/task revision changed, but cannot report success or
    /// relabel another occurrence. The pinned request remains historical truth.
    @discardableResult
    func markExecutionUnknown(_ request: SchedulerSubmissionRequest, owner: String, token: String,
                              now: Date = Date()) -> Bool {
        guard persistenceError == nil,
              let index = occurrences.firstIndex(where: { $0.id == request.occurrenceID }),
              occurrences[index].state == .running || occurrences[index].state == .leased,
              occurrences[index].effectID == request.effectID,
              occurrences[index].taskVersion == request.taskVersion,
              occurrences[index].leaseOwner == owner, occurrences[index].leaseToken == token else { return false }
        let before = occurrences
        let beforeJournal = occurrenceJournal
        occurrences[index].state = .unknown
        occurrences[index].leaseOwner = nil
        occurrences[index].leaseToken = nil
        occurrences[index].leaseExpiresAt = nil
        occurrences[index].deliveryReceipt = SchedulerDeliveryReceipt(status: .unknown, recordedAt: now, detail: "执行结果需核对")
        occurrences[index].submissionReceipt = SchedulerComposerSubmissionReceipt(request: request, status: .unknown,
            recordedAt: now, executionTurnID: occurrences[index].executionTurnID,
            executionMessageID: occurrences[index].executionMessageID)
        appendJournal(for: occurrences[index], at: now)
        guard persistOccurrences() else { restoreOccurrenceSnapshot(before, beforeJournal); return false }
        return true
    }

    /// Historical failed/UNKNOWN target observations are read-only. This is
    /// separate from recovery eligibility: inspecting failed work must never
    /// relax the terminal transition or reconcileDeliveredOccurrence guards.
    func inspectTargetDeliveryOccurrence(id: UUID) -> SchedulerOccurrence? {
        guard persistenceError == nil,
              let occurrence = occurrence(id: id),
              occurrence.state == .failed || occurrence.state == .unknown
                || occurrence.state == .unknownReconciled else { return nil }
        return occurrence
    }

    /// UNKNOWN is inspectable but never implicitly retried.
    func inspectUnknownOccurrence(id: UUID) -> SchedulerOccurrence? {
        guard persistenceError == nil,
              let occurrence = occurrence(id: id),
              occurrence.state == .unknown || occurrence.state == .unknownReconciled else { return nil }
        return occurrence
    }

    /// Close a lost scheduler receipt only from an identity-matched durable
    /// target fact. Historical task edits do not relabel this old attempt.
    @discardableResult
    func reconcileDeliveredOccurrence(id: UUID, targetFact: ScheduledTranscriptDelivery,
                                      now: Date = Date()) -> Bool {
        guard persistenceError == nil,
              let index = occurrences.firstIndex(where: { $0.id == id }),
              occurrences[index].state == .unknown,
              targetFact.occurrenceID == id,
              targetFact.effectID == occurrences[index].effectID,
              targetFact.taskID == occurrences[index].taskID,
              targetFact.taskVersion == occurrences[index].taskVersion,
              targetFact.executionTurnID == occurrences[index].executionTurnID,
              targetFact.executionMessageID == occurrences[index].executionMessageID else { return false }
        let occurrence = occurrences[index]
        let request = occurrence.submissionReceipt?.request ?? SchedulerSubmissionRequest(
            occurrenceID: occurrence.id, effectID: occurrence.effectID,
            taskID: occurrence.taskID, taskVersion: occurrence.taskVersion,
            idempotencyKey: occurrence.idempotencyKey, command: occurrence.command,
            targetSessionID: occurrence.targetSessionID, targetProjectID: occurrence.targetProjectID,
            targetTurnID: occurrence.targetTurnID, sourceTaskID: occurrence.taskID)
        guard request.hasValidTarget else { return false }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[index].state = .succeeded
        occurrences[index].deliveryReceipt = SchedulerDeliveryReceipt(
            status: .delivered, recordedAt: now, detail: "目标转录已持久提交")
        occurrences[index].submissionReceipt = SchedulerComposerSubmissionReceipt(
            request: request, status: .delivered, recordedAt: now,
            executionTurnID: targetFact.executionTurnID,
            executionMessageID: targetFact.executionMessageID)
        appendJournal(for: occurrences[index], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Mark an UNKNOWN receipt as reconciled. A retry is rejected until this
    /// explicit review/reconcile step has been persisted.
    @discardableResult
    func reconcileUnknownOccurrence(id: UUID, now: Date = Date()) -> Bool {
        guard persistenceError == nil,
              let index = occurrences.firstIndex(where: { $0.id == id }),
              occurrences[index].state == .unknown else { return false }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[index].state = .unknownReconciled
        occurrences[index].reconciliationProof = UUID().uuidString.lowercased()
        appendJournal(for: occurrences[index], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Explicit retry creates a new occurrence only when the pinned task
    /// version is still current. The UNKNOWN row is retained as evidence.
    @discardableResult
    func retryUnknownOccurrence(
        id: UUID,
        expectedControlRevision: Int,
        proofToken: String,
        now: Date = Date()
    ) -> SchedulerOccurrence? {
        guard persistenceError == nil,
              let index = occurrences.firstIndex(where: { $0.id == id }),
              occurrences[index].state == .unknownReconciled,
              !proofToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              occurrences[index].reconciliationProof == proofToken,
              occurrences[index].controlRevision > 0,
              occurrences[index].controlRevision == occurrences[index].taskVersion,
              occurrences[index].controlRevision == expectedControlRevision,
              let task = task(id: occurrences[index].taskID),
              task.version == occurrences[index].taskVersion,
              task.isEnabled,
              CronValidator.validate(task.cronExpression) == nil,
              task.isAuthorized,
              !task.authorizationRevoked,
              !task.isDeleted,
              !task.authorizationActorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !task.authorizationScopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !task.authorizationPolicyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.authorizationExpiresAt.map({ $0 > now }) ?? true,
              task.hasValidTarget,
              occurrences.filter({
                  $0.taskID == task.id
                      && $0.scheduledMinute == occurrences[index].scheduledMinute
                      && $0.taskVersion == occurrences[index].taskVersion
              }).count < Self.maxRetryChainLength else { return nil }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[index].state = .retryRequested
        appendJournal(for: occurrences[index], at: now)
        let retry = SchedulerOccurrence(
            id: UUID(),
            taskID: task.id,
            scheduledMinute: occurrences[index].scheduledMinute,
            taskVersion: task.version,
            command: task.command,
            idempotencyKey: "\(occurrences[index].idempotencyKey):retry:\(occurrenceJournal.count + 1)",
            retryOfOccurrenceID: occurrences[index].id,
            targetSessionID: task.targetSessionID,
            targetProjectID: task.targetProjectID,
            targetTurnID: task.targetTurnID,
            state: .triggered,
            controlRevision: task.version,
            leaseOwner: nil,
            leaseToken: nil,
            leaseExpiresAt: nil,
            deliveryReceipt: nil,
            submissionReceipt: nil,
            reconciliationProof: nil,
            createdAt: now,
            sourceAnchorVersion: occurrences[index].sourceAnchorVersion,
            sourceAnchorDigest: occurrences[index].sourceAnchorDigest,
            authorizationVersion: task.authorizationVersion,
            authorizationActorID: task.authorizationActorID,
            authorizationScopeID: task.authorizationScopeID,
            authorizationPolicyRevision: task.authorizationPolicyRevision,
            authorizationExpiresAt: task.authorizationExpiresAt,
            authorizationRevoked: task.authorizationRevoked
        )
        occurrences.append(retry)
        appendJournal(for: retry, at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return nil
        }
        return retry
    }

    /// Explicitly closes UNKNOWN without deleting its receipt or journal.
    @discardableResult
    func abortUnknownOccurrence(
        id: UUID,
        expectedControlRevision: Int,
        proofToken: String,
        now: Date = Date()
    ) -> Bool {
        guard persistenceError == nil,
              let index = occurrences.firstIndex(where: { $0.id == id }),
              occurrences[index].state == .unknownReconciled,
              !proofToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              occurrences[index].reconciliationProof == proofToken,
              occurrences[index].controlRevision > 0,
              occurrences[index].controlRevision == occurrences[index].taskVersion,
              occurrences[index].controlRevision == expectedControlRevision else { return false }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[index].state = .aborted
        appendJournal(for: occurrences[index], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Cancel is a fenced terminal transition; a late callback cannot revive it.
    @discardableResult
    func cancelOccurrence(
        id: UUID,
        owner: String? = nil,
        token: String? = nil,
        expectedTaskVersion: Int,
        expectedControlRevision: Int,
        now: Date = Date()
    ) -> Bool {
        guard persistenceError == nil else { return false }
        guard let idx = occurrences.firstIndex(where: { $0.id == id }),
              let currentTask = task(id: occurrences[idx].taskID),
              currentTask.version == occurrences[idx].taskVersion,
              !occurrences[idx].state.isTerminal,
              occurrences[idx].taskVersion == expectedTaskVersion,
              occurrences[idx].controlRevision > 0,
              occurrences[idx].controlRevision == occurrences[idx].taskVersion,
              occurrences[idx].controlRevision == expectedControlRevision,
              Self.validTransition(from: occurrences[idx].state, to: .cancelled) else {
            return false
        }
        if occurrences[idx].state == .leased || occurrences[idx].state == .running {
            guard let owner, let token,
                  occurrences[idx].leaseOwner == owner,
                  occurrences[idx].leaseToken == token,
                  occurrences[idx].leaseExpiresAt.map({ $0 > now }) == true else { return false }
        }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        occurrences[idx].state = .cancelled
        occurrences[idx].leaseOwner = nil
        occurrences[idx].leaseToken = nil
        occurrences[idx].leaseExpiresAt = nil
        appendJournal(for: occurrences[idx], at: now)
        guard persistOccurrences() else {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return false
        }
        return true
    }

    /// Conservative restart reconcile: queued work is resumable; persisted
    /// leases become UNKNOWN on the first pass because their owner/token are
    /// process-local, and later expired leases become UNKNOWN as well. No
    /// submitted/running side effect is silently redispatched.
    @discardableResult
    func reconcileExpiredOccurrences(now: Date = Date()) -> Int {
        guard persistenceError == nil else { return 0 }
        let previousOccurrences = occurrences
        let previousJournal = occurrenceJournal
        let isRestartRecovery = restartRecoveryPending
        var changed = 0
        for idx in occurrences.indices {
            guard let expiry = occurrences[idx].leaseExpiresAt,
                  occurrences[idx].state == .leased || occurrences[idx].state == .running else { continue }
            if isRestartRecovery, expiry > now,
               let owner = occurrences[idx].leaseOwner,
               Self.processLeaseOwnerLiveness(owner) != false {
                // The original token stays authoritative. A live or
                // temporarily unprobeable process is not a crashed owner;
                // expiry still follows the existing UNKNOWN path below.
                continue
            }
            guard isRestartRecovery || expiry <= now else { continue }
            occurrences[idx].state = .unknown
            occurrences[idx].deliveryReceipt = SchedulerDeliveryReceipt(
                status: .unknown,
                recordedAt: now,
                detail: isRestartRecovery
                    ? "runtime restarted; lease owner is no longer resumable; explicit reconcile required"
                    : "lease expired; explicit reconcile required"
            )
            occurrences[idx].submissionReceipt = nil
            occurrences[idx].leaseOwner = nil
            occurrences[idx].leaseToken = nil
            occurrences[idx].leaseExpiresAt = nil
            appendJournal(for: occurrences[idx], at: now)
            changed += 1
        }
        if changed > 0, !persistOccurrences() {
            restoreOccurrenceSnapshot(previousOccurrences, previousJournal)
            return 0
        }
        restartRecoveryPending = false
        return changed
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            tasks = []
            return
        }
        do {
            tasks = try JSONDecoder().decode([SchedulerTask].self, from: data)
        } catch {
            // A rejected row cannot turn the whole durable task group into a
            // normal writable empty store. Preserve its exact original bytes.
            tasks = []
            persistenceError = .invalidTaskDefinitions(defaultsKey: Self.defaultsKey)
        }
    }

    private func loadOccurrences() {
        guard persistenceError == nil else { return }
        guard FileManager.default.fileExists(atPath: occurrenceLedgerURL.path) else {
            occurrences = []
            occurrenceJournal = []
            lastObservedLedgerData = nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: occurrenceLedgerURL)
        } catch {
            persistenceError = .ledgerReadFailed(path: occurrenceLedgerURL.path)
            occurrences = []
            occurrenceJournal = []
            return
        }
        let decoder = JSONDecoder()
        if let ledger = try? decoder.decode(OccurrenceLedger.self, from: data), ledger.schemaVersion == 1 {
            guard validateLedger(occurrences: ledger.occurrences, journal: ledger.journal) else {
                rejectCorruptLedger()
                return
            }
            occurrences = ledger.occurrences
            occurrenceJournal = ledger.journal
            lastObservedLedgerData = data
        } else if let legacy = try? decoder.decode([SchedulerOccurrence].self, from: data) {
            // Pre-journal ledgers are migrated into a legal lifecycle trace.
            // A single terminal fact is not an admissible history: every
            // occurrence must begin with TRIGGERED and follow only the same
            // transitions used by the live runtime. Legacy bytes remain in
            // place until the next normal atomic persist.
            var sequence = 0
            var journal: [SchedulerOccurrenceJournalEntry] = []
            for occurrence in legacy {
                let states = Self.legacyJournalStates(for: occurrence.state)
                for state in states {
                    sequence += 1
                    journal.append(SchedulerOccurrenceJournalEntry(
                        sequence: sequence,
                        occurrenceID: occurrence.id,
                        idempotencyKey: occurrence.idempotencyKey,
                        effectID: occurrence.effectID,
                        state: state,
                        recordedAt: occurrence.createdAt
                    ))
                }
            }
            guard validateLedger(occurrences: legacy, journal: journal) else {
                rejectCorruptLedger()
                return
            }
            occurrences = legacy
            occurrenceJournal = journal
            lastObservedLedgerData = data
        } else {
            rejectCorruptLedger()
        }
    }

    private static func legacyJournalStates(
        for terminalState: SchedulerOccurrenceState
    ) -> [SchedulerOccurrenceState] {
        switch terminalState {
        case .triggered: return [.triggered]
        case .waitingApproval: return [.triggered, .waitingApproval]
        case .authorized: return [.triggered, .authorized]
        case .admitted: return [.triggered, .authorized, .admitted]
        case .dispatched: return [.triggered, .authorized, .admitted, .dispatched]
        case .leased: return [.triggered, .authorized, .admitted, .dispatched, .leased]
        case .running: return [.triggered, .authorized, .admitted, .dispatched, .leased, .running]
        case .succeeded, .failed:
            return [.triggered, .authorized, .admitted, .dispatched, .leased, .running, terminalState]
        case .cancelled: return [.triggered, .cancelled]
        case .unknown:
            return [.triggered, .authorized, .admitted, .dispatched, .leased, .running, .unknown]
        case .unknownReconciled:
            return [.triggered, .authorized, .admitted, .dispatched, .leased, .running, .unknown, .unknownReconciled]
        case .retryRequested:
            return [.triggered, .authorized, .admitted, .dispatched, .leased, .running, .unknown, .unknownReconciled, .retryRequested]
        case .aborted:
            return [.triggered, .authorized, .admitted, .dispatched, .leased, .running, .unknown, .unknownReconciled, .aborted]
        }
    }

    private func rejectCorruptLedger() {
        let quarantinePath = quarantineCorruptLedger()
        persistenceError = .corruptLedger(quarantinePath: quarantinePath)
        occurrences = []
        occurrenceJournal = []
    }

    private func persist() {
        // Authorization's existing ledger-failure rollback still persists its
        // before-image. A rejected definitions load never grants a write path.
        if let persistenceError, case .invalidTaskDefinitions = persistenceError { return }
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Creation/preview confirmation must observe the written definitions
    /// before reporting success or committing authorization to the ledger.
    /// This is the existing UserDefaults reopen contract, not a disk flush
    /// or an atomic transaction spanning preferences and the occurrence file.
    private func persistConfirmedDefinitions() -> Bool {
        persist()
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let written = try? JSONDecoder().decode([SchedulerTask].self, from: data),
              written == tasks else {
            if persistenceError == nil {
                persistenceError = .taskDefinitionsWriteFailed(defaultsKey: Self.defaultsKey)
            }
            return false
        }
        return true
    }

    private func restoreOccurrenceSnapshot(
        _ previousOccurrences: [SchedulerOccurrence],
        _ previousJournal: [SchedulerOccurrenceJournalEntry]
    ) {
        occurrences = previousOccurrences
        occurrenceJournal = previousJournal
    }

    @discardableResult
    private func persistOccurrences() -> Bool {
        let ledger = OccurrenceLedger(schemaVersion: 1, occurrences: occurrences, journal: occurrenceJournal)
        guard let data = try? JSONEncoder().encode(ledger) else {
            persistenceError = .ledgerWriteFailed(path: occurrenceLedgerURL.path)
            return false
        }
        guard persistenceError == nil else { return false }
        var committed = false
        guard withLockedLedger({
            do {
                let diskData: Data?
                if FileManager.default.fileExists(atPath: occurrenceLedgerURL.path) {
                    diskData = try Data(contentsOf: occurrenceLedgerURL)
                } else {
                    diskData = nil
                }
                // A second store may have won the same claim. Its write must
                // not be replaced with this instance's stale before-image.
                guard diskData == lastObservedLedgerData else {
                    persistenceError = .ledgerWriteFailed(path: occurrenceLedgerURL.path)
                    return
                }
                try writeAtomically(data, to: occurrenceLedgerURL)
                lastObservedLedgerData = data
                committed = true
            } catch {
                persistenceError = .ledgerWriteFailed(path: occurrenceLedgerURL.path)
            }
        }) else {
            persistenceError = .ledgerWriteFailed(path: occurrenceLedgerURL.path)
            return false
        }
        return committed
    }

    /// One sidecar flock covers the read/compare/rename cycle, including a
    /// nested persist from reserveOccurrence. MainActor serializes stores in
    /// this process; flock also fences another process using the same root.
    private func withLockedLedger(_ body: () -> Void) -> Bool {
        if heldLedgerLockFD != nil { body(); return true }
        let directory = occurrenceLedgerURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        let lockURL = occurrenceLedgerURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var acquired = false
        for _ in 0..<50 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            guard errno == EWOULDBLOCK else { return false }
            Darwin.usleep(2_000)
        }
        guard acquired else { return false }
        heldLedgerLockFD = descriptor
        defer {
            heldLedgerLockFD = nil
            _ = flock(descriptor, LOCK_UN)
        }
        body()
        return true
    }

    private func quarantineCorruptLedger() -> String {
        let quarantine = occurrenceLedgerURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: occurrenceLedgerURL, to: quarantine)
            return quarantine.path
        } catch {
            // Keep the original in place if it cannot be moved. The store is
            // still fail-closed and will never overwrite the evidence.
            return occurrenceLedgerURL.path
        }
    }

    /// Write a complete ledger beside the destination, fsync it, then rename
    /// it into place. A torn write therefore leaves either old or new JSON.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        var descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: url.path) }
        var completed = false
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if !completed { _ = temporaryURL.path.withCString { Darwin.unlink($0) } }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                guard written > 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: url.path) }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: url.path) }
        guard Darwin.close(descriptor) == 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: url.path) }
        descriptor = -1
        let renameResult = temporaryURL.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renameResult == 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: url.path) }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: directory.path) }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw SchedulerTaskStoreError.ledgerWriteFailed(path: directory.path) }
        completed = true
    }

    private func appendJournal(for occurrence: SchedulerOccurrence, at date: Date = Date()) {
        occurrenceJournal.append(
            SchedulerOccurrenceJournalEntry(
                sequence: occurrenceJournal.count + 1,
                occurrenceID: occurrence.id,
                idempotencyKey: occurrence.idempotencyKey,
                effectID: occurrence.effectID,
                state: occurrence.state,
                recordedAt: date
            )
        )
    }

    /// Validate the complete decoded projection before admitting it into the
    /// live store. This rejects semantic corruption that still parses as JSON.
    private func validateLedger(
        occurrences: [SchedulerOccurrence],
        journal: [SchedulerOccurrenceJournalEntry]
    ) -> Bool {
        let occurrenceIDs = occurrences.map(\.id)
        let idempotencyKeys = occurrences.map(\.idempotencyKey)
        guard Set(occurrenceIDs).count == occurrenceIDs.count,
              Set(idempotencyKeys).count == idempotencyKeys.count,
              occurrences.allSatisfy({
                  $0.taskVersion > 0
                      && $0.controlRevision > 0
                      && $0.controlRevision == $0.taskVersion
                      && !$0.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.id, $0) })
        let byIndex = Dictionary(uniqueKeysWithValues: occurrences.enumerated().map { ($0.element.id, $0.offset) })
        // Retry ancestry is an explicit bounded DAG. Parent rows must already
        // exist in ledger order; this rejects cycles and retry storms before
        // any projected state is admitted.
        guard occurrences.allSatisfy({ occurrence in
            var cursor = occurrence
            var visited = Set<UUID>()
            // Count rows, not parent edges: the starting row is row one.
            // This intentionally matches retryUnknownOccurrence's group
            // count fence, so a ninth decoded row cannot be admitted.
            var chainLength = 1
            while let parentID = cursor.retryOfOccurrenceID {
                guard chainLength < Self.maxRetryChainLength,
                      visited.insert(cursor.id).inserted,
                      let parent = byID[parentID],
                      let parentIndex = byIndex[parentID],
                      let childIndex = byIndex[cursor.id],
                      parentIndex < childIndex else { return false }
                cursor = parent
                chainLength += 1
            }
            return visited.insert(cursor.id).inserted
        }) else { return false }
        let semanticGroups = Dictionary(grouping: occurrences) {
            "\($0.taskID.uuidString.lowercased())|\($0.scheduledMinute.timeIntervalSinceReferenceDate)|\($0.taskVersion)"
        }
        // A semantic identity may be reopened only through an explicit,
        // persisted retry chain. A second root (or two attempts claiming the
        // same parent) is ledger corruption and must quarantine fail-closed.
        guard semanticGroups.values.allSatisfy({ group in
            let roots = group.filter { $0.retryOfOccurrenceID == nil }
            guard roots.count == 1 else { return false }
            var invalidParent = false
            let children = group.compactMap { occurrence -> UUID? in
                guard let parentID = occurrence.retryOfOccurrenceID else { return nil }
                guard parentID != occurrence.id,
                      let parent = byID[parentID],
                      parent.taskID == occurrence.taskID,
                      parent.scheduledMinute == occurrence.scheduledMinute,
                      parent.taskVersion == occurrence.taskVersion,
                      parent.state == .retryRequested else {
                    invalidParent = true
                    return nil
                }
                return parentID
            }
            guard children.count == group.count - 1,
                  Set(children).count == children.count,
                  !invalidParent else { return false }
            return true
        }) else { return false }
        guard journal.enumerated().allSatisfy({ offset, entry in
            entry.sequence == offset + 1
                && byID[entry.occurrenceID]?.idempotencyKey == entry.idempotencyKey
                && byID[entry.occurrenceID]?.effectID == entry.effectID
        }) else { return false }
        for occurrence in occurrences {
            // Routing is pinned at reservation. Current-version rows must
            // match the task; edited tasks retain historical snapshots.
            guard let sourceTask = task(id: occurrence.taskID),
                  occurrence.taskVersion <= sourceTask.version else { return false }
            if occurrence.taskVersion == sourceTask.version {
                guard occurrence.targetSessionID == sourceTask.targetSessionID,
                      occurrence.targetProjectID == sourceTask.targetProjectID,
                      occurrence.targetTurnID == sourceTask.targetTurnID else { return false }
            }
            let facts = journal.filter { $0.occurrenceID == occurrence.id }
            guard let firstFact = facts.first,
                  firstFact.state == .triggered,
                  let lastFact = facts.last,
                  lastFact.state == occurrence.state else { return false }
            let activeLease = occurrence.state == .leased || occurrence.state == .running
            if activeLease {
                guard let owner = occurrence.leaseOwner,
                      !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let token = occurrence.leaseToken,
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      occurrence.leaseExpiresAt != nil,
                      occurrence.deliveryReceipt == nil else { return false }
            } else {
                guard occurrence.leaseOwner == nil,
                      occurrence.leaseToken == nil,
                      occurrence.leaseExpiresAt == nil else { return false }
            }
            if occurrence.state == .succeeded || occurrence.state == .failed {
                guard let receipt = occurrence.submissionReceipt,
                      receipt.request.hasValidTarget else { return false }
            }
            if let submissionReceipt = occurrence.submissionReceipt {
                let request = submissionReceipt.request
                guard request.occurrenceID == occurrence.id,
                      request.effectID == occurrence.effectID,
                      request.taskID == occurrence.taskID,
                      request.taskVersion == occurrence.taskVersion,
                      request.idempotencyKey == occurrence.idempotencyKey,
                      !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      request.sourceTaskID == occurrence.taskID,
                      request.targetSessionID == occurrence.targetSessionID,
                      request.targetProjectID == occurrence.targetProjectID,
                      request.targetTurnID == occurrence.targetTurnID,
                      request.hasValidTarget,
                      submissionReceipt.status == occurrence.deliveryReceipt?.status,
                      occurrence.state == .succeeded || occurrence.state == .failed
                        || occurrence.state == .unknown || occurrence.state == .unknownReconciled
                        || occurrence.state == .retryRequested || occurrence.state == .aborted else {
                    return false
                }
            }
            if occurrence.state == .unknown && occurrence.reconciliationProof != nil {
                return false
            }
            if occurrence.state == .unknownReconciled || occurrence.state == .retryRequested || occurrence.state == .aborted {
                guard let proof = occurrence.reconciliationProof,
                      !proof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      proof == proof.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            }
            if occurrence.state == .succeeded {
                guard occurrence.deliveryReceipt?.status == .delivered else { return false }
            }
            if occurrence.state == .failed {
                guard occurrence.deliveryReceipt?.status == .failed else { return false }
            }
            if occurrence.state == .unknown || occurrence.state == .unknownReconciled || occurrence.state == .retryRequested || occurrence.state == .aborted {
                guard occurrence.deliveryReceipt?.status == .unknown else { return false }
            }
            var prior: SchedulerOccurrenceState?
            for entry in journal where entry.occurrenceID == occurrence.id {
                if let prior, prior != entry.state,
                   !Self.validTransition(from: prior, to: entry.state) {
                    return false
                }
                prior = entry.state
            }
        }
        return true
    }

    private static func validTransition(from: SchedulerOccurrenceState, to: SchedulerOccurrenceState) -> Bool {
        switch (from, to) {
        case (.triggered, .waitingApproval),
             (.triggered, .authorized),
             (.triggered, .cancelled),
             (.waitingApproval, .authorized),
             (.waitingApproval, .cancelled),
             (.authorized, .admitted),
             (.authorized, .cancelled),
             (.admitted, .dispatched),
             (.admitted, .cancelled),
             (.dispatched, .leased),
             (.dispatched, .cancelled),
             (.leased, .running),
             (.leased, .cancelled),
             (.leased, .unknown),
             (.running, .succeeded),
             (.running, .failed),
             (.running, .cancelled),
             (.running, .unknown),
             (.unknown, .succeeded),
             (.unknown, .unknownReconciled),
             (.unknownReconciled, .retryRequested),
             (.unknownReconciled, .aborted):
            return true
        default:
            return false
        }
    }
}
