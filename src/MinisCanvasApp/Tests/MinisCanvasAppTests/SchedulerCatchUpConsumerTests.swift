import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Startup and wake catch-up consumer")
@MainActor
struct SchedulerCatchUpConsumerTests {
    @Test func reservesLatestOnceAndKeepsHistoryMarkerAcrossReopen() throws {
        let suite = "catch-up-synthetic-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-24T13:30:00Z"))
        let task = SchedulerTask(name: "synthetic hourly", cronExpression: "0 * * * *",
            timeZoneIdentifier: "UTC", command: "synthetic command",
            createdAt: now.addingTimeInterval(-3 * 24 * 3600), isAuthorized: true,
            targetSessionID: UUID(), targetProjectID: "synthetic-project", targetTurnID: 1)
        defaults.set(try JSONEncoder().encode([task]), forKey: "miniscanvas.scheduler.tasks.v1")
        let ledger = directory.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        var notifications: [UUID] = []
        var submissions: [SchedulerSubmissionRequest] = []
        let runtime = SchedulerTaskRuntime(store: store, submitRequest: { submissions.append($0) })
        runtime.onCatchUpReserved = { notifications.append($0.id) }
        runtime.catchUpMissedTasks(at: now)
        runtime.catchUpMissedTasks(at: now)
        runtime.pollNow(at: now)
        #expect(store.persistenceError == nil)
        #expect(store.occurrences.count == 1)
        #expect(submissions.count == 1)
        let row = try #require(store.occurrences.first)
        #expect(row.isCatchUp)
        #expect(row.scheduledMinute == now.addingTimeInterval(-30 * 60))
        #expect(row.createdAt == now)
        #expect(notifications == [row.id])
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.occurrence(id: row.id)?.isCatchUp == true)
        let restart = SchedulerTaskRuntime(store: reopened, submitRequest: { _ in
            Issue.record("A completed/uncertain catch-up must not be resubmitted on restart")
        })
        restart.catchUpMissedTasks(at: now)
        restart.pollNow(at: now)
        #expect(reopened.occurrences.count == 1)
    }

    @Test func scheduledEffectCarriesUnattendedOriginThroughRealSubmitter() async throws {
        let suite = "origin-synthetic-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = Date()
        let task = SchedulerTask(name: "synthetic origin", cronExpression: "* * * * *",
            timeZoneIdentifier: "UTC", command: "synthetic", isAuthorized: true,
            targetSessionID: UUID(), targetProjectID: "synthetic-project", targetTurnID: 1)
        defaults.set(try JSONEncoder().encode([task]), forKey: "miniscanvas.scheduler.tasks.v1")
        let store = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: directory.appendingPathComponent("occurrences.json"))
        var runtime: SchedulerTaskRuntime?
        var activity: [Bool] = []
        let observed: ApprovalExecutionOrigin = await withCheckedContinuation { continuation in
            let owner = SchedulerTaskRuntime(store: store, now: { now }, submitEffect: { _ in
                continuation.resume(returning: ApprovalExecutionOriginContext.current)
                return SchedulerEffectOutcome(status: .unknown)
            })
            owner.onExecutionActivityChanged = { activity.append($0) }
            runtime = owner
            owner.pollNow(at: now)
        }
        await runtime?.stopAndJoin()
        #expect(activity == [true, false])
        #expect(runtime?.hasRunningEffects == false)
        #expect(observed == .scheduledTask)
        #expect(ApprovalExecutionOriginContext.current == .interactive)
    }
}
