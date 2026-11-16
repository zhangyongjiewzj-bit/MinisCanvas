import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Follows the production Store -> Runtime -> Task Center consumers. The
/// submission callback only supplies a controlled delivery result.
@Suite("D-SCHEDE explicit retry stays pinned across a definition edit")
@MainActor
struct SchedulerPinnedRetryVersion2532Tests {
    @Test func reviewedV1RetryRemainsV1AndNextDueIsAnIndependentV2Attempt() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("schedE-2532-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "schedE.2532.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = root.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let due = Date(timeIntervalSince1970: 1_756_650_000)
        let oldTarget = UUID()
        let newTarget = UUID()
        #expect(store.add(
            name: "versioned retry", cronExpression: "* * * * *", command: "v1-command",
            targetSessionID: oldTarget, targetProjectID: "project-v1", targetTurnID: 1
        ) == nil)
        let created = try #require(store.allTasks().first)
        #expect(store.authorize(created.id, actorID: "owner-v1", scopeID: "project-v1",
                                policyRevision: "policy-v1"))
        let v1 = try #require(store.task(id: created.id))

        var firstRequests: [SchedulerSubmissionRequest] = []
        let runtime = SchedulerTaskRuntime(store: store, submitOccurrenceResult: { request in
            firstRequests.append(request)
            return .unknown
        })
        runtime.pollNow(at: due)
        let originalRequest = try #require(firstRequests.first)
        let original = try #require(store.occurrence(id: originalRequest.occurrenceID))
        #expect(firstRequests.count == 1)
        #expect(original.state == .unknown)
        #expect(originalRequest.taskVersion == v1.version)
        #expect(runtime.reconcileUnknownOccurrence(id: original.id, now: due.addingTimeInterval(1)))
        let proof = try #require(store.occurrence(id: original.id)?.reconciliationProof)
        let originalReceipt = try #require(store.occurrence(id: original.id)?.submissionReceipt)
        let retry = try #require(runtime.retryReconciledOccurrence(
            id: original.id, expectedControlRevision: v1.version,
            proofToken: proof, now: due.addingTimeInterval(2)
        ))
        #expect(retry.id != original.id)
        #expect(retry.retryOfOccurrenceID == original.id)
        #expect(retry.taskVersion == v1.version)
        #expect(retry.command == "v1-command")
        #expect(retry.targetSessionID == oldTarget)
        #expect(retry.submissionReceipt == nil)

        var edited = v1
        edited.command = "v2-command"
        edited.targetSessionID = newTarget
        edited.targetProjectID = "project-v2"
        edited.targetTurnID = 2
        edited.authorizationPolicyRevision = "policy-v2"
        #expect(store.update(edited, expectedVersion: v1.version) == nil)
        let v2 = try #require(store.task(id: v1.id))
        #expect(v2.version == v1.version + 1)
        #expect(!v2.isAuthorized)
        #expect(store.authorize(v2.id, actorID: "owner-v2", scopeID: "project-v2",
                                policyRevision: "policy-v2"))
        #expect(store.occurrence(id: original.id)?.submissionReceipt == originalReceipt)

        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.occurrence(id: retry.id)?.submissionReceipt == nil)
        var deliveredRequests: [SchedulerSubmissionRequest] = []
        let resumed = SchedulerTaskRuntime(store: reopened, submitOccurrenceResult: { request in
            deliveredRequests.append(request)
            return .delivered
        })
        resumed.pollNow(at: due.addingTimeInterval(20))
        let pinnedRetry = try #require(deliveredRequests.first)
        #expect(deliveredRequests.count == 1)
        #expect(pinnedRetry.occurrenceID == retry.id)
        #expect(pinnedRetry.taskVersion == v1.version)
        #expect(pinnedRetry.command == "v1-command")
        #expect(pinnedRetry.targetSessionID == oldTarget)
        #expect(reopened.occurrence(id: retry.id)?.state == .succeeded)
        #expect(reopened.occurrence(id: original.id)?.submissionReceipt == originalReceipt)

        resumed.pollNow(at: due.addingTimeInterval(60))
        let next = try #require(deliveredRequests.last)
        #expect(deliveredRequests.count == 2)
        #expect(next.occurrenceID != retry.id && next.occurrenceID != original.id)
        #expect(next.effectID != pinnedRetry.effectID)
        #expect(next.idempotencyKey != pinnedRetry.idempotencyKey)
        #expect(next.taskVersion == v2.version)
        #expect(next.command == "v2-command")
        #expect(next.targetSessionID == newTarget)
        #expect(reopened.occurrence(id: next.occurrenceID)?.retryOfOccurrenceID == nil)
        #expect(reopened.occurrence(id: original.id)?.submissionReceipt == originalReceipt)

        let observation = SchedulerSlashObservation.capture(from: reopened)
        let output = TaskCenterSlashCommandAdapter(schedulerObservation: { observation })
            .execute("/scheduler")
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["payload"] as? [String: Any])
        let rows = try #require(payload["occurrences"] as? [[String: Any]])
        let retryRow = try #require(rows.first { $0["occurrence_id"] as? String == retry.id.uuidString.lowercased() })
        let nextRow = try #require(rows.first { $0["occurrence_id"] as? String == next.occurrenceID.uuidString.lowercased() })
        #expect(retryRow["task_version"] as? Int == v1.version)
        #expect(retryRow["retry_of_occurrence_id"] as? String == original.id.uuidString.lowercased())
        #expect(nextRow["task_version"] as? Int == v2.version)
        #expect(nextRow["retry_of_occurrence_id"] == nil)
        #expect(!output.contains("v1-command") && !output.contains("v2-command"))
    }
}
