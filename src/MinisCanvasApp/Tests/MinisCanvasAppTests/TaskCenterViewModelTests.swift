import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center receipt view model")
struct TaskCenterViewModelTests {
    @Test func receiptViewModelHasStableAccessibleStatusAndActionLabels() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "ax-task",
            parentID: "session-a",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "ax-run"
        )
        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "execution-failed"))

        let row = try #require(
            TaskCenterControlConsumer(store: store)
                .receiptRows(now: Date(timeIntervalSince1970: 1_850_000_000))
                .first
        )
        #expect(row.accessibilityLabel.contains("任务"))
        #expect(row.accessibilityLabel.contains("失败"))
        #expect(row.accessibilityLabel.contains("Run ax-run"))
        #expect(row.accessibilityLabel.contains("Effect effect:ax-run"))
        #expect(row.accessibilityLabel.contains("可重试"))
        #expect(row.retryAccessibilityLabel == "重试任务 ax-task")
        #expect(row.cancelAccessibilityLabel == nil)
    }

    @Test func sourceViewExposesReceiptStateFailureAndControlAccessibilityContracts() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for contract in [
            "receiptRows(now:",
            "failureReason",
            ".accessibilityLabel(receipt?.accessibilityLabel",
            "task-center-receipt"
        ] {
            #expect(source.contains(contract), "Missing Task Center receipt contract: \(contract)")
        }

        // Bind readable action labels to the current production caller, not old
        // receipt-row property names which the view no longer references.
        let controlsStart = try #require(source.range(of: "ForEach(controlActions, id: \\.rawValue) { action in"))
        let controlsEnd = try #require(source.range(of: ".accessibilityValue(\"可用\")", range: controlsStart.upperBound..<source.endIndex))
        let controls = String(source[controlsStart.lowerBound..<controlsEnd.lowerBound])
        #expect(controls.contains("onControl(action)"))
        #expect(controls.contains(".accessibilityLabel(actionAccessibilityLabel(action))"))

        let actionsStart = try #require(source.range(of: "private var controlActions: [TaskCenterControlAction] {"))
        let actionsEnd = try #require(source.range(of: "private var receiptSummary:", range: actionsStart.upperBound..<source.endIndex))
        let actions = String(source[actionsStart.lowerBound..<actionsEnd.lowerBound])
        #expect(actions.contains("case .queued, .running:"))
        #expect(actions.contains("case .failed, .cancelled:"))
        #expect(actions.contains("guard receipt?.cancelAvailable == true else { return [] }"))
        #expect(actions.contains("fact.status == .queued ? .cancel : .stop"))
        #expect(actions.contains("return receipt?.retryAvailable == true ? [.retry] : []"))

        let labelStart = try #require(source.range(of: "private func actionAccessibilityLabel(_ action: TaskCenterControlAction) -> String {"))
        let labelEnd = try #require(source.range(of: "\n    }", range: labelStart.upperBound..<source.endIndex))
        let labelCaller = String(source[labelStart.lowerBound..<labelEnd.lowerBound])
        #expect(labelCaller.contains("let title = humanDisplayTitle"))
        #expect(labelCaller.contains("return TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: title, action: action)"))

        let retry = TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .retry)
        let cancel = TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .cancel)
        #expect(retry == "重试任务 春日整理")
        #expect(cancel == "取消任务 春日整理")
        #expect(retry != cancel)
        #expect(retry != TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "秋日归档", action: .retry))
        #expect(cancel != TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "秋日归档", action: .cancel))
    }
}
