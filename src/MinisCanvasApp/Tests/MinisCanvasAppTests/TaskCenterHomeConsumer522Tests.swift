import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center canonical home sections (522)")
struct TaskCenterHomeConsumer522Tests {
    @Test func currentWorkAndHistoryRetainExactCanonicalReceipts() throws {
        let store = AgentTaskStore()
        for id in ["queued", "running", "approval", "input", "failed", "old-success", "new-success"] {
            _ = try store.enqueue(taskID: id, parentID: "parent", providerID: "offline", modelID: "test")
            if id == "queued" { continue }
            let run = try store.startRun(taskID: id, parentID: "parent", runID: "run-" + id)
            switch id {
            case "approval": _ = try store.appendEvent(runID: run.runID, kind: .approvalRequired, detail: "approval")
            case "input": _ = try store.appendEvent(runID: run.runID, kind: .inputRequired, detail: "input")
            case "failed": _ = try store.finish(runID: run.runID, outcome: .failed(reason: "synthetic"))
            case "old-success", "new-success": _ = try store.finish(runID: run.runID, outcome: .succeeded)
            default: break
            }
        }
        let before = store.taskCenterSnapshots(includeArchived: true)
        let receipts = store.allReceipts()
        let consumer = TaskCenterControlConsumer(store: store)
        let rows = consumer.receiptRows()
        let sections = consumer.homeReceiptSections(TaskCenterReceiptFilter())
        #expect(Set(sections.current.map(\.taskID)) == Set(["queued", "running", "approval", "input", "failed"]))
        #expect(sections.recentHistory.map(\.taskID) == ["new-success", "old-success"])
        #expect(Set(sections.current.map(\.stableID)).isDisjoint(with: sections.recentHistory.map(\.stableID)))
        for row in sections.current + sections.recentHistory {
            #expect(rows.first { $0.taskID == row.taskID && $0.parentID == row.parentID } == row)
        }
        #expect(consumer.homeReceiptSections(TaskCenterReceiptFilter(status: .completed)).current.isEmpty)
        #expect(consumer.homeReceiptSections(TaskCenterReceiptFilter(status: .failed)).current.map(\.taskID) == ["failed"])
        #expect(consumer.homeReceiptSections(TaskCenterReceiptFilter(sourceSessionID: "parent")).current.isEmpty)
        #expect(store.taskCenterSnapshots(includeArchived: true) == before)
        #expect(store.allReceipts() == receipts)
    }

    @Test func diagnosticsAggregateOnlyVersionedSessionControlsAcrossReconstruction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks522-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: file)
        for id in ["new", "switch", "rename", "fork"] {
            let task = try store.enqueue(taskID: "session-action:" + id, parentID: "parent",
                                         providerID: nil, modelID: nil, configurationFingerprint: "session-action-v1")
            let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "control-" + id)
            _ = try store.appendEvent(runID: run.runID, kind: .started, detail: "session-action")
            _ = try store.finish(runID: run.runID, outcome: .succeeded)
        }
        // Spelling without the real producer fingerprint is still a user task.
        _ = try store.enqueue(taskID: "session-action:ordinary", parentID: "parent",
                              providerID: "offline", modelID: "test", configurationFingerprint: "ordinary")
        let before = try Data(contentsOf: file)
        let consumer = TaskCenterControlConsumer(store: store)
        #expect(consumer.userTaskObservation().counts.total == 1)
        #expect(consumer.homeReceiptSections(TaskCenterReceiptFilter()).current.map(\.taskID) == ["session-action:ordinary"])
        let diagnostics = consumer.sessionActionDiagnosticObservation()
        #expect(diagnostics.counts.total == 4 && diagnostics.counts.succeeded == 4)
        #expect(Set(diagnostics.taskSnapshots.map(\.taskID)) == Set(["new", "switch", "rename", "fork"].map { "session-action:" + $0 }))
        let reopened = try AgentTaskStore(persistenceURL: file)
        let recoveredConsumer = TaskCenterControlConsumer(store: reopened)
        #expect(recoveredConsumer.sessionActionDiagnosticObservation() == diagnostics)
        #expect(recoveredConsumer.receiptRows() == consumer.receiptRows())
        #expect(try Data(contentsOf: file) == before)
    }
}
