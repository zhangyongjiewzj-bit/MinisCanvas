import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class Recovery306RequestCapture {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("Recovery306 restarted scheduler submission consumer")
@MainActor
struct Recovery306SchedulerConsumerTests {
    @Test("reopening a live lease blocks its request while a fresh due task still dispatches")
    func restartedRunningOccurrenceDoesNotResubmit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery306-scheduler-\(UUID().uuidString)", isDirectory: true)
        let suite = "recovery306-scheduler-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let ledger = root.appendingPathComponent("occurrences.json")
        let first = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(first.add(name: "previous run", cronExpression: "* * * * *", command: "old synthetic effect",
            targetSessionID: UUID(), targetProjectID: "recovery306", targetTurnID: 1) == nil)
        let oldTask = try #require(first.allTasks().first)
        #expect(first.authorize(oldTask.id))
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        #expect(first.reconcileExpiredOccurrences(now: now) == 0)
        let occurrence = try #require(first.reserveOccurrence(taskID: oldTask.id, at: now))
        let transitions: [(SchedulerOccurrenceState, SchedulerOccurrenceState)] = [
            (SchedulerOccurrenceState.triggered, .authorized),
            (.authorized, .admitted),
            (.admitted, .dispatched),
        ]
        for (before, after) in transitions {
            #expect(first.compareAndSwapOccurrence(id: occurrence.id, expected: before, next: after,
                expectedControlRevision: oldTask.version, now: now))
        }
        let token = try #require(first.claimLease(id: occurrence.id, owner: "previous-runtime",
            expectedControlRevision: oldTask.version, now: now, ttl: 300))

        // The production polling seam, rather than only the store helper,
        // consumes the restart uncertainty before any request is submitted.
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let capture = Recovery306RequestCapture()
        let runtime = SchedulerTaskRuntime(store: reopened, submitRequest: { capture.requests.append($0) })
        runtime.pollNow(at: now.addingTimeInterval(1))
        runtime.pollNow(at: now.addingTimeInterval(2))
        #expect(capture.requests.isEmpty)
        #expect(reopened.occurrence(id: occurrence.id)?.state == .unknown)
        #expect(reopened.occurrences.count == 1)
        #expect(reopened.executionIdentity(id: occurrence.id)?.effectID == occurrence.effectID)
        #expect(!reopened.recordDelivery(id: occurrence.id, owner: "previous-runtime", token: token,
            status: .delivered, now: now.addingTimeInterval(2), expectedTaskVersion: oldTask.version,
            expectedControlRevision: oldTask.version))

        // Positive control excludes a vacuous zero caused by disabled polling
        // or an unusable fixture. Only the newly authorized task may submit.
        #expect(reopened.add(name: "fresh due", cronExpression: "* * * * *", command: "fresh synthetic effect",
            targetSessionID: UUID(), targetProjectID: "recovery306", targetTurnID: 2) == nil)
        let fresh = try #require(reopened.allTasks().first { $0.id != oldTask.id })
        #expect(reopened.authorize(fresh.id))
        runtime.pollNow(at: now.addingTimeInterval(3))
        #expect(capture.requests.map(\.taskID) == [fresh.id])
        #expect(capture.requests.allSatisfy { $0.effectID != occurrence.effectID })
        #expect(reopened.occurrence(id: occurrence.id)?.state == .unknown)
    }
}
