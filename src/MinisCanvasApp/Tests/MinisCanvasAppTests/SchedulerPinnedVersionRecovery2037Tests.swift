import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class Scheduler2037Requests {
    let status: SchedulerDeliveryReceipt.Status
    private(set) var values: [SchedulerSubmissionRequest] = []

    init(status: SchedulerDeliveryReceipt.Status) { self.status = status }

    func submit(_ request: SchedulerSubmissionRequest) -> SchedulerDeliveryReceipt.Status {
        values.append(request)
        return status
    }
}

@Suite("D-SCHEDE pinned scheduler version recovery")
@MainActor
struct SchedulerPinnedVersionRecovery2037Tests {
    @Test("reviewed v1 UNKNOWN cannot borrow a newly approved v2 definition for retry")
    func oldUnknownNeverBecomesV2Retry() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("schedE-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "schedE-\(UUID().uuidString)"))
        let ledger = root.appendingPathComponent("occurrences.json")
        let first = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let due = Date(timeIntervalSince1970: 1_756_650_000)
        let v1Session = UUID()
        let v2Session = UUID()
        #expect(first.add(name: "versioned schedule", cronExpression: "* * * * *",
            command: "v1 command", targetSessionID: v1Session,
            targetProjectID: "v1-project", targetTurnID: 1) == nil)
        let created = try #require(first.allTasks().first)
        #expect(first.authorize(created.id, actorID: "v1-user", scopeID: "v1-project",
            policyRevision: "v1-policy"))
        let v1 = try #require(first.task(id: created.id))
        let firstRequests = Scheduler2037Requests(status: .unknown)
        let firstRuntime = SchedulerTaskRuntime(store: first,
            submitOccurrenceResult: { firstRequests.submit($0) })
        firstRuntime.pollNow(at: due)
        let oldRequest = try #require(firstRequests.values.first)
        let oldOccurrence = try #require(first.occurrence(id: oldRequest.occurrenceID))
        #expect(firstRequests.values.count == 1)
        #expect(oldRequest.taskVersion == v1.version)
        #expect(oldRequest.command == "v1 command")
        #expect(oldRequest.targetSessionID == v1Session)
        #expect(oldOccurrence.state == .unknown)

        // Review can persist a proof, but it cannot convert the old attempt
        // into a new version or relabel its original submission receipt.
        #expect(firstRuntime.reconcileUnknownOccurrence(id: oldOccurrence.id,
            now: due.addingTimeInterval(1)))
        let reviewed = try #require(first.occurrence(id: oldOccurrence.id))
        let proof = try #require(reviewed.reconciliationProof)
        let oldReceipt = try #require(reviewed.submissionReceipt)
        let oldJournal = first.occurrenceJournal.filter { $0.occurrenceID == oldOccurrence.id }

        var edited = v1
        edited.command = "v2 command"
        edited.targetSessionID = v2Session
        edited.targetProjectID = "v2-project"
        edited.targetTurnID = 2
        edited.authorizationPolicyRevision = "v2-policy"
        #expect(first.update(edited, expectedVersion: v1.version) == nil)
        let v2 = try #require(first.task(id: v1.id))
        #expect(v2.version == v1.version + 1)
        #expect(!v2.isAuthorized)
        #expect(first.authorize(v2.id, actorID: "v2-user", scopeID: "v2-project",
            policyRevision: "v2-policy"))
        #expect(firstRuntime.retryReconciledOccurrence(id: oldOccurrence.id,
            expectedControlRevision: v1.version, proofToken: proof,
            now: due.addingTimeInterval(2)) == nil)
        #expect(firstRuntime.retryReconciledOccurrence(id: oldOccurrence.id,
            expectedControlRevision: v2.version, proofToken: proof,
            now: due.addingTimeInterval(2)) == nil)
        #expect(first.occurrence(id: oldOccurrence.id)?.state == .unknownReconciled)
        #expect(first.occurrence(id: oldOccurrence.id)?.submissionReceipt == oldReceipt)
        #expect(first.occurrenceJournal.filter { $0.occurrenceID == oldOccurrence.id } == oldJournal)
        #expect(first.occurrences.allSatisfy { $0.retryOfOccurrenceID == nil })
        firstRuntime.pollNow(at: due.addingTimeInterval(20))
        #expect(firstRequests.values == [oldRequest])

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrence(id: oldOccurrence.id)?.state == .unknownReconciled)
        #expect(reopened.occurrence(id: oldOccurrence.id)?.submissionReceipt == oldReceipt)
        let reopenedRequests = Scheduler2037Requests(status: .delivered)
        let resumedRuntime = SchedulerTaskRuntime(store: reopened,
            submitOccurrenceResult: { reopenedRequests.submit($0) })
        resumedRuntime.pollNow(at: due.addingTimeInterval(30))
        #expect(reopenedRequests.values.isEmpty)
        resumedRuntime.pollNow(at: due.addingTimeInterval(60))
        let nextRequest = try #require(reopenedRequests.values.first)
        #expect(reopenedRequests.values.count == 1)
        #expect(nextRequest.taskID == oldRequest.taskID)
        #expect(nextRequest.taskVersion == v2.version)
        #expect(nextRequest.command == "v2 command")
        #expect(nextRequest.targetSessionID == v2Session)
        #expect(nextRequest.targetProjectID == "v2-project")
        #expect(nextRequest.targetTurnID == 2)
        #expect(nextRequest.occurrenceID != oldRequest.occurrenceID)
        #expect(nextRequest.effectID != oldRequest.effectID)
        #expect(nextRequest.idempotencyKey != oldRequest.idempotencyKey)
        #expect(reopened.occurrence(id: nextRequest.occurrenceID)?.retryOfOccurrenceID == nil)
        #expect(reopened.occurrence(id: nextRequest.occurrenceID)?.state == .succeeded)
        #expect(reopened.occurrence(id: oldOccurrence.id)?.submissionReceipt == oldReceipt)
        #expect(reopened.occurrenceJournal.filter { $0.occurrenceID == oldOccurrence.id } == oldJournal)
    }
}
