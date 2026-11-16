import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-OUTPUT-05 large tool output visible consumer")
struct P3AcceptanceM04_LargeToolOutputSummaryConsumerTests {
    @Test func settledLargeOutputShowsMeasuredSummaryWithoutRawBody() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-output-summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "synthetic-output-session-A",
                turnID: 7,
                messageID: "synthetic-output-message"
            ),
            operationID: "synthetic-output-operation",
            attempt: 1
        )
        let receipt = try ledger.mint(
            toolCallID: "large-shell-output",
            toolName: "shell_execute",
            attemptID: "synthetic-attempt",
            attemptNumber: 1,
            executionIdentity: identity
        )
        let canary = "synthetic-private-output-value"
        let stdout = String(repeating: "row\n", count: 2_000) + canary
        let output = String(decoding: try JSONSerialization.data(withJSONObject: [
            "exit_code": 7,
            "stdout": stdout,
            "stderr": "warning\n",
        ]), as: UTF8.self)
        let summary = ToolOutputSummary.capture(toolName: "shell_execute", output: output)
        let settled = try ledger.settle(
            receipt,
            status: .succeeded,
            outputSummary: summary
        )
        let fact = try #require(settled)
        let restored = try #require(ToolExecutionFactLedger(persistenceURL: url).facts.first)
        #expect(restored == fact)
        #expect(restored.executionIdentity?.turn.sessionID == "synthetic-output-session-A")

        let consumer = ToolLifecycleConsumer()
        #expect(await consumer.ingestToolExecutionFact(
            restored,
            eventID: restored.toolCallID,
            eventName: restored.toolName,
            taskID: "synthetic-task-A",
            expectedAttemptID: restored.attemptID,
            scopeID: "synthetic-scope-A"
        ))
        let event = try #require(consumer.toolLifecycleEvents.first)
        let visible = ToolEventCard.displayModel(for: event)
        #expect(event.identity.sessionID == "synthetic-output-session-A")
        #expect(event.outputSummary == summary)
        #expect(visible.summary.contains("退出码 7"))
        #expect(visible.summary.contains("标准输出 \(stdout.utf8.count) 字节、2001 行"))
        #expect(visible.summary.contains("标准错误 8 字节、1 行"))
        #expect(visible.status == "完成")
        #expect(!visible.summary.contains(canary))
        #expect(!visible.accessibilityLabel.contains(canary))
        let durableEvent = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!durableEvent.contains(canary))
        #expect(!String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains(canary))
    }

    @Test func oldFactWithoutOutputSummaryKeepsExistingVisibleLabel() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-old-output-summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "synthetic-output-session-B",
                turnID: 8,
                messageID: "synthetic-old-message"
            ),
            operationID: "synthetic-old-operation",
            attempt: 1
        )
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try ledger.mint(
            toolCallID: "old-file-read",
            toolName: "file_read",
            attemptID: "old-attempt",
            attemptNumber: 1,
            executionIdentity: identity
        )
        let fact = try #require(try ledger.settle(receipt, status: .succeeded))
        #expect(fact.outputSummary == nil)
        let consumer = ToolLifecycleConsumer()
        #expect(await consumer.ingestToolExecutionFact(
            fact,
            eventID: fact.toolCallID,
            eventName: fact.toolName,
            taskID: "synthetic-task-B",
            expectedAttemptID: fact.attemptID,
            scopeID: "synthetic-scope-B"
        ))
        let event = try #require(consumer.toolLifecycleEvents.first)
        let visible = ToolEventCard.displayModel(for: event)
        #expect(event.identity.sessionID == "synthetic-output-session-B")
        #expect(event.outputSummary == nil)
        #expect(visible.summary == "读取文件：参数与结果正文已隐藏")
        #expect(visible.status == "完成")
    }

}
