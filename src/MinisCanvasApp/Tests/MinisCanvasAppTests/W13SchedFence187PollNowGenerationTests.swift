import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// QODER-DEV-W13-SCHEDFENCE-187 (wave-4, 2026-09-23): started-generation fence
// for SchedulerTaskRuntime.pollNow. Authority: P3-SCHED-01 detail D-SCHEDC
// ("暂停恢复取消CAS一致且取消后零dispatch") and 执行单25 BL4 ("lease
// owner/heartbeat/TTL/fencing … 重启只恢复 queued 或已确认 stale lease").
// A timer-scheduled polling round is admitted only while its start-window
// generation is the currently started one; a round that lands after a pause,
// a sleep/date-change backlog crossing a stop, or a restart must drive zero
// occurrences. The untagged call remains the manual/recovery entry.

private final class Fence187RequestCapture: @unchecked Sendable {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("P3-SCHED-01 pollNow started-generation fence (DEV-187)")
@MainActor
struct W13SchedFence187PollNowGenerationTests {

    private static let pollTaskID = "miniscanvas.scheduler.poll"

    private func makeStore() -> (SchedulerTaskStore, () -> Void) {
        let suite = "sched-fence187-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sched-fence187-\(UUID().uuidString)", isDirectory: true)
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func addAuthorizedTask(to store: SchedulerTaskStore) -> SchedulerTask {
        store.add(
            name: "栅栏任务",
            cronExpression: "* * * * *",
            command: "fence-command",
            targetSessionID: UUID(),
            targetProjectID: "fence-187",
            targetTurnID: 7
        )
        let task = store.allTasks()[0]
        #expect(store.authorize(task.id))
        return task
    }

    /// Rows whose scheduled bucket is the same calendar minute as `date`.
    ///
    /// `Calendar.isDate(_:inSameMinuteAs:)` is not part of this SDK: the only
    /// `isDate(_:inSame…As:)` overload in the MacOSX26.5 Foundation interface
    /// is `isDate(_:inSameDayAs:)`, which is exactly why the compiler proposed
    /// that label. The generalised form it is specialised from,
    /// `isDate(_:equalTo:toGranularity:)`, is present, so the minute bucket is
    /// requested with `.minute` instead of downgrading the assertion to `.day`.
    ///
    /// Equivalence: comparing at `.minute` requires era/year/month/day/hour/
    /// minute to be equal under `Calendar.current`, i.e. both instants lie in
    /// one and the same minute interval — the same predicate a
    /// `inSameMinuteAs:` overload would express. That also matches the producer,
    /// which derives the stored bucket as
    /// `calendar.dateInterval(of: .minute, for: date)?.start`
    /// (SchedulerTaskStore.reserveOccurrence) before writing `scheduledMinute`.
    /// `.day` would not isolate a bucket: the probe minutes below all share one
    /// calendar day, so the "alien generation drove no row" checks would match
    /// the legitimate earlier row and fail for the wrong reason.
    private func rowsAtMinute(_ store: SchedulerTaskStore, task: SchedulerTask, _ date: Date) -> [SchedulerOccurrence] {
        store.occurrences.filter { row in
            row.taskID == task.id
                && Calendar.current.isDate(row.scheduledMinute, equalTo: date, toGranularity: .minute)
        }
    }

    @Test func taggedRoundIsAdmittedOnlyByTheCurrentStartedGeneration() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let capture = Fence187RequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, submitRequest: { request in
            capture.requests.append(request)
        })
        let base = Date(timeIntervalSince1970: 1_756_650_000)
        let minuteB = base.addingTimeInterval(60)
        let minuteC = base.addingTimeInterval(120)
        let minuteD = base.addingTimeInterval(180)

        // Not started yet: a tagged round is rejected before reconcile,
        // reservation, or dispatch. The row must not even exist.
        runtime.pollNow(at: base, startedGeneration: 1)
        #expect(rowsAtMinute(store, task: task, base).isEmpty)
        #expect(capture.requests.isEmpty)

        // The untagged manual entry keeps its existing recovery semantics.
        runtime.pollNow(at: base)
        #expect(capture.requests.count == 1)
        #expect(rowsAtMinute(store, task: task, base).first?.state == .unknown)

        // Started window: the current label drives, an alien label drives zero.
        runtime.start()
        let generation1 = runtime.startedGeneration
        #expect(generation1 == 1)
        let afterStart = capture.requests.count
        runtime.pollNow(at: minuteB, startedGeneration: generation1 + 42)
        #expect(capture.requests.count == afterStart)
        #expect(rowsAtMinute(store, task: task, minuteB).isEmpty)
        runtime.pollNow(at: minuteB, startedGeneration: generation1)
        #expect(capture.requests.count == afterStart + 1)
        #expect(rowsAtMinute(store, task: task, minuteB).first?.state == .unknown)

        // Stopped window: even the label of the last started generation
        // dispatches zero; only the untagged manual entry still drives.
        runtime.stop()
        let afterStop = capture.requests.count
        runtime.pollNow(at: minuteC, startedGeneration: generation1)
        #expect(capture.requests.count == afterStop)
        #expect(rowsAtMinute(store, task: task, minuteC).isEmpty)
        runtime.pollNow(at: minuteC)
        #expect(capture.requests.count == afterStop + 1)

        // Restart: the superseded window's label is rejected although the
        // runtime is started again; only the new window's label drives.
        runtime.start()
        let generation2 = runtime.startedGeneration
        #expect(generation2 == 2)
        let afterRestart = capture.requests.count
        runtime.pollNow(at: minuteD, startedGeneration: generation1)
        #expect(capture.requests.count == afterRestart)
        #expect(rowsAtMinute(store, task: task, minuteD).isEmpty)
        runtime.pollNow(at: minuteD, startedGeneration: generation2)
        #expect(capture.requests.count == afterRestart + 1)
        #expect(rowsAtMinute(store, task: task, minuteD).first?.state == .unknown)
        runtime.stop()
    }

    @Test func inFlightTimerTickHonorsTheFenceAcrossStop() async throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let task = addAuthorizedTask(to: store)
        let scheduler = TaskScheduler()
        let capture = Fence187RequestCapture()
        let runtime = SchedulerTaskRuntime(store: store, scheduler: scheduler, submitRequest: { request in
            capture.requests.append(request)
        })
        runtime.start()

        // Control first: a tick queued while its generation is the started
        // one must really drive the production chain end to end, so the later
        // rejection cannot pass just because the tick path never fires.
        let controlDate = Date().addingTimeInterval(120)
        let controlRow = try #require(store.reserveOccurrence(taskID: task.id, at: controlDate))
        #expect(controlRow.state == .triggered)
        scheduler.runNow(id: Self.pollTaskID)
        let beforeControl = capture.requests.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(capture.requests.count == beforeControl + 1)
        #expect(store.occurrence(id: controlRow.id)?.state == .unknown)

        // A tick already in flight when the window stops drives zero: its
        // main-actor round lands after stop(), which is exactly where the
        // old guard (persistenceError only) would have dispatched it. The
        // test never yields between runNow and stop, so the landing order is
        // deterministic under @MainActor.
        let victimDate = Date().addingTimeInterval(180)
        let victimRow = try #require(store.reserveOccurrence(taskID: task.id, at: victimDate))
        #expect(victimRow.state == .triggered)
        scheduler.runNow(id: Self.pollTaskID)
        runtime.stop()
        let beforeStop = capture.requests.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(capture.requests.count == beforeStop)
        #expect(store.occurrence(id: victimRow.id)?.state == .triggered)
        #expect(store.occurrence(id: victimRow.id)?.leaseOwner == nil)
        #expect(store.occurrence(id: victimRow.id)?.deliveryReceipt == nil)

        // The manual untagged recovery entry can still complete the row.
        runtime.pollNow(at: victimDate)
        #expect(capture.requests.count == beforeStop + 1)
        #expect(store.occurrence(id: victimRow.id)?.state == .unknown)
    }
}
