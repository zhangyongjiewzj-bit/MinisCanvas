import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class SchedulerIgnoringDefaults2211: UserDefaults {
    var ignoresDefinitionWrites = false
    var remainingAcceptedWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if ignoresDefinitionWrites && defaultName == "miniscanvas.scheduler.tasks.v1" {
            guard remainingAcceptedWrites > 0 else { return }
            remainingAcceptedWrites -= 1
        }
        super.set(value, forKey: defaultName)
    }


}

@MainActor
private final class SchedulerCreationCapture2211 {
    var requests: [SchedulerSubmissionRequest] = []
}

@Suite("D-SCHEDA creation and preview commit failure")
@MainActor
struct SchedulerCreationCommit2211Tests {
    @Test("ignored definition writes cannot publish creation or authorization", arguments: ["creation", "source-binding", "grant"])
    func ignoredWriteCannotAuthorizeOrDispatch(stage: String) throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("scheda2211-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(SchedulerIgnoringDefaults2211(suiteName: "scheda2211-\(UUID().uuidString)"))
        let ledger = root.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let due = Date(timeIntervalSince1970: 1_756_650_000)
        let digest = String(repeating: "a", count: 64)
        let session = UUID()
        var displayed: SchedulerTaskPreview?
        if stage != "creation" {
            #expect(store.add(name: "synthetic schedule", cronExpression: "* * * * *",
                command: "synthetic command", targetSessionID: session,
                targetProjectID: "synthetic-project", targetTurnID: 1) == nil)
            var task = try #require(store.allTasks().first)
            if stage == "grant" {
                task.sourceAnchorDigest = digest
                #expect(store.update(task, expectedVersion: task.version) == nil)
            }
            store.providerPreflightResolver = { _, _ in
                SchedulerProviderPreflight(providerID: "synthetic-provider", modelID: "synthetic-model",
                    credentialVersion: "synthetic-revision", status: .ready, detail: "ready")
            }
            var preview = try #require(store.preview(taskID: task.id, now: due))
            preview.observedSourceAnchorDigest = digest
            preview.observedPolicyRevision = "synthetic-policy"
            displayed = preview
        }
        let priorTasks = store.tasks
        let priorData = defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
        let priorOccurrences = store.occurrences
        let priorJournal = store.occurrenceJournal
        defaults.ignoresDefinitionWrites = true
        if stage == "creation" {
            #expect(store.add(name: "uncommitted schedule", cronExpression: "* * * * *",
                command: "synthetic command", targetSessionID: session,
                targetProjectID: "synthetic-project", targetTurnID: 1) != nil)
        } else {
            let preview = try #require(displayed)
            #expect(!store.confirmPreview(preview, actorID: "synthetic-user",
                scopeID: "synthetic-project", policyRevision: "synthetic-policy", now: due,
                sourceAnchorConfirmed: true, currentSourceAnchorDigest: digest,
                currentPolicyRevision: "synthetic-policy"))
        }
        #expect(store.persistenceError != nil)
        #expect(store.tasks == priorTasks)
        #expect(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == priorData)
        #expect(store.occurrences == priorOccurrences)
        #expect(store.occurrenceJournal == priorJournal)
        let capture = SchedulerCreationCapture2211()
        SchedulerTaskRuntime(store: store, submitRequest: { capture.requests.append($0) }).pollNow(at: due)
        #expect(capture.requests.isEmpty)
        #expect(store.occurrences == priorOccurrences)
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.persistenceError == nil)
        #expect(reopened.tasks == priorTasks)
        #expect(reopened.tasks.allSatisfy { !$0.isAuthorized })
        #expect(reopened.occurrences == priorOccurrences)
    }

    @Test("accepted creation and exact confirmation survive Store reopen")
    func acceptedWriteReopensExactAuthorizedFacts() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("scheda2211-positive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(SchedulerIgnoringDefaults2211(suiteName: "scheda2211-positive-\(UUID().uuidString)"))
        let ledger = root.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        let due = Date(timeIntervalSince1970: 1_756_650_000)
        let digest = String(repeating: "b", count: 64)
        #expect(store.add(name: "committed schedule", cronExpression: "* * * * *",
            command: "synthetic command", targetSessionID: UUID(),
            targetProjectID: "synthetic-project", targetTurnID: 1) == nil)
        let created = try #require(store.allTasks().first)
        var preview = try #require(store.preview(taskID: created.id, now: due))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = "synthetic-policy"
        #expect(!created.isAuthorized)
        #expect(store.confirmPreview(preview, actorID: "synthetic-user", scopeID: "synthetic-project",
            policyRevision: "synthetic-policy", now: due, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: "synthetic-policy"))
        let committed = try #require(store.task(id: created.id))
        #expect(store.persistenceError == nil)
        #expect(committed.isAuthorized)
        #expect(committed.sourceAnchorDigest == digest)
        #expect(committed.authorizationActorID == "synthetic-user")
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.task(id: created.id) == committed)
        #expect(reopened.occurrences.isEmpty)
        #expect(reopened.occurrenceJournal.isEmpty)
    }
    @Test("a committed source binding remains truth when the following grant write fails")
    func committedBindingIsNotPretendedToRollBack() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("scheda2211-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(SchedulerIgnoringDefaults2211(suiteName: "scheda2211-boundary-\(UUID().uuidString)"))
        let ledger = root.appendingPathComponent("occurrences.json")
        let store = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(store.add(name: "binding boundary", cronExpression: "* * * * *",
            command: "synthetic command", targetSessionID: UUID(),
            targetProjectID: "synthetic-project", targetTurnID: 1) == nil)
        let created = try #require(store.allTasks().first)
        let due = Date(timeIntervalSince1970: 1_756_650_000)
        let digest = String(repeating: "c", count: 64)
        var preview = try #require(store.preview(taskID: created.id, now: due))
        preview.observedSourceAnchorDigest = digest
        preview.observedPolicyRevision = "synthetic-policy"
        defaults.ignoresDefinitionWrites = true
        defaults.remainingAcceptedWrites = 1
        #expect(!store.confirmPreview(preview, actorID: "synthetic-user", scopeID: "synthetic-project",
            policyRevision: "synthetic-policy", now: due, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: "synthetic-policy"))
        var expectedBinding = created
        expectedBinding.version += 1
        expectedBinding.sourceAnchorDigest = digest
        #expect(store.task(id: created.id) == expectedBinding)
        #expect(store.persistenceError != nil)
        #expect(store.occurrences.isEmpty)
        #expect(store.occurrenceJournal.isEmpty)
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.task(id: created.id) == expectedBinding)
        #expect(reopened.occurrences.isEmpty)
        #expect(reopened.occurrenceJournal.isEmpty)
        let capture = SchedulerCreationCapture2211()
        SchedulerTaskRuntime(store: reopened, submitRequest: { capture.requests.append($0) }).pollNow(at: due)
        #expect(capture.requests.isEmpty)
        #expect(!reopened.occurrences.isEmpty)
        #expect(reopened.occurrences.allSatisfy { $0.state == .waitingApproval })
    }
}
