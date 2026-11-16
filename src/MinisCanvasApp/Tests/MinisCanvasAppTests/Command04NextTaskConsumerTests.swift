import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 next task uses canonical Task Center order")
struct Command04NextTaskConsumerTests {
    @Test func selectionAdvancesWrapsAndRevalidatesStaleCurrentWithoutTaskEffects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("command04-next-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: file)
        _ = try store.enqueue(taskID: "z-running", parentID: "synthetic-parent",
                              providerID: "offline", modelID: "fixture")
        _ = try store.startRun(taskID: "z-running", parentID: "synthetic-parent",
                               runID: "synthetic-run")
        for id in ["a-queued", "b-queued"] {
            _ = try store.enqueue(taskID: id, parentID: "synthetic-parent",
                                  providerID: "offline", modelID: "fixture")
        }
        let consumer = TaskCenterControlConsumer(store: store)
        let rows = consumer.homeReceiptSections(TaskCenterReceiptFilter()).current
        #expect(rows.map(\.taskID) == ["z-running", "a-queued", "b-queued"])
        let before = try Data(contentsOf: file)
        let first = TaskCenterNextTaskSelection.nextID(in: rows, after: nil)
        #expect(first == rows[0].stableID)
        let second = TaskCenterNextTaskSelection.nextID(in: rows, after: first)
        #expect(second == rows[1].stableID)
        #expect(TaskCenterNextTaskSelection.nextID(in: rows, after: second) == rows[2].stableID)
        #expect(TaskCenterNextTaskSelection.nextID(in: rows, after: rows[2].stableID) == first)
        #expect(TaskCenterNextTaskSelection.nextID(in: rows, after: "stale") == first)
        #expect(TaskCenterNextTaskSelection.nextID(in: [], after: first) == nil)
        #expect(try Data(contentsOf: file) == before)

        _ = try store.finish(runID: "synthetic-run", outcome: .succeeded)
        let refreshed = consumer.homeReceiptSections(TaskCenterReceiptFilter()).current
        #expect(refreshed.map(\.taskID) == ["a-queued", "b-queued"])
        #expect(TaskCenterNextTaskSelection.nextID(in: refreshed, after: first)
                == refreshed[0].stableID)
    }
}
