import Testing
import Foundation
@testable import MinisCanvasApp

private final class SchedulerSubmissionSpy: @unchecked Sendable {
    var commands: [String] = []
}

// MARK: - 波4 定时任务：SchedulerTaskStore CRUD + cron 校验 + 启用开关
//
// 用独立 UserDefaults suite 隔离存储，绝不污染真实 <standard> 键。

@Suite("波4 SchedulerTaskStore")
@MainActor
struct SchedulerTaskStoreTests {

    /// 独立 suite（每次测试新建，defer 清理避免污染）。
    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let name = "scheduler-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, { d.removePersistentDomain(forName: name) })
    }

    // MARK: cron 校验

    @Test func validCronAccepted() {
        #expect(CronValidator.validate("0 9 * * 1") == nil)
        #expect(CronValidator.validate("*/5 * * * *") == nil)
        #expect(CronValidator.validate("30 8 * * 1-5") == nil)
        #expect(CronValidator.validate("0 0 1 1 *") == nil)
        #expect(CronValidator.validate("0,15,30,45 * * * *") == nil)
        #expect(CronValidator.validate("0 9 * * 7") == nil, "周 7 合法（= 周日）")
    }

    @Test func cronMatchingUsesMinuteHourAndWeekday() {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31 // Monday
        components.hour = 9
        components.minute = 0
        components.second = 0
        let date = calendar.date(from: components)!

        #expect(CronValidator.matches("0 9 * * 1", date: date, calendar: calendar))
        #expect(!CronValidator.matches("1 9 * * 1", date: date, calendar: calendar))
        #expect(CronValidator.matches("* * * * *", date: date, calendar: calendar))
        #expect(CronValidator.matches("0 9 31 * 2", date: date, calendar: calendar),
                "日期与星期均受限时按 cron 的 OR 语义匹配")
        #expect(CronValidator.matches("0 9 */4 * 1", date: date, calendar: calendar),
                "步进日期是受限集合；星期一仍应按 OR 语义触发")
    }

    @Test func invalidCronRejected() {
        #expect(CronValidator.validate("0 9 * *") != nil, "4 段非法")
        #expect(CronValidator.validate("0 9 * * * *") != nil, "6 段非法")
        #expect(CronValidator.validate("60 * * * *") != nil, "分 60 越界")
        #expect(CronValidator.validate("* 24 * * *") != nil, "时 24 越界")
        #expect(CronValidator.validate("* * 0 * *") != nil, "日 0 越界")
        #expect(CronValidator.validate("* * * 13 *") != nil, "月 13 越界")
        #expect(CronValidator.validate("* * * * 8") != nil, "周 8 越界")
        #expect(CronValidator.validate("abc * * * *") != nil, "非数字")
        #expect(CronValidator.validate("*/0 * * * *") != nil, "步进 0 非法")
        #expect(CronValidator.validate("5-1 * * * *") != nil, "范围下界>上界")
        #expect(CronValidator.validate("") != nil, "空表达式非法")
    }

    // MARK: CRUD

    @Test func addPersistsAcrossInstances() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        #expect(store.add(name: "周报", cronExpression: "0 9 * * 1", command: "生成周报") == nil)

        // 新实例 = 模拟 App 重启后从盘上恢复
        let reopened = SchedulerTaskStore(defaults: d)
        let tasks = reopened.allTasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].name == "周报")
        #expect(tasks[0].cronExpression == "0 9 * * 1")
        #expect(tasks[0].command == "生成周报")
        #expect(tasks[0].isEnabled == true)
    }

    @Test func addRejectsInvalidCronAndDoesNotWrite() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        // 返回错误，且不落盘
        #expect(store.add(name: "坏任务", cronExpression: "60 * * * *", command: "x") != nil)
        #expect(store.allTasks().isEmpty)
    }

    @Test func deleteRemovesTask() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        store.add(name: "A", cronExpression: "0 9 * * *", command: "a")
        store.add(name: "B", cronExpression: "0 10 * * *", command: "b")
        #expect(store.allTasks().count == 2)

        let target = store.allTasks().first { $0.name == "A" }!
        store.delete(id: target.id)
        let remaining = store.allTasks()
        #expect(remaining.count == 1)
        #expect(remaining[0].name == "B")
    }

    @Test func updateModifiesFields() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        store.add(name: "A", cronExpression: "0 9 * * *", command: "a")
        var task = store.allTasks()[0]
        task.name = "A2"
        task.cronExpression = "30 18 * * 5"
        task.command = "a2"
        #expect(store.update(task) == nil)

        let updated = store.allTasks()[0]
        #expect(updated.name == "A2")
        #expect(updated.cronExpression == "30 18 * * 5")
        #expect(updated.command == "a2")
    }

    @Test func updateRejectsInvalidCronAndKeepsOld() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        store.add(name: "A", cronExpression: "0 9 * * *", command: "a")
        var task = store.allTasks()[0]
        task.cronExpression = "99 * * * *"
        #expect(store.update(task) != nil, "非法 cron 应拒绝更新")

        #expect(store.allTasks()[0].cronExpression == "0 9 * * *", "原值应保留")
    }

    // MARK: 启用开关

    @Test func enabledFilterAndToggle() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        store.add(name: "A", cronExpression: "0 9 * * *", command: "a")
        store.add(name: "B", cronExpression: "0 10 * * *", command: "b", isEnabled: false)

        #expect(store.enabledTasks().count == 1)
        #expect(store.enabledTasks()[0].name == "A")

        // 切换 B 启用
        let b = store.allTasks().first { $0.name == "B" }!
        store.setEnabled(b.id, enabled: true)
        #expect(store.enabledTasks().count == 2)

        // 切换 A 停用
        let a = store.allTasks().first { $0.name == "A" }!
        store.setEnabled(a.id, enabled: false)
        #expect(store.enabledTasks().count == 1)
        #expect(store.enabledTasks()[0].name == "B")
    }

    @Test("D-SCHEDULE-01 同根创建保存、重开禁启及原消费者删除")
    func completeCRUDUsesOneDurableRootAndProductionDeletionConsumer() throws {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-crud-763-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        #expect(store.add(name: "完整生命周期", cronExpression: "* * * * *",
            command: "original prompt", targetSessionID: sessionID,
            targetProjectID: "crud-763", targetTurnID: 1) == nil)
        let created = try #require(store.allTasks().first)
        #expect(store.allTasks() == [created])
        #expect(created.name == "完整生命周期" && created.command == "original prompt")
        #expect(created.cronExpression == "* * * * *" && created.isEnabled)
        #expect(created.targetSessionID == sessionID && created.targetProjectID == "crud-763")
        #expect(created.targetTurnID == 1 && created.version == 1 && !created.isAuthorized)
        let originalDeletion = try #require(SchedulerTaskDeletionConsumer.request(for: created, now: now))

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.allTasks() == [created], "同根重开须保留完整任务值及稳定ID")
        var edited = created
        edited.name = "保存后的完整生命周期"
        edited.command = "saved prompt"
        #expect(reopened.update(edited, expectedVersion: created.version) == nil)
        let saved = try #require(reopened.task(id: created.id))
        edited.version = created.version + 1
        edited.authorizationVersion = created.authorizationVersion + 1
        #expect(saved == edited)
        let afterSave = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(afterSave.allTasks() == [saved])
        #expect(afterSave.authorize(saved.id, actorID: "crud-763-owner",
            scopeID: "crud-763", policyRevision: "crud-763-policy"))
        let authorized = try #require(afterSave.task(id: saved.id))
        let queued = try #require(afterSave.reserveOccurrence(taskID: saved.id, at: now))
        #expect(queued.state == .triggered && queued.taskVersion == authorized.version)
        #expect(queued.targetSessionID == sessionID && queued.command == "saved prompt")

        afterSave.setEnabled(saved.id, enabled: false)
        var pausedTask = authorized
        pausedTask.isEnabled = false
        pausedTask.enablementRevision += 1
        let paused = try #require(afterSave.occurrence(id: queued.id))
        #expect(paused.state == .cancelled)
        let pausedJournal = afterSave.occurrenceJournal
        let disabledReload = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(disabledReload.persistenceError == nil)
        #expect(disabledReload.allTasks() == [pausedTask] && disabledReload.enabledTasks().isEmpty)
        #expect(disabledReload.occurrences == [paused])
        #expect(disabledReload.occurrenceJournal == pausedJournal)
        let capture = SchedulerSubmissionSpy()
        SchedulerTaskRuntime(store: disabledReload, submitCommand: { capture.commands.append($0) })
            .pollNow(at: now.addingTimeInterval(60))
        #expect(capture.commands.isEmpty)

        disabledReload.setEnabled(saved.id, enabled: true)
        var resumedTask = authorized
        resumedTask.enablementRevision += 2
        let enabledReload = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        // 暂停改启用会记录启用时刻（新字段，有意为之）；其余字段必须与重开前完全一致。
        resumedTask.enabledAt = try #require(enabledReload.task(id: saved.id)?.enabledAt)
        #expect(enabledReload.allTasks() == [resumedTask])
        #expect(enabledReload.enabledTasks() == [resumedTask])
        #expect(enabledReload.occurrences == [paused])
        let runtime = SchedulerTaskRuntime(store: enabledReload,
            submitCommand: { capture.commands.append($0) })
        runtime.pollNow(at: now.addingTimeInterval(60))
        #expect(capture.commands == ["saved prompt"], "恢复后真实Runtime消费保存的任务一次")
        // The existing command-only boundary proves handoff, not delivery.
        // Keep its durable UNKNOWN result instead of inventing success.
        let handedOff = try #require(enabledReload.latestOccurrence(for: saved.id))
        #expect(handedOff.id != paused.id && handedOff.state == .unknown)
        let handoffReceipt = try #require(handedOff.submissionReceipt)
        #expect(handoffReceipt.status == .unknown)
        #expect(handoffReceipt.request.occurrenceID == handedOff.id)
        #expect(handoffReceipt.request.taskID == saved.id && handoffReceipt.request.taskVersion == saved.version)
        #expect(handoffReceipt.request.effectID == handedOff.effectID)
        #expect(handoffReceipt.request.idempotencyKey == handedOff.idempotencyKey)
        #expect(handoffReceipt.request.command == "saved prompt")
        #expect(handoffReceipt.request.targetSessionID == sessionID)
        #expect(handoffReceipt.request.targetProjectID == "crud-763" && handoffReceipt.request.targetTurnID == 1)
        #expect(handedOff.deliveryReceipt?.status == .unknown)
        #expect(handedOff.deliveryReceipt?.detail == "delivery receipt unavailable")
        #expect(handedOff.leaseOwner == nil && handedOff.leaseToken == nil && handedOff.leaseExpiresAt == nil)
        let queuedForDeletion = try #require(enabledReload.reserveOccurrence(
            taskID: saved.id, at: now.addingTimeInterval(120)))
        #expect(queuedForDeletion.state == .triggered)
        let beforeDeletionRows = enabledReload.occurrences
        let beforeDeletionJournal = enabledReload.occurrenceJournal
        let beforeDeletionTasks = try #require(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1"))
        let beforeDeletionLedger = try Data(contentsOf: ledger)

        #expect(SchedulerTaskDeletionConsumer.confirm(originalDeletion,
            selectedTaskID: saved.id, store: enabledReload, now: now.addingTimeInterval(1))
            == .rejected(.taskChanged))
        let deletion = try #require(SchedulerTaskDeletionConsumer.request(for: authorized, now: now))
        #expect(deletion.taskID == saved.id && deletion.taskVersion == saved.version)
        #expect(SchedulerTaskDeletionConsumer.confirm(deletion,
            selectedTaskID: saved.id, store: enabledReload, now: deletion.expiresAt)
            == .rejected(.expired))
        #expect(enabledReload.allTasks() == [resumedTask])
        #expect(enabledReload.occurrences == beforeDeletionRows)
        #expect(enabledReload.occurrenceJournal == beforeDeletionJournal)
        #expect(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == beforeDeletionTasks)
        #expect(try Data(contentsOf: ledger) == beforeDeletionLedger)

        #expect(SchedulerTaskDeletionConsumer.confirm(deletion,
            selectedTaskID: saved.id, store: enabledReload, now: now.addingTimeInterval(1)) == .deleted)
        let tombstone = try #require(enabledReload.task(id: saved.id))
        var expectedTombstone = resumedTask
        expectedTombstone.isEnabled = false
        expectedTombstone.isAuthorized = false
        expectedTombstone.authorizationRevoked = true
        expectedTombstone.isDeleted = true
        expectedTombstone.version += 1
        #expect(tombstone == expectedTombstone)
        #expect(enabledReload.allTasks().isEmpty && enabledReload.enabledTasks().isEmpty)
        #expect(enabledReload.occurrence(id: paused.id) == paused)
        #expect(enabledReload.occurrence(id: handedOff.id) == handedOff)
        let cancelled = try #require(enabledReload.occurrence(id: queuedForDeletion.id))
        #expect(cancelled.state == .cancelled && cancelled.submissionReceipt == nil)
        #expect(cancelled.taskID == saved.id && cancelled.taskVersion == authorized.version)
        let deletedRows = enabledReload.occurrences
        let deletedJournal = enabledReload.occurrenceJournal
        let deletedTaskBytes = try #require(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1"))
        let deletedLedgerBytes = try Data(contentsOf: ledger)
        let deletedReload = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(deletedReload.persistenceError == nil)
        #expect(deletedReload.task(id: saved.id) == tombstone)
        #expect(deletedReload.allTasks().isEmpty && deletedReload.enabledTasks().isEmpty)
        #expect(deletedReload.occurrences == deletedRows && deletedReload.occurrenceJournal == deletedJournal)
        #expect(SchedulerTaskDeletionConsumer.confirm(deletion,
            selectedTaskID: saved.id, store: deletedReload, now: now.addingTimeInterval(1))
            == .rejected(.missingOrDeleted))
        deletedReload.setEnabled(saved.id, enabled: true)
        SchedulerTaskRuntime(store: deletedReload, submitCommand: { capture.commands.append($0) })
            .pollNow(at: now.addingTimeInterval(120))
        runtime.pollNow(at: now.addingTimeInterval(120))
        #expect(capture.commands == ["saved prompt"], "删除后重开及原runtime均不可再派发")
        #expect(deletedReload.task(id: saved.id) == tombstone)
        #expect(deletedReload.occurrences == deletedRows && deletedReload.occurrenceJournal == deletedJournal)
        #expect(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == deletedTaskBytes)
        #expect(try Data(contentsOf: ledger) == deletedLedgerBytes)
    }

    @Test func allTasksSortedNewestFirst() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        store.add(name: "A", cronExpression: "0 9 * * *", command: "a")
        store.add(name: "B", cronExpression: "0 10 * * *", command: "b")
        // 后添加的 A 时间戳更晚 → 排在前面
        let names = store.allTasks().map(\.name)
        #expect(names == ["B", "A"])
    }

    @Test func previewIsReadOnlyAndBindsExactTaskVersionAndTarget() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        let sessionID = UUID()
        store.add(
            name: "预览",
            cronExpression: "*/5 * * * *",
            command: "原始命令",
            targetSessionID: sessionID,
            targetProjectID: "project-preview",
            targetTurnID: 4
        )
        let task = store.allTasks()[0]
        let beforeOccurrences = store.occurrences
        let beforeJournal = store.occurrenceJournal
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let preview = store.preview(taskID: task.id, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)

        #expect(preview?.taskID == task.id)
        #expect(preview?.taskVersion == task.version)
        #expect(preview?.command == "原始命令")
        #expect(preview?.targetSessionID == sessionID)
        #expect(preview?.predictedTriggers.isEmpty == false)
        #expect(store.occurrences == beforeOccurrences)
        #expect(store.occurrenceJournal == beforeJournal)
    }

    @Test func legacyTaskWithoutZoneCannotDispatchUntilPreviewIsConfirmed() throws {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-legacy-zone-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let legacy = SchedulerTask(
            name: "旧任务",
            cronExpression: "* * * * *",
            timeZoneIdentifier: nil,
            command: "legacy-command",
            isAuthorized: true,
            targetSessionID: UUID(),
            targetProjectID: "legacy-project",
            targetTurnID: 1
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "miniscanvas.scheduler.tasks.v1")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
        let loaded = try #require(store.task(id: legacy.id))
        #expect(loaded.timeZoneIdentifier == nil)
        #expect(!store.authorize(legacy.id))

        let before = Date(timeIntervalSince1970: 1_756_650_000)
        let oldQueued = try #require(store.reserveOccurrence(taskID: legacy.id, at: before))
        let spy = SchedulerSubmissionSpy()
        SchedulerTaskRuntime(store: store, submitCommand: { spy.commands.append($0) })
            .pollNow(at: before)
        #expect(spy.commands.isEmpty)
        #expect(store.occurrence(id: oldQueued.id)?.state == .triggered)

        let preview = try #require(store.preview(
            taskID: legacy.id, now: before, timeZone: TimeZone(identifier: "UTC")!
        ))
        #expect(preview.authorizationState == .waiting)
        #expect(store.confirmPreview(preview, actorID: "user", scopeID: "legacy-project",
            policyRevision: "scheduler-policy-v1", now: before))
        let rebound = try #require(store.task(id: legacy.id))
        #expect(rebound.timeZoneIdentifier == preview.timeZoneIdentifier)
        #expect(rebound.version == legacy.version + 1)
        #expect(SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledgerURL)
            .task(id: legacy.id)?.timeZoneIdentifier
            == preview.timeZoneIdentifier)
    }

    @Test func previewRejectsMissingAndRepeatedDSTMinutes() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: defaults)
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        store.add(name: "spring", cronExpression: "30 2 * * *", command: "spring")
        let spring = store.allTasks()[0]
        let springDay = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9))!
        #expect(store.preview(taskID: spring.id, now: springDay, timeZone: zone) == nil)

        store.add(name: "autumn", cronExpression: "30 1 * * *", command: "autumn")
        let autumn = store.allTasks()[0]
        let autumnDay = calendar.date(from: DateComponents(year: 2025, month: 11, day: 2))!
        #expect(store.preview(taskID: autumn.id, now: autumnDay, timeZone: zone) == nil)
    }

    @Test func confirmPreviewUsesVersionFingerprintExpiryAndExplicitScope() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        store.add(
            name: "确认",
            cronExpression: "* * * * *",
            command: "confirm-me",
            targetSessionID: UUID(),
            targetProjectID: "project-confirm",
            targetTurnID: 2
        )
        let task = store.allTasks()[0]
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let preview = store.preview(taskID: task.id, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)!

        #expect(store.confirmPreview(preview, actorID: "", scopeID: "project-confirm", policyRevision: "p", now: now) == false)
        #expect(store.confirmPreview(preview, actorID: "user-1", scopeID: "project-confirm", policyRevision: "p", now: now) == true)
        #expect(store.task(id: task.id)?.isAuthorized == true)

        let expired = SchedulerTaskPreview(
            taskID: preview.taskID,
            taskVersion: preview.taskVersion,
            name: preview.name,
            cronExpression: preview.cronExpression,
            command: preview.command,
            targetSessionID: preview.targetSessionID,
            targetProjectID: preview.targetProjectID,
            targetTurnID: preview.targetTurnID,
            isEnabled: preview.isEnabled,
            authorizationActorID: preview.authorizationActorID,
            authorizationScopeID: preview.authorizationScopeID,
            authorizationPolicyRevision: preview.authorizationPolicyRevision,
            authorizationExpiresAt: preview.authorizationExpiresAt,
            authorizationRevoked: preview.authorizationRevoked,
            authorizationState: preview.authorizationState,
            timeZoneIdentifier: preview.timeZoneIdentifier,
            predictedTriggers: preview.predictedTriggers,
            fingerprint: preview.fingerprint,
            expiresAt: now.addingTimeInterval(-1)
        )
        #expect(store.confirmPreview(expired, actorID: "user-2", scopeID: "project-confirm", policyRevision: "p", now: now) == false)
    }

    @Test func productionRuntimeDispatchesEnabledTaskOncePerMinute() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-occurrences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let store = SchedulerTaskStore(defaults: d, occurrenceLedgerURL: ledgerURL)
        let targetSessionID = UUID()
        store.add(
            name: "启用",
            cronExpression: "* * * * *",
            command: "执行启用",
            targetSessionID: targetSessionID,
            targetProjectID: "scheduler-test-project",
            targetTurnID: 1
        )
        store.add(
            name: "停用",
            cronExpression: "* * * * *",
            command: "执行停用",
            isEnabled: false,
            targetSessionID: UUID(),
            targetProjectID: "scheduler-test-project",
            targetTurnID: 1
        )
        let enabledTask = store.allTasks().first { $0.name == "启用" }!
        #expect(store.authorize(enabledTask.id))

        let spy = SchedulerSubmissionSpy()
        let runtime = SchedulerTaskRuntime(
            store: store,
            submitCommand: { command in spy.commands.append(command) }
        )
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        runtime.pollNow(at: now)
        runtime.pollNow(at: now.addingTimeInterval(30))
        runtime.pollNow(at: now.addingTimeInterval(60))

        #expect(spy.commands == ["执行启用", "执行启用"])
    }

    @Test func occurrenceKeepsPinnedCommandAfterCurrentTaskEdit() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-pinned-command-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let store = SchedulerTaskStore(defaults: d, occurrenceLedgerURL: ledgerURL)
        store.add(
            name: "固定命令",
            cronExpression: "* * * * *",
            command: "command-v1",
            targetSessionID: UUID(),
            targetProjectID: "project-pinned",
            targetTurnID: 1
        )
        let task = store.allTasks()[0]
        #expect(store.authorize(task.id))
        let originalDate = Date(timeIntervalSince1970: 1_756_650_000)
        let original = store.reserveOccurrence(taskID: task.id, at: originalDate)!

        let capture = SchedulerSubmissionSpy()
        let requestRuntime = SchedulerTaskRuntime(store: store, submitRequest: { request in
            capture.commands.append(request.command)
        })
        requestRuntime.pollNow(at: originalDate)

        var edited = task
        edited.command = "command-v2"
        #expect(store.update(edited) == nil)

        #expect(store.occurrence(id: original.id)?.command == "command-v1")
        #expect(capture.commands == ["command-v1"])
    }

    @Test func productionRuntimeStartIsIdempotentAndStops() {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let runtime = SchedulerTaskRuntime(
            store: SchedulerTaskStore(defaults: d),
            submitCommand: { _ in }
        )

        runtime.start()
        runtime.start()
        #expect(runtime.isStarted)
        runtime.stop()
        #expect(!runtime.isStarted)
    }

    @Test func productionRuntimeReconcilesExpiredLeaseBeforePolling() throws {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-expired-lease-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }

        let targetSessionID = UUID()
        let store = SchedulerTaskStore(defaults: d, occurrenceLedgerURL: ledgerURL)
        store.add(
            name: "过期 lease",
            cronExpression: "* * * * *",
            command: "不应重复提交",
            targetSessionID: targetSessionID,
            targetProjectID: "scheduler-test-project",
            targetTurnID: 1
        )
        let task = try #require(store.allTasks().first)
        #expect(store.authorize(task.id))

        let now = Date(timeIntervalSince1970: 1_756_650_000)
        // Consume the store-open pass before creating this runtime lease;
        // this test then exercises wall-clock expiry during a live poll.
        #expect(store.reconcileExpiredOccurrences(now: now) == 0)
        let occurrence = try #require(store.reserveOccurrence(taskID: task.id, at: now))
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .triggered, next: .authorized,
            expectedControlRevision: task.version, now: now
        ))
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .authorized, next: .admitted,
            expectedControlRevision: task.version, now: now
        ))
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .admitted, next: .dispatched,
            expectedControlRevision: task.version, now: now
        ))
        let token = try #require(store.claimLease(
            id: occurrence.id,
            owner: "test-owner",
            expectedControlRevision: task.version,
            now: now,
            ttl: 1
        ))
        #expect(store.heartbeat(
            id: occurrence.id,
            owner: "test-owner",
            token: token,
            now: now,
            ttl: 1
        ))

        let spy = SchedulerSubmissionSpy()
        let runtime = SchedulerTaskRuntime(
            store: store,
            submitCommand: { command in spy.commands.append(command) }
        )
        runtime.pollNow(at: now.addingTimeInterval(2))

        #expect(store.occurrence(id: occurrence.id)?.state == .unknown)
        #expect(spy.commands.isEmpty)
        #expect(store.recordDelivery(
            id: occurrence.id, owner: "test-owner", token: token, status: .delivered,
            now: now.addingTimeInterval(2), expectedTaskVersion: task.version,
            expectedControlRevision: task.version
        ) == false)
        #expect(store.cancelOccurrence(
            id: occurrence.id, owner: "test-owner", token: token,
            expectedTaskVersion: task.version, expectedControlRevision: task.version,
            now: now.addingTimeInterval(2)
        ) == false)
        #expect(store.claimLease(
            id: occurrence.id, owner: "new-runtime",
            expectedControlRevision: task.version, now: now.addingTimeInterval(2)
        ) == nil)
    }

    @Test func restartReconcilesPersistedLeaseBeforeTTLAndDoesNotCreateAttempt() throws {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-restart-lease-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }

        let store = SchedulerTaskStore(defaults: d, occurrenceLedgerURL: ledgerURL)
        store.add(
            name: "重启 lease",
            cronExpression: "* * * * *",
            command: "不可重复",
            targetSessionID: UUID(),
            targetProjectID: "scheduler-test-project",
            targetTurnID: 1
        )
        let task = try #require(store.allTasks().first)
        #expect(store.authorize(task.id))
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        #expect(store.reconcileExpiredOccurrences(now: now) == 0)
        let occurrence = try #require(store.reserveOccurrence(taskID: task.id, at: now))
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .triggered, next: .authorized,
            expectedControlRevision: task.version, now: now
        ))
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .authorized, next: .admitted,
            expectedControlRevision: task.version, now: now
        ))
        #expect(store.compareAndSwapOccurrence(
            id: occurrence.id, expected: .admitted, next: .dispatched,
            expectedControlRevision: task.version, now: now
        ))
        let oldToken = try #require(store.claimLease(
            id: occurrence.id,
            owner: "old-runtime",
            expectedControlRevision: task.version,
            now: now,
            ttl: 300
        ))

        let restarted = SchedulerTaskStore(defaults: d, occurrenceLedgerURL: ledgerURL)
        #expect(restarted.reconcileExpiredOccurrences(now: now.addingTimeInterval(1)) == 1)
        #expect(restarted.occurrence(id: occurrence.id)?.state == .unknown)
        #expect(restarted.occurrence(id: occurrence.id)?.deliveryReceipt?.detail?.contains("runtime restarted") == true)
        #expect(restarted.occurrence(id: occurrence.id)?.leaseOwner == nil)
        #expect(restarted.occurrence(id: occurrence.id)?.leaseToken == nil)
        #expect(restarted.occurrences.count == 1)
        #expect(restarted.resumableOccurrences().isEmpty)
        #expect(restarted.recordDelivery(
            id: occurrence.id, owner: "old-runtime", token: oldToken, status: .delivered,
            now: now.addingTimeInterval(1), expectedTaskVersion: task.version,
            expectedControlRevision: task.version
        ) == false)
        #expect(restarted.cancelOccurrence(
            id: occurrence.id, owner: "old-runtime", token: oldToken,
            expectedTaskVersion: task.version, expectedControlRevision: task.version,
            now: now.addingTimeInterval(1)
        ) == false)
        #expect(restarted.claimLease(
            id: occurrence.id, owner: "new-runtime",
            expectedControlRevision: task.version, now: now.addingTimeInterval(1)
        ) == nil)
    }

    // MARK: 每次运行开新会话

    @Test func newSessionOptionSurvivesRestartAndNeedsReauthorization() throws {
        let (d, cleanup) = makeDefaults()
        defer { cleanup() }
        let store = SchedulerTaskStore(defaults: d)
        let sessionID = UUID()
        #expect(store.add(name: "日报", cronExpression: "0 9 * * *", command: "总结昨天",
                          targetSessionID: sessionID, targetProjectID: "P1", targetTurnID: 1,
                          opensNewSessionEachRun: true) == nil)
        var task = try #require(store.tasks.first)
        #expect(task.opensNewSessionEachRun)
        #expect(SchedulerTaskStore(defaults: d).tasks.first?.opensNewSessionEachRun == true)

        // 关掉这个选项属于执行范围变化：授权版本前进、需要重新授权。
        let before = task.authorizationVersion
        task.opensNewSessionEachRun = false
        #expect(store.update(task, expectedVersion: task.version,
                             expectedEnablementRevision: task.enablementRevision) == nil)
        let after = try #require(store.tasks.first)
        #expect(after.authorizationVersion == before + 1)
        #expect(!after.isAuthorized)
    }

    @Test func scheduledRunSessionIDIsStablePerTrigger() {
        let a = ChatStore.scheduledRunSessionID(effectID: "effect-1")
        #expect(a == ChatStore.scheduledRunSessionID(effectID: "effect-1"))
        #expect(a != ChatStore.scheduledRunSessionID(effectID: "effect-2"))
    }

}
