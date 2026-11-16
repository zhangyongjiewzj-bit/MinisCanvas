import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class SchedulerPinnedPreflight2202Capture {
    var preflightTasks: [SchedulerTask] = []
    var requests: [SchedulerSubmissionRequest] = []
    var preflights: [SchedulerProviderPreflight?] = []
}

@Suite("D-SCHEDE reopened pinned occurrence provider preflight")
@MainActor
struct SchedulerPinnedPreflight2202Tests {
    @Test("old queued target readiness is independent of the edited target", arguments: [true, false])
    func reopenedQueuedOccurrencePreflightsItsPinnedTarget(oldTargetReady: Bool) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("sched2202-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "sched2202-\(UUID().uuidString)"))
        let ledger = root.appendingPathComponent("occurrences.json")
        let first = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let due = Date(timeIntervalSince1970: 1_756_650_000)
        let oldSession = UUID()
        let newSession = UUID()
        #expect(first.add(name: "pinned readiness", cronExpression: "* * * * *",
            command: "old command", targetSessionID: oldSession,
            targetProjectID: "old-project", targetTurnID: 1) == nil)
        let initial = try #require(first.allTasks().first)
        #expect(first.authorize(initial.id, actorID: "synthetic-user",
            scopeID: "old-project", policyRevision: "old-policy"))
        let oldTask = try #require(first.task(id: initial.id))
        let queued = try #require(first.reserveOccurrence(taskID: oldTask.id, at: due))
        var edited = oldTask
        edited.command = "new command"
        edited.targetSessionID = newSession
        edited.targetProjectID = "new-project"
        edited.targetTurnID = 2
        edited.authorizationPolicyRevision = "new-policy"
        #expect(first.update(edited, expectedVersion: oldTask.version) == nil)
        #expect(first.authorize(oldTask.id, actorID: "synthetic-user",
            scopeID: "new-project", policyRevision: "new-policy"))
        let newTask = try #require(first.task(id: oldTask.id))

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrence(id: queued.id)?.state == .triggered)
        let capture = SchedulerPinnedPreflight2202Capture()
        let ready = SchedulerProviderPreflight(providerID: "synthetic-provider",
            modelID: "synthetic-model", credentialVersion: "synthetic-revision",
            status: .ready, detail: "synthetic readiness")
        let blocked = SchedulerProviderPreflight.unavailable("synthetic target unavailable")
        let runtime = SchedulerTaskRuntime(store: reopened, now: { due },
            providerPreflightResolver: { task, _ in
                capture.preflightTasks.append(task)
                // Controlled target visibility; no provider, credential, or network is touched.
                let readyTarget = oldTargetReady ? oldSession : newSession
                return task.targetSessionID == readyTarget ? ready : blocked
            }, submitEffect: { context in
                capture.requests.append(context.request)
                capture.preflights.append(context.providerPreflight)
                return SchedulerEffectOutcome(status: .delivered)
            })
        runtime.pollNow(at: due)
        for _ in 0..<100 { await Task.yield() }
        let observed = try #require(capture.preflightTasks.first)
        #expect(observed.targetSessionID == oldSession)
        #expect(observed.targetProjectID == "old-project")
        #expect(observed.targetTurnID == 1)
        #expect(capture.requests.count == (oldTargetReady ? 1 : 0))
        #expect(reopened.occurrence(id: queued.id)?.state == (oldTargetReady ? .succeeded : .triggered))
        if oldTargetReady {
            let request = try #require(capture.requests.first)
            #expect(request.occurrenceID == queued.id)
            #expect(request.taskVersion == oldTask.version)
            #expect(request.command == "old command")
            #expect(request.targetSessionID == oldSession)
            let observedPreflight = try #require(capture.preflights.first)
            #expect(observedPreflight == ready)
        } else {
            #expect(reopened.occurrence(id: queued.id)?.leaseToken == nil)
            #expect(reopened.occurrence(id: queued.id)?.executionTurnID == nil)
        }
        let oldReceipt = reopened.occurrence(id: queued.id)?.submissionReceipt
        runtime.pollNow(at: due.addingTimeInterval(60))
        for _ in 0..<100 { await Task.yield() }
        let newOccurrence = try #require(reopened.occurrences.first { $0.taskVersion == newTask.version })
        #expect(newOccurrence.id != queued.id)
        #expect(newOccurrence.effectID != queued.effectID)
        #expect(newOccurrence.retryOfOccurrenceID == nil)
        #expect(newOccurrence.state == (oldTargetReady ? .triggered : .succeeded))
        #expect(capture.requests.count == 1)
        #expect(reopened.occurrence(id: queued.id)?.submissionReceipt == oldReceipt)
        runtime.stop()
    }
}
