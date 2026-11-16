import Foundation

/// Fail-closed reasons for the canonical cron boundary. The scheduler never
/// silently coerces an invalid expression, timezone, local DST instant, or
/// occurrence spacing into a runnable task.
public enum TaskScheduleValidationError: String, Error, Codable, Equatable, Sendable {
    case emptyTaskID
    case invalidCronExpression
    case invalidTimeZone
    case invalidPinnedVersion
    case invalidReferenceDate
    case pastTrigger
    case missingLocalTime
    case ambiguousLocalTime
    case tooFrequent
    case noNextFire
    case duplicateOccurrence
}

private struct CanonicalCronExpression: Equatable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let canonical: String

    init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 else { throw TaskScheduleValidationError.invalidCronExpression }
        minutes = try Self.parse(fields[0], range: 0...59, weekday: false)
        hours = try Self.parse(fields[1], range: 0...23, weekday: false)
        daysOfMonth = try Self.parse(fields[2], range: 1...31, weekday: false)
        months = try Self.parse(fields[3], range: 1...12, weekday: false)
        let parsedWeekdays = try Self.parse(fields[4], range: 0...7, weekday: true)
        weekdays = Set(parsedWeekdays.map { $0 == 7 ? 0 : $0 })
        canonical = [
            Self.render(minutes, range: 0...59),
            Self.render(hours, range: 0...23),
            Self.render(daysOfMonth, range: 1...31),
            Self.render(months, range: 1...12),
            Self.render(weekdays, range: 0...6)
        ].joined(separator: " ")
    }

    func matches(_ components: DateComponents) -> Bool {
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else {
            return false
        }
        guard daysOfMonth.contains(day) || weekdays.contains((weekday - 1) % 7) else {
            return false
        }
        let dayOfMonthWildcard = daysOfMonth.count == 31
        let weekdayWildcard = weekdays.count == 7
        if dayOfMonthWildcard || weekdayWildcard {
            return daysOfMonth.contains(day) && weekdays.contains((weekday - 1) % 7)
        }
        return daysOfMonth.contains(day) || weekdays.contains((weekday - 1) % 7)
    }

    var orderedHours: [Int] { hours.sorted() }
    var orderedMinutes: [Int] { minutes.sorted() }

    private static func parse(
        _ field: String,
        range: ClosedRange<Int>,
        weekday: Bool
    ) throws -> Set<Int> {
        guard !field.isEmpty else { throw TaskScheduleValidationError.invalidCronExpression }
        var values = Set<Int>()
        for component in field.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = component.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2, !parts[0].isEmpty else {
                throw TaskScheduleValidationError.invalidCronExpression
            }
            let step: Int
            if parts.count == 2 {
                guard let parsedStep = Int(parts[1]), parsedStep > 0 else {
                    throw TaskScheduleValidationError.invalidCronExpression
                }
                step = parsedStep
            } else {
                step = 1
            }
            let base = String(parts[0])
            let bounds: (Int, Int)
            if base == "*" {
                bounds = (range.lowerBound, range.upperBound)
            } else if base.contains("-") {
                let pair = base.split(separator: "-", omittingEmptySubsequences: false)
                guard pair.count == 2,
                      let lower = Int(pair[0]), let upper = Int(pair[1]), lower <= upper,
                      range.contains(lower), range.contains(upper) else {
                    throw TaskScheduleValidationError.invalidCronExpression
                }
                bounds = (lower, upper)
            } else {
                guard parts.count == 1, let value = Int(base), range.contains(value) else {
                    throw TaskScheduleValidationError.invalidCronExpression
                }
                bounds = (value, value)
            }
            for value in stride(from: bounds.0, through: bounds.1, by: step) {
                values.insert(value)
            }
        }
        guard !values.isEmpty else { throw TaskScheduleValidationError.invalidCronExpression }
        if weekday && !values.allSatisfy({ (0...7).contains($0) }) {
            throw TaskScheduleValidationError.invalidCronExpression
        }
        return values
    }

    private static func render(_ values: Set<Int>, range: ClosedRange<Int>) -> String {
        if values.count == range.count && values == Set(range) { return "*" }
        return values.sorted().map(String.init).joined(separator: ",")
    }
}

/// Canonical scheduler input. The expression and timezone are normalized once
/// at the boundary; all next-fire and occurrence calculations consume this
/// exact snapshot.
public struct TaskScheduleDefinition: Codable, Equatable, Hashable, Sendable {
    public let taskID: String
    public let cronExpression: String
    public let timeZoneIdentifier: String
    public let pinnedVersion: Int

    public init(
        taskID: String,
        cronExpression: String,
        timeZoneIdentifier: String,
        pinnedVersion: Int
    ) throws {
        let normalizedID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw TaskScheduleValidationError.emptyTaskID }
        guard pinnedVersion > 0 else { throw TaskScheduleValidationError.invalidPinnedVersion }
        let cron = try CanonicalCronExpression(cronExpression)
        // Validate the identifier without rewriting it. On Apple Foundation a
        // TimeZone built from "UTC" reports identifier "GMT", so assigning
        // timeZone.identifier here would silently replace the caller's saved
        // zone and destroy the canonical snapshot's UTC identity. The original
        // string is kept verbatim; every consumer re-resolves it through
        // TimeZone(identifier:), which is deterministic for validated inputs.
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw TaskScheduleValidationError.invalidTimeZone
        }
        self.taskID = normalizedID
        self.cronExpression = cron.canonical
        self.timeZoneIdentifier = timeZoneIdentifier
        self.pinnedVersion = pinnedVersion
    }
}

/// Stable occurrence identity. UTC minute plus task/version prevents a later
/// task edit or a repeated local wall-clock minute from aliasing an old row.
public struct TaskScheduleOccurrenceIdentity: Codable, Equatable, Hashable, Sendable {
    public let taskID: String
    public let pinnedVersion: Int
    public let scheduledMinute: Int64

    public init(taskID: String, pinnedVersion: Int, scheduledDate: Date) throws {
        let normalizedID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw TaskScheduleValidationError.emptyTaskID }
        guard pinnedVersion > 0 else { throw TaskScheduleValidationError.invalidPinnedVersion }
        let seconds = scheduledDate.timeIntervalSince1970
        guard seconds.isFinite else { throw TaskScheduleValidationError.invalidReferenceDate }
        self.taskID = normalizedID
        self.pinnedVersion = pinnedVersion
        self.scheduledMinute = Int64(floor(seconds / 60))
    }

    /// Wire form of the identity. The `m` segment carries the scheduled minute
    /// expressed as its minute-aligned epoch-second boundary (scheduledMinute
    /// * 60), so the id is second-scale, timezone-independent and stable
    /// across runs: two occurrences alias only when they fall in the same UTC
    /// minute.
    public var rawValue: String {
        "\(taskID)#v\(pinnedVersion)#m\(scheduledMinute * 60)"
    }
}

/// The next fire is a typed production result rather than a bare Date, so a
/// consumer cannot lose the task/version identity while enqueueing work.
public struct TaskScheduleOccurrence: Codable, Equatable, Hashable, Sendable {
    public let identity: TaskScheduleOccurrenceIdentity
    public let scheduledDate: Date
    public let timeZoneIdentifier: String
    public let cronExpression: String

    public init(definition: TaskScheduleDefinition, scheduledDate: Date) throws {
        self.identity = try TaskScheduleOccurrenceIdentity(
            taskID: definition.taskID,
            pinnedVersion: definition.pinnedVersion,
            scheduledDate: scheduledDate
        )
        self.scheduledDate = scheduledDate
        self.timeZoneIdentifier = definition.timeZoneIdentifier
        self.cronExpression = definition.cronExpression
    }

    public var taskID: String { identity.taskID }
    public var pinnedVersion: Int { identity.pinnedVersion }
    public var occurrenceID: String { identity.rawValue }
}

// MARK: - TaskScheduler

/// 后台任务调度器：按固定间隔触发已注册的 `BackgroundTask`。
///
/// 继承 OpenMinis 手机端 Background 能力（Agent/Background/ 的保活与
/// 周期任务思路），macOS 简化版用 DispatchSourceTimer 驱动，不依赖
/// iOS 后台执行权限。每个任务一个计时器；触发时异步执行 action，
/// 并记录 `TaskExecutionRecord`（上次执行时间/状态/耗时）供 UI 展示。
///
/// 线程模型：`@unchecked Sendable`，所有状态在内部 NSLock 下读写；
/// 计时器回调与 action 执行都在后台队列，不阻塞主线程。
public final class TaskScheduler: @unchecked Sendable {

    /// 执行记录保留上限（超出丢弃最旧的）。
    public let maxRecords: Int

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "miniscore.taskscheduler", qos: .utility)
    private let timerFactory: @Sendable (DispatchQueue) -> any DispatchSourceTimer
    private var tasks: [String: BackgroundTask] = [:]
    private var timers: [String: DispatchSourceTimer] = [:]
    private var records: [TaskExecutionRecord] = []

    public init(maxRecords: Int = 100) {
        self.maxRecords = max(1, maxRecords)
        self.timerFactory = { DispatchSource.makeTimerSource(queue: $0) }
    }

    /// Internal composition boundary for observing native timer lifetime.
    /// Public registrations keep the system DispatchSourceTimer factory.
    init(maxRecords: Int = 100,
         timerFactory: @escaping @Sendable (DispatchQueue) -> any DispatchSourceTimer) {
        self.maxRecords = max(1, maxRecords)
        self.timerFactory = timerFactory
    }

    /// Resolve one strictly-future occurrence from the canonical schedule.
    /// The returned identity carries the task and pinned version, while the
    /// local calendar calculation rejects DST gaps/duplicates instead of
    /// silently selecting an arbitrary wall-clock instant.
    public static func nextOccurrence(
        for definition: TaskScheduleDefinition,
        after referenceDate: Date,
        minimumSpacing: TimeInterval = 60
    ) throws -> TaskScheduleOccurrence {
        guard referenceDate.timeIntervalSinceReferenceDate.isFinite else {
            throw TaskScheduleValidationError.invalidReferenceDate
        }
        guard minimumSpacing.isFinite, minimumSpacing >= 60 else {
            throw TaskScheduleValidationError.tooFrequent
        }
        guard let timeZone = TimeZone(identifier: definition.timeZoneIdentifier) else {
            throw TaskScheduleValidationError.invalidTimeZone
        }
        let cron = try CanonicalCronExpression(definition.cronExpression)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firstDate = try nextDate(
            for: definition,
            cron: cron,
            calendar: calendar,
            timeZone: timeZone,
            after: referenceDate
        )
        let secondDate = try nextDate(
            for: definition,
            cron: cron,
            calendar: calendar,
            timeZone: timeZone,
            after: firstDate
        )
        guard secondDate.timeIntervalSince(firstDate) >= minimumSpacing else {
            throw TaskScheduleValidationError.tooFrequent
        }
        return try TaskScheduleOccurrence(definition: definition, scheduledDate: firstDate)
    }

    /// The latest elapsed occurrence in the last seven days, strictly after
    /// the caller's durable watermark. Earlier missed runs are intentionally
    /// discarded; this does not create a new retry for an existing occurrence.
    public static func mostRecentMissedOccurrence(
        for definition: TaskScheduleDefinition,
        after watermark: Date,
        before now: Date
    ) throws -> TaskScheduleOccurrence? {
        guard watermark.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw TaskScheduleValidationError.invalidReferenceDate
        }
        guard let zone = TimeZone(identifier: definition.timeZoneIdentifier) else {
            throw TaskScheduleValidationError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let cron = try CanonicalCronExpression(definition.cronExpression)
        // The current minute belongs to the normal poll, even if startup lands
        // several seconds after its minute boundary.
        guard let currentMinute = calendar.dateInterval(of: .minute, for: now)?.start else {
            throw TaskScheduleValidationError.invalidReferenceDate
        }
        let lowerBound = max(watermark, now.addingTimeInterval(-7 * 24 * 60 * 60))
        let startOfToday = calendar.startOfDay(for: now)
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: startOfToday) else {
                throw TaskScheduleValidationError.noNextFire
            }
            for hour in cron.orderedHours.reversed() {
                for minute in cron.orderedMinutes.reversed() {
                    var local = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                    local.hour = hour
                    local.minute = minute
                    local.second = 0
                    guard cron.matches(local), let candidate = calendar.date(from: local),
                          candidate < currentMinute, candidate > lowerBound else { continue }
                    let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
                    guard resolved.year == local.year, resolved.month == local.month,
                          resolved.day == local.day, resolved.hour == hour,
                          resolved.minute == minute else {
                        throw TaskScheduleValidationError.missingLocalTime
                    }
                    // Share the production DST/spacing contract rather than
                    // accepting Foundation's normalization of a gap or fold.
                    let occurrence = try nextOccurrence(for: definition, after: candidate.addingTimeInterval(-60))
                    guard occurrence.scheduledDate == candidate else { continue }
                    return occurrence
                }
            }
        }
        return nil
    }

    /// Validate a batch before persistence/dispatch. Duplicate identities are
    /// a hard failure so a repeated polling pass cannot create two rows.
    public static func uniqueOccurrences(
        _ occurrences: [TaskScheduleOccurrence]
    ) throws -> [TaskScheduleOccurrence] {
        var seen = Set<TaskScheduleOccurrenceIdentity>()
        for occurrence in occurrences {
            guard seen.insert(occurrence.identity).inserted else {
                throw TaskScheduleValidationError.duplicateOccurrence
            }
        }
        return occurrences
    }

    private static func nextDate(
        for definition: TaskScheduleDefinition,
        cron: CanonicalCronExpression,
        calendar: Calendar,
        timeZone: TimeZone,
        after referenceDate: Date
    ) throws -> Date {
        let referenceComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        guard let referenceDay = calendar.date(from: referenceComponents) else {
            throw TaskScheduleValidationError.noNextFire
        }

        // Eight years bounds even sparse leap-day schedules while keeping an
        // invalid or hostile schedule from turning validation into an unbounded
        // scan.
        for dayOffset in 0...(366 * 8) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: referenceDay) else {
                throw TaskScheduleValidationError.noNextFire
            }
            let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = dayComponents.year,
                  let month = dayComponents.month,
                  let dayOfMonth = dayComponents.day else { continue }

            for hour in cron.orderedHours {
                for minute in cron.orderedMinutes {
                    var local = DateComponents()
                    local.calendar = calendar
                    local.timeZone = timeZone
                    local.year = year
                    local.month = month
                    local.day = dayOfMonth
                    local.weekday = calendar.component(.weekday, from: day)
                    local.hour = hour
                    local.minute = minute
                    local.second = 0
                    guard cron.matches(local) else { continue }

                    guard let candidate = calendar.date(from: local) else {
                        throw TaskScheduleValidationError.missingLocalTime
                    }
                    let resolved = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: candidate
                    )
                    guard resolved.year == year,
                          resolved.month == month,
                          resolved.day == dayOfMonth,
                          resolved.hour == hour,
                          resolved.minute == minute else {
                        throw TaskScheduleValidationError.missingLocalTime
                    }
                    guard candidate > referenceDate else {
                        continue
                    }

                    let first = calendar.nextDate(
                        after: candidate.addingTimeInterval(-1),
                        matching: local,
                        matchingPolicy: .strict,
                        repeatedTimePolicy: .first,
                        direction: .forward
                    )
                    let last = calendar.nextDate(
                        after: candidate.addingTimeInterval(-1),
                        matching: local,
                        matchingPolicy: .strict,
                        repeatedTimePolicy: .last,
                        direction: .forward
                    )
                    if let first, let last, first != last {
                        throw TaskScheduleValidationError.ambiguousLocalTime
                    }
                    return candidate
                }
            }
        }
        throw TaskScheduleValidationError.noNextFire
    }

    deinit {
        stopAll()
    }

    // MARK: - 注册 / 注销

    /// 注册任务并（若启用）启动其计时器。同 id 重复注册会先注销旧任务。
    @discardableResult
    public func register(_ task: BackgroundTask) -> Bool {
        // DispatchSourceTimer has no useful representation for an empty
        // identity or a non-positive/non-finite interval. Reject malformed
        // definitions before replacing an existing task or constructing a
        // timer, so an invalid caller cannot trap the scheduler or erase a
        // valid registration.
        guard Self.isSchedulable(task) else { return false }

        lock.lock()
        if tasks[task.id] != nil {
            cancelTimerUnlocked(for: task.id)
        }
        tasks[task.id] = task
        let shouldStart = task.isEnabled
        lock.unlock()

        if shouldStart {
            startTimer(for: task)
        }
        return shouldStart
    }

    /// 注销任务：取消计时器并移除。无此 id 时静默。
    public func unregister(id: String) {
        lock.lock()
        tasks.removeValue(forKey: id)
        cancelTimerUnlocked(for: id)
        lock.unlock()
    }

    /// Revoke the frozen lease for a task and advance its registration
    /// generation. Delayed callbacks and in-flight results from the previous
    /// generation are then recorded as stale instead of being committed.
    @discardableResult
    public func revoke(id: String) -> Bool {
        lock.lock()
        guard let task = tasks[id], let authorization = task.authorization else {
            lock.unlock()
            return false
        }

        var revokedLease = authorization.lease
        revokedLease.revoke()
        let revokedTask = BackgroundTask(
            id: task.id,
            title: task.title,
            intervalSeconds: task.intervalSeconds,
            isEnabled: task.isEnabled,
            lastRunAt: task.lastRunAt,
            generation: UUID(),
            authorization: BackgroundTaskAuthorization(goal: authorization.goal, lease: revokedLease),
            action: task.action
        )
        tasks[id] = revokedTask
        cancelTimerUnlocked(for: id)
        lock.unlock()
        return true
    }

    /// 停止所有任务并清空注册表（同时保留执行记录）。
    public func stopAll() {
        lock.lock()
        for taskID in timers.keys {
            cancelTimerUnlocked(for: taskID)
        }
        tasks.removeAll()
        lock.unlock()
    }

    // MARK: - 启停

    /// 启用任务（启动计时器）。无此 id 时返回 false。
    @discardableResult
    public func enable(id: String) -> Bool {
        lock.lock()
        guard var task = tasks[id], !task.isEnabled else {
            let exists = tasks[id] != nil
            lock.unlock()
            return exists
        }
        task.isEnabled = true
        tasks[id] = task
        lock.unlock()
        startTimer(for: task)
        return true
    }

    /// 禁用任务（取消计时器，不再自动触发）。无此 id 时返回 false。
    @discardableResult
    public func disable(id: String) -> Bool {
        lock.lock()
        guard var task = tasks[id], task.isEnabled else {
            let exists = tasks[id] != nil
            lock.unlock()
            return exists
        }
        task.isEnabled = false
        tasks[id] = task
        cancelTimerUnlocked(for: id)
        lock.unlock()
        return true
    }

    // MARK: - 查询

    /// 按 id 查询任务（当前快照）。
    public func task(id: String) -> BackgroundTask? {
        lock.lock(); defer { lock.unlock() }
        return tasks[id]
    }

    /// 全部已注册任务。
    public func allTasks() -> [BackgroundTask] {
        lock.lock(); defer { lock.unlock() }
        return tasks.values.sorted { $0.id < $1.id }
    }

    /// 执行记录（最新在前），供 UI 展示上次执行时间/状态。
    public func executionRecords() -> [TaskExecutionRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    // MARK: - 手动触发

    /// 立即执行一次任务（无需等待间隔）。禁用中的任务不执行。
    public func runNow(id: String) {
        lock.lock()
        let generation = tasks[id]?.generation
        lock.unlock()
        guard let generation else { return }
        fire(taskID: id, generation: generation)
    }

    // MARK: - 内部

    private static func isSchedulable(_ task: BackgroundTask) -> Bool {
        !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.intervalSeconds.isFinite
            && task.intervalSeconds > 0
    }

    private func startTimer(for task: BackgroundTask) {
        let timer = timerFactory(queue)
        timer.schedule(
            deadline: .now() + task.intervalSeconds,
            repeating: task.intervalSeconds,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.fire(taskID: task.id, generation: task.generation)
        }
        timer.resume()

        lock.lock()
        guard tasks[task.id]?.generation == task.generation,
              tasks[task.id]?.isEnabled == true else {
            timer.cancel()
            lock.unlock()
            return
        }
        cancelTimerUnlocked(for: task.id)
        timers[task.id] = timer
        lock.unlock()
    }

    private func cancelTimerUnlocked(for taskID: String) {
        timers.removeValue(forKey: taskID)?.cancel()
    }

    /// 触发任务：校验启用状态、generation 与冻结 policy → 更新 lastRunAt
    /// → 异步执行 action → 以同一 policy 再次校验并记录终态。
    private func fire(taskID: String, generation: UUID) {
        lock.lock()
        guard let task = tasks[taskID] else {
            lock.unlock()
            let now = Date()
            recordExecution(
                taskID: taskID,
                startedAt: now,
                finishedAt: now,
                status: .rejected(.staleGeneration),
                expectedGeneration: generation
            )
            return
        }
        guard task.isEnabled else {
            lock.unlock()
            return
        }
        guard task.generation == generation else {
            lock.unlock()
            let now = Date()
            recordExecution(
                taskID: taskID,
                startedAt: now,
                finishedAt: now,
                status: .rejected(.staleGeneration),
                expectedGeneration: generation
            )
            return
        }

        let startedAt = Date()
        if let authorization = task.authorization,
           let rejection = admissionRejection(for: authorization, at: startedAt) {
            if rejection != .leaseNotActive {
                cancelTimerUnlocked(for: taskID)
            }
            lock.unlock()
            recordExecution(
                taskID: taskID,
                startedAt: startedAt,
                finishedAt: startedAt,
                status: .rejected(rejection),
                expectedGeneration: generation
            )
            return
        }

        var mutableTask = task
        mutableTask.lastRunAt = startedAt
        tasks[taskID] = mutableTask
        let action = mutableTask.action
        lock.unlock()

        Task {
            let actionStatus: TaskExecutionRecord.Status
            do {
                try await action()
                actionStatus = .success
            } catch {
                actionStatus = .failed("\(error)")
            }
            let finishedAt = Date()
            self.recordExecution(
                taskID: taskID,
                startedAt: startedAt,
                finishedAt: finishedAt,
                status: actionStatus,
                expectedGeneration: generation
            )
        }
    }

    /// Returns a stable rejection reason for the frozen goal/lease at one
    /// instant. This is intentionally pure so it can run under `lock` while
    /// finalizing an execution record.
    private func admissionRejection(
        for authorization: BackgroundTaskAuthorization,
        at date: Date
    ) -> BackgroundTaskAdmissionRejection? {
        let goal = authorization.goal
        let lease = authorization.lease
        guard goal.deadline.timeIntervalSinceReferenceDate.isFinite,
              goal.createdAt.timeIntervalSinceReferenceDate.isFinite,
              goal.deadline > goal.createdAt else {
            return .invalidGoalWindow
        }
        guard goal.budget > 0 else { return .zeroBudget }
        guard date < goal.deadline else { return .goalExpired }
        guard lease.goalID == goal.goalID else { return .goalLeaseMismatch }
        if let leaseScope = lease.scopeID, leaseScope != goal.scopeID {
            return .scopeMismatch
        }
        guard lease.issuedAt.timeIntervalSinceReferenceDate.isFinite,
              lease.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              lease.expiresAt > lease.issuedAt else {
            return .invalidLeaseWindow
        }
        if lease.revoked { return .leaseRevoked }
        guard date >= lease.issuedAt else { return .leaseNotActive }
        guard date < lease.expiresAt else { return .leaseExpired }
        return nil
    }

    /// 同步记录一次执行（从 Task 内调用；NSLock 不能在 async 上下文使用，
    /// 故抽成独立同步方法）。若 generation 已被替换/撤销，或冻结 lease
    /// 在 action 完成时失效，则覆盖 action 结果为可消费的 `.rejected` 终态。
    private func recordExecution(
        taskID: String,
        startedAt: Date,
        finishedAt: Date,
        status: TaskExecutionRecord.Status,
        expectedGeneration: UUID? = nil
    ) {
        lock.lock()
        var finalStatus = status
        if let expectedGeneration {
            if let currentTask = tasks[taskID], currentTask.generation == expectedGeneration {
                if let authorization = currentTask.authorization,
                   let rejection = admissionRejection(for: authorization, at: finishedAt) {
                    finalStatus = .rejected(rejection)
                    if rejection != .leaseNotActive {
                        cancelTimerUnlocked(for: taskID)
                    }
                }
            } else {
                finalStatus = .rejected(.staleGeneration)
            }
        }
        insertExecutionRecord(
            taskID: taskID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            status: finalStatus
        )
        lock.unlock()
    }

    private func insertExecutionRecord(
        taskID: String,
        startedAt: Date,
        finishedAt: Date,
        status: TaskExecutionRecord.Status
    ) {
        records.insert(
            TaskExecutionRecord(taskID: taskID, startedAt: startedAt, finishedAt: finishedAt, status: status),
            at: 0
        )
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
    }
}
