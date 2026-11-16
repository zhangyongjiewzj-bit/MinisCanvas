import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("3088 Scheduler incomplete-target read-only preview")
@MainActor
struct SchedulerPreviewSelection3088Tests {
    private func fixture() throws -> (SchedulerTaskStore, UserDefaults, URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let domain = "scheduler-preview-3088-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let root = formal.rootDirectory.appendingPathComponent(domain, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let ledger = root.appendingPathComponent("occurrences.json")
        return (SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger), defaults, ledger)
    }

    @Test("partial target stays visible without granting or registering an occurrence",
          arguments: [false, true], ["turn", "session", "project", "all"])
    func partialTargetRemainsReadOnly(enabled: Bool, missing: String) throws {
        let (store, defaults, ledger) = try fixture()
        #expect(store.add(name: "synthetic readonly preview", cronExpression: "0 0 1 1 *",
            command: "synthetic command", isEnabled: enabled,
            targetSessionID: missing == "session" || missing == "all" ? nil : UUID(),
            targetProjectID: missing == "project" || missing == "all" ? nil : "synthetic-project",
            targetTurnID: missing == "turn" || missing == "all" ? nil : 1) == nil)
        let task = try #require(store.allTasks().first)
        let before = defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
        let storePreview = try #require(store.preview(taskID: task.id))
        let displayed = try #require(SchedulerControlPreviewConsumer.makePreview(
            taskID: task.id, store: store, runtime: nil))
        #expect(displayed.taskID == task.id)
        #expect(displayed.taskVersion == storePreview.taskVersion)
        #expect(displayed.fingerprint == storePreview.fingerprint)
        #expect(displayed.cronExpression == "0 0 1 1 *")
        #expect(displayed.predictedTriggers.count == 5)
        #expect(displayed.targetSessionID == task.targetSessionID)
        #expect(displayed.targetProjectID == task.targetProjectID)
        #expect(displayed.targetTurnID == task.targetTurnID)
        #expect(displayed.isEnabled == enabled)
        #expect(!displayed.hasValidTarget)
        #expect(displayed.observedSourceAnchorDigest == nil)
        #expect(!SchedulerControlProductionProjection(preview: displayed,
            occurrences: store.occurrences).canProduceDispatchIntent)
        // Even a caller supplying a valid-looking observation cannot authorize an incomplete target.
        var attempted = displayed
        let digest = String(repeating: "a", count: 64)
        attempted.observedSourceAnchorDigest = digest
        attempted.observedPolicyRevision = "synthetic-policy"
        #expect(!store.confirmPreview(attempted, actorID: "synthetic-user", scopeID: "synthetic-project",
            policyRevision: "synthetic-policy", sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: digest, currentPolicyRevision: "synthetic-policy"))
        #expect(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == before)
        #expect(store.task(id: task.id) == task)
        #expect(store.occurrences.isEmpty && store.occurrenceJournal.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.path))
        let reopened = SchedulerTaskStore(defaults: defaults, occurrenceLedgerURL: ledger)
        #expect(reopened.task(id: task.id) == task)
        #expect(!reopened.task(id: task.id)!.isAuthorized)
    }

    @Test("complete target remains visible; missing task still has no preview")
    func completeTargetAndMissingTaskControls() throws {
        let (store, defaults, ledger) = try fixture()
        let session = UUID()
        #expect(store.add(name: "complete synthetic target", cronExpression: "0 0 1 1 *",
            command: "synthetic command", isEnabled: false, targetSessionID: session,
            targetProjectID: "synthetic-project", targetTurnID: 1) == nil)
        let task = try #require(store.allTasks().first)
        let before = defaults.data(forKey: "miniscanvas.scheduler.tasks.v1")
        let displayed = try #require(SchedulerControlPreviewConsumer.makePreview(
            taskID: task.id, store: store, runtime: nil))
        #expect(displayed.hasValidTarget)
        #expect(displayed.targetSessionID == session && displayed.targetTurnID == 1)
        #expect(displayed.targetProjectID == "synthetic-project")
        #expect(displayed.observedPolicyRevision == nil && displayed.observedSourceAnchorDigest == nil)
        #expect(!SchedulerControlProductionProjection(preview: displayed,
            occurrences: store.occurrences).canProduceDispatchIntent)
        #expect(SchedulerControlPreviewConsumer.makePreview(taskID: UUID(), store: store, runtime: nil) == nil)
        #expect(defaults.data(forKey: "miniscanvas.scheduler.tasks.v1") == before)
        #expect(store.task(id: task.id) == task)
        #expect(store.occurrences.isEmpty && store.occurrenceJournal.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.path))
    }
}
