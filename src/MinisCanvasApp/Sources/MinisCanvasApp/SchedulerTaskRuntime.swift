import Foundation
import MinisCore

struct SchedulerEffectOutcome: Sendable {
    let status: SchedulerDeliveryReceipt.Status
    var executionTurnID: Int? = nil
    var executionMessageID: String? = nil
}

/// An observation of the pinned target, never an execution authorization or
/// replacement receipt. A missing fact does not prove that no effect occurred.
enum SchedulerTargetDeliveryObservation: Equatable {
    case unavailable
    case noMatchingFact(occurrence: SchedulerOccurrence)
    case identityConflict(occurrence: SchedulerOccurrence, targetFact: ScheduledTranscriptDelivery)
    case deliveryObserved(occurrence: SchedulerOccurrence, targetFact: ScheduledTranscriptDelivery)
    case deliveryConflictsWithFailure(occurrence: SchedulerOccurrence, targetFact: ScheduledTranscriptDelivery)
}

/// A capability backed by the actual durable occurrence, not a Boolean
/// supplied by the caller. The consumer rechecks it at every effect boundary.
@MainActor
struct SchedulerExecutionContext {
    let request: SchedulerSubmissionRequest
    let store: SchedulerTaskStore
    let owner: String
    let token: String
    let now: @MainActor @Sendable () -> Date
    /// Ephemeral provider/model readiness captured immediately before the
    /// lease. It is compared again by ChatStore and never persisted.
    let providerPreflight: SchedulerProviderPreflight?

    init(
        request: SchedulerSubmissionRequest,
        store: SchedulerTaskStore,
        owner: String,
        token: String,
        now: @escaping @MainActor @Sendable () -> Date,
        providerPreflight: SchedulerProviderPreflight? = nil
    ) {
        self.request = request
        self.store = store
        self.owner = owner
        self.token = token
        self.now = now
        self.providerPreflight = providerPreflight
    }

    func isCurrent() -> Bool {
        !Task.isCancelled && store.isSubmissionCurrent(request, owner: owner, token: token, now: now())
    }
}

/// Main-actor scheduler production consumer. The store owns every durable
/// trigger/lease/effect/event identity; this runtime only drives legal CAS
/// transitions and hands an immutable submission request to the composition
/// root. It never derives a destination from the focused session.
@MainActor
final class SchedulerTaskRuntime {
    private static let pollTaskID = "miniscanvas.scheduler.poll"
    private static let pollInterval: TimeInterval = 60
    typealias CommandSubmitter = @MainActor @Sendable (String) -> Void
    typealias RequestSubmitter = @MainActor @Sendable (SchedulerSubmissionRequest) throws -> Void
    typealias ProviderPreflightResolver = SchedulerTaskStore.ProviderPreflightResolver

    private let store: SchedulerTaskStore
    private let scheduler: TaskScheduler
    typealias EffectSubmitter = @MainActor @Sendable (SchedulerExecutionContext) async throws -> SchedulerEffectOutcome
    private let submitEffect: EffectSubmitter?
    private let targetDeliveryResolver: (@MainActor (SchedulerOccurrence) -> ScheduledTranscriptDelivery?)?
    private struct OwnedEffectTask {
        let identity: UUID
        let task: Task<Void, Never>
    }
    private var effectTasks: [UUID: OwnedEffectTask] = [:]
    private var executionNow: @MainActor @Sendable () -> Date = Date.init
    private var sourceAnchorResolver: (@MainActor (UUID, String, Int) -> String?)?
    private var policyRevisionResolver: (@MainActor () -> String?)?
    private let providerPreflightResolver: ProviderPreflightResolver?
    private let submitCommand: CommandSubmitter?
    private let submitRequest: RequestSubmitter?
    private let submitOccurrenceResult: (@MainActor @Sendable (SchedulerSubmissionRequest) -> SchedulerDeliveryReceipt.Status)?
    private let ownerID = SchedulerTaskStore.currentProcessLeaseOwnerID()
    private let leaseTTL: TimeInterval = 300
    private var started = false
    /// Identifies the current start→stop window. Every timer-scheduled poll
    /// round carries the label of the generation that scheduled it, and only
    /// the currently started generation may drive the store, so a stopped or
    /// superseded runtime window dispatches zero occurrences (D-SCHEDC).
    private(set) var startedGeneration: UInt64 = 0
    private(set) var lastRecoveryCount = 0
    var onCatchUpReserved: (@MainActor (SchedulerOccurrence) -> Void)?
    var onExecutionActivityChanged: (@MainActor (Bool) -> Void)?
    var hasRunningEffects: Bool { !effectTasks.isEmpty }
    /// Visible to the task-center consumer; a rejected DST schedule is never
    /// silently normalized or replaced with another run.
    private(set) var catchUpErrors: [UUID: String] = [:]

    init(
        store: SchedulerTaskStore,
        scheduler: TaskScheduler = TaskScheduler(),
        submitCommand: @escaping CommandSubmitter
    ) {
        self.store = store
        self.submitEffect = nil
        self.targetDeliveryResolver = nil
        self.scheduler = scheduler
        self.submitCommand = submitCommand
        self.submitRequest = nil
        self.submitOccurrenceResult = nil
        self.providerPreflightResolver = nil
    }

    init(
        store: SchedulerTaskStore,
        scheduler: TaskScheduler = TaskScheduler(),
        submitRequest: @escaping RequestSubmitter
    ) {
        self.store = store
        self.submitEffect = nil
        self.targetDeliveryResolver = nil
        self.scheduler = scheduler
        self.submitCommand = nil
        self.submitRequest = submitRequest
        self.submitOccurrenceResult = nil
        self.providerPreflightResolver = nil
    }

    /// Test/adapter boundary that supplies a durable delivery outcome. Keeping
    /// this overload preserves the existing production-consumer contract while
    /// allowing the runtime to distinguish delivered, failed, and unknown.
    init(
        store: SchedulerTaskStore,
        scheduler: TaskScheduler = TaskScheduler(),
        submitOccurrenceResult: @escaping @MainActor @Sendable (SchedulerSubmissionRequest) -> SchedulerDeliveryReceipt.Status
    ) {
        self.store = store
        self.submitEffect = nil
        self.targetDeliveryResolver = nil
        self.scheduler = scheduler
        self.submitCommand = nil
        self.submitRequest = nil
        self.submitOccurrenceResult = submitOccurrenceResult
        self.providerPreflightResolver = nil
    }

    init(
        store: SchedulerTaskStore,
        scheduler: TaskScheduler = TaskScheduler(),
        now: @escaping @MainActor @Sendable () -> Date = Date.init,
        sourceAnchorResolver: (@MainActor (UUID, String, Int) -> String?)? = nil,
        policyRevisionResolver: (@MainActor () -> String?)? = nil,
        providerPreflightResolver: ProviderPreflightResolver? = nil,
        targetDeliveryResolver: (@MainActor (SchedulerOccurrence) -> ScheduledTranscriptDelivery?)? = nil,
        submitEffect: @escaping EffectSubmitter
    ) {
        self.store = store
        self.scheduler = scheduler
        self.executionNow = now
        self.sourceAnchorResolver = sourceAnchorResolver
        self.policyRevisionResolver = policyRevisionResolver
        self.providerPreflightResolver = providerPreflightResolver
        self.submitEffect = submitEffect
        self.targetDeliveryResolver = targetDeliveryResolver
        self.submitCommand = nil
        self.submitRequest = nil
        self.submitOccurrenceResult = nil
    }

    func currentPolicyRevision() -> String? { policyRevisionResolver?() }

    func sourceAnchorDigest(sessionID: UUID, projectID: String, ordinal: Int) -> String? {
        sourceAnchorResolver?(sessionID, projectID, ordinal)
    }

    func providerPreflight(taskID: UUID, now: Date = Date()) -> SchedulerProviderPreflight? {
        guard let task = store.task(id: taskID) else { return nil }
        return providerPreflightResolver?(task, now)
    }

    func start() {
        guard !started else { return }
        started = true
        startedGeneration += 1
        let generation = startedGeneration
        lastRecoveryCount = store.reconcileExpiredOccurrences()
        scheduler.register(
            BackgroundTask(
                id: Self.pollTaskID,
                title: "MinisCanvas 定时任务",
                intervalSeconds: Self.pollInterval
            ) { [weak self] in
                guard let self else { return }
                await self.poll(at: Date(), startedGeneration: generation)
            }
        )
        // Reconcile and resume durable work immediately after a restart. The
        // store remains the CAS/idempotency owner, so this cannot duplicate an
        // occurrence already completed by an earlier runtime instance. The
        // round carries this window's label so a later stop/restart fences it.
        let now = executionNow()
        catchUpMissedTasks(at: now)
        pollNow(at: now, startedGeneration: generation)
    }

    /// The App's NSWorkspace wake observer calls this exact production owner.
    /// A stopped runtime remains stopped and cannot reserve or dispatch work.
    func resumeAfterWake(at date: Date = Date()) {
        guard started else { return }
        catchUpMissedTasks(at: date)
        pollNow(at: date, startedGeneration: startedGeneration)
    }

    func catchUpMissedTasks(at date: Date) {
        guard store.persistenceError == nil else { return }
        catchUpErrors.removeAll()
        for task in store.enabledTasks() {
            guard task.hasValidTarget, task.sourceAnchorVersion == 2,
                  let zoneID = task.timeZoneIdentifier else { continue }
            do {
                let definition = try TaskScheduleDefinition(taskID: task.id.uuidString,
                    cronExpression: task.cronExpression, timeZoneIdentifier: zoneID,
                    pinnedVersion: task.version)
                let watermark = store.occurrences.filter { $0.taskID == task.id }
                    .map(\.scheduledMinute).max() ?? task.createdAt
                // 暂停后再启用：从启用时刻往后算，不补跑暂停期间错过的触发。
                guard let missed = try TaskScheduler.mostRecentMissedOccurrence(for: definition,
                    after: max(task.createdAt, watermark, task.enabledAt ?? .distantPast),
                    before: date) else { continue }
                var calendar = Calendar(identifier: .gregorian)
                guard let zone = TimeZone(identifier: zoneID) else {
                    throw TaskScheduleValidationError.invalidTimeZone
                }
                calendar.timeZone = zone
                if let row = store.reserveOccurrence(taskID: task.id, at: missed.scheduledDate,
                    calendar: calendar, isCatchUp: true, recordedAt: date) {
                    onCatchUpReserved?(row)
                }
            } catch {
                catchUpErrors[task.id] = String(describing: error)
            }
        }
    }

    func stop() {
        started = false
        scheduler.stopAll()
        // Retain each owner until its real Task (including its watchdog)
        // terminates. Cancellation alone is not a completion receipt.
        for owner in effectTasks.values { owner.task.cancel() }
    }

    /// Graceful owner shutdown for the effects owned at this stop boundary.
    /// A later start/manual poll may own new work; this await does not clear
    /// or adopt any replacement generation after it suspends. The composition
    /// owner calls this outside an effect submitter (which cannot join itself).
    func stopAndJoin() async {
        let ownedTasks = effectTasks.values.map(\.task)
        stop()
        for task in ownedTasks { await task.value }
    }

    var isStarted: Bool { started }

    // MARK: Explicit recovery consumer

    /// Query the registered canonical target reader for failed/UNKNOWN work.
    /// Preserve the original terminal state, receipt and journal even if a
    /// durable delivery conflicts with the failure report. In particular this
    /// operation neither reconciles UNKNOWN nor creates a retry/proof/attempt.
    func queryTargetDelivery(id: UUID) -> SchedulerTargetDeliveryObservation {
        guard let occurrence = store.inspectTargetDeliveryOccurrence(id: id),
              let targetDeliveryResolver else { return .unavailable }
        guard let fact = targetDeliveryResolver(occurrence) else {
            return .noMatchingFact(occurrence: occurrence)
        }
        guard fact.occurrenceID == occurrence.id,
              fact.effectID == occurrence.effectID,
              fact.taskID == occurrence.taskID,
              fact.taskVersion == occurrence.taskVersion,
              fact.executionTurnID == occurrence.executionTurnID,
              fact.executionMessageID == occurrence.executionMessageID else {
            return .identityConflict(occurrence: occurrence, targetFact: fact)
        }
        if occurrence.state == .failed {
            return .deliveryConflictsWithFailure(occurrence: occurrence, targetFact: fact)
        }
        return .deliveryObserved(occurrence: occurrence, targetFact: fact)
    }

    /// Recovery is an explicit downstream action, never a side effect of a
    /// poll/restart. Keep these operations on the runtime boundary so the
    /// task-center consumer cannot reach around the production scheduler and
    /// mutate the durable ledger without the same identity fences.
    @discardableResult
    func reconcileUnknownOccurrence(id: UUID, now: Date = Date()) -> Bool {
        if let targetDeliveryResolver {
            guard let occurrence = store.inspectUnknownOccurrence(id: id),
                  let fact = targetDeliveryResolver(occurrence) else { return false }
            return store.reconcileDeliveredOccurrence(id: id, targetFact: fact, now: now)
        }
        return store.reconcileUnknownOccurrence(id: id, now: now)
    }

    @discardableResult
    func retryReconciledOccurrence(
        id: UUID,
        expectedControlRevision: Int,
        proofToken: String,
        now: Date = Date()
    ) -> SchedulerOccurrence? {
        // A production UNKNOWN without a target fact is inconclusive. An old
        // random proof cannot authorize another effect after this upgrade.
        guard targetDeliveryResolver == nil else { return nil }
        return store.retryUnknownOccurrence(
            id: id,
            expectedControlRevision: expectedControlRevision,
            proofToken: proofToken,
            now: now
        )
    }

    /// 用户在失败记录上点“重新执行”：按任务当前版本新建一条本分钟的触发记录并立刻驱动。
    /// 失败的定时任务不会自动重试，只有这个由用户发起的入口。只接受明确失败（.failed）的记录，
    /// 结果不确定的记录仍走“先对账”流程，避免重复执行。
    @discardableResult
    func rerunFailedOccurrence(id: UUID, now: Date = Date()) -> Bool {
        guard let failed = store.occurrence(id: id), failed.state == .failed,
              let task = store.task(id: failed.taskID), !task.isDeleted, task.isEnabled,
              let fresh = store.reserveOccurrence(taskID: task.id, at: now),
              fresh.id != failed.id, fresh.state == .triggered else { return false }
        pollNow(at: now)
        return true
    }

    @discardableResult
    func abortReconciledOccurrence(
        id: UUID,
        expectedControlRevision: Int,
        proofToken: String,
        now: Date = Date()
    ) -> Bool {
        store.abortUnknownOccurrence(
            id: id,
            expectedControlRevision: expectedControlRevision,
            proofToken: proofToken,
            now: now
        )
    }

    @discardableResult
    func cancelOccurrence(
        id: UUID,
        expectedTaskVersion: Int,
        expectedControlRevision: Int,
        owner: String? = nil,
        token: String? = nil,
        now: Date = Date()
    ) -> Bool {
        let cancelled = store.cancelOccurrence(
            id: id,
            owner: owner,
            token: token,
            expectedTaskVersion: expectedTaskVersion,
            expectedControlRevision: expectedControlRevision,
            now: now
        )
        if cancelled { effectTasks[id]?.task.cancel() }
        return cancelled
    }

    /// Polling is deterministic at minute granularity. Repeated calls for the
    /// same minute reuse the store's idempotency row and cannot duplicate an
    /// effect or event.
    ///
    /// A timer-scheduled round must carry the started-generation label of the
    /// runtime window that scheduled it. A round that lands after its window
    /// ended—e.g. a tick already in flight across a pause, a sleep wake-up, a
    /// date change, or a restart—returns before it can reconcile, reserve, or
    /// dispatch anything: only the currently started generation drives, and a
    /// stopped runtime drives zero (D-SCHEDC 取消后零dispatch). An untagged
    /// call stays the explicit manual/recovery entry for owners outside the
    /// production timer, matching the recovery consumers above.
    func pollNow(
        at date: Date = Date(),
        calendar: Calendar = .current,
        startedGeneration generation: UInt64? = nil
    ) {
        if let generation {
            guard started, generation == startedGeneration else { return }
        }
        guard store.persistenceError == nil else { return }
        // A live runtime can outlive the lease that was active at its last
        // tick. Reconcile at every durable polling boundary; otherwise an
        // expired running row remains non-resumable until the next restart.
        _ = store.reconcileExpiredOccurrences(now: date)
        for task in store.enabledTasks() {
            // The saved zone is part of the authorized task definition. Legacy
            // rows with no zone and invalid zones must not fall back to the
            // machine's current zone after a restart or a timezone change.
            guard let zoneID = task.timeZoneIdentifier,
                  let zone = TimeZone(identifier: zoneID) else { continue }
            // Keep the legacy injected calendar parameter for callers, but
            // production matching uses the core definition's Gregorian
            // calendar and the task's persisted zone.
            var boundCalendar = Calendar(identifier: .gregorian)
            boundCalendar.timeZone = zone
            guard CronValidator.matches(task.cronExpression, date: date, calendar: boundCalendar),
                  let definition = try? TaskScheduleDefinition(
                    taskID: task.id.uuidString,
                    cronExpression: task.cronExpression,
                    timeZoneIdentifier: zoneID,
                    pinnedVersion: task.version
                  ) else { continue }
            let minute = boundCalendar.dateInterval(of: .minute, for: date)?.start ?? date
            // The core occurrence boundary rejects DST gaps/folds and binds
            // the same task/version/UTC minute shown in the authorized preview.
            guard let occurrence = try? TaskScheduler.nextOccurrence(
                for: definition,
                after: minute.addingTimeInterval(-60)
            ), occurrence.scheduledDate == minute else { continue }
            _ = store.reserveOccurrence(taskID: task.id, at: date, calendar: boundCalendar)
        }
        for occurrence in store.resumableOccurrences() {
            drive(occurrenceID: occurrence.id, now: date)
        }
    }

    private func poll(at date: Date, startedGeneration generation: UInt64) async {
        pollNow(at: date, startedGeneration: generation)
    }

    private func drive(occurrenceID: UUID, now: Date) {
        guard let initial = store.occurrence(id: occurrenceID),
              let task = store.task(id: initial.taskID),
              let zoneID = task.timeZoneIdentifier,
              TimeZone(identifier: zoneID) != nil,
              task.isEnabled,
              !task.isDeleted,
              initial.sourceAnchorVersion == 2,
              initial.targetSessionID != nil,
              initial.targetProjectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              (initial.targetTurnID ?? 0) > 0 else { return }

        var occurrence = initial
        guard store.isOccurrenceAuthorized(occurrence, now: now) else {
            if occurrence.state == .triggered {
                _ = store.compareAndSwapOccurrence(
                    id: occurrenceID,
                    expected: .triggered,
                    next: .waitingApproval,
                    expectedControlRevision: occurrence.controlRevision,
                    now: now
                )
            }
            return
        }
        // Readiness belongs to the occurrence's fixed target. A later task
        // edit must neither block that target nor authorize it through a
        // different ready target; current task control/grant fences above stay.
        var preflightTask = task
        preflightTask.targetSessionID = occurrence.targetSessionID
        preflightTask.targetProjectID = occurrence.targetProjectID
        preflightTask.targetTurnID = occurrence.targetTurnID
        let providerPreflight = providerPreflightResolver?(preflightTask, now)
        if providerPreflightResolver != nil,
           providerPreflight?.isReadyForExecution != true {
            // Keep the occurrence resumable. No lease, execution identity, or
            // external request is created until the same facts are ready.
            return
        }
        if occurrence.state == .triggered {
            guard store.compareAndSwapOccurrence(
                id: occurrenceID,
                expected: .triggered,
                next: .authorized,
                expectedControlRevision: occurrence.controlRevision,
                now: now
            ) else { return }
            guard let updated = store.occurrence(id: occurrenceID) else { return }
            occurrence = updated
        }
        guard occurrence.state == .authorized || occurrence.state == .admitted || occurrence.state == .dispatched else { return }

        if occurrence.state == .authorized {
            guard store.compareAndSwapOccurrence(
                id: occurrenceID,
                expected: .authorized,
                next: .admitted,
                expectedControlRevision: occurrence.controlRevision,
                now: now
            ), let updated = store.occurrence(id: occurrenceID) else { return }
            occurrence = updated
        }
        if occurrence.state == .admitted {
            guard occurrence.targetSessionID != nil,
                  occurrence.targetProjectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  occurrence.targetTurnID ?? 0 > 0,
                  store.compareAndSwapOccurrence(
                    id: occurrenceID,
                    expected: .admitted,
                    next: .dispatched,
                    expectedControlRevision: occurrence.controlRevision,
                    now: now
                  ), let updated = store.occurrence(id: occurrenceID) else {
                _ = store.compareAndSwapOccurrence(
                    id: occurrenceID,
                    expected: .admitted,
                    next: .cancelled,
                    expectedControlRevision: occurrence.controlRevision,
                    now: now
                )
                return
            }
            occurrence = updated
        }
        guard occurrence.state == .dispatched,
              let token = store.claimLease(
                id: occurrenceID,
                owner: ownerID,
                expectedControlRevision: occurrence.controlRevision,
                now: now
              ),
              store.heartbeat(id: occurrenceID, owner: ownerID, token: token, now: now) else { return }

        guard let current = store.occurrence(id: occurrenceID),
              let currentTask = store.task(id: current.taskID) else { return }
        let request = SchedulerSubmissionRequest(
            occurrenceID: current.id,
            effectID: current.effectID,
            taskID: currentTask.id,
            taskVersion: current.taskVersion,
            idempotencyKey: current.idempotencyKey,
            command: current.command,
            targetSessionID: current.targetSessionID,
            targetProjectID: current.targetProjectID,
            targetTurnID: current.targetTurnID,
            sourceTaskID: currentTask.id
        )
        if let submitEffect {
            launchEffect(submitEffect, request: request, token: token,
                         providerPreflight: providerPreflight)
            return
        }
        do {
            let deliveryStatus: SchedulerDeliveryReceipt.Status
            if let submitOccurrenceResult {
                deliveryStatus = submitOccurrenceResult(request)
            } else if let submitRequest {
                try submitRequest(request)
                // Legacy synchronous callback proves handoff only.
                deliveryStatus = .unknown
            } else {
                submitCommand?(current.command)
                // Composer is currently fire-and-forget. Do not claim a
                // successful effect until its boundary returns a receipt.
                deliveryStatus = .unknown
            }
            _ = store.recordDelivery(
                id: current.id,
                owner: ownerID,
                token: token,
                status: deliveryStatus,
                detail: deliveryStatus == .unknown ? "delivery receipt unavailable" : nil,
                now: now,
                expectedTaskVersion: current.taskVersion,
                expectedControlRevision: current.controlRevision
            )
        } catch {
            _ = store.recordDelivery(
                id: current.id,
                owner: ownerID,
                token: token,
                status: .failed,
                detail: "scheduler submission failed",
                now: now,
                expectedTaskVersion: current.taskVersion,
                expectedControlRevision: current.controlRevision
            )
        }
    }
    private func launchEffect(_ submit: @escaping EffectSubmitter,
                              request: SchedulerSubmissionRequest,
                              token: String,
                              providerPreflight: SchedulerProviderPreflight? = nil) {
        guard effectTasks[request.occurrenceID] == nil else { return }
        let context = SchedulerExecutionContext(request: request, store: store,
            owner: ownerID, token: token, now: executionNow,
            providerPreflight: providerPreflight)
        let identity = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    guard context.isCurrent(), self.store.heartbeat(id: request.occurrenceID,
                        owner: context.owner, token: context.token, now: context.now()) else {
                        if self.effectTasks[request.occurrenceID]?.identity == identity {
                            self.effectTasks[request.occurrenceID]?.task.cancel()
                        }
                        return
                    }
                }
            }
            await self.performEffect(submit, context: context)
            watchdog.cancel()
            await watchdog.value
            if self.effectTasks[request.occurrenceID]?.identity == identity {
                self.effectTasks.removeValue(forKey: request.occurrenceID)
                self.onExecutionActivityChanged?(self.hasRunningEffects)
            }
        }
        effectTasks[request.occurrenceID] = OwnedEffectTask(identity: identity, task: task)
        onExecutionActivityChanged?(hasRunningEffects)
    }

    private func performEffect(_ submit: EffectSubmitter, context: SchedulerExecutionContext) async {
        let request = context.request
            do {
                guard context.isCurrent() else { throw CancellationError() }
                let outcome = try await ApprovalExecutionOriginContext.$current.withValue(.scheduledTask) {
                    try await submit(context)
                }
                if let receipt = self.store.occurrence(id: request.occurrenceID)?.submissionReceipt,
                   receipt.request == request, receipt.status == outcome.status { return }
                guard context.isCurrent() else { throw CancellationError() }
                _ = self.store.recordDelivery(id: request.occurrenceID, owner: context.owner,
                    token: context.token, status: outcome.status, now: context.now(),
                    expectedTaskVersion: request.taskVersion, expectedControlRevision: request.taskVersion,
                    executionTurnID: outcome.executionTurnID, executionMessageID: outcome.executionMessageID)
            } catch is CancellationError {
                // A cancelled async task may already have reached a provider,
                // tool, or durable target commit. Runtime stop/lease loss is
                // therefore uncertainty, not proof that no effect occurred.
                // An explicit user cancel has already fenced the row in the
                // store; markExecutionUnknown cannot revive that terminal row.
                _ = self.store.markExecutionUnknown(request, owner: context.owner,
                    token: context.token, now: context.now())
            } catch {
                let status: SchedulerDeliveryReceipt.Status
                if let typed = error as? SessionStoreError, case .sessionCommitUncertain = typed { status = .unknown }
                else if let typed = error as? ChatStore.ScheduledSubmissionError, case .effectUncertain = typed { status = .unknown }
                else { status = .failed }
                if !self.store.recordDelivery(id: request.occurrenceID, owner: context.owner,
                    token: context.token, status: status, detail: status == .unknown ? "执行结果需核对" : "目标执行失败", now: context.now(),
                    expectedTaskVersion: request.taskVersion, expectedControlRevision: request.taskVersion) {
                    _ = self.store.markExecutionUnknown(request, owner: context.owner, token: context.token, now: context.now())
                }
            }
    }

}
