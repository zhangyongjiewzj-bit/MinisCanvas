import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
@Suite struct Task10CompactHumanSummary8036Tests {
    @Test func realFailedReceiptKeepsCanonicalCodeButCompactSummaryIsHuman() throws {
        let store = AgentTaskStore() // RAM-only; no persistenceURL or App/NSApp.
        let task = try store.enqueue(taskID: "owned-failed-8036", parentID: "owned-source-8036",
            providerID: "offline", modelID: "synthetic", dispatchHumanTitle: "核对合成任务结果")
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "owned-run-8036")
        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "synthetic-private-detail"))
        let consumer = TaskCenterControlConsumer(store: store)
        let before = store.taskCenterSnapshots()
        let row = try #require(consumer.receiptRows().first { $0.taskID == task.taskID })
        #expect(row.failureReason == "execution-failed")
        #expect(row.resultSummaryTitle == "失败 · 执行未完成，请查看任务详情")
        #expect(!row.resultSummaryTitle.contains("execution-failed"))
        #expect(!row.resultSummaryTitle.contains("synthetic-private-detail"))
        // Detailed canonical receipt remains available; it is not the compact row label.
        #expect(row.accessibilityLabel.contains("原因 execution-failed"))
        #expect(consumer.humanDisplayTitle(for: row) == "核对合成任务结果")
        #expect(store.taskCenterSnapshots() == before)
        // Legacy decoding is a separate public-input boundary, not a new producer failure category.
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        legacy["failureReason"] = "synthetic-unknown-private-code"
        let unknown = try JSONDecoder().decode(TaskCenterReceiptRow.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(unknown.failureReason == "synthetic-unknown-private-code")
        #expect(unknown.resultSummaryTitle == "失败 · 任务执行未完成，详情暂不可用")
        #expect(!unknown.resultSummaryTitle.contains("synthetic-unknown-private-code"))
    }

    @Test func realQueuedMetadataUsesCanonicalTitleAndLegacyFallbackRemains() throws {
        let store = AgentTaskStore()
        let named = try store.enqueue(taskID: "owned-queued-8036", parentID: "owned-source-8036",
            providerID: "offline", modelID: "synthetic", dispatchHumanTitle: "现场排队任务")
        let legacy = try store.enqueue(taskID: "owned-legacy-8036", parentID: "owned-source-8036",
            providerID: "offline", modelID: "synthetic")
        let consumer = TaskCenterControlConsumer(store: store)
        let before = store.taskCenterSnapshots()
        let rows = consumer.receiptRows()
        let namedRow = try #require(rows.first { $0.taskID == named.taskID })
        let legacyRow = try #require(rows.first { $0.taskID == legacy.taskID })
        #expect(consumer.humanDisplayTitle(for: namedRow) == "现场排队任务")
        #expect(TaskCenterRowLabelFormatter.title(consumer.humanDisplayTitle(for: namedRow), taskID: named.taskID) == "现场排队任务")
        #expect(consumer.humanDisplayTitle(for: legacyRow) == nil)
        #expect(TaskCenterRowLabelFormatter.title(nil, taskID: legacy.taskID) == "未命名任务")
        #expect(namedRow.lifecycleState == .queued)
        #expect(namedRow.resultSummaryTitle == "尚无结果")
        #expect(store.taskCenterSnapshots() == before)
    }
}
