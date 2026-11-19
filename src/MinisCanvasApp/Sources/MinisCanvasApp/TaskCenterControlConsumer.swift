import Foundation
import MinisCore

public enum TaskCenterReceiptState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case approvalRequired
    case inputRequired
    case failed
    case cancelled
    case retrying
    case completed

    public var title: String {
        switch self {
        case .queued: return "排队"
        case .running: return "运行中"
        case .approvalRequired: return "等待审批"
        case .inputRequired: return "等待输入"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .retrying: return "重试中"
        case .completed: return "已完成"
        }
    }
}

public enum TaskCenterFilterStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case inProgress
    case waitingApproval
    case failed
    case completed

    public var title: String {
        switch self {
        case .inProgress: return "进行中"
        case .waitingApproval: return "待审批"
        case .failed: return "失败"
        case .completed: return "已完成"
        }
    }
}

public struct TaskCenterReceiptFilter: Codable, Equatable, Sendable {
    public let status: TaskCenterFilterStatus?
    public let sourceSessionID: String?
    public let includeArchived: Bool

    public init(
        status: TaskCenterFilterStatus? = nil,
        sourceSessionID: String? = nil,
        includeArchived: Bool = false
    ) {
        self.status = status
        self.sourceSessionID = sourceSessionID
        self.includeArchived = includeArchived
    }
}

/// Presentation sections from the same filtered canonical receipts. Folding
/// history never archives, cancels, retries or changes a task identity.
struct TaskCenterHomeReceiptSections: Equatable, Sendable {
    let current: [TaskCenterReceiptRow]
    let recentHistory: [TaskCenterReceiptRow]
}

public struct TaskCenterArchiveRequest: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let actorID: String
    public let idempotencyKey: String
    public let action: AgentTaskArchiveAction

    public init(
        taskID: String,
        parentID: String,
        actorID: String,
        idempotencyKey: String,
        action: AgentTaskArchiveAction
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.actorID = actorID
        self.idempotencyKey = idempotencyKey
        self.action = action
    }
}

/// A single observation snapshot's user-facing lifecycle classification.
/// This is intentionally separate from receipt state: an identity mismatch is
/// stale evidence, not a new task outcome.
public enum TaskCenterObservationState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case attention
    case terminal
    case stale

    public var title: String {
        switch self {
        case .queued: return "排队"
        case .running: return "运行中"
        case .attention: return "需要处理"
        case .terminal: return "终态"
        case .stale: return "陈旧观测"
        }
    }
}

/// Stable identity carried by every task-center observation. Event sequence is
/// optional for legacy ledgers, but when present it fences the displayed event
/// to the same task/run/attempt tuple.
public struct TaskCenterObservationIdentity: Codable, Equatable, Hashable, Sendable {
    public let taskID: String
    public let parentID: String
    public let runID: String?
    public let attemptID: String?
    public let eventSequence: Int?

    public init(
        taskID: String,
        parentID: String,
        runID: String?,
        attemptID: String?,
        eventSequence: Int?
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.runID = runID
        self.attemptID = attemptID
        self.eventSequence = eventSequence
    }
}

/// Stable, read-only navigation target for a child transcript. The parent
/// identity is retained so closing the child view can return without rebinding
/// to whichever conversation happens to be active later.
public struct TaskCenterChildSessionNavigation: Codable, Equatable, Sendable {
    public let parentSessionID: String
    public let childSessionID: String
    public let taskID: String
    /// Nil in old result-only rows. Only a ledger-bound locator can open content.
    public let locator: ChildTranscriptLocator?

    public init(parentSessionID: String, childSessionID: String, taskID: String) {
        self.parentSessionID = parentSessionID
        self.childSessionID = childSessionID
        self.taskID = taskID
        self.locator = nil
    }

    public init(locator: ChildTranscriptLocator) {
        self.parentSessionID = locator.parentSessionID
        self.childSessionID = locator.childSessionID
        self.taskID = locator.taskID
        self.locator = locator
    }

    public var accessibilityLabel: String {
        "打开子会话 \(childSessionID)，返回父会话 \(parentSessionID)"
    }
}

/// Read-only, bounded presentation copied from a verified persisted child session.
/// Tool arguments, tool output and media are never part of this value.
public struct TaskCenterChildTranscriptMessage: Equatable, Sendable, Identifiable {
    public let id: Int
    public let roleTitle: String
    public let content: String
}

public struct TaskCenterChildTranscript: Equatable, Sendable {
    public let navigation: TaskCenterChildSessionNavigation
    public let revision: UInt64
    public let truncated: Bool
    public let messages: [TaskCenterChildTranscriptMessage]
}

/// Read-only destination for the one live approval prompt. The request itself
/// stays in ApprovalPromptCenter and is revalidated before presentation.
public struct TaskCenterApprovalNavigation: Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let sessionID: String
    public let runID: String
    public let attemptID: String
    public let requestID: String
    public let identityDigest: String
}

/// A source-session destination is tied to one canonical task observation.
/// It never switches the active ChatStore session by itself.
public struct TaskCenterSourceSessionNavigation: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let sourceSessionID: String
    public let runID: String?
    public let attemptID: String?

    public init(
        taskID: String, parentID: String, sourceSessionID: String,
        runID: String?, attemptID: String?
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.sourceSessionID = sourceSessionID
        self.runID = runID
        self.attemptID = attemptID
    }
}

public struct TaskCenterSourceSessionTranscript: Equatable, Sendable {
    public let navigation: TaskCenterSourceSessionNavigation
    public let revision: UInt64
    public let truncated: Bool
    public let messages: [TaskCenterChildTranscriptMessage]
}

/// Opens a canonical child result, not a filesystem artifact. Evidence refs
/// are not ArtifactStore identities and must never become file URLs here.
public struct TaskCenterResultNavigation: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let runID: String
    public let attemptID: String
    public let resultIdempotencyKey: String

    public init(
        taskID: String, parentID: String, runID: String,
        attemptID: String, resultIdempotencyKey: String
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.runID = runID
        self.attemptID = attemptID
        self.resultIdempotencyKey = resultIdempotencyKey
    }
}

public struct TaskCenterResultDetail: Equatable, Sendable {
    public let navigation: TaskCenterResultNavigation
    public let statusTitle: String
    public let outputDigest: String
    public let displayOutput: String?
    public let evidenceCount: Int
    public let durationSeconds: Double?
    public let tokenUsage: ChildResultTokenUsage?
    public let settledToolCalls: Int?
    public let artifactsComplete: Bool
    public let files: [TaskCenterFileArtifactNavigation]
}

/// Bounded output/artifact information for Task Center. Raw child output is
/// intentionally omitted; the canonical result envelope remains the source
/// and a verified child session can show bounded, safe transcript text.
public struct TaskCenterArtifactSummary: Codable, Equatable, Sendable {
    public let outputDigest: String?
    public let evidenceReferences: [String]
    public let hasOutput: Bool

    public init(envelope: ChildResultEnvelope) {
        outputDigest = envelope.outputDigest.isEmpty ? nil : envelope.outputDigest
        evidenceReferences = envelope.evidenceRefs
        hasOutput = envelope.output != nil
    }

    public var title: String {
        if evidenceReferences.isEmpty {
            return hasOutput ? "已有输出" : "暂无产物"
        }
        return "产物 \(evidenceReferences.count) 项"
    }
}

/// Durable success-terminal backlink for one settled child task, projected
/// from the canonical ledger only when the task snapshot, its canonical
/// receipt and the canonical terminal event all agree on the same
/// run/attempt identity. This mirrors the external-session
/// `lastOutputBacklink` semantics: event identity plus bounded digest only,
/// never raw child output. A succeeded task whose receipts do not resolve
/// keeps no backlink at all ("not recorded"); the projection never invents
/// a placeholder to make a terminal success look settled.
public struct TaskCenterSucceededBacklink: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let sourceSessionID: String?
    public let runID: String
    public let attemptID: String
    public let terminalEventSequence: Int
    /// Canonical child-result identity when the success settled with an
    /// envelope; nil for plain finished runs.
    public let resultIdempotencyKey: String?
    public let outputDigest: String?
    public let evidenceReferences: [String]

    init(
        task: AgentTaskSnapshot,
        receipt: AgentTaskReceipt,
        terminalEventSequence: Int,
        envelope: ChildResultEnvelope?
    ) {
        self.taskID = task.taskID
        self.parentID = task.parentID
        self.sourceSessionID = task.sourceSessionID
        self.runID = receipt.runID
        self.attemptID = receipt.attemptID
        self.terminalEventSequence = terminalEventSequence
        self.resultIdempotencyKey = envelope?.idempotencyKey
        if let digest = envelope?.outputDigest, !digest.isEmpty {
            self.outputDigest = digest
        } else {
            self.outputDigest = nil
        }
        self.evidenceReferences = envelope?.evidenceRefs ?? []
    }

    public var accessibilityLabel: String {
        var parts = [
            "成功回执回链",
            "Task \(taskID)",
            "Run \(runID)",
            "Attempt \(attemptID)",
            "事件序号 \(terminalEventSequence)"
        ]
        if let resultIdempotencyKey {
            parts.append("Result " + resultIdempotencyKey)
        }
        if let outputDigest {
            parts.append("摘要 " + outputDigest)
        }
        parts.append(sourceSessionID.map { "来源会话 " + $0 } ?? "来源会话未知")
        return parts.joined(separator: "，")
    }
}

/// Recovery is separate from task state: a recovered running task is not a
/// terminal fact and must be reviewed before another control action is issued.
public enum TaskCenterRecoveryState: String, Codable, Equatable, Sendable {
    case none
    case needsUserReview

    public var title: String {
        switch self {
        case .none: return "无需复核"
        case .needsUserReview: return "需要人工复核"
        }
    }
}

/// One stable, user-visible receipt row projected from the canonical task ledger.
///
/// Task, run, attempt and effect are intentionally represented together so a
/// refresh, session switch, or process restart cannot make the UI invent a
/// second identity. Effect IDs are stable local receipt identities; the
/// durable task receipt remains the source of outcome truth.
public struct TaskCenterReceiptRow: Codable, Equatable, Sendable, Identifiable {
    // Reanchored from the existing 29ac412 TASK09 donor.
    public var isDefaultSurfacePriority: Bool {
        switch lifecycleState {
        case .queued, .running, .approvalRequired, .inputRequired, .retrying, .failed:
            return true
        case .cancelled, .completed:
            return false
        }
    }

    public let taskID: String
    public let parentID: String
    public let sessionID: String
    public let sourceSessionID: String?
    public let receiptID: String
    public let runID: String?
    public let attemptID: String?
    public let effectID: String
    public let taskState: TaskCenterReceiptState
    public let runState: TaskCenterReceiptState
    public let attemptState: TaskCenterReceiptState
    public let effectState: TaskCenterReceiptState
    /// Lifecycle state from the latest canonical task event. This preserves
    /// approval/input pauses that are not representable by AgentTaskStatus.
    public let lifecycleState: TaskCenterReceiptState
    /// State of this one identity-bound observation; stale never masquerades
    /// as a fresh task outcome.
    public let observationState: TaskCenterObservationState
    public let observationIdentity: TaskCenterObservationIdentity
    /// Exact persisted child-session identity and lossless return target.
    public let childSessionID: String?
    public let childNavigation: TaskCenterChildSessionNavigation?
    /// Canonical child result for this exact task/run/attempt, if settled.
    public let childResultEnvelope: ChildResultEnvelope?
    public let artifactSummary: TaskCenterArtifactSummary?
    /// Exact canonical cancelled-attempt interval; legacy ledgers remain unknown.
    public let cancelledAttemptDuration: TimeInterval?
    /// Durable success-terminal backlink, projected only when this row's
    /// canonical receipt and terminal event both prove the same success.
    public let succeededBacklink: TaskCenterSucceededBacklink?
    /// Canonical user-authored title, projected only from the durable
    /// session-creation provenance (`creation.action.title`). Tasks without
    /// creation metadata — including real dispatched agent child tasks — have
    /// no canonical title and stay nil so the UI can fall back to the task ID.
    public let userTitle: String?
    /// Kind of the latest canonical event on this row's observed run. Pairs
    /// with `observationIdentity.eventSequence` to project ledger progress;
    /// it never copies or re-derives task state.
    public let lastEventKind: AgentTaskEventKind?
    /// Durable recovery projection; no control is exposed while review is needed.
    public let recoveryState: TaskCenterRecoveryState
    /// Read-only classification of a recovered, unsettled production child.
    /// It is never a terminal receipt or authority to resume the child.
    public let needsChildTerminalReview: Bool
    public let failureReason: String?
    public let retryAvailable: Bool
    public let cancelAvailable: Bool
    public let isArchived: Bool
    public let archiveAvailable: Bool
    public let restoreAvailable: Bool

    /// Current-process observation only; never encoded as a durable receipt.
    public private(set) var childToolActivityTitle: String? = nil
    /// Read-only projection from the identity-bound child transcript; never a receipt.
    public private(set) var todoProgress: SessionTodoProgress? = nil

    public var stableID: String {
        let identity = "\(parentID.count):\(parentID)\(taskID.count):\(taskID)"
        return Data(identity.utf8).base64EncodedString()
    }

    public var id: String { stableID }

    private enum CodingKeys: String, CodingKey {
        case taskID, parentID, sessionID, sourceSessionID, receiptID, runID, attemptID, effectID
        case taskState, runState, attemptState, effectState, lifecycleState
        case observationState, observationIdentity
        case childSessionID, childNavigation, childResultEnvelope, artifactSummary
        case succeededBacklink, cancelledAttemptDuration
        case userTitle, lastEventKind
        case recoveryState, needsChildTerminalReview, failureReason
        case retryAvailable, cancelAvailable, isArchived, archiveAvailable, restoreAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(String.self, forKey: .taskID)
        parentID = try container.decode(String.self, forKey: .parentID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        sourceSessionID = try container.decodeIfPresent(String.self, forKey: .sourceSessionID)
        receiptID = try container.decode(String.self, forKey: .receiptID)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID)
        effectID = try container.decode(String.self, forKey: .effectID)
        taskState = try container.decode(TaskCenterReceiptState.self, forKey: .taskState)
        runState = try container.decode(TaskCenterReceiptState.self, forKey: .runState)
        attemptState = try container.decode(TaskCenterReceiptState.self, forKey: .attemptState)
        effectState = try container.decode(TaskCenterReceiptState.self, forKey: .effectState)
        lifecycleState = try container.decodeIfPresent(
            TaskCenterReceiptState.self,
            forKey: .lifecycleState
        ) ?? taskState
        observationState = try container.decodeIfPresent(
            TaskCenterObservationState.self,
            forKey: .observationState
        ) ?? Self.deriveObservationState(lifecycleState: lifecycleState, stale: false)
        observationIdentity = try container.decodeIfPresent(
            TaskCenterObservationIdentity.self,
            forKey: .observationIdentity
        ) ?? TaskCenterObservationIdentity(
            taskID: taskID,
            parentID: parentID,
            runID: runID,
            attemptID: attemptID,
            eventSequence: nil
        )
        let decodedNavigation = try container.decodeIfPresent(
            TaskCenterChildSessionNavigation.self,
            forKey: .childNavigation
        )
        // Legacy serialized rows may contain a deterministic placeholder ID.
        // Never turn that value into a navigable session.
        if let decodedNavigation,
           let locator = decodedNavigation.locator,
           locator.isWellFormed,
           locator.taskID == taskID,
           locator.parentID == parentID,
           locator.runID == runID,
           locator.attemptID == attemptID,
           locator.childSessionID == decodedNavigation.childSessionID,
           locator.parentSessionID == decodedNavigation.parentSessionID {
            childNavigation = decodedNavigation
        } else {
            childNavigation = nil
        }
        childSessionID = childNavigation?.childSessionID
        childResultEnvelope = try container.decodeIfPresent(
            ChildResultEnvelope.self,
            forKey: .childResultEnvelope
        )
        artifactSummary = try container.decodeIfPresent(
            TaskCenterArtifactSummary.self,
            forKey: .artifactSummary
        )
        succeededBacklink = try container.decodeIfPresent(
            TaskCenterSucceededBacklink.self,
            forKey: .succeededBacklink
        )
        cancelledAttemptDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .cancelledAttemptDuration)
        userTitle = try container.decodeIfPresent(String.self, forKey: .userTitle)
        lastEventKind = try container.decodeIfPresent(
            AgentTaskEventKind.self,
            forKey: .lastEventKind
        )
        recoveryState = try container.decodeIfPresent(
            TaskCenterRecoveryState.self,
            forKey: .recoveryState
        ) ?? .none
        needsChildTerminalReview = (try container.decodeIfPresent(
            Bool.self, forKey: .needsChildTerminalReview
        ) ?? false) && recoveryState == .needsUserReview
            && childResultEnvelope == nil && runID != nil
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        retryAvailable = try container.decode(Bool.self, forKey: .retryAvailable)
        cancelAvailable = try container.decode(Bool.self, forKey: .cancelAvailable)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        archiveAvailable = try container.decodeIfPresent(Bool.self, forKey: .archiveAvailable) ?? false
        restoreAvailable = try container.decodeIfPresent(Bool.self, forKey: .restoreAvailable) ?? isArchived
    }

    /// An execution deadline is a terminal cause carried by the canonical
    /// child result. Lease expiry and observation time are separate facts.
    public var isDeadlineExpired: Bool {
        guard lifecycleState == .failed, observationState == .terminal,
              lastEventKind == .failed,
              let envelope = childResultEnvelope,
              envelope.taskID == taskID,
              envelope.runID == runID,
              envelope.attemptID == attemptID,
              observationIdentity.taskID == taskID,
              observationIdentity.parentID == parentID,
              observationIdentity.runID == runID,
              observationIdentity.attemptID == attemptID,
              case .failed(let reason) = envelope.outcome else { return false }
        return reason == "DEADLINE_EXCEEDED"
    }

    public var statusTitle: String {
        isDeadlineExpired ? "已过期" : lifecycleState.title
    }

    public var isStale: Bool { observationState == .stale }

    /// Names the observed ledger event without treating it as a measured work percentage.
    public var currentStepTitle: String {
        if isDeadlineExpired { return "已过期" }
        return lastEventKind.map { TaskCenterEventKindLabel.title(for: $0) } ?? lifecycleState.title
    }

    public var eventProgressTitle: String? {
        if let todoProgress, !todoProgress.todos.isEmpty {
            return ProductRedactionPolicy.redact(todoProgress.summary)
        }
        guard let sequence = observationIdentity.eventSequence,
              let lastEventKind else { return nil }
        return "事件 \(sequence)（\(TaskCenterEventKindLabel.title(for: lastEventKind))）"
    }

    /// Use the settled child interval, or the canonical cancelled attempt's
    /// observed interval. Missing/unordered clocks never produce a duration.
    public func durationTitle() -> String {
        let seconds: TimeInterval
        if let envelope = childResultEnvelope,
           let startedAt = envelope.startedAt, let finishedAt = envelope.finishedAt {
            seconds = finishedAt.timeIntervalSince(startedAt)
        } else if childResultEnvelope == nil, lifecycleState == .cancelled,
                  let cancelledAttemptDuration {
            seconds = cancelledAttemptDuration
        } else { return "未记录" }
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else {
            return "未记录"
        }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)秒" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return "\(minutes)分\(remainder)秒" }
        return "\(minutes / 60)小时\(minutes % 60)分\(remainder)秒"
    }

    /// Compact user-facing explanation; canonical failureReason remains in details.
    public var failureReasonDisplayTitle: String? {
        guard let failureReason else { return nil }
        switch failureReason {
        case "execution-failed": return "执行未完成，请查看任务详情"
        case AgentTaskPublicFailureCategory.projectTargetUnavailable.message:
            return AgentTaskPublicFailureCategory.projectTargetUnavailable.title
        case AgentTaskPublicFailureCategory.chatRuntimeMissingRequiredSnapshot.message:
            return AgentTaskPublicFailureCategory.chatRuntimeMissingRequiredSnapshot.title
        default: return "任务执行未完成，详情暂不可用"
        }
    }

    public var resultSummaryTitle: String {
        if needsChildTerminalReview { return "子任务真实终态未记录" }
        if isDeadlineExpired { return "已过期" }
        if let envelope = childResultEnvelope {
            switch envelope.outcome {
            case .succeeded:
                if artifactSummary?.hasOutput == true { return "已完成 · 有输出" }
                if artifactSummary?.evidenceReferences.isEmpty == false { return "已完成 · 有证据" }
                return "已完成"
            case .failed:
                return "失败 · \(failureReasonDisplayTitle ?? "原因未记录")"
            case .cancelled:
                return "已取消"
            }
        }
        switch lifecycleState {
        case .failed: return "失败 · \(failureReasonDisplayTitle ?? "原因未记录")"
        case .cancelled: return "已取消"
        case .completed: return "结果未记录"
        case .queued, .running, .approvalRequired, .inputRequired, .retrying:
            return "尚无结果"
        }
    }

    public var retryAccessibilityLabel: String? {
        retryAvailable ? "重试任务 \(taskID)" : nil
    }

    public var cancelAccessibilityLabel: String? {
        cancelAvailable ? "取消任务 \(taskID)" : nil
    }

    public var accessibilityLabel: String {
        var parts = [
            "任务 \(taskID)",
            "Task 状态 \(statusTitle)",
            "观测状态 \(observationState.title)",
            "Run \(runID ?? "未创建")，状态 \(runState.title)",
            "Attempt \(attemptID ?? "未创建")，状态 \(attemptState.title)",
            "Effect \(effectID)，状态 \(effectState.title)"
        ]
        if let userTitle {
            parts.insert("标题 \(userTitle)", at: 1)
        }
        parts.append("当前步骤 \(currentStepTitle)")
        parts.append("进度 \(eventProgressTitle ?? "未记录")")
        parts.append("耗时 \(durationTitle())")
        parts.append("结果 \(resultSummaryTitle)")
        if let failureReason {
            parts.append("原因 \(failureReason)")
        }
        if let childResultEnvelope {
            parts.append("Result \(childResultEnvelope.idempotencyKey)")
        }
        if let childSessionID {
            parts.append("子会话 \(childSessionID)")
        }
        if let artifactSummary {
            parts.append(artifactSummary.title)
        }
        if let succeededBacklink {
            parts.append(
                "成功回执回链 Run \(succeededBacklink.runID)，Attempt \(succeededBacklink.attemptID)，事件序号 \(succeededBacklink.terminalEventSequence)"
            )
        }
        if let sourceSessionID {
            parts.append("来源会话 " + sourceSessionID)
        } else {
            parts.append("来源会话未知")
        }
        if isArchived {
            parts.append("已归档")
        }
        if recoveryState != .none {
            parts.append(recoveryState.title)
        }
        if needsChildTerminalReview {
            parts.append("子任务 \(taskID) 的父任务 \(parentID)，Run \(runID ?? "未记录") 真实终态未记录")
        }
        if retryAvailable {
            parts.append("可重试")
        }
        if cancelAvailable {
            parts.append("可取消")
        }
        return parts.joined(separator: "，")
    }

    fileprivate init(
        taskID: String,
        parentID: String,
        sessionID: String,
        sourceSessionID: String?,
        receiptID: String,
        runID: String?,
        attemptID: String?,
        effectID: String,
        state: TaskCenterReceiptState,
        lifecycleState: TaskCenterReceiptState,
        observationState: TaskCenterObservationState,
        observationIdentity: TaskCenterObservationIdentity,
        childNavigation: TaskCenterChildSessionNavigation?,
        childResultEnvelope: ChildResultEnvelope?,
        succeededBacklink: TaskCenterSucceededBacklink?,
        userTitle: String?,
        lastEventKind: AgentTaskEventKind?,
        recoveryState: TaskCenterRecoveryState,
        needsChildTerminalReview: Bool,
        failureReason: String?,
        retryAvailable: Bool,
        cancelAvailable: Bool,
        isArchived: Bool,
        archiveAvailable: Bool,
        restoreAvailable: Bool,
        cancelledAttemptDuration: TimeInterval? = nil,
        childToolActivityTitle: String? = nil,
        todoProgress: SessionTodoProgress? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.sessionID = sessionID
        self.sourceSessionID = sourceSessionID
        self.receiptID = receiptID
        self.runID = runID
        self.attemptID = attemptID
        self.effectID = effectID
        taskState = state
        runState = state
        attemptState = state
        effectState = state
        self.lifecycleState = lifecycleState
        self.observationState = observationState
        self.observationIdentity = observationIdentity
        self.childSessionID = childNavigation?.childSessionID
        self.childNavigation = childNavigation
        self.childResultEnvelope = childResultEnvelope
        artifactSummary = childResultEnvelope.map(TaskCenterArtifactSummary.init)
        self.succeededBacklink = succeededBacklink
        self.userTitle = userTitle
        self.lastEventKind = lastEventKind
        self.recoveryState = recoveryState
        self.needsChildTerminalReview = needsChildTerminalReview
        self.failureReason = failureReason
        self.retryAvailable = retryAvailable
        self.cancelAvailable = cancelAvailable
        self.isArchived = isArchived
        self.archiveAvailable = archiveAvailable
        self.restoreAvailable = restoreAvailable
        self.cancelledAttemptDuration = cancelledAttemptDuration
        self.childToolActivityTitle = childToolActivityTitle
        self.todoProgress = todoProgress
    }

    fileprivate static func deriveObservationState(
        lifecycleState: TaskCenterReceiptState,
        stale: Bool
    ) -> TaskCenterObservationState {
        if stale { return .stale }
        switch lifecycleState {
        case .approvalRequired, .inputRequired: return .attention
        case .completed, .failed, .cancelled: return .terminal
        case .running, .retrying: return .running
        case .queued: return .queued
        }
    }
}

enum TaskCenterEventKindLabel {
    static func title(for kind: AgentTaskEventKind?) -> String {
        guard let kind else { return "无事件" }
        switch kind {
        case .started: return "已启动"
        case .progress: return "进展"
        case .approvalRequired: return "等待审批"
        case .inputRequired: return "等待输入"
        case .submissionUnknown: return "提交状态未知"
        case .completed: return "已完成"
        case .failed: return "已失败"
        case .cancelled: return "已取消"
        case .terminalDuplicate: return "重复终态"
        }
    }
}

public enum TaskCenterControlAction: String, Codable, Equatable, Sendable {
    case pause
    case resume
    case stop
    case retry
    case cancel

    fileprivate var goalCommand: GoalTaskCenterCommand {
        switch self {
        case .pause: return .pause
        case .resume: return .resume
        case .stop, .cancel: return .stop
        case .retry: return .retry
        }
    }

    var title: String {
        switch self {
        case .pause: return "暂停"
        case .resume: return "恢复"
        case .stop: return "停止"
        case .retry: return "重试"
        case .cancel: return "取消"
        }
    }

    var keylineIcon: MinisIcon {
        switch self {
        case .pause: return .pause
        case .resume: return .play
        case .stop: return .stop
        case .retry: return .retry
        case .cancel: return .cancel
        }
    }

    var systemImage: String {
        switch self {
        case .pause: return "pause.circle"
        case .resume: return "play.circle"
        case .stop: return "stop.circle"
        case .retry: return "arrow.clockwise.circle"
        case .cancel: return "xmark.circle"
        }
    }
}

public struct TaskCenterControlRequest: Codable, Equatable, Sendable {
    public let taskID: String
    public let parentID: String
    public let revision: String
    public let scopeID: String
    public let actorID: String
    public let idempotencyKey: String
    public let action: TaskCenterControlAction
    public let runID: String?

    public init(
        taskID: String,
        parentID: String,
        revision: String,
        scopeID: String,
        actorID: String,
        idempotencyKey: String,
        action: TaskCenterControlAction,
        runID: String? = nil
    ) {
        self.taskID = taskID
        self.parentID = parentID
        self.revision = revision
        self.scopeID = scopeID
        self.actorID = actorID
        self.idempotencyKey = idempotencyKey
        self.action = action
        self.runID = runID
    }
}

public struct TaskCenterControlReceipt: Codable, Equatable, Sendable {
    public let request: TaskCenterControlRequest
    public let beforeRevision: String
    public let afterFact: GoalTaskCenterTaskFact
    public let resultingRunID: String?
    public let cancelledTaskIDs: [String]
    public let durableIdempotencyKey: String

    fileprivate init(
        request: TaskCenterControlRequest,
        execution: GoalTaskControlExecutionReceipt,
        durableIdempotencyKey: String
    ) {
        self.request = request
        self.beforeRevision = execution.beforeRevision
        self.afterFact = execution.afterFact
        self.resultingRunID = execution.resultingRunID
        self.cancelledTaskIDs = execution.cancelledTaskIDs
        self.durableIdempotencyKey = durableIdempotencyKey
    }
}

public enum TaskCenterControlConsumerError: Error, Equatable, Sendable {
    case unavailable
    case retryRequestUnavailable
    case retryDidNotDispatch
    case facade(GoalTaskCenterFacadeError)
    case executor(GoalTaskControlExecutorError)
    case archive(AgentTaskStoreError)

    var userMessage: String {
        switch self {
        case .unavailable:
            return "控制通道未接入，任务保持只读"
        case .retryDidNotDispatch:
            return "当前模式仅预览，未启动重试"
        case .retryRequestUnavailable:
            return "原任务请求无法验证，重试未启动；请在来源会话重新提交任务"
        case .facade(.revisionMismatch):
            return "任务已变化，请刷新后重试"
        case .facade(.scopeMismatch), .facade(.leaseNotActive):
            return "授权范围或 lease 已失效，控制已拒绝"
        case .facade:
            return "任务控制请求未通过校验"
        case .executor(.needsUserReview):
            return "外部提交状态未知，需要人工复核"
        case .executor(.idempotencyKeyConflict):
            return "重复控制请求与已有回执不一致"
        case .executor(.controlRevisionMismatch), .executor(.controlStateConflict):
            return "控制状态已变化，请刷新后重试"
        case .executor:
            return "任务控制未执行，状态保持不变"
        case .archive(.archiveNotEligible):
            return "仅已完成任务可以归档"
        case .archive(.archiveIdentityMismatch), .archive(.archiveReceiptMismatch):
            return "任务已变化，请刷新后重试"
        case .archive(.archiveIdempotencyConflict):
            return "归档请求与已有回执不一致"
        case .archive(.archiveStateConflict):
            return "归档状态已变化，请刷新后重试"
        case .archive:
            return "归档未执行，状态保持不变"
        }
    }
}

/// Explicit result for the automatic-task creation seam. A rejection is
/// rendered by Task Center and never converted into a silent queued task.
public enum TaskCenterAutomaticTaskCreationResult: Equatable, Sendable {
    case admitted(AgentAutomaticTaskCreationReceipt)
    case rejected(TaskCenterAutomaticTaskCreationRejection)

    public var userMessage: String {
        switch self {
        case .admitted:
            return "自动任务已纳入任务中心"
        case .rejected(let reason):
            return reason.userMessage
        }
    }
}

public enum TaskCenterAutomaticTaskCreationRejection: Equatable, Sendable {
    case serviceUnavailable
    case invalidRequest(AgentTaskCreationValidationError)
    case policy(AgentTaskAutomaticCreationRejection)
    case idempotencyConflict

    public var userMessage: String {
        switch self {
        case .serviceUnavailable:
            return "自动任务入口未接入生产租约服务，任务未创建"
        case .invalidRequest:
            return "自动任务请求无效，任务未创建"
        case .policy(let reason):
            switch reason {
            case .goalBudgetExhausted: return "自动任务预算为零，任务未创建"
            case .goalExpired, .leaseExpired: return "自动任务时限已过期，任务未创建"
            case .leaseRevoked: return "自动任务租约已撤销，任务未创建"
            case .goalScopeMismatch, .leaseGoalMismatch, .leaseScopeMismatch:
                return "自动任务授权范围不一致，任务未创建"
            case .goalDeadlineInvalid, .leaseNotActive, .leaseWindowInvalid:
                return "自动任务租约无效，任务未创建"
            }
        case .idempotencyConflict:
            return "自动任务请求与已有任务冲突，任务未创建"
        }
    }
}

/// Read-only bridge from the external-session runtime ledger into Task Center.
/// The snapshot carries only state, recovery affordances and a durable output
/// backlink; it never carries raw external-session output.
public struct TaskCenterExternalSessionProjection: Equatable, Sendable {
    public let snapshot: ExternalSessionRuntimeSnapshot

    public init(snapshot: ExternalSessionRuntimeSnapshot) {
        self.snapshot = snapshot
    }

    public var accessibilityLabel: String {
        let actions = snapshot.recoveryActions.map(\.title).joined(separator: "、")
        let actionText = actions.isEmpty ? "无" : actions
        return "外部会话：\(snapshot.userMessage)，恢复动作：\(actionText)"
    }
}

/// App production consumer for Goal/Task Center controls.
///
/// Binding resolution is deliberately explicit. Until the production composition
/// root installs the active Goal/Lease, every control request fails closed while
/// observation remains available from the canonical AgentTaskStore.
public struct TaskCenterFileArtifactNavigation: Equatable, Hashable, Sendable, Identifiable {
    public let binding: TaskFileArtifactBinding
    public let diffID: String
    public let producerReceiptID: String
    public let producerCompositeKey: ToolExecutionCompositeKey
    public let outputSHA256: String
    public let displayName: String
    public var id: String { "\(diffID):\(producerReceiptID)" }
}

struct TaskCenterFileArtifactAccess: Equatable, Sendable {
    let record: FileChangeRecord
    let workspaceRoot: String

    init(record: FileChangeRecord, workspaceRoot: String) {
        self.record = record
        self.workspaceRoot = record.workspaceRoot ?? workspaceRoot
    }
}

public final class TaskCenterControlConsumer: @unchecked Sendable {
    public typealias BindingProvider = @Sendable (AgentTaskSnapshot) -> GoalTaskCenterBinding?

    private let store: AgentTaskStore
    private let requiresLiveRetryExecution: Bool
    private var retryBindingGeneration: UInt64 = 0
    private var childRetryExecutions: [RetryOwnerKey: ChildTaskRetryExecution] = [:]
    private var retryTasksByRunID: [String: Task<SubAgentReport, Never>] = [:]

    private struct RetryOwnerKey: Hashable {
        let taskID: String
        let parentID: String
    }
    private let automaticCreationService: AgentTaskCommandService?
    private let lock = NSLock()
    private let bindingPersistenceURL: URL?
    private var productionBinding: GoalTaskCenterBinding?
    private var productionTaskBindings: [String: DurableTaskGoalLeaseBinding] = [:]
    private var bindingPersistenceFailed = false
    private var bindingProvider: BindingProvider?
    private var receiptsByIdempotencyKey: [String: TaskCenterControlReceipt] = [:]
    private var externalSessionProjection: TaskCenterExternalSessionProjection?
    private var externalSessionObservation: ExternalSessionRuntimeObservation?
    private var externalSessionBindingID: UUID?
    private var childTranscriptSessionStore: SessionStore?
    private var fileArtifactLedger: FileChangeLedger?
    private var fileArtifactFacts: ToolExecutionFactLedger?
    private var fileArtifactTargetValidator: (@Sendable (String, String) -> URL?)?
    private var fileArtifactProjectValidator: (@MainActor (String, String) -> Bool)?
    /// 产物生成之后项目授权没有被撤销重授（授权版本未变）。未接线时不额外限制。
    private var fileArtifactGrantCurrent: (@MainActor (String, Date) -> Bool)?
    private var fileArtifactBindingRevision: UInt64 = 0

    public init(
        store: AgentTaskStore,
        bindingProvider: BindingProvider? = nil,
        bindingPersistenceURL: URL? = nil,
        automaticCreationService: AgentTaskCommandService? = nil,
        childTranscriptSessionStore: SessionStore? = nil,
        requiresLiveRetryExecution: Bool = false
    ) {
        self.store = store
        self.requiresLiveRetryExecution = requiresLiveRetryExecution
        self.bindingPersistenceURL = bindingPersistenceURL
        self.bindingProvider = bindingProvider
        self.automaticCreationService = automaticCreationService
        self.childTranscriptSessionStore = childTranscriptSessionStore

        guard let bindingPersistenceURL,
              FileManager.default.fileExists(atPath: bindingPersistenceURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: bindingPersistenceURL)
            let durable = try JSONDecoder().decode(
                DurableGoalLeaseBinding.self,
                from: data
            )
            productionBinding = GoalTaskCenterBinding(
                taskID: "",
                parentID: "",
                goal: durable.goal,
                lease: durable.lease
            )
            productionTaskBindings = durable.taskBindings
            let boundGoal = durable.goal
            let boundLease = durable.lease
            self.bindingProvider = Self.makeBindingProvider(
                goal: boundGoal, lease: boundLease, taskBindings: durable.taskBindings
            )
        } catch {
            // A damaged binding must never be silently replaced with a new
            // policy envelope on the next attach.
            bindingPersistenceFailed = true
        }
    }

    /// Reassembly retires registrations, not the canonical ledger or a healthy
    /// physical operation. Old factories cannot register into the new binding.
    func resetChildRetryBindings() {
        lock.lock()
        retryBindingGeneration &+= 1
        childRetryExecutions.removeAll()
        lock.unlock()
    }

    func makeChildRetryRegistration() -> @Sendable (ChildTaskRetryExecution) -> Void {
        lock.lock()
        let generation = retryBindingGeneration
        lock.unlock()
        return { [weak self] execution in
            guard let self, execution.belongs(to: self.store) else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.retryBindingGeneration == generation else { return }
            self.childRetryExecutions[RetryOwnerKey(taskID: execution.taskID,
                                                   parentID: execution.parentID)] = execution
        }
    }

    /// Await the actual retry producer, rather than polling a displayed state.
    func joinRetryExecution(runID: String) async -> SubAgentReport? {
        let operation = retryExecutionTask(runID: runID)
        return await operation?.value
    }

    private func retryExecutionTask(runID: String) -> Task<SubAgentReport, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return retryTasksByRunID[runID]
    }

    /// Called by the production composition root only after ChatStore has
    /// attached its canonical SessionStore. Nil removes transcript navigation.
    func bindChildTranscriptSessionStore(_ sessionStore: SessionStore?) {
        lock.lock()
        defer { lock.unlock() }
        childTranscriptSessionStore = sessionStore
    }

    func sharesChildTranscriptSessionStore(_ sessionStore: SessionStore) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return childTranscriptSessionStore === sessionStore
    }

    private func currentChildTranscriptSessionStore() -> SessionStore? {
        lock.lock()
        defer { lock.unlock() }
        return childTranscriptSessionStore
    }

    /// Composition supplies the exact existing producer and terminal authority.
    /// Reattachment invalidates destinations from the previous ledger instance.
    func bindFileArtifacts(ledger: FileChangeLedger?, facts: ToolExecutionFactLedger?,
                          targetValidator: (@Sendable (String, String) -> URL?)? = nil,
                          projectValidator: (@MainActor (String, String) -> Bool)? = nil,
                          grantCurrent: (@MainActor (String, Date) -> Bool)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        fileArtifactLedger = ledger
        fileArtifactFacts = facts
        fileArtifactTargetValidator = targetValidator
        fileArtifactProjectValidator = projectValidator
        fileArtifactGrantCurrent = grantCurrent
        fileArtifactBindingRevision &+= 1
    }

    private func currentFileArtifactAuthorities() -> (FileChangeLedger, ToolExecutionFactLedger)? {
        lock.lock()
        defer { lock.unlock() }
        guard let ledger = fileArtifactLedger, let facts = fileArtifactFacts,
              fileArtifactTargetValidator != nil else { return nil }
        return (ledger, facts)
    }

    public func fileArtifactNavigations(for row: TaskCenterReceiptRow,
                                        limit: Int? = nil) -> [TaskCenterFileArtifactNavigation] {
        guard row.observationState != .stale,
              let runID = row.runID, let attemptID = row.attemptID,
              let (ledger, _) = currentFileArtifactAuthorities() else { return [] }
        return ledger.records(taskID: row.taskID, parentID: row.parentID, runID: runID, attemptID: attemptID)
            .reversed().compactMap { record -> TaskCenterFileArtifactNavigation? in
                guard let binding = record.taskArtifactBinding,
                      let receiptID = record.producerReceiptID,
                      let key = record.producerCompositeKey,
                      let digest = record.outputSHA256 else { return nil }
                let navigation = TaskCenterFileArtifactNavigation(
                    binding: binding, diffID: record.diffID, producerReceiptID: receiptID,
                    producerCompositeKey: key, outputSHA256: digest,
                    displayName: ProductRedactionPolicy.redact(record.path, maxLength: 256)
                )
                return fileArtifactAccess(navigation: navigation) == nil ? nil : navigation
            }.prefix(max(0, limit ?? ChatInspectorSnapshot.maxFileChangeRows)).map { $0 }
    }

    /// Uses the same canonical receipt and current safe-open gate as the result
    /// page. Missing authority or inaccessible records never means zero artifacts.
    public func childResultPresentationFacts(
        envelope: ChildResultEnvelope, parentID: String
    ) -> ChildResultPresentationFacts? {
        guard currentResultEnvelope(taskID: envelope.taskID, parentID: parentID) == envelope,
              let locator = envelope.childTranscriptLocator, locator.isWellFormed,
              let row = receiptRows(includeArchived: true).first(where: {
                  $0.taskID == envelope.taskID && $0.parentID == parentID
                      && $0.runID == envelope.runID && $0.attemptID == envelope.attemptID
              }), let (ledger, facts) = currentFileArtifactAuthorities() else { return nil }
        let records = ledger.records(taskID: envelope.taskID, parentID: parentID,
                                     runID: envelope.runID, attemptID: envelope.attemptID)
        let files = fileArtifactNavigations(for: row, limit: Int.max)
        let artifacts = files.compactMap { file -> ChildResultArtifact? in
            guard let record = records.first(where: { $0.diffID == file.diffID }) else { return nil }
            return ChildResultArtifact(path: ProductRedactionPolicy.redact(record.path, maxLength: Int.max),
                                       sha256: file.outputSHA256)
        }
        let matching = facts.facts.filter { $0.childTranscriptLocator == locator }
        var keys = Set<ToolExecutionCompositeKey>()
        let task = store.snapshot(taskID: envelope.taskID, parentID: parentID)
        let child = store.retryRunRuntimeBinding(runID: envelope.runID)?.child ?? task?.childRuntimeIdentity
        var complete = facts.hasDurableAuthority && child?.childSessionID == locator.childSessionID
            && child?.childTaskID == locator.taskID && child?.generationID != nil
            && child.flatMap { try? $0.requireVerifiedGeneration() } != nil
        for fact in matching {
            guard let key = fact.compositeKey,
                  fact.executionIdentity?.turn.sessionID == locator.childSessionID,
                  fact.executionIdentity?.turn.messageID == locator.taskID,
                  fact.executionIdentity?.operationID == child?.generationID,
                  fact.parentRuntimeIdentity == child?.rootParentIdentity,
                  facts.fact(compositeKey: key, receiptID: fact.receiptID) == fact else {
                complete = false; continue
            }
            keys.insert(key)
        }
        if facts.pendingReceipts.contains(where: { $0.childTranscriptLocator == locator }) { complete = false }
        guard currentResultEnvelope(taskID: envelope.taskID, parentID: parentID) == envelope else { return nil }
        return ChildResultPresentationFacts(artifacts: artifacts,
            artifactsComplete: files.count == records.count,
            settledToolCalls: complete ? keys.count : nil)
    }

    private enum FileArtifactOrigin: Equatable {
        case creation(projectID: String?)
        case child(locator: ChildTranscriptLocator, identity: ChildRuntimeIdentity,
                   source: ParentRuntimeIdentity, projectID: String)

        var projectID: String? {
            switch self {
            case .creation(let projectID): return projectID
            case .child(_, _, _, let projectID): return projectID
            }
        }

        func matches(_ fact: ToolExecutionFact, binding: TaskFileArtifactBinding) -> Bool {
            switch self {
            case .creation: return true // Preserve the original creation consumer.
            case .child(let locator, let identity, _, _):
                return fact.targetTaskBinding == nil && fact.targetTaskSource == nil
                    && fact.childTranscriptLocator == locator
                    && fact.parentRuntimeIdentity == identity.rootParentIdentity
                    && fact.executionIdentity?.operationID == identity.generationID
                    && fact.executionIdentity?.turn.sessionID == binding.producerSessionID
                    && fact.executionIdentity?.turn.messageID == binding.taskID
            }
        }
    }

    private func fileArtifactOrigin(task: AgentTaskSnapshot,
                                    binding: TaskFileArtifactBinding) -> FileArtifactOrigin? {
        if let creation = task.creation {
            guard creation.source.sessionID == binding.sourceSessionID,
                  creation.action.workingDirectory == binding.workingDirectory else { return nil }
            return .creation(projectID: creation.action.projectID)
        }
        // A generic row must have the enqueue-verified runtime, not just an ID
        // that resembles a task. Retry keeps its logical row and exact runtime.
        guard let locator = task.childTranscriptLocator,
              let originalParent = task.parentRuntimeIdentity,
              let projectID = binding.projectID, !projectID.isEmpty,
              let child = store.retryRunRuntimeBinding(runID: binding.runID)?.child
                ?? task.childRuntimeIdentity,
              let parent = child.rootParentIdentity,
              (try? child.requireVerifiedGeneration()) != nil,
              child.parentGoalID != nil, child.parentGoalScopeID != nil,
              originalParent.taskID == binding.parentID,
              originalParent.sessionID == binding.sourceSessionID,
              parent.sessionID == binding.sourceSessionID,
              child.childTaskID == binding.taskID,
              child.childSessionID == binding.producerSessionID,
              URL(fileURLWithPath: child.workingDirectory).resolvingSymlinksInPath()
                .standardizedFileURL.path == binding.workingDirectory,
              locator.taskID == binding.taskID, locator.parentID == binding.parentID,
              locator.runID == binding.runID, locator.attemptID == binding.attemptID,
              locator.childSessionID == binding.producerSessionID,
              locator.parentSessionID == binding.sourceSessionID,
              store.childTranscriptLocator(taskID: binding.taskID, parentID: binding.parentID,
                  runID: binding.runID, attemptID: binding.attemptID,
                  childExecutionID: locator.childExecutionID,
                  parentContextSnapshotID: locator.parentContextSnapshotID) == locator else { return nil }
        if let retry = store.retryRunRuntimeBinding(runID: binding.runID) {
            guard retry.originalParentID == binding.parentID,
                  retry.parent == parent, retry.child == child,
                  locator.runtimeParentID == parent.taskID else { return nil }
        } else {
            guard parent == originalParent, locator.runtimeParentID == nil,
                  child.parentTaskID == binding.parentID else { return nil }
        }
        return .child(locator: locator, identity: child, source: originalParent, projectID: projectID)
    }

    /// Called again at click and immediately around preview IO. Tool attempt
    /// and task attempt are checked in their own domains, never compared.
    func fileArtifactAccess(navigation: TaskCenterFileArtifactNavigation) -> TaskCenterFileArtifactAccess? {
        let binding = navigation.binding
        guard binding.isValid,
              let task = store.snapshot(taskID: binding.taskID, parentID: binding.parentID),
              task.status == .succeeded,
              let origin = fileArtifactOrigin(task: task, binding: binding),
              store.controlSnapshot(taskID: binding.taskID, parentID: binding.parentID)?.runID == binding.runID,
              store.canonicalAttemptID(runID: binding.runID) == binding.attemptID,
              let receipt = store.receipt(runID: binding.runID),
              receipt.attemptID == binding.attemptID, receipt.outcome == .succeeded,
              receiptBelongsToTask(receipt, task: task),
              let (ledger, facts) = currentFileArtifactAuthorities(),
              let record = ledger.record(diffID: navigation.diffID, sessionID: binding.producerSessionID),
              record.taskArtifactBinding == binding,
              record.producerReceiptID == navigation.producerReceiptID,
              record.producerCompositeKey == navigation.producerCompositeKey,
              record.outputSHA256 == navigation.outputSHA256,
              let fact = facts.fact(compositeKey: navigation.producerCompositeKey, receiptID: navigation.producerReceiptID),
              origin.matches(fact, binding: binding),
              ledger.artifactEvidence(diffID: record.diffID, sessionID: record.sessionID, fact: fact) != nil,
              let currentTask = store.snapshot(taskID: binding.taskID, parentID: binding.parentID),
              currentTask.status == .succeeded,
              fileArtifactOrigin(task: currentTask, binding: binding) == origin,
              store.controlSnapshot(taskID: binding.taskID, parentID: binding.parentID)?.runID == binding.runID,
              store.canonicalAttemptID(runID: binding.runID) == binding.attemptID,
              let (currentLedger, currentFacts) = currentFileArtifactAuthorities(),
              currentLedger === ledger, currentFacts === facts else { return nil }
        return TaskCenterFileArtifactAccess(record: record, workspaceRoot: ledger.workspaceRoot)
    }

    func fileArtifactTargetAuthorized(navigation: TaskCenterFileArtifactNavigation, target: URL) -> Bool {
        guard let access = fileArtifactAccess(navigation: navigation) else { return false }
        lock.lock()
        let validator = fileArtifactTargetValidator
        let revision = fileArtifactBindingRevision
        lock.unlock()
        guard let admitted = validator?(target.path, navigation.binding.workingDirectory),
              admitted.standardizedFileURL == target.standardizedFileURL else { return false }
        guard fileArtifactAccess(navigation: navigation) == access else { return false }
        lock.lock()
        defer { lock.unlock() }
        return fileArtifactBindingRevision == revision
    }

    /// Native project grants belong to the main actor. Check them before IO,
    /// after the background read, and while presenting cached preview bytes.
    /// No completed task is required to re-enter the running approval path.
    @MainActor
    func fileArtifactPresentationAuthorized(navigation: TaskCenterFileArtifactNavigation, target: URL? = nil) -> Bool {
        guard let access = fileArtifactAccess(navigation: navigation),
              let task = store.snapshot(taskID: navigation.binding.taskID, parentID: navigation.binding.parentID),
              let projectID = fileArtifactOrigin(task: task, binding: navigation.binding)?.projectID else { return false }
        lock.lock()
        let validator = fileArtifactProjectValidator
        let grantCurrent = fileArtifactGrantCurrent
        let revision = fileArtifactBindingRevision
        lock.unlock()
        guard validator?(projectID, navigation.binding.workingDirectory) == true,
              grantCurrent?(projectID, access.record.timestamp) ?? true,
              fileArtifactAccess(navigation: navigation) == access,
              target.map({ fileArtifactTargetAuthorized(navigation: navigation, target: $0) }) ?? true else { return false }
        lock.lock()
        defer { lock.unlock() }
        return fileArtifactBindingRevision == revision
    }

    /// Production consumer for autonomous task creation. The policy service is
    /// injected by the composition root; absent that dependency the result is
    /// an explicit user-visible rejection and no store mutation occurs.
    public func createAutomatic(
        _ request: AgentAutomaticTaskCreationRequest,
        now: Date = Date()
    ) -> TaskCenterAutomaticTaskCreationResult {
        guard let automaticCreationService else {
            return .rejected(.serviceUnavailable)
        }
        do {
            return .admitted(try automaticCreationService.createAutomatic(request, now: now))
        } catch AgentTaskAutomaticCreationError.rejected(let reason) {
            return .rejected(.policy(reason))
        } catch AgentTaskAutomaticCreationError.invalidRequest(let reason) {
            return .rejected(.invalidRequest(reason))
        } catch AgentTaskAutomaticCreationError.idempotencyConflict {
            return .rejected(.idempotencyConflict)
        } catch {
            return .rejected(.serviceUnavailable)
        }
    }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bindingProvider != nil
    }

    public var externalSessionRuntime: TaskCenterExternalSessionProjection? {
        lock.lock()
        defer { lock.unlock() }
        return externalSessionProjection
    }

    /// Composition roots may publish the external adapter's latest snapshot;
    /// Task Center remains read-only and does not acquire control authority.
    public func updateExternalSessionRuntime(_ snapshot: ExternalSessionRuntimeSnapshot?) {
        lock.lock()
        externalSessionProjection = snapshot.map(TaskCenterExternalSessionProjection.init)
        lock.unlock()
    }

    /// Publishes the adapter's current, secret-free runtime snapshot through the
    /// production composition seam. Task Center consumes only this projection;
    /// it never receives the adapter implementation or its control authority.
    public func bindExternalSessionRuntime(from adapter: ExternalSessionAppAdapter) {
        let bindingID = UUID()
        lock.lock()
        let previousObservation = externalSessionObservation
        externalSessionObservation = nil
        // Retire the source before cancelling its token: a publisher may have
        // already copied that callback and can invoke it after cancellation.
        externalSessionBindingID = bindingID
        lock.unlock()
        previousObservation?.cancel()

        let observation = adapter.observeRuntime { [weak self] snapshot in
            self?.updateExternalSessionRuntime(snapshot, bindingID: bindingID)
        }
        lock.lock()
        if externalSessionBindingID == bindingID {
            externalSessionObservation = observation
            lock.unlock()
        } else {
            // Another bind won while observeRuntime delivered its initial value.
            // Do not retain its predecessor's token or cancel under our lock.
            lock.unlock()
            observation.cancel()
        }
    }

    private func updateExternalSessionRuntime(
        _ snapshot: ExternalSessionRuntimeSnapshot, bindingID: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard externalSessionBindingID == bindingID else { return }
        externalSessionProjection = TaskCenterExternalSessionProjection(snapshot: snapshot)
    }

    /// Installs the production Goal/Lease used for task-center control.
    ///
    /// The same policy envelope applies to each task in the canonical ledger;
    /// task and parent identity are still bound per request before execution.
    public func installProductionGoal(goal: GoalEnvelope, lease: AutonomyLease) {
        lock.lock()
        var resolvedGoal = goal
        var resolvedLease = lease
        if bindingPersistenceURL != nil {
            guard !bindingPersistenceFailed else {
                lock.unlock()
                return
            }
            if let productionBinding {
                resolvedGoal = productionBinding.goal
                resolvedLease = productionBinding.lease
            } else {
                do {
                    try persistProductionBinding(goal: resolvedGoal, lease: resolvedLease)
                    productionBinding = GoalTaskCenterBinding(
                        taskID: "",
                        parentID: "",
                        goal: resolvedGoal,
                        lease: resolvedLease
                    )
                } catch {
                    bindingPersistenceFailed = true
                    lock.unlock()
                    return
                }
            }
        }

        if productionBinding == nil {
            productionBinding = GoalTaskCenterBinding(
                taskID: "", parentID: "", goal: resolvedGoal, lease: resolvedLease
            )
        }

        let boundGoal = resolvedGoal
        let boundLease = resolvedLease
        bindingProvider = Self.makeBindingProvider(
            goal: boundGoal, lease: boundLease, taskBindings: productionTaskBindings
        )
        lock.unlock()
    }

    /// Freeze the actual parent task's Goal/Lease before it can dispatch a
    /// child. This extends the existing durable binding authority; recovered
    /// child records with a verified root never fall back to the old global
    /// binding when this exact parent entry is missing.
    @discardableResult
    public func installTopLevelTaskGoal(
        taskID: String, goal: GoalEnvelope, lease: AutonomyLease
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taskID.isEmpty, lease.goalID == goal.goalID,
              lease.scopeID == goal.scopeID,
              lease.expiresAt == goal.deadline,
              !bindingPersistenceFailed,
              let productionBinding else { return false }
        if let previous = productionTaskBindings[taskID] {
            return previous.goal == goal && previous.lease == lease
        }
        var next = productionTaskBindings
        next[taskID] = DurableTaskGoalLeaseBinding(goal: goal, lease: lease)
        do {
            try persistProductionBinding(
                goal: productionBinding.goal,
                lease: productionBinding.lease,
                taskBindings: next
            )
        } catch {
            bindingPersistenceFailed = true
            return false
        }
        productionTaskBindings = next
        bindingProvider = Self.makeBindingProvider(
            goal: productionBinding.goal,
            lease: productionBinding.lease,
            taskBindings: next
        )
        return true
    }

    /// Read the exact policy captured by the normal visible user-event
    /// submission. This lookup never renews a lease or substitutes the old
    /// Task Center row's policy for a newly admitted parent turn.
    func topLevelTaskGoalLease(
        taskID: String
    ) -> (goal: GoalEnvelope, lease: AutonomyLease)? {
        lock.lock()
        defer { lock.unlock() }
        guard !bindingPersistenceFailed,
              let binding = productionTaskBindings[taskID] else { return nil }
        return (binding.goal, binding.lease)
    }

    private static func makeBindingProvider(
        goal: GoalEnvelope,
        lease: AutonomyLease,
        taskBindings: [String: DurableTaskGoalLeaseBinding] = [:]
    ) -> BindingProvider {
        { snapshot in
            if let child = snapshot.childRuntimeIdentity {
                guard let parent = snapshot.parentRuntimeIdentity,
                      parent.taskID == snapshot.parentID,
                      // The single pre-migration binding is usable only for
                      // an exact old Goal ID/scope match; it is never renewed
                      // or substituted for a new child's missing authority.
                      let bound = taskBindings[parent.taskID]
                        ?? (child.parentGoalID == goal.goalID
                            ? DurableTaskGoalLeaseBinding(goal: goal, lease: lease)
                            : nil),
                      child.hasVerifiedRootBoundary(parent: parent, goal: bound.goal),
                      bound.lease.goalID == bound.goal.goalID,
                      bound.lease.scopeID == bound.goal.scopeID else { return nil }
                return GoalTaskCenterBinding(
                    taskID: snapshot.taskID,
                    parentID: snapshot.parentID,
                    goal: bound.goal,
                    lease: bound.lease
                )
            }
            return GoalTaskCenterBinding(
                taskID: snapshot.taskID,
                parentID: snapshot.parentID,
                goal: goal,
                lease: lease
            )
        }
    }

    private func persistProductionBinding(
        goal: GoalEnvelope, lease: AutonomyLease,
        taskBindings: [String: DurableTaskGoalLeaseBinding] = [:]
    ) throws {
        guard let bindingPersistenceURL else { return }
        try FileManager.default.createDirectory(
            at: bindingPersistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            DurableGoalLeaseBinding(
                goal: goal, lease: lease, taskBindings: taskBindings
            )
        )
        try data.write(to: bindingPersistenceURL, options: .atomic)
    }

    public func project(now: Date = Date()) -> GoalTaskCenterProjection {
        let provider = currentBindingProvider()
        guard let provider else {
            return GoalTaskCenterFacade(store: store).project(now: now)
        }

        let bindings = store.taskCenterSnapshots().compactMap(provider)
        guard let facade = try? GoalTaskCenterFacade(store: store, bindings: bindings) else {
            return GoalTaskCenterFacade(store: store).project(now: now)
        }
        return facade.project(now: now)
    }

    /// Read-only production projection for the visible Task/Receipt surface.
    ///
    /// The projection deliberately reads only the canonical store. It does not
    /// depend on the active chat session, and terminal receipts survive a new
    /// consumer instance because AgentTaskStore persists them.
    public func receiptRows(
        now: Date = Date(),
        includeArchived: Bool = false
    ) -> [TaskCenterReceiptRow] {
        // Child settlement commits task/run/attempt/event/receipt atomically,
        // but this projection reads them through separate store methods. A
        // terminal write between those calls must not publish an old running
        // task beside a new success (or cancellation) result. Re-read until
        // one committed ledger version spans the entire projection.
        for _ in 0..<8 {
            let version = store.taskCenterReadVersion()
            let rows = receiptRowsAtOneVersion(now: now, includeArchived: includeArchived)
            if store.taskCenterReadVersion() == version { return rows }
        }
        // Sustained concurrent mutation is not evidence for any single row.
        return []
    }

    private var versionedRowsCache: (version: UInt64, includeArchived: Bool, rows: [TaskCenterReceiptRow])?

    /// Periodic-refresh variant: the projection does not depend on wall-clock
    /// time, so the last result is reused until the ledger version advances.
    public func receiptRowsReusingVersion(includeArchived: Bool = false) -> [TaskCenterReceiptRow] {
        let version = store.taskCenterReadVersion()
        lock.lock()
        if let cached = versionedRowsCache, cached.version == version,
           cached.includeArchived == includeArchived {
            lock.unlock()
            return cached.rows
        }
        lock.unlock()
        let rows = receiptRows(includeArchived: includeArchived)
        guard store.taskCenterReadVersion() == version else { return rows }
        lock.lock()
        versionedRowsCache = (version, includeArchived, rows)
        lock.unlock()
        return rows
    }

    private func receiptRowsAtOneVersion(
        now: Date,
        includeArchived: Bool
    ) -> [TaskCenterReceiptRow] {
        let snapshots = store.taskCenterSnapshots(includeArchived: includeArchived)
            .filter { !Self.isSessionActionControlTask($0) }
        let receipts = store.allReceipts()

        return snapshots.map { task in
            let taskReceipts = receipts.filter { receipt in
                receiptBelongsToTask(receipt, task: task)
            }
            let latestReceipt = taskReceipts.last
            let control = store.controlSnapshot(
                taskID: task.taskID,
                parentID: task.parentID
            )
            let currentRunID = control?.runID
            let retrying = task.status == .running
                && latestReceipt != nil
                && latestReceipt?.runID != currentRunID
            let state = Self.receiptState(
                taskStatus: task.status,
                retrying: retrying
            )
            // Select the event and attempt from the same run identity. A
            // previous receipt may remain while a retry is starting, but its
            // event must never be presented as the current run's observation.
            let observationRunID = currentRunID ?? latestReceipt?.runID
            let latestEvent = observationRunID.flatMap { store.events(runID: $0).last }
            let lifecycleState = Self.lifecycleState(
                taskStatus: task.status,
                eventKind: latestEvent?.kind,
                retrying: retrying
            )
            let activeAttempt = currentRunID
                .flatMap { store.attempts(runID: $0).last }
            let receiptAttempt: AgentTaskAttemptSnapshot? = {
                guard currentRunID == nil, let latestReceipt else { return nil }
                return store.attempts(runID: latestReceipt.runID).last
            }()
            let attempt = activeAttempt ?? receiptAttempt
            let staleReceipt = currentRunID != nil
                && latestReceipt?.runID != nil
                && latestReceipt?.runID != currentRunID
                && task.status != .running
            let observationState = TaskCenterReceiptRow.deriveObservationState(
                lifecycleState: lifecycleState,
                stale: staleReceipt
            )
            let observationIdentity = TaskCenterObservationIdentity(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: observationRunID,
                attemptID: attempt?.attemptID,
                eventSequence: latestEvent?.sequence
            )
            let canonicalReceipt: AgentTaskReceipt? = latestReceipt.flatMap { receipt -> AgentTaskReceipt? in
                guard currentRunID == nil || receipt.runID == currentRunID else {
                    return nil
                }
                return receipt
            }
            let canonicalChildResult = canonicalReceipt.flatMap { receipt in
                childResultEnvelope(task: task, runID: receipt.runID)
            }
            let childNavigation = task.childTranscriptLocator.flatMap { locator in
                validatedChildSession(locator) != nil
                    ? TaskCenterChildSessionNavigation(locator: locator) : nil
            }
            let recoveryState: TaskCenterRecoveryState = currentRunID
                .flatMap { store.recoveryState(runID: $0) } == .needsUserReview
                ? .needsUserReview
                : .none
            let needsChildTerminalReview = recoveryState == .needsUserReview
                && task.childRuntimeIdentity != nil
                && currentRunID != nil
                && canonicalReceipt == nil
            let receiptID = canonicalReceipt?.runID
                ?? currentRunID
                ?? "task-center:\(task.parentID):\(task.taskID)"
            let failureReason = Self.redactedFailureReason(
                taskStatus: task.status,
                receipt: canonicalReceipt,
                publicFailure: canonicalReceipt.flatMap { store.publicFailureCategory(for: $0) }
            )
            let archiveAvailable = task.status == .succeeded
                && lifecycleState == .completed
                && !task.isArchived
                && recoveryState == .none
                && canonicalReceipt?.outcome == .succeeded
                && latestEvent?.kind == .completed
                && latestEvent?.sequence == observationIdentity.eventSequence
                && attempt?.attemptID == canonicalReceipt?.attemptID
            // Success-terminal backlink: the durable receipt, its canonical
            // terminal event and the canonical attempt must all name the same
            // run identity. Anything less stays "not recorded"; a settled
            // success is never represented by placeholder text or a relative
            // timestamp.
            let succeededBacklink: TaskCenterSucceededBacklink?
            if task.status == .succeeded,
               lifecycleState == .completed,
               recoveryState == .none,
               let canonicalReceipt,
               canonicalReceipt.outcome == .succeeded,
               let latestEvent,
               latestEvent.kind == .completed,
               latestEvent.runID == canonicalReceipt.runID,
               latestEvent.sequence == observationIdentity.eventSequence,
               attempt?.attemptID == canonicalReceipt.attemptID,
               store.canonicalAttemptID(runID: canonicalReceipt.runID) == canonicalReceipt.attemptID {
                succeededBacklink = TaskCenterSucceededBacklink(
                    task: task,
                    receipt: canonicalReceipt,
                    terminalEventSequence: latestEvent.sequence,
                    envelope: canonicalChildResult
                )
            } else {
                succeededBacklink = nil
            }

            let cancelledDuration: TimeInterval? = {
                guard childNavigation != nil, task.status == .cancelled,
                      recoveryState == .none, canonicalChildResult == nil,
                      let receipt = canonicalReceipt, receipt.outcome == .cancelled,
                      let attempt, attempt.status == .cancelled,
                      attempt.runID == currentRunID, attempt.attemptID == receipt.attemptID,
                      attempt.parentContextSnapshotID == receipt.parentContextSnapshotID,
                      let startedAt = attempt.startedAt, let finishedAt = attempt.finishedAt else { return nil }
                let seconds = finishedAt.timeIntervalSince(startedAt)
                return seconds.isFinite && seconds >= 0 ? seconds : nil
            }()
            let childActivityTitle = observationRunID.flatMap { runID -> String? in
                guard observationState != .stale, let attemptID = attempt?.attemptID,
                      let activity = store.childToolActivities(taskID: task.taskID,
                          parentID: task.parentID, runID: runID).last,
                      activity.attemptID == attemptID else { return nil }
                // The request producer may summarize files with their path.
                // Keep targets in the approval preview, never in this compact card.
                let summary = activity.toolName.hasPrefix("file_")
                    ? "文件目标已隐藏，详见审批"
                    : (activity.summary == "运行命令（参数见审批）"
                        ? activity.summary : "工具请求（参数已隐藏）")
                return "工具：" + ProductRedactionPolicy.redact(activity.toolName, maxLength: 64)
                    + " · 已请求 · " + ProductRedactionPolicy.redact(summary, maxLength: 160)
            }
            return TaskCenterReceiptRow(
                taskID: task.taskID,
                parentID: task.parentID,
                sessionID: task.parentContextSnapshotID ?? task.parentID,
                sourceSessionID: task.sourceSessionID,
                receiptID: receiptID,
                runID: currentRunID ?? latestReceipt?.runID,
                attemptID: attempt?.attemptID ?? latestReceipt?.attemptID,
                effectID: "effect:\(receiptID)",
                state: state,
                lifecycleState: lifecycleState,
                observationState: observationState,
                observationIdentity: observationIdentity,
                childNavigation: childNavigation,
                childResultEnvelope: canonicalChildResult,
                succeededBacklink: succeededBacklink,
                userTitle: Self.projectedUserTitle(task),
                lastEventKind: latestEvent?.kind,
                recoveryState: recoveryState,
                needsChildTerminalReview: needsChildTerminalReview,
                failureReason: failureReason,
                retryAvailable: state == .failed || state == .cancelled,
                cancelAvailable: recoveryState == .none
                    && (state == .queued
                        || state == .running
                        || state == .retrying),
                isArchived: task.isArchived,
                archiveAvailable: archiveAvailable,
                restoreAvailable: task.isArchived,
                cancelledAttemptDuration: cancelledDuration,
                childToolActivityTitle: childActivityTitle,
                todoProgress: task.childTranscriptLocator
                    .flatMap { validatedChildSession($0) }
                    .flatMap { SessionTodoProgress.latest(in: $0.messages) }
            )
        }
        .sorted {
            if $0.parentID != $1.parentID { return $0.parentID < $1.parentID }
            return $0.taskID < $1.taskID
        }
    }

    /// Session actions remain in the canonical ledger for diagnostics, but
    /// their versioned control records are not user tasks.
    private static func isSessionActionControlTask(_ task: AgentTaskSnapshot) -> Bool {
        task.configurationFingerprint == "session-action-v1"
            && task.taskID.hasPrefix("session-action:")
            && task.taskID != "session-action:"
            && task.providerID == nil
            && task.modelID == nil
            && task.creation == nil
    }

    func userTaskObservation() -> TaskCenterObservationSnapshot {
        TaskCenterObservationSnapshot(snapshots: store.taskCenterSnapshots()
            .filter { !Self.isSessionActionControlTask($0) })
    }

    /// Aggregate the existing control ledger without user task controls.
    func sessionActionDiagnosticObservation() -> TaskCenterObservationSnapshot {
        TaskCenterObservationSnapshot(snapshots: store.taskCenterSnapshots(includeArchived: true)
            .filter(Self.isSessionActionControlTask))
    }

    // Reuse the existing d4a95300e recent-history display bound. It never
    // removes durable records or limits an explicit status/source/archive query.
    static let defaultRecentHistoryLimit = 20

    func homeReceiptSections(
        _ filter: TaskCenterReceiptFilter,
        now: Date = Date()
    ) -> TaskCenterHomeReceiptSections {
        let rows = filteredReceiptRows(filter, now: now).filter { !$0.isArchived }
        let receiptOrder = Dictionary(uniqueKeysWithValues: store.allReceipts().enumerated().map {
            ($0.element.runID, $0.offset)
        })
        let history = rows.filter { !$0.isDefaultSurfacePriority }.sorted {
            let left = $0.runID.flatMap { receiptOrder[$0] } ?? -1
            let right = $1.runID.flatMap { receiptOrder[$0] } ?? -1
            if left != right { return left > right }
            return $0.stableID < $1.stableID
        }
        let current = rows.filter(\.isDefaultSurfacePriority).sorted {
            let left = Self.homePriority($0.lifecycleState)
            let right = Self.homePriority($1.lifecycleState)
            return left == right ? $0.stableID < $1.stableID : left < right
        }
        let isDefaultHome = filter.status == nil
            && filter.sourceSessionID == nil && !filter.includeArchived
        let recentHistory = isDefaultHome
            ? Array(history.prefix(Self.defaultRecentHistoryLimit)) : history
        return TaskCenterHomeReceiptSections(current: current, recentHistory: recentHistory)
    }

    // The existing 02217dfc9b attention ordering, applied only to presentation.
    private static func homePriority(_ state: TaskCenterReceiptState) -> Int {
        switch state {
        case .approvalRequired, .inputRequired: return 0
        case .failed: return 1
        case .running, .retrying: return 2
        case .queued: return 3
        case .cancelled: return 4
        case .completed: return 5
        }
    }

    public func filteredReceiptRows(
        _ filter: TaskCenterReceiptFilter,
        now: Date = Date()
    ) -> [TaskCenterReceiptRow] {
        guard filter.sourceSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            return []
        }
        return receiptRows(now: now, includeArchived: filter.includeArchived).filter { row in
            guard filter.sourceSessionID == nil || row.sourceSessionID == filter.sourceSessionID else {
                return false
            }
            guard let status = filter.status else { return true }
            switch status {
            case .inProgress:
                return row.lifecycleState == .queued
                    || row.lifecycleState == .running
                    || row.lifecycleState == .retrying
            case .waitingApproval:
                return row.lifecycleState == .approvalRequired
                    || row.lifecycleState == .inputRequired
            case .failed:
                return row.lifecycleState == .failed
            case .completed:
                return row.lifecycleState == .completed
            }
        }
    }

    /// Read-only success-terminal backlinks derived from the same canonical
    /// projection pipeline as `receiptRows`. This adds no second state source:
    /// a backlink exists only for rows whose receipt/attempt/terminal-event
    /// identities already prove a settled success.
    public func succeededBacklinks(
        includeArchived: Bool = false
    ) -> [TaskCenterSucceededBacklink] {
        receiptRows(includeArchived: includeArchived).compactMap(\.succeededBacklink)
    }

    public func applyArchive(
        _ request: TaskCenterArchiveRequest,
        now: Date = Date()
    ) throws -> AgentTaskArchiveReceipt {
        guard let task = store.snapshot(taskID: request.taskID, parentID: request.parentID),
              let row = receiptRows(now: now, includeArchived: true).first(where: {
                  $0.taskID == request.taskID && $0.parentID == request.parentID
              }),
              let runID = row.runID,
              let attemptID = row.attemptID,
              let eventSequence = row.observationIdentity.eventSequence else {
            throw TaskCenterControlConsumerError.archive(.archiveNotEligible)
        }
        if request.action == .archive, !row.archiveAvailable {
            throw TaskCenterControlConsumerError.archive(.archiveNotEligible)
        }
        if request.action == .restore, !row.restoreAvailable {
            throw TaskCenterControlConsumerError.archive(.archiveStateConflict)
        }

        let coreRequest = AgentTaskArchiveRequest(
            taskID: request.taskID,
            parentID: request.parentID,
            expectedSnapshotIdentity: AgentTaskSnapshotIdentity(snapshot: task),
            runID: runID,
            attemptID: attemptID,
            eventSequence: eventSequence,
            sourceSessionID: row.sourceSessionID,
            actorID: request.actorID,
            idempotencyKey: request.idempotencyKey,
            action: request.action
        )
        do {
            return try store.applyArchive(coreRequest, now: now)
        } catch let error as AgentTaskStoreError {
            throw TaskCenterControlConsumerError.archive(error)
        }
    }

    /// Returns the canonical child result only when task, run, attempt and
    /// parent-context backlinks all agree. This path is read-only and never
    /// fabricates a result from a legacy report or task status.
    public func childResult(
        taskID: String,
        parentID: String,
        runID: String
    ) -> ChildResultEnvelope? {
        guard let task = store.snapshot(taskID: taskID, parentID: parentID) else {
            return nil
        }
        return childResultEnvelope(task: task, runID: runID)
    }

    /// Revalidates the current task/attempt and persisted lineage on every
    /// read, including after a navigation link was opened. A stale retry or
    /// foreign session cannot keep displaying an earlier child transcript.
    public func childTranscript(
        navigation: TaskCenterChildSessionNavigation
    ) -> TaskCenterChildTranscript? {
        guard let locator = childLocator(for: navigation),
              let session = validatedChildSession(locator) else { return nil }
        let limit = 100
        let skipped = max(0, session.messages.count - limit)
        let toolNames = Self.toolNamesByCallID(session.messages)
        let messages = session.messages.enumerated().dropFirst(skipped).map { index, message in
            let roleTitle: String
            let content: String
            switch message.role {
            case .tool:
                roleTitle = "工具结果"
                content = Self.omittedToolResultText(message, toolNames: toolNames)
            case .user where index > 0:
                roleTitle = "工具反馈"
                content = "[工具结果内容已省略]"
            case .user:
                roleTitle = "任务输入"
                content = Self.safeChildMessageContent(message)
            case .assistant:
                roleTitle = "子代理"
                content = Self.safeChildMessageContent(message)
            }
            return TaskCenterChildTranscriptMessage(
                id: index, roleTitle: roleTitle, content: content
            )
        }
        return TaskCenterChildTranscript(
            navigation: navigation,
            revision: session.transcriptRevision,
            truncated: skipped > 0,
            messages: messages
        )
    }

    /// The builtin transcript writer binds this locator. The mailbox
    /// rechecks the exact running attempt and parent under its own lock.
    @MainActor
    func canMoveChildToBackground(navigation: TaskCenterChildSessionNavigation) -> Bool {
        guard let locator = childLocator(for: navigation) else { return false }
        return store.canMoveChildToBackground(locator: locator)
    }

    @MainActor
    func moveChildToBackground(navigation: TaskCenterChildSessionNavigation) async -> Bool {
        guard let locator = childLocator(for: navigation) else { return false }
        return await store.requestMoveChildToBackground(locator: locator)
    }

    /// 任务中心用来判断"数据是否变了"的廉价签名：账本版本 + 后台子任务数。
    var observationSignature: [UInt64] {
        [store.taskCenterReadVersion(), UInt64(store.liveBackgroundChildOrchestrationCount())]
    }

    /// 任务中心里有按时间变化的显示（Goal 租约是否到期、最近历史的时间窗口），只看账本版本时
    /// 到点也不会刷新。所以在数据签名后面再带一个粗粒度的时间段：账本没变时每
    /// `timeRefreshSeconds` 秒才重算一次，不回到半秒一次。
    static let timeRefreshSeconds: Double = 10

    func observationSignature(now: Date) -> [UInt64] {
        observationSignature + [UInt64(max(0, now.timeIntervalSince1970) / Self.timeRefreshSeconds)]
    }

    func backgroundChildCount() -> Int {
        store.liveBackgroundChildOrchestrationCount()
    }

    func stopAllBackgroundChildren() async {
        await store.cancelAllBackgroundChildOrchestrations()
    }

    @MainActor
    func appendChildInstruction(navigation: TaskCenterChildSessionNavigation, text: String) throws {
        guard let locator = childLocator(for: navigation),
              let sessionStore = currentChildTranscriptSessionStore() else {
            throw ChildInstructionMailboxError.staleAttempt
        }
        try PersistenceTransactionFence.withRead([sessionStore.persistenceDomain]) {
            try PersistenceTransactionFence.requireLiveRead(sessionStore.persistenceDomain)
            guard validatedChildSession(locator) != nil,
                  let task = store.snapshot(taskID: locator.taskID, parentID: locator.parentID),
                  task.childTranscriptLocator == locator else {
                throw ChildInstructionMailboxError.staleAttempt
            }
            let retry = store.retryRunRuntimeBinding(runID: locator.runID)
            guard let parent = retry?.parent ?? task.parentRuntimeIdentity,
                  let child = retry?.child ?? task.childRuntimeIdentity,
                  parent.isValid, parent.sessionID == locator.parentSessionID,
                  parent.taskID == (locator.runtimeParentID ?? locator.parentID),
                  child.rootParentIdentity == parent,
                  child.childTaskID == locator.taskID, child.childSessionID == locator.childSessionID,
                  (try? child.requireVerifiedGeneration()) != nil else {
                throw ChildInstructionMailboxError.foreignSource
            }
            if let retry {
                guard retry.taskID == locator.taskID, retry.originalParentID == locator.parentID,
                      retry.attemptID == locator.attemptID, locator.runtimeParentID == parent.taskID else {
                    throw ChildInstructionMailboxError.foreignSource
                }
            }
            guard currentChildTranscriptSessionStore() === sessionStore else {
                throw ChildInstructionMailboxError.staleAttempt
            }
            try store.appendChildInstruction(locator: locator, source: parent, text: text)
        }
    }

    private func childLocator(for navigation: TaskCenterChildSessionNavigation) -> ChildTranscriptLocator? {
        guard let locator = navigation.locator,
              navigation.parentSessionID == locator.parentSessionID,
              navigation.childSessionID == locator.childSessionID,
              navigation.taskID == locator.taskID else { return nil }
        return locator
    }

    /// A lifecycle label alone cannot identify an approval. Only the live,
    /// bound request for this exact canonical task attempt can be navigated to.
    public func approvalNavigation(
        for row: TaskCenterReceiptRow,
        pendingRequest: ApprovalRequest?,
        now: Date = Date()
    ) -> TaskCenterApprovalNavigation? {
        guard let current = receiptRows(now: now, includeArchived: true).first(where: {
            $0.taskID == row.taskID && $0.parentID == row.parentID
        }),
              current == row,
              current.lifecycleState == .approvalRequired,
              current.lastEventKind == .approvalRequired,
              current.observationState == .attention,
              current.observationIdentity.eventSequence != nil,
              current.recoveryState == .none,
              let runID = current.runID,
              let attemptID = current.attemptID,
              let mapping = store.currentPendingApprovalBinding(
                  taskID: current.taskID, parentID: current.parentID, now: now
              ),
              mapping.taskID == current.taskID,
              mapping.parentID == current.parentID,
              mapping.taskRunID == runID,
              mapping.taskAttemptID == attemptID,
              let pendingRequest,
              pendingRequest.requiresApproval,
              !pendingRequest.requestID.isEmpty,
              mapping.approvalRequestID == pendingRequest.requestID,
              // `sessionID` may fall back to parentID in legacy task rows;
              // only child navigation or creation provenance proves it.
              let provenSessionID = current.childNavigation?.childSessionID
                  ?? current.sourceSessionID,
              mapping.childSessionID == provenSessionID
        else { return nil }
        if let binding = pendingRequest.binding {
            guard binding.isValid,
                  binding.expiresAt > now,
                  binding.taskID == current.taskID,
                  mapping.approvalBindingDigest == binding.identityDigest,
                  mapping.approvalRunID == binding.runID,
                  mapping.approvalAttemptID == binding.attemptID,
                  mapping.childGenerationID == binding.runID,
                  mapping.expiresAt == binding.expiresAt,
                  binding.sessionID == provenSessionID else { return nil }
        } else {
            // Core registers Composer navigation only under its verified child
            // TaskLocal, policy facts and presentation identity. This UI refresh
            // has no child TaskLocal: consume that still-live canonical index,
            // never manufacture a legacy binding or treat it as authorization.
            guard case .childTask(let taskID, let parentID)? = pendingRequest.source,
                  taskID == current.taskID, parentID == current.parentID,
                  let mode = pendingRequest.composerMode,
                  ComposerTaskMode(rawValue: mode) != nil,
                  pendingRequest.sessionID == provenSessionID,
                  pendingRequest.taskID == current.taskID,
                  pendingRequest.identityDigest == mapping.approvalBindingDigest
            else { return nil }
        }
        return TaskCenterApprovalNavigation(
            taskID: current.taskID, parentID: current.parentID,
            sessionID: mapping.childSessionID, runID: runID, attemptID: attemptID,
            requestID: pendingRequest.requestID,
            identityDigest: mapping.approvalBindingDigest
        )
    }

    /// Read the MainActor approval center's current immutable request again
    /// on each presentation refresh. A replaced or expired prompt disappears.
    public func pendingApproval(
        navigation: TaskCenterApprovalNavigation,
        pendingRequest: ApprovalRequest?,
        now: Date = Date()
    ) -> ApprovalRequest? {
        guard let row = receiptRows(now: now, includeArchived: true).first(where: {
            $0.taskID == navigation.taskID && $0.parentID == navigation.parentID
        }),
              approvalNavigation(for: row, pendingRequest: pendingRequest, now: now) == navigation
        else { return nil }
        return pendingRequest
    }

    /// Build an advisory link from canonical in-memory identity only. Row
    /// rendering never reads a full session; the destination performs lineage
    /// validation and reports a missing/unreadable source when actually opened.
    public func sourceSessionNavigation(
        for row: TaskCenterReceiptRow
    ) -> TaskCenterSourceSessionNavigation? {
        guard row.observationState != .stale,
              let sourceSessionID = row.sourceSessionID,
              currentChildTranscriptSessionStore() != nil else { return nil }
        let navigation = TaskCenterSourceSessionNavigation(
            taskID: row.taskID, parentID: row.parentID,
            sourceSessionID: sourceSessionID,
            runID: row.runID, attemptID: row.attemptID
        )
        return sourceNavigationMatchesCanonicalTask(navigation) ? navigation : nil
    }

    private func sourceNavigationMatchesCanonicalTask(
        _ navigation: TaskCenterSourceSessionNavigation
    ) -> Bool {
        guard !navigation.sourceSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let task = store.snapshot(taskID: navigation.taskID, parentID: navigation.parentID),
              task.sourceSessionID == navigation.sourceSessionID,
              let control = store.controlSnapshot(taskID: task.taskID, parentID: task.parentID),
              control.runID == navigation.runID else { return false }
        if let runID = navigation.runID {
            return store.canonicalAttemptID(runID: runID) == navigation.attemptID
        }
        return navigation.attemptID == nil
    }

    /// Revalidate on every presentation refresh so a retry, changed source,
    /// removed session or stale task cannot keep an old transcript open.
    public func sourceTranscript(
        navigation: TaskCenterSourceSessionNavigation
    ) -> TaskCenterSourceSessionTranscript? {
        guard sourceNavigationMatchesCanonicalTask(navigation),
              let sessionStore = currentChildTranscriptSessionStore(),
              let session = sessionStore.loadSession(id: navigation.sourceSessionID),
              session.id == navigation.sourceSessionID,
              currentChildTranscriptSessionStore() === sessionStore,
              sourceNavigationMatchesCanonicalTask(navigation) else { return nil }

        let limit = 100
        let skipped = max(0, session.messages.count - limit)
        let toolNames = Self.toolNamesByCallID(session.messages)
        let messages = session.messages.enumerated().dropFirst(skipped).map { index, message in
            let roleTitle: String
            let content: String
            switch message.role {
            case .tool:
                roleTitle = "工具结果"
                content = Self.omittedToolResultText(message, toolNames: toolNames)
            case .user:
                roleTitle = "用户"
                content = Self.safeChildMessageContent(message)
            case .assistant:
                roleTitle = "助手"
                content = Self.safeChildMessageContent(message)
            }
            return TaskCenterChildTranscriptMessage(
                id: index, roleTitle: roleTitle, content: content
            )
        }
        return TaskCenterSourceSessionTranscript(
            navigation: navigation,
            revision: session.transcriptRevision,
            truncated: skipped > 0,
            messages: messages
        )
    }

    /// The result destination is available only for the current canonical
    /// run/attempt and an actual output or evidence reference. A retry cannot
    /// expose the prior attempt's result under the same task ID.
    public func resultNavigation(
        for row: TaskCenterReceiptRow
    ) -> TaskCenterResultNavigation? {
        guard row.observationState != .stale,
              let envelope = currentResultEnvelope(taskID: row.taskID, parentID: row.parentID),
              envelope.runID == row.runID,
              envelope.attemptID == row.attemptID else { return nil }
        return TaskCenterResultNavigation(
            taskID: row.taskID, parentID: row.parentID,
            runID: envelope.runID, attemptID: envelope.attemptID,
            resultIdempotencyKey: envelope.idempotencyKey
        )
    }

    /// Re-read the canonical result on each presentation refresh. Only a
    /// bounded redacted output and the evidence count cross the UI boundary.
    public func resultDetail(
        navigation: TaskCenterResultNavigation
    ) -> TaskCenterResultDetail? {
        guard let envelope = currentResultEnvelope(taskID: navigation.taskID, parentID: navigation.parentID),
              envelope.runID == navigation.runID,
              envelope.attemptID == navigation.attemptID,
              envelope.idempotencyKey == navigation.resultIdempotencyKey else { return nil }
        let statusTitle: String
        switch envelope.outcome {
        case .succeeded: statusTitle = "已完成"
        case .failed: statusTitle = "失败"
        case .cancelled: statusTitle = "已取消"
        }
        let displayOutput = (envelope.output ?? envelope.error).map {
            OrchestrationToolExecutor.resultSummary($0)
        }
        let facts = childResultPresentationFacts(envelope: envelope, parentID: navigation.parentID)
        let row = receiptRows(includeArchived: true).first {
            $0.taskID == navigation.taskID && $0.parentID == navigation.parentID
                && $0.runID == navigation.runID && $0.attemptID == navigation.attemptID
        }
        let files = row.map { fileArtifactNavigations(for: $0, limit: Int.max) } ?? []
        guard currentResultEnvelope(taskID: navigation.taskID, parentID: navigation.parentID) == envelope else { return nil }
        return TaskCenterResultDetail(
            navigation: navigation,
            statusTitle: statusTitle,
            outputDigest: envelope.outputDigest,
            displayOutput: displayOutput,
            evidenceCount: envelope.evidenceRefs.count,
            durationSeconds: envelope.startedAt.flatMap { start in envelope.finishedAt.map { $0.timeIntervalSince(start) } },
            tokenUsage: envelope.tokenUsage, settledToolCalls: facts?.settledToolCalls,
            artifactsComplete: facts?.artifactsComplete ?? false, files: files
        )
    }

    /// The same canonical receipt/envelope checks used by receiptRows, scoped
    /// to one task. No full receipt projection or unrelated transcript reads.
    private func currentResultEnvelope(taskID: String, parentID: String) -> ChildResultEnvelope? {
        guard let task = store.snapshot(taskID: taskID, parentID: parentID),
              let runID = store.controlSnapshot(taskID: taskID, parentID: parentID)?.runID,
              let receipt = store.receipt(runID: runID),
              receiptBelongsToTask(receipt, task: task),
              let envelope = childResultEnvelope(task: task, runID: runID),
              envelope.attemptID == receipt.attemptID,
              receipt.childResultEnvelope == envelope,
              envelope.output != nil || !envelope.evidenceRefs.isEmpty else { return nil }
        return envelope
    }

    /// 工具调用 id 对应的工具名（只取名字，不取参数）。
    private static func toolNamesByCallID(_ messages: [LLMMessage]) -> [String: String] {
        var names: [String: String] = [:]
        for call in messages.flatMap(\.toolCalls) { names[call.id] = call.name }
        return names
    }

    /// 工具结果的正文不在任务记录里保存，这里至少说明是哪个工具的结果。
    private static func omittedToolResultText(_ message: LLMMessage, toolNames: [String: String]) -> String {
        guard let id = message.toolCallID, let name = toolNames[id] else { return "[工具结果内容已省略]" }
        let safeName = ProductRedactionPolicy.redact(name, maxLength: 64)
        return "[工具结果内容已省略] 工具：\(safeName)"
    }

    private static func safeChildMessageContent(_ message: LLMMessage) -> String {
        guard message.toolCalls.isEmpty,
              !message.content.contains("\"tool_calls\""),
              !message.content.contains("<tool_call") else {
            // 写入记录时已把调用概括成“工具：名称 目标”行（已脱敏）；显示这些行，原始参数仍不显示。
            let summaryLines = message.content.split(separator: "\n")
                .filter { $0.hasPrefix("工具：") }
                .map { ProductRedactionPolicy.redact(String($0), maxLength: 200) }
            let names = message.toolCalls.map { "工具：" + ProductRedactionPolicy.redact($0.name, maxLength: 64) }
            let lines = summaryLines.isEmpty ? names : summaryLines
            return lines.isEmpty ? "[工具调用参数已省略]"
                : "[工具调用参数已省略]\n" + lines.joined(separator: "\n")
        }
        let safe = ProductRedactionPolicy.redact(message.content, maxLength: 1_024)
        return safe.isEmpty ? "（无可显示内容）" : safe
    }

    private func validatedChildSession(_ locator: ChildTranscriptLocator) -> ChatSession? {
        guard locator.isWellFormed,
              locator.lineageVersion == ChatSession.currentLineageVersion,
              let sessionStore = currentChildTranscriptSessionStore(),
              let task = store.snapshot(taskID: locator.taskID, parentID: locator.parentID),
              task.childTranscriptLocator == locator,
              task.parentContextSnapshotID == locator.parentContextSnapshotID,
              task.sourceSessionID == nil || task.sourceSessionID == locator.parentSessionID,
              let control = store.controlSnapshot(taskID: locator.taskID, parentID: locator.parentID),
              control.runID == locator.runID,
              let attempt = store.attempt(runID: locator.runID, attemptID: locator.attemptID),
              attempt.parentContextSnapshotID == locator.parentContextSnapshotID,
              store.childTranscriptLocator(
                  taskID: locator.taskID, parentID: locator.parentID,
                  runID: locator.runID, attemptID: locator.attemptID,
                  childExecutionID: locator.childExecutionID,
                  parentContextSnapshotID: locator.parentContextSnapshotID
              ) == locator,
              store.recoveryState(runID: locator.runID) != .needsUserReview else { return nil }

        if let envelope = store.childResultEnvelope(
            taskID: locator.taskID, parentID: locator.parentID, runID: locator.runID
        ) {
            guard envelope.childTranscriptLocator == locator,
                  envelope.childExecutionID == locator.childExecutionID,
                  task.status != .running else { return nil }
        } else {
            guard canReadChildWithoutResult(locator, task: task,
                control: control, attempt: attempt) else { return nil }
        }

        guard let parent = sessionStore.loadSession(id: locator.parentSessionID),
              let child = sessionStore.loadSession(id: locator.childSessionID),
              child.id == locator.childSessionID,
              child.parentSessionID == parent.id,
              child.forkedFromSessionID == parent.id,
              child.rootSessionID == parent.rootSessionID,
              child.projectID == parent.projectID,
              let forkedRevision = child.forkedThroughTranscriptRevision,
              forkedRevision <= parent.transcriptRevision,
              child.createdByTaskID == locator.taskID,
              child.createdByRunID == locator.runID,
              child.lineageVersion == locator.lineageVersion,
              child.forkedThroughMessageID == nil,
              child.transcriptRevision == UInt64(child.messages.count),
              child.messages.allSatisfy({ message in
                  message.images.isEmpty && message.audios.isEmpty
                      && message.toolCalls.allSatisfy {
                          $0.rawArguments == "{}" && $0.arguments.isEmpty
                      }
              }),
              currentChildTranscriptSessionStore() === sessionStore,
              store.childTranscriptLocator(
                  taskID: locator.taskID, parentID: locator.parentID,
                  runID: locator.runID, attemptID: locator.attemptID,
                  childExecutionID: locator.childExecutionID,
                  parentContextSnapshotID: locator.parentContextSnapshotID
              ) == locator,
              let finalTask = store.snapshot(taskID: locator.taskID, parentID: locator.parentID),
              let finalControl = store.controlSnapshot(
                  taskID: locator.taskID, parentID: locator.parentID
              ),
              let finalAttempt = store.attempt(
                  runID: locator.runID, attemptID: locator.attemptID
              ),
              finalTask.childTranscriptLocator == locator,
              finalControl.runID == locator.runID,
              store.recoveryState(runID: locator.runID) != .needsUserReview else { return nil }
        if let finalEnvelope = store.childResultEnvelope(
            taskID: locator.taskID, parentID: locator.parentID, runID: locator.runID
        ) {
            guard finalEnvelope.childTranscriptLocator == locator,
                  finalTask.status != .running else { return nil }
        } else {
            guard canReadChildWithoutResult(locator, task: finalTask,
                control: finalControl, attempt: finalAttempt) else { return nil }
        }
        return child
    }

    /// A cancelled current run keeps its already-bound transcript readable.
    /// Its canonical receipt grants no permission to resume or write.
    private func canReadChildWithoutResult(
        _ locator: ChildTranscriptLocator, task: AgentTaskSnapshot,
        control: AgentTaskControlSnapshot, attempt: AgentTaskAttemptSnapshot
    ) -> Bool {
        if task.status == .running, attempt.status == .running,
           control.state == .active { return true }
        guard task.status == .cancelled, attempt.status == .cancelled,
              control.state == .stopped || control.state == .terminal,
              control.runID == locator.runID,
              store.canonicalAttemptID(runID: locator.runID) == locator.attemptID,
              let receipt = store.receipt(runID: locator.runID),
              receiptBelongsToTask(receipt, task: task),
              receipt.attemptID == locator.attemptID,
              receipt.parentContextSnapshotID == locator.parentContextSnapshotID,
              receipt.outcome == .cancelled, receipt.childResultEnvelope == nil else { return false }
        return true
    }

    /// Defensive diagnostic for any terminal receipt whose run backlink no
    /// longer resolves to the canonical task ledger. Valid persisted stores
    /// reject this shape during recovery; callers must not treat it as a result.
    public func orphanReceiptRunIDs() -> [String] {
        let tasks = store.taskCenterSnapshots(includeArchived: true)
        return store.allReceipts()
            .filter { receipt in
                !tasks.contains { receiptBelongsToTask(receipt, task: $0) }
            }
            .map(\.runID)
            .sorted()
    }

    /// A duplicate click with the same request consumes its existing fact;
    /// it does not append another user event or issue another parent turn.
    func previousControlReceipt(
        for request: TaskCenterControlRequest
    ) throws -> TaskCenterControlReceipt? {
        lock.lock()
        defer { lock.unlock() }
        guard let prior = receiptsByIdempotencyKey[request.idempotencyKey] else { return nil }
        guard prior.request == request else {
            throw TaskCenterControlConsumerError.executor(.idempotencyKeyConflict)
        }
        return prior
    }

    public func execute(
        _ request: TaskCenterControlRequest,
        now: Date = Date()
    ) throws -> TaskCenterControlReceipt {
        if let prior = try previousControlReceipt(for: request) { return prior }

        let retryExecution: ChildTaskRetryExecution?
        if request.action == .retry {
            lock.lock()
            retryExecution = childRetryExecutions[RetryOwnerKey(taskID: request.taskID,
                                                               parentID: request.parentID)]
            lock.unlock()
            if requiresLiveRetryExecution {
                guard let retryExecution, retryExecution.originalRunID == request.runID,
                      retryExecution.hasLiveOwner else {
                    throw TaskCenterControlConsumerError.unavailable
                }
            }
        } else {
            retryExecution = nil
        }

        guard let provider = currentBindingProvider(),
              let snapshot = store.snapshot(taskID: request.taskID, parentID: request.parentID),
              let binding = provider(snapshot) else {
            throw TaskCenterControlConsumerError.unavailable
        }

        let executor: GoalTaskControlExecutor
        do {
            executor = try GoalTaskControlExecutor(
                store: store,
                bindings: [binding]
            )
        } catch let error as GoalTaskCenterFacadeError {
            throw TaskCenterControlConsumerError.facade(error)
        } catch {
            throw TaskCenterControlConsumerError.unavailable
        }

        let durableIdempotencyKey = Self.durableIdempotencyKey(for: request)
        let coreRequest = GoalTaskCenterCommandRequest(
            taskID: request.taskID,
            parentID: request.parentID,
            revision: request.revision,
            scopeID: request.scopeID,
            actorID: request.actorID,
            idempotencyKey: durableIdempotencyKey,
            command: request.action.goalCommand,
            runID: request.runID
        )

        do {
            let execution = try executor.execute(coreRequest, now: now)
            let receipt = TaskCenterControlReceipt(
                request: request,
                execution: execution,
                durableIdempotencyKey: durableIdempotencyKey
            )
            lock.lock()
            defer { lock.unlock() }
            if let prior = receiptsByIdempotencyKey[request.idempotencyKey] {
                guard prior.request == request else {
                    throw TaskCenterControlConsumerError.executor(.idempotencyKeyConflict)
                }
                return prior
            }
            receiptsByIdempotencyKey[request.idempotencyKey] = receipt
            if let retryExecution, let resultingRunID = receipt.resultingRunID,
               retryTasksByRunID[resultingRunID] == nil {
                let durableKey = receipt.durableIdempotencyKey
                retryTasksByRunID[resultingRunID] = Task {
                    await retryExecution.resume(resultingRunID: resultingRunID,
                                                durableIdempotencyKey: durableKey)
                }
            }
            return receipt
        } catch let error as GoalTaskCenterFacadeError {
            throw TaskCenterControlConsumerError.facade(error)
        } catch let error as GoalTaskControlExecutorError {
            throw TaskCenterControlConsumerError.executor(error)
        }
    }

    private func currentBindingProvider() -> BindingProvider? {
        lock.lock()
        defer { lock.unlock() }
        return bindingProvider
    }

    /// Historical receipts use persisted ownership, never the current-run
    /// command fence. Their attempt and context must still match exactly.
    private func receiptBelongsToTask(
        _ receipt: AgentTaskReceipt,
        task: AgentTaskSnapshot
    ) -> Bool {
        guard receipt.taskID == task.taskID,
              let identity = store.historicalRunIdentity(
                  runID: receipt.runID, taskID: task.taskID, parentID: task.parentID
              ) else { return false }
        return identity.attemptID == receipt.attemptID
            && identity.parentContextSnapshotID == receipt.parentContextSnapshotID
    }

    private func childResultEnvelope(
        task: AgentTaskSnapshot,
        runID: String
    ) -> ChildResultEnvelope? {
        guard let envelope = store.childResultEnvelope(taskID: task.taskID, parentID: task.parentID, runID: runID),
              envelope.taskID == task.taskID,
              envelope.parentContextSnapshotID == task.parentContextSnapshotID,
              store.canonicalAttemptID(runID: runID) == envelope.attemptID else {
            return nil
        }
        return envelope
    }

    private static func durableIdempotencyKey(
        for request: TaskCenterControlRequest
    ) -> String {
        let fields = [
            "task-center-control-v1",
            request.action.rawValue,
            request.idempotencyKey
        ]
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func receiptState(
        taskStatus: AgentTaskStatus,
        retrying: Bool
    ) -> TaskCenterReceiptState {
        if retrying { return .retrying }
        switch taskStatus {
        case .queued: return .queued
        case .running: return .running
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .succeeded: return .completed
        }
    }

    private static func lifecycleState(
        taskStatus: AgentTaskStatus,
        eventKind: AgentTaskEventKind?,
        retrying: Bool
    ) -> TaskCenterReceiptState {
        if retrying { return .retrying }
        switch eventKind {
        case .approvalRequired: return .approvalRequired
        case .inputRequired: return .inputRequired
        default: return receiptState(taskStatus: taskStatus, retrying: false)
        }
    }

    /// AgentTaskStore already bounds failure outcomes to a category. Keep the
    /// UI fail-closed as well in case an older or hand-built ledger is loaded.
    private static func redactedFailureReason(
        taskStatus: AgentTaskStatus,
        receipt: AgentTaskReceipt?,
        publicFailure: AgentTaskPublicFailureCategory?
    ) -> String? {
        guard taskStatus == .failed else { return nil }
        if let publicFailure { return publicFailure.message }
        guard let receipt else { return "execution-failed" }
        guard case .failed(let reason) = receipt.outcome else {
            return "execution-failed"
        }
        return reason == "execution-failed" ? reason : "execution-failed"
    }

    /// The compact UI may also show a dispatch producer's explicit human title.
    /// Read it from the same canonical record, without reclassifying the task
    /// as a session-action creation or inventing a title from an identity.
    public func humanDisplayTitle(for row: TaskCenterReceiptRow) -> String? {
        guard let snapshot = store.snapshot(taskID: row.taskID, parentID: row.parentID) else {
            return nil
        }
        if let creationTitle = Self.projectedUserTitle(snapshot) { return creationTitle }
        guard let title = snapshot.dispatchHumanTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    /// Canonical user-authored title, taken only from durable session-creation
    /// provenance already persisted by the store. A task without creation
    /// metadata — a dispatched agent child, a legacy ledger entry — has no
    /// canonical title, so the projection returns nil instead of inventing
    /// one; the UI falls back to the task ID. Blank values are rejected even
    /// though a store-admitted creation is already validated non-blank.
    static func projectedUserTitle(_ snapshot: AgentTaskSnapshot) -> String? {
        guard let title = snapshot.creation?.action.title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : title
    }
}

private struct DurableGoalLeaseBinding: Codable {
    let goal: GoalEnvelope
    let lease: AutonomyLease
    let taskBindings: [String: DurableTaskGoalLeaseBinding]

    init(
        goal: GoalEnvelope, lease: AutonomyLease,
        taskBindings: [String: DurableTaskGoalLeaseBinding] = [:]
    ) {
        self.goal = goal
        self.lease = lease
        self.taskBindings = taskBindings
    }

    private enum CodingKeys: String, CodingKey {
        case goal, lease, taskBindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = try container.decode(GoalEnvelope.self, forKey: .goal)
        lease = try container.decode(AutonomyLease.self, forKey: .lease)
        taskBindings = try container.decodeIfPresent(
            [String: DurableTaskGoalLeaseBinding].self,
            forKey: .taskBindings
        ) ?? [:]
    }
}

private struct DurableTaskGoalLeaseBinding: Codable, Equatable {
    let goal: GoalEnvelope
    let lease: AutonomyLease
}
