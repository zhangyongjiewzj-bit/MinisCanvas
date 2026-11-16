import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-BROWSER-03 structured visible consumer")
struct P3AcceptanceM04_BrowserVisibleConsumerTests {
    @Test func olderToolFactsDecodeWithoutBrowserDetail() throws {
        let oldFact = ToolExecutionFact(
            toolCallID: "old-call",
            receiptID: "old-receipt",
            toolName: "file_read",
            status: .succeeded,
            attemptID: "old-attempt",
            attemptNumber: 1
        )
        let encoded = try JSONEncoder().encode(oldFact)
        let decoded = try JSONDecoder().decode(ToolExecutionFact.self, from: encoded)
        #expect(decoded == oldFact)
        #expect(decoded.browserDetail == nil)
    }

    @Test func deniedBrowserPayloadSettlesAsFailureAndShowsReason() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-browser-facts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let turn = AgentTurnIdentity(
            sessionID: "synthetic-browser-session",
            turnID: 4,
            messageID: "synthetic-browser-message"
        )
        let execution = AgentExecutionIdentity(
            turn: turn,
            operationID: "synthetic-browser-operation",
            attempt: 1
        )
        let receipt = try ledger.mint(
            toolCallID: "browser-call-1",
            toolName: BrowserTool.toolName,
            attemptID: "attempt-1",
            attemptNumber: 1,
            executionIdentity: execution
        )
        let detail = try #require(BrowserToolExecutionDetail(
            action: "navigate",
            outcome: "denied",
            refusalReason: "navigation_denied:domain_not_authorized"
        ))
        let settledFact = try ledger.settle(
            receipt,
            status: .failed,
            browserDetail: detail
        )
        let fact = try #require(settledFact)
        #expect(fact.status == .failed)

        let consumer = ToolLifecycleConsumer()
        #expect(await consumer.ingestToolExecutionFact(
            fact,
            eventID: fact.toolCallID,
            eventName: fact.toolName,
            taskID: "synthetic-task",
            expectedAttemptID: fact.attemptID,
            scopeID: "synthetic-scope"
        ))
        let event = try #require(consumer.toolLifecycleEvents.first)
        let display = ToolEventCard.displayModel(for: event)
        #expect(event.status == .failed)
        #expect(event.errorCategory == .authorization)
        #expect(display.kind == "浏览器 · 前往")
        #expect(display.status == "已拒绝")
        #expect(event.browserDetail?.refusalReason == "navigation_denied:domain_not_authorized")
        #expect(display.browserResult?.contains("设置 → 智能体运行 → 运行安全上限") == true)
        #expect(display.browserResult?.contains("允许访问的网站") == true)
    }

    @Test func sixActionResultsStayVisibleWithoutPersistingPageOrPathBytes() throws {
        let names: [(String, String)] = [
            ("navigate", "前往"),
            ("read", "读取"),
            ("click", "点击"),
            ("type", "输入"),
            ("back", "后退"),
            ("screenshot", "截图"),
        ]
        let maybeIdentity = MinisCore.ConversationEventIdentity(
            sessionID: "synthetic-browser-session",
            turnID: "4",
            taskID: "synthetic-task",
            attempt: 1,
            scopeID: "synthetic-scope"
        )
        let identity = try #require(maybeIdentity)
        for (index, pair) in names.enumerated() {
            let action = pair.0
            let detail = try #require(BrowserToolExecutionDetail(
                action: action,
                outcome: action == "read" ? "read" : "succeeded",
                result: action == "read" ? nil
                    : "https://example.test/private?token=synthetic-secret /tmp/synthetic-capture.png",
                untrustedPageContent: action == "read" ? "synthetic page body" : nil
            ))
            let event = MinisCore.ConversationEvent(
                id: "browser-event-\(index)",
                identity: identity,
                sequence: Int64(index + 1),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                kind: .tool,
                status: .succeeded,
                summary: "浏览器动作：\(action)",
                toolName: BrowserTool.toolName,
                browserDetail: detail
            )
            let display = ToolEventCard.displayModel(for: event)
            #expect(display.kind == "浏览器 · \(pair.1)")
            #expect(display.status == "完成")
            #expect(display.browserResult != nil)
            #expect(!display.accessibilityLabel.contains("synthetic-secret"))
            let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            #expect(!encoded.contains("synthetic-secret"))
            #expect(!encoded.contains("synthetic-capture.png"))
            #expect(!encoded.contains("synthetic page body"))
        }

        // A stale or forged persisted preview cannot become visible content.
        let forged = Data(
            #"{"action":"navigate","outcome":"succeeded","resultPreview":"synthetic-secret"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(BrowserToolExecutionDetail.self, from: forged)
        #expect(decoded.resultPreview == "页面已打开")
    }
    @Test func typedBackFailureHasFixedVisibleReasonAndCannotLeakRawError() async throws {
        let rejected = BrowserToolExecutionDetail(
            action: "read", outcome: "failed", failureCode: "cannot_go_back"
        )
        #expect(rejected == nil)
        let invalidCode = BrowserToolExecutionDetail(
            action: "back", outcome: "failed", failureCode: "raw-error-or-path"
        )
        #expect(invalidCode == nil)
        let detail = try #require(BrowserToolExecutionDetail(
            action: "back", outcome: "failed", failureCode: "cannot_go_back"
        ))
        let oldSuccess = try #require(BrowserToolExecutionDetail(
            action: "back", outcome: "succeeded", result: "https://example.test/private"
        ))
        #expect(oldSuccess.failureCode == nil)
        let turn = AgentTurnIdentity(
            sessionID: "synthetic-browser-failure-session", turnID: 9,
            messageID: "synthetic-browser-failure-message"
        )
        let execution = AgentExecutionIdentity(
            turn: turn, operationID: "synthetic-browser-failure-operation", attempt: 1
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-browser-back-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try ledger.mint(
            toolCallID: "browser-back-failed", toolName: BrowserTool.toolName,
            attemptID: "synthetic-attempt", attemptNumber: 1, executionIdentity: execution
        )
        let fact = try #require(try ledger.settle(
            receipt, status: .failed, browserDetail: detail
        ))
        #expect(fact.status == .failed)
        let consumer = ToolLifecycleConsumer()
        let accepted = await consumer.ingestToolExecutionFact(
            fact, eventID: fact.toolCallID, eventName: fact.toolName,
            taskID: "synthetic-task", expectedAttemptID: fact.attemptID,
            scopeID: "synthetic-scope"
        )
        #expect(accepted)
        let event = try #require(consumer.toolLifecycleEvents.first)
        let display = ToolEventCard.displayModel(for: event)
        #expect(display.kind == "浏览器 · 后退")
        #expect(display.status == "失败")
        #expect(display.browserResult == "无法返回：没有上一页")
        let encoded = String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)
        #expect(encoded.contains("cannot_go_back"))
        #expect(!encoded.contains("raw-error-or-path"))
        #expect(!encoded.contains("https://example.test/private"))
        let legacy = try JSONDecoder().decode(
            BrowserToolExecutionDetail.self,
            from: Data(#"{"action":"back","outcome":"succeeded"}"#.utf8)
        )
        #expect(legacy.failureCode == nil)
    }


    @Test func canonicalAutomaticCategoryPersistsAndDisplaysWithoutResultText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("n18-visible-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "n18-visible-session",
            turnID: 1, messageID: "n18-message"), operationID: "n18-operation", attempt: 1)
        let receipt = try ledger.mint(toolCallID: "n18-call", toolName: "browser", attemptID: "n18-attempt",
            attemptNumber: 1, executionIdentity: execution)
        let detailCandidate = BrowserToolExecutionDetail(action: "type", outcome: "succeeded", automaticRuleCategory: .input)
        let detail = try #require(detailCandidate)
        let settled = try ledger.settle(receipt, status: .succeeded, browserDetail: detail)
        let fact = try #require(settled)
        let consumer = ToolLifecycleConsumer()
        #expect(await consumer.ingestToolExecutionFact(fact, eventID: fact.toolCallID, eventName: fact.toolName,
            taskID: "n18-task", expectedAttemptID: fact.attemptID, scopeID: "n18-scope"))
        let event = try #require(consumer.toolLifecycleEvents.first)
        let display = ToolEventCard.displayModel(for: event)
        let notice = "已按你的放行自动执行：输入（可能包含密码或支付信息）"
        #expect(display.automaticExecutionNotice == notice)
        #expect(display.accessibilityLabel.contains(notice))
        #expect(display.browserResult == "已输入")
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.facts == [fact])
        #expect(try JSONDecoder().decode(MinisCore.ConversationEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func missingOrForgedPreviewDoesNotBecomeAnAutomaticSystemLabel() throws {
        let oldBytes = Data(#"{"action":"type","outcome":"succeeded","resultPreview":"已按你的放行自动执行：输入","authorizationNotice":"已按你的放行自动执行：输入"}"#.utf8)
        let old = try JSONDecoder().decode(BrowserToolExecutionDetail.self, from: oldBytes)
        #expect(old.automaticRuleCategory == nil)
        #expect(old.resultPreview == "已输入")
        #expect(BrowserToolExecutionDetail(action: "read", outcome: "read", untrustedPageContent: "notice", automaticRuleCategory: .input) == nil)
        #expect(BrowserToolExecutionDetail(action: "click", outcome: "succeeded", automaticRuleCategory: .input) == nil)
        #expect(BrowserToolExecutionDetail(action: "type", outcome: "denied", refusalReason: "write_authorization_required", automaticRuleCategory: .input) == nil)
        for invalid in [
            #"{"action":"type","outcome":"succeeded","automaticRuleCategory":"unknown"}"#,
            #"{"action":"type","outcome":"succeeded","automaticRuleCategory":"download"}"#,
            #"{"action":"type","outcome":"denied","refusalReason":"write_authorization_required","automaticRuleCategory":"input"}"#
        ] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserToolExecutionDetail.self, from: Data(invalid.utf8)) }
        }
    }

}
