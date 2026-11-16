import Foundation

// MARK: - BackgroundTaskAuthorization

/// Frozen policy facts attached to one background task registration.
///
/// The values are copied into the task at registration time.  A caller that
/// renews or revokes a lease must register a new task generation; an existing
/// action never observes mutable policy state halfway through an execution.
public struct BackgroundTaskAuthorization: Codable, Equatable, Sendable, Hashable {
    public let goal: GoalEnvelope
    public let lease: AutonomyLease

    public init(goal: GoalEnvelope, lease: AutonomyLease) {
        self.goal = goal
        self.lease = lease
    }
}

/// Production-consumable reasons why a policy-bound task was not admitted or
/// why an in-flight result could not be committed.
public enum BackgroundTaskAdmissionRejection: String, Codable, Equatable, Sendable {
    case staleGeneration = "stale_generation"
    case invalidGoalWindow = "invalid_goal_window"
    case zeroBudget = "zero_budget"
    case goalExpired = "goal_expired"
    case goalLeaseMismatch = "goal_lease_mismatch"
    case scopeMismatch = "scope_mismatch"
    case invalidLeaseWindow = "invalid_lease_window"
    case leaseNotActive = "lease_not_active"
    case leaseExpired = "lease_expired"
    case leaseRevoked = "lease_revoked"
}

// MARK: - BackgroundTask

/// 后台任务定义：一个可调度的、按固定间隔重复执行的动作。
///
/// 继承 OpenMinis 手机端 Background 能力（Agent/Background/
/// BackgroundKeepAliveManager.swift 的"长任务保活"思路），macOS 简化版
/// 抽象为纯任务调度：不依赖 ActivityKit/定位/音频保活，由
/// `TaskScheduler` 用 DispatchSourceTimer 驱动。
///
/// `action` 为 `@Sendable () async -> Void`，可在闭包内安全捕获值类型
/// 或 actor；执行结果（成功/失败）由 `TaskScheduler` 记录为
/// `TaskExecutionRecord` 供 UI 展示。
public struct BackgroundTask: Identifiable, Sendable {
    /// 任务唯一标识（注册/启停/查询用）。
    public let id: String
    /// 展示名（设置页/任务列表用）。
    public var title: String
    /// 执行间隔（秒）。触发后计时器按该间隔重复。
    public var intervalSeconds: TimeInterval
    /// 上次实际执行开始时间；从未执行时为 nil。
    public var lastRunAt: Date?
    /// 是否启用。禁用后调度器取消其计时器，不再触发。
    public var isEnabled: Bool
    /// Registration generation. Replacing or revoking a task must use a new
    /// generation so delayed timer callbacks and action completions are stale.
    public let generation: UUID
    /// Frozen goal/lease binding. Nil keeps the legacy scheduler contract for
    /// tasks that do not perform policy-bound work.
    public let authorization: BackgroundTaskAuthorization?
    /// 任务动作。调度器每次触发（或手动 runNow）时异步执行；抛错会被
    /// 调度器捕获并记录为 `.failed` 执行记录。
    public let action: @Sendable () async throws -> Void

    public init(
        id: String,
        title: String,
        intervalSeconds: TimeInterval,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        generation: UUID = UUID(),
        authorization: BackgroundTaskAuthorization? = nil,
        action: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.title = title
        self.intervalSeconds = intervalSeconds
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.generation = generation
        self.authorization = authorization
        self.action = action
    }

    /// Convenience boundary for production callers that already hold a
    /// frozen goal and lease. The policy-bound overload makes accidental
    /// unbound registration harder while preserving the legacy initializer.
    public init(
        id: String,
        title: String,
        intervalSeconds: TimeInterval,
        goal: GoalEnvelope,
        lease: AutonomyLease,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        generation: UUID = UUID(),
        action: @escaping @Sendable () async throws -> Void
    ) {
        self.init(
            id: id,
            title: title,
            intervalSeconds: intervalSeconds,
            isEnabled: isEnabled,
            lastRunAt: lastRunAt,
            generation: generation,
            authorization: BackgroundTaskAuthorization(goal: goal, lease: lease),
            action: action
        )
    }
}

// MARK: - TaskExecutionRecord

/// 一次任务执行的记录（供 UI 展示：上次执行时间/状态/耗时）。
public struct TaskExecutionRecord: Identifiable, Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case success
        case failed(String)
        case rejected(BackgroundTaskAdmissionRejection)
    }

    public let id: UUID
    /// 所属任务 id。
    public let taskID: String
    public let startedAt: Date
    public let finishedAt: Date
    public let status: Status

    /// 执行耗时（秒）。
    public var duration: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    public init(
        id: UUID = UUID(),
        taskID: String,
        startedAt: Date,
        finishedAt: Date,
        status: Status
    ) {
        self.id = id
        self.taskID = taskID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
    }
}
