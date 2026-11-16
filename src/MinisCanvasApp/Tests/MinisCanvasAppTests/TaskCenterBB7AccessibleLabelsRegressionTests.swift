import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("bb7 readable Task Center labels: pure values and source callers")
@MainActor
struct TaskCenterBB7AccessibleLabelsRegressionTests {
    @Test
    func childSessionCallerKeepsReadableCategoryAndNavigationIdentity() throws {
        let source = try observationSource()
        let start = try #require(source.range(of: "if let childNavigation = receipt?.childNavigation"))
        let end = try #require(source.range(of: "let approvalNavigation =", range: start.upperBound..<source.endIndex))
        let child = String(source[start.lowerBound..<end.lowerBound])
        #expect(child.contains(".accessibilityLabel(\"打开子会话并保留父任务位置\")"))
        #expect(child.contains("\"task-center-child-session-\\(childNavigation.childSessionID)\""))
        #expect(child.contains(".accessibilityIdentifier("))
        #expect(child.contains("TaskCenterChildSessionView("))
        #expect(child.contains("navigation: childNavigation"))
        #expect(!child.contains(".accessibilityLabel(childNavigation.accessibilityLabel)"))
        let categories = ["打开子会话并保留父任务位置", "停止任务 春日整理", "取消任务 春日整理", "重试任务 春日整理", "任务 春日整理，等待审批，需要处理"]
        #expect(Set(categories).count == categories.count)
    }

    @Test
    func stopLabelIsReadableAndDistinguishesHumanTaskTitles() throws {
        #expect(TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .stop) == "停止任务 春日整理")
        #expect(TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "秋日归档", action: .stop) == "停止任务 秋日归档")
        #expect(TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .stop) != TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "秋日归档", action: .stop))
        try assertActualControlCaller()
    }

    @Test
    func cancelLabelIsReadableAndDistinctFromStopAndRetry() throws {
        let label = TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .cancel)
        #expect(label == "取消任务 春日整理")
        #expect(label != TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .stop))
        #expect(label != TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .retry))
        try assertActualControlCaller()
    }

    @Test
    func retryLabelIsReadableAndPreservesHumanTaskContext() throws {
        #expect(TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .retry) == "重试任务 春日整理")
        #expect(TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "秋日归档", action: .retry) == "重试任务 秋日归档")
        #expect(TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .retry) != TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: "春日整理", action: .cancel))
        try assertActualControlCaller()
    }

    @Test
    func blockedLabelDistinguishesApprovalInputAndHumanTaskTitles() throws {
        let approval = TaskCenterRowLabelFormatter.blockedAccessibilityLabel(title: "春日整理", state: .approvalRequired)
        let input = TaskCenterRowLabelFormatter.blockedAccessibilityLabel(title: "春日整理", state: .inputRequired)
        #expect(approval == "任务 春日整理，等待审批，需要处理")
        #expect(input == "任务 春日整理，等待输入，需要处理")
        #expect(approval != input)
        #expect(approval != TaskCenterRowLabelFormatter.blockedAccessibilityLabel(title: "秋日归档", state: .approvalRequired))
        let source = try observationSource()
        #expect(source.contains("TaskCenterRowLabelFormatter.blockedAccessibilityLabel(title: displayTitle, state: lifecycleState)"))
        #expect(source.contains("displayTitle: humanDisplayTitle"))
    }

    private func assertActualControlCaller() throws {
        let source = try observationSource()
        #expect(source.contains(".accessibilityLabel(actionAccessibilityLabel(action))"))
        #expect(source.contains("let title = humanDisplayTitle"))
        #expect(source.contains("TaskCenterRowLabelFormatter.controlAccessibilityLabel(title: title, action: action)"))
    }

    private func observationSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift"), encoding: .utf8)
    }
}
