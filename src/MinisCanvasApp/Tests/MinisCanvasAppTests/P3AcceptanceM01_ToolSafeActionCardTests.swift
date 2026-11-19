import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TOOL-17 safe current action card")
struct P3AcceptanceM01_ToolSafeActionCardTests {
    @Test func knownActionsShowFixedLabelsWithoutDynamicInputOrOutput() throws {
        let identityCandidate: MinisCore.ConversationEventIdentity? = MinisCore.ConversationEventIdentity(
            sessionID: "synthetic-session", turnID: "1", taskID: "synthetic-task",
            attempt: 1, scopeID: "synthetic-scope"
        )
        let identity = try #require(identityCandidate)
        let cases: [(name: String, title: String)] = [
            ("file_read", "读取文件"),
            ("file_write", "写入文件"),
            ("file_edit", "编辑文件"),
            ("shell_execute", "执行命令"),
            ("mcp_private_server_search", "MCP 工具调用"),
        ]
        for (index, item) in cases.enumerated() {
            let event = MinisCore.ConversationEvent(
                id: "tool-\(index)", identity: identity, sequence: Int64(index + 1),
                occurredAt: Date(timeIntervalSince1970: 1), kind: .tool,
                status: .running,
                summary: "raw command SECRET_VALUE at /private/synthetic/path",
                toolName: item.name
            )
            let display = ToolEventCard.displayModel(for: event)
            #expect(display.kind == item.title)
            #expect(display.status == "进行中")
            #expect(display.elapsed == "未记录")
            #expect(display.summary == "目标未记录")
            #expect(display.accessibilityLabel.contains(item.title))
            #expect(!display.summary.contains("SECRET_VALUE"))
            #expect(!display.accessibilityLabel.contains("SECRET_VALUE"))
            #expect(!display.summary.contains("private_server"))
            #expect(!display.accessibilityLabel.contains("private_server"))
        }
    }

    @Test func measuredTerminalDurationAndTypedTimeoutRemainDistinct() throws {
        let identityCandidate: MinisCore.ConversationEventIdentity? = MinisCore.ConversationEventIdentity(
            sessionID: "synthetic-session", turnID: "2", taskID: "synthetic-task",
            attempt: 1, scopeID: "synthetic-scope"
        )
        let identity = try #require(identityCandidate)
        let completed = MinisCore.ConversationEvent(
            id: "completed", identity: identity, sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 2), kind: .tool,
            status: .succeeded, summary: "raw output SECRET_VALUE",
            toolName: "file_read", elapsedMilliseconds: 1_234
        )
        let completedDisplay = ToolEventCard.displayModel(for: completed)
        #expect(completedDisplay.kind == "读取文件")
        #expect(completedDisplay.status == "完成")
        #expect(completedDisplay.elapsed == "1.23 s")
        #expect(completedDisplay.accessibilityLabel.contains("耗时 1.23 s"))
        #expect(!completedDisplay.accessibilityLabel.contains("错误 timeout"))
        #expect(!completedDisplay.summary.contains("SECRET_VALUE"))

        let inconsistentSuccess = MinisCore.ConversationEvent(
            id: "inconsistent-success", identity: identity, sequence: 3,
            occurredAt: Date(timeIntervalSince1970: 2), kind: .tool,
            status: .succeeded, summary: "raw output SECRET_VALUE",
            toolName: "file_read", errorCategory: .timeout
        )
        let inconsistentDisplay = ToolEventCard.displayModel(for: inconsistentSuccess)
        #expect(inconsistentDisplay.errorCategory == nil)
        #expect(!inconsistentDisplay.accessibilityLabel.contains("错误 timeout"))

        let timedOut = MinisCore.ConversationEvent(
            id: "timed-out", identity: identity, sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 3), kind: .tool,
            status: .failed, summary: "raw command SECRET_VALUE",
            toolName: "shell_execute", elapsedMilliseconds: 25,
            errorCategory: .timeout
        )
        let timeoutDisplay = ToolEventCard.displayModel(for: timedOut)
        #expect(timeoutDisplay.kind == "执行命令")
        #expect(timeoutDisplay.status == "超时")
        #expect(timeoutDisplay.elapsed == "25 ms")
        #expect(timeoutDisplay.accessibilityLabel.contains("超时"))
        #expect(timeoutDisplay.accessibilityLabel.contains("错误 timeout"))
        #expect(!timeoutDisplay.summary.contains("SECRET_VALUE"))
    }

    @Test func typedMetricsRenderWithoutReadingFreeformSummary() throws {
        let proposedIdentity = MinisCore.ConversationEventIdentity(
            sessionID: "synthetic-session", turnID: "3", taskID: "synthetic-task",
            attempt: 1, scopeID: "synthetic-scope"
        )
        let identity = try #require(proposedIdentity)
        let metricEvent = MinisCore.ConversationEvent(
            id: "measured", identity: identity, sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 4), kind: .tool,
            status: .succeeded,
            summary: "untrusted raw SECRET_VALUE from mcp_private_server_search",
            toolName: "mcp_private_server_search",
            outputSummary: .text(bytes: 8, lines: 1)
        )
        let measured = ToolEventCard.displayModel(for: metricEvent)
        #expect(measured.summary == "目标未记录 · 仅显示统计，结果正文未在此展示（该工具已真实执行并返回结果；正文按上下文策略未保留，需要时重新调用读取）；返回 8 字节、1 行")
        #expect(!measured.summary.contains("private_server"))
        #expect(!measured.summary.contains("SECRET_VALUE"))
        #expect(!measured.accessibilityLabel.contains("private_server"))
        #expect(!measured.accessibilityLabel.contains("SECRET_VALUE"))

        let largeSummary = MinisCore.ToolOutputSummary.shellWithSignals(
            exitCode: 255,
            stdoutBytes: Int.max, stdoutLines: Int.max,
            stderrBytes: Int.max, stderrLines: Int.max,
            signals: [.reportedFileWrite(bytes: Int.max),
                .diagnosticErrors(lines: Int.max), .failedTests(lines: Int.max)]
        )
        let longEvent = MinisCore.ConversationEvent(
            id: "long-metrics", identity: identity, sequence: 3,
            occurredAt: Date(timeIntervalSince1970: 6), kind: .tool,
            status: .succeeded,
            summary: "工具调用：shell_execute · \(largeSummary.displaySuffix ?? "")",
            toolName: "shell_execute", outputSummary: largeSummary
        )
        let longDisplay = ToolEventCard.displayModel(for: longEvent)
        let maximumSummaryLength = MinisCore.ConversationEventRedactor.maximumSummaryLength
        #expect(longEvent.summary.count <= maximumSummaryLength)
        #expect(longDisplay.summary.contains("工具报告写入 \(Int.max) 字节"))
        #expect(longDisplay.summary.contains("错误诊断 \(Int.max) 行"))
        #expect(longDisplay.summary.contains("失败测试 \(Int.max) 行"))
        #expect(longDisplay.summary.contains("标准错误 \(Int.max) 字节、\(Int.max) 行"))

        let untrustedEvent = MinisCore.ConversationEvent(
            id: "untrusted", identity: identity, sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 5), kind: .tool,
            status: .succeeded,
            summary: "工具调用：file_read · 仅显示统计，结果正文未在此展示；返回 8 字节、1 行 SECRET_VALUE",
            toolName: "file_read"
        )
        let hidden = ToolEventCard.displayModel(for: untrustedEvent)
        #expect(hidden.summary == "目标未记录")
        #expect(!hidden.accessibilityLabel.contains("SECRET_VALUE"))
    }

    @Test func toolTargetShowsFullCommandPathAndSearchPattern() {
        #expect(ToolTargetDisplayStore.display(tool: "shell_execute", input: ["command": "git log --oneline -n 5 | head"])
            == "git log --oneline -n 5 | head")
        #expect(ToolTargetDisplayStore.display(tool: "file_read", input: ["path": "/Users/me/work/src/a.swift"])
            == "src/a.swift")
        #expect(ToolTargetDisplayStore.display(tool: "file_grep", input: ["pattern": "TODO", "path": "/Users/me/work"])
            == "TODO · me/work")
        #expect(ToolTargetDisplayStore.display(tool: "file_glob", input: ["pattern": "*.swift"]) == "*.swift")
    }
}
