import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center compact row labels")
struct TaskCenterRowLabelFormatterTests {
    @Test func taskTitleUsesProducerTitleAndNeverFallsBackToIdentity() {
        let id = "internal123"
        #expect(TaskCenterRowLabelFormatter.title("  整理采购单  ", taskID: id) == "整理采购单")
        #expect(TaskCenterRowLabelFormatter.title(nil, taskID: id) == "未命名任务")
        #expect(TaskCenterRowLabelFormatter.title("   ", taskID: id) == "未命名任务")
        #expect(TaskCenterRowLabelFormatter.title(id, taskID: id) == "未命名任务")
        #expect(TaskCenterRowLabelFormatter.title("2E8D10D8-8A8C-4FB5-A0B2-38BD80132842", taskID: id) == "未命名任务")
    }

    @Test func sourceLabelsUseActualCatalogAndStableDistinctFallbacks() {
        let first = "2E8D10D8-8A8C-4FB5-A0B2-38BD80132842"
        let second = "A06834ED-DAC9-4A58-9781-59E1F72FB374"
        let third = "C06834ED-DAC9-4A58-9781-59E1F72FB374"
        let labels = TaskCenterRowLabelFormatter.sourceLabels(
            ids: [third, second, first, first],
            knownTitles: [second: "项目讨论", third: "项目讨论", first: first]
        )
        #expect(labels[first] == "来源会话 1")
        #expect(labels[second] == "项目讨论（来源会话 2）")
        #expect(labels[third] == "项目讨论（来源会话 3）")
        #expect(TaskCenterRowLabelFormatter.source(second, labels: labels) == labels[second])
        #expect(TaskCenterRowLabelFormatter.source(nil, labels: labels) == "来源未知")
        #expect(TaskCenterRowLabelFormatter.source("missing", labels: labels) == "来源会话不可用")
        #expect(TaskCenterRowLabelFormatter.sourceLabels(ids: [first, third, second], knownTitles: [second: "项目讨论", third: "项目讨论", first: first]) == labels)
    }

    @Test @MainActor func backgroundCommandDetailLocalizesAgentStopReason() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BackgroundShellSnapshot(
            id: "background-command", sessionID: "session", commandPreview: "fixture",
            state: .stopped, exitCode: nil, processID: 1,
            startedAt: started, endedAt: started.addingTimeInterval(2),
            timeoutSeconds: 60, stdoutBytes: 0, stderrBytes: 0,
            endNote: "stopped by shell_stop"
        )

        let detail = BackgroundCommandsSection.detailLine(snapshot, now: started.addingTimeInterval(10))

        #expect(detail == "已停止 · 用时 2 秒 · 由智能体停止")
    }

    @Test func rowAccessibilitySummaryUsesTaskFactsWithoutInternalIdentity() {
        let label = TaskCenterRowLabelFormatter.accessibilityLabel(
            title: "整理采购单", source: "家庭项目", status: "已完成",
            step: "完成", progress: "事件 3（完成）", duration: "12秒",
            result: "已完成 · 有输出", recovery: "恢复：需要人工复核"
        )
        #expect(label == "任务 整理采购单，状态 已完成，来源会话 家庭项目，当前步骤 完成，进度 事件 3（完成），耗时 12秒，结果 已完成 · 有输出，恢复：需要人工复核")
        #expect(!label.contains("Run "))
        #expect(!label.contains("Attempt "))
        #expect(!label.contains("Effect "))
    }
}
