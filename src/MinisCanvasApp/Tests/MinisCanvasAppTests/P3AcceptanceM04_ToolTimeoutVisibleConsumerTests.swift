import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TOOL-13 distinct terminal tool states")
struct P3AcceptanceM04_ToolTimeoutVisibleConsumerTests {
    @Test func typedTimeoutOrdinaryFailureAndCancellationStayDistinct() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-tool-terminals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let consumer = ToolLifecycleConsumer()
        let cases: [(status: ToolExecutionStatus, category: ToolExecutionFailureCategory?,
                     visible: String, eventCategory: MinisCore.ConversationEventErrorCategory?)] = [
            (.failed, .timeout, "超时", .timeout),
            (.failed, nil, "失败", .tool),
            (.cancelled, nil, "已取消", nil),
        ]

        for (index, expected) in cases.enumerated() {
            let callID = "synthetic-terminal-\(index)"
            let execution = AgentExecutionIdentity(
                turn: AgentTurnIdentity(
                    sessionID: "synthetic-session", turnID: index + 1,
                    messageID: "synthetic-message-\(index)"
                ),
                operationID: "synthetic-operation-\(index)", attempt: 1
            )
            let receipt = try ledger.mint(
                toolCallID: callID, toolName: "file_read",
                attemptID: "synthetic-attempt-\(index)", attemptNumber: 1,
                executionIdentity: execution
            )
            let settled = try ledger.settle(
                receipt, status: expected.status,
                failureCategory: expected.category
            )
            let fact = try #require(settled)
            #expect(fact.failureCategory == expected.category)
            #expect(await consumer.ingestToolExecutionFact(
                fact, eventID: callID, eventName: "file_read",
                taskID: "synthetic-task", expectedAttemptID: fact.attemptID,
                scopeID: "synthetic-scope"
            ))
            let event = try #require(consumer.toolLifecycleEvents.last)
            let display = ToolEventCard.displayModel(for: event)
            #expect(event.errorCategory == expected.eventCategory)
            #expect(display.status == expected.visible)
            #expect(display.accessibilityLabel.contains(expected.visible))
        }
    }

    @Test func oldFactWithoutFailureCategoryStaysOrdinaryFailure() throws {
        let oldFact = ToolExecutionFact(
            toolCallID: "old-call", receiptID: "old-receipt", toolName: "file_read",
            status: .failed, attemptID: "old-attempt", attemptNumber: 1
        )
        let decoded = try JSONDecoder().decode(
            ToolExecutionFact.self, from: JSONEncoder().encode(oldFact)
        )
        #expect(decoded.failureCategory == nil)
        #expect(decoded.status == .failed)
    }
}
