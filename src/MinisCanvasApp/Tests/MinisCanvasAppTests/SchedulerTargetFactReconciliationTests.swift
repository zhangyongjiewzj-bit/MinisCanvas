import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Scheduler target fact reconciliation")
@MainActor
struct SchedulerTargetFactReconciliationTests {
    @Test func unknownRequiresMatchingCanonicalDeliveryBeforeClosing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-target-fact-\(UUID().uuidString)", isDirectory: true)
        let suite = "scheduler-target-fact-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let targetStore = SessionStore(directory: root.appendingPathComponent("target"))
        let targetID = UUID()
        let target = try targetStore.createSession(id: targetID.uuidString, projectID: "runtime-project")
        let ledger = root.appendingPathComponent("occurrences.json")
        let schedulerStore = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(schedulerStore.add(name: "同目标对账", cronExpression: "* * * * *",
            command: "local prompt", targetSessionID: targetID,
            targetProjectID: "runtime-project", targetTurnID: 7) == nil)
        var task = try #require(schedulerStore.allTasks().first)
        task.sourceAnchorDigest = String(repeating: "a", count: 64)
        #expect(schedulerStore.update(task, expectedVersion: task.version) == nil)
        task = try #require(schedulerStore.task(id: task.id))
        #expect(schedulerStore.authorize(task.id))
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let occurrence = try #require(schedulerStore.reserveOccurrence(taskID: task.id, at: now))
        let transitions: [(SchedulerOccurrenceState, SchedulerOccurrenceState)] = [
            (SchedulerOccurrenceState.triggered, .authorized),
            (.authorized, .admitted),
            (.admitted, .dispatched)
        ]
        for (before, after) in transitions {
            #expect(schedulerStore.compareAndSwapOccurrence(id: occurrence.id, expected: before,
                next: after, expectedControlRevision: occurrence.controlRevision, now: now))
        }
        let token = try #require(schedulerStore.claimLease(id: occurrence.id, owner: "scheduler-runtime",
            expectedControlRevision: occurrence.controlRevision, now: now))
        #expect(schedulerStore.heartbeat(id: occurrence.id, owner: "scheduler-runtime", token: token, now: now))
        let request = SchedulerSubmissionRequest(occurrenceID: occurrence.id, effectID: occurrence.effectID,
            taskID: task.id, taskVersion: occurrence.taskVersion, idempotencyKey: occurrence.idempotencyKey,
            command: occurrence.command, targetSessionID: targetID, targetProjectID: "runtime-project",
            targetTurnID: 7, sourceTaskID: task.id)
        let execution = try #require(schedulerStore.beginExecutionIdentity(request,
            owner: "scheduler-runtime", token: token, minimumTurn: 8, now: now))
        #expect(schedulerStore.recordDelivery(id: occurrence.id, owner: "scheduler-runtime", token: token,
            status: .unknown, now: now, expectedTaskVersion: occurrence.taskVersion,
            expectedControlRevision: occurrence.controlRevision,
            executionTurnID: execution.turn, executionMessageID: execution.messageID))
        let runtime = SchedulerTaskRuntime(store: schedulerStore,
            targetDeliveryResolver: { row in
                guard let session = targetStore.loadSession(id: targetID.uuidString),
                      session.projectID == row.targetProjectID else { return nil }
                return session.scheduledTranscriptDeliveries.first {
                    $0.occurrenceID == row.id && $0.effectID == row.effectID
                        && $0.taskID == row.taskID && $0.taskVersion == row.taskVersion
                        && $0.executionTurnID == row.executionTurnID
                        && $0.executionMessageID == row.executionMessageID
                }
            }, submitEffect: { _ in throw CancellationError() })
        #expect(!runtime.reconcileUnknownOccurrence(id: occurrence.id, now: now))
        #expect(schedulerStore.occurrence(id: occurrence.id)?.state == .unknown)
        #expect(runtime.retryReconciledOccurrence(id: occurrence.id,
            expectedControlRevision: occurrence.controlRevision, proofToken: "arbitrary", now: now) == nil)

        let fact = ScheduledTranscriptDelivery(occurrenceID: occurrence.id, effectID: occurrence.effectID,
            taskID: task.id, taskVersion: occurrence.taskVersion,
            executionTurnID: execution.turn, executionMessageID: execution.messageID)
        _ = try targetStore.compareAndCommitTranscript(sessionID: target.id,
            projectID: "runtime-project", expectedRevision: target.transcriptRevision,
            expectedMessages: target.messages,
            replacementMessages: [LLMMessage(role: .user, content: "local prompt"),
                                  LLMMessage(role: .assistant, content: "done")],
            scheduledDelivery: fact)
        #expect(runtime.reconcileUnknownOccurrence(id: occurrence.id, now: now.addingTimeInterval(1)))
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrence(id: occurrence.id)?.state == .succeeded)
        #expect(reopened.occurrence(id: occurrence.id)?.deliveryReceipt?.status == .delivered)
        #expect(reopened.occurrences.count == 1)
        #expect(SessionStore(directory: root.appendingPathComponent("target"))
            .loadSession(id: targetID.uuidString)?.scheduledTranscriptDeliveries == [fact])
    }
}
