import Foundation
import Testing
@testable import MinisCore

@Suite("UX-03 结构化对话事件投影 Core 合同")
struct ConversationEventProjectionTests {

    @Test("思考事件保留完整运行时身份")
    func thinkingEventProjectsWithCompleteIdentity() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let event = ConversationEvent(
            id: "thinking-1",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .thinking,
            status: .running,
            summary: "正在思考"
        )

        var projection = ConversationEventProjection()
        let accepted = projection.ingest(event)

        #expect(accepted)
        #expect(projection.events == [event])
        #expect(projection.events[0].identity.sessionID == "session-a")
        #expect(projection.events[0].identity.turnID == "turn-7")
        #expect(projection.events[0].identity.taskID == "task-9")
        #expect(projection.events[0].identity.attempt == 1)
        #expect(projection.events[0].identity.scopeID == "scope-a")
    }

    @Test("投影覆盖停止、耗时、切模、工具、审批和任务事件")
    func lifecycleEventKindsAreProjectable() throws {
        let expected: [(ConversationEventKind, ConversationEventStatus)] = [
            (.thinking, .running),
            (.stop, .stopped),
            (.duration, .succeeded),
            (.modelSwitch, .succeeded),
            (.tool, .running),
            (.approval, .waiting),
            (.task, .cancelled),
        ]
        let events = try expected.enumerated().map { index, item in
            let identity = try #require(ConversationEventIdentity(
                sessionID: "session-a",
                turnID: "turn-7",
                taskID: "task-\(index)",
                attempt: 1,
                scopeID: "scope-a"
            ))
            return ConversationEvent(
                id: "event-\(index)",
                identity: identity,
                sequence: Int64(index + 1),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                kind: item.0,
                status: item.1,
                summary: "event-\(index)",
                toolCallID: [.tool, .approval].contains(item.0) ? "call-event-\(index)" : nil,
                receiptID: [.tool, .approval].contains(item.0) ? "receipt-event-\(index)" : nil,
                approvalDecision: item.0 == .approval ? .requested : nil
            )
        }

        let projection = ConversationEventProjection(events: events)

        #expect(projection.events.map(\.kind) == expected.map(\.0))
        #expect(projection.events.map(\.status) == expected.map(\.1))
    }

    @Test("展示摘要脱敏、去路径并限制长度")
    func displaySummaryIsRedactedAndBounded() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let event = ConversationEvent(
            id: "tool-1",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .failed,
            summary: "读取 /Users/alice/private.txt；Authorization: Bearer super-secret-token https://example.com/private",
            toolCallID: "call-redaction-1",
            receiptID: "receipt-redaction-1"
        )

        #expect(!event.summary.contains("/Users/alice"))
        #expect(!event.summary.contains("super-secret-token"))
        #expect(!event.summary.contains("https://example.com/private"))
        #expect(event.summary.count <= ConversationEventRedactor.maximumSummaryLength)
    }

    @Test("旧事件缺少输出统计字段仍可解码，typed 统计保持独立持久事实")
    func optionalToolOutputSummaryPreservesLegacyDecodeAndRoundTrip() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-output", turnID: "turn-1", taskID: "task-output",
            attempt: 1, scopeID: "scope-output"
        ))
        let metrics = ToolOutputSummary.textWithSignals(
            bytes: Int.max, lines: Int.max,
            signals: [.reportedFileWrite(bytes: Int.max),
                .diagnosticErrors(lines: Int.max), .failedTests(lines: Int.max)]
        )
        let event = ConversationEvent(
            id: "typed-output", identity: identity, sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1), kind: .tool,
            status: .succeeded,
            summary: "工具调用：file_write · \(metrics.displaySuffix ?? "")",
            toolName: "file_write", outputSummary: metrics
        )
        #expect(event.summary.count <= ConversationEventRedactor.maximumSummaryLength)
        let encoded = try JSONEncoder().encode(event)
        let restored = try JSONDecoder().decode(ConversationEvent.self, from: encoded)
        #expect(restored.outputSummary == metrics)
        #expect(restored == event)

        var oldObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldObject.removeValue(forKey: "outputSummary")
        let oldBytes = try JSONSerialization.data(withJSONObject: oldObject)
        let oldEvent = try JSONDecoder().decode(ConversationEvent.self, from: oldBytes)
        #expect(oldEvent.outputSummary == nil)
        #expect(oldEvent.summary == event.summary)
    }

    @Test("产品事件展示投影脱敏并限制所有 UI 字段")
    func productDisplayProjectionRedactsMetadataAndBoundsFields() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let event = ConversationEvent(
            id: "tool-display-1",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .failed,
            summary: String(repeating: "summary ", count: 80),
            providerID: "provider-token Authorization: Bearer provider-secret https://provider.example/private",
            modelID: "/Users/alice/private/model-secret",
            toolCallID: "call-display-1",
            receiptID: "receipt-display-1",
            knownSecrets: ["provider-secret"]
        )

        let display = ConversationEventProjection.display(for: event, knownSecrets: ["provider-secret"])

        #expect(display.summary.count <= ConversationEventRedactor.maximumSummaryLength)
        #expect(display.provider.count <= ConversationEventRedactor.maximumFieldLength)
        #expect(display.model.count <= ConversationEventRedactor.maximumFieldLength)
        #expect(display.accessibilityLabel.count <= ConversationEventRedactor.maximumSummaryLength)
        for value in [display.summary, display.provider, display.model, display.accessibilityLabel] {
            #expect(!value.contains("provider-secret"))
            #expect(!value.contains("/Users/alice"))
            #expect(!value.contains("https://"))
        }
    }

    @Test("工具开始、成功、失败保留耗时且终态拒绝迟到结果")
    func toolLifecycleRejectsLateFailureAfterSuccess() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let makeEvent: (Int64, ConversationEventStatus, String, Int?) -> ConversationEvent = {
            sequence, status, summary, elapsedMilliseconds in
            ConversationEvent(
                id: "tool-1",
                identity: identity,
                sequence: sequence,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                kind: .tool,
                status: status,
                summary: summary,
                toolName: "shell_execute",
                toolCallID: "call-shell-1",
                receiptID: "receipt-shell-1",
                elapsedMilliseconds: elapsedMilliseconds,
                errorCategory: status == .failed ? .tool : nil
            )
        }
        let started = makeEvent(1, .running, "工具开始", nil)
        let succeeded = makeEvent(2, .succeeded, "工具完成", 900)
        let lateFailure = makeEvent(3, .failed, "迟到失败", 1_200)

        var projection = ConversationEventProjection()
        let acceptedStarted = projection.ingest(started)
        let acceptedSucceeded = projection.ingest(succeeded)
        let acceptedLateFailure = projection.ingest(lateFailure)

        #expect(acceptedStarted)
        #expect(acceptedSucceeded)
        #expect(!acceptedLateFailure)
        #expect(projection.events.first?.status == .succeeded)
        #expect(projection.events.first?.toolName == "shell_execute")
        #expect(projection.events.first?.elapsedMilliseconds == 900)
        #expect(projection.events.first?.errorCategory == nil)
    }

    @Test("同一 toolCallID 的不同 callback ID 幂等合并并拒绝终态后的迟到回调")
    func toolCallIdentityMakesCallbacksIdempotent() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let started = ConversationEvent(
            id: "callback-started",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .running,
            summary: "工具开始",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-1"
        )
        let duplicateStarted = ConversationEvent(
            id: "callback-started-retry",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .running,
            summary: "重复工具开始",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-1"
        )
        let completed = ConversationEvent(
            id: "callback-completed",
            identity: identity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .tool,
            status: .succeeded,
            summary: "工具完成",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-1",
            elapsedMilliseconds: 12
        )
        let lateFailure = ConversationEvent(
            id: "callback-late-failure",
            identity: identity,
            sequence: 3,
            occurredAt: Date(timeIntervalSince1970: 3),
            kind: .tool,
            status: .failed,
            summary: "迟到失败",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-1",
            errorCategory: .tool
        )

        var projection = ConversationEventProjection()
        let acceptedStarted = projection.ingest(started)
        #expect(acceptedStarted)
        let acceptedDuplicateStarted = projection.ingest(duplicateStarted)
        #expect(!acceptedDuplicateStarted)
        #expect(projection.events.count == 1)
        let acceptedCompleted = projection.ingest(completed)
        #expect(acceptedCompleted)
        let acceptedLateFailure = projection.ingest(lateFailure)
        #expect(!acceptedLateFailure)
        #expect(projection.events.count == 1)
        #expect(projection.events[0].id == "callback-completed")
        #expect(projection.events[0].toolCallID == "call-1")
        #expect(projection.events[0].status == .succeeded)

        let encoded = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(ConversationEventProjection.self, from: encoded)
        #expect(decoded == projection)
    }

    @Test("同一运行时身份的终态拒绝不同 event ID 的迟到结果")
    func terminalIdentityRejectsLateResultWithDifferentEventID() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let terminal = ConversationEvent(
            id: "task-terminal",
            identity: identity,
            sequence: 10,
            occurredAt: Date(timeIntervalSince1970: 10),
            kind: .task,
            status: .cancelled,
            summary: "任务已取消"
        )
        let lateToolResult = ConversationEvent(
            id: "tool-result",
            identity: identity,
            sequence: 11,
            occurredAt: Date(timeIntervalSince1970: 11),
            kind: .tool,
            status: .succeeded,
            summary: "迟到工具结果",
            toolName: "file_read",
            toolCallID: "call-late-1",
            receiptID: "receipt-late-1"
        )

        var projection = ConversationEventProjection()
        let acceptedTerminal = projection.ingest(terminal)
        let acceptedLateToolResult = projection.ingest(lateToolResult)

        #expect(acceptedTerminal)
        #expect(!acceptedLateToolResult)
        #expect(projection.events == [terminal])

        let replayedOutOfOrder = ConversationEventProjection(events: [lateToolResult, terminal])
        #expect(replayedOutOfOrder.events == [terminal])
    }

    @Test("新 attempt 接管后拒绝旧 attempt 的迟到回调")
    func newerAttemptRejectsLateOlderAttempt() throws {
        let firstIdentity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let secondIdentity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 2,
            scopeID: "scope-a"
        ))
        let first = ConversationEvent(
            id: "attempt-1-start",
            identity: firstIdentity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .running,
            summary: "第一次尝试",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-attempt-1"
        )
        let second = ConversationEvent(
            id: "attempt-2-start",
            identity: secondIdentity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .tool,
            status: .running,
            summary: "第二次尝试",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-attempt-2"
        )
        let lateFirst = ConversationEvent(
            id: "attempt-1-late",
            identity: firstIdentity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 3),
            kind: .tool,
            status: .failed,
            summary: "第一次尝试迟到失败",
            toolName: "file_read",
            toolCallID: "call-1",
            receiptID: "receipt-attempt-1",
            errorCategory: .timeout
        )

        var projection = ConversationEventProjection()
        let acceptedFirst = projection.ingest(first)
        #expect(acceptedFirst)
        let acceptedSecond = projection.ingest(second)
        #expect(acceptedSecond)
        let acceptedLateFirst = projection.ingest(lateFirst)
        #expect(!acceptedLateFirst)
        #expect(projection.events.map(\.id) == ["attempt-1-start", "attempt-2-start"])
    }

    @Test("重复终态回放保持单一终态且不自行构造新事件")
    func duplicateTerminalReplayIsIdempotent() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let terminal = ConversationEvent(
            id: "terminal-1",
            identity: identity,
            sequence: 9,
            occurredAt: Date(timeIntervalSince1970: 9),
            kind: .task,
            status: .succeeded,
            summary: "任务完成"
        )
        let replay = ConversationEvent(
            id: "terminal-replay",
            identity: identity,
            sequence: 9,
            occurredAt: Date(timeIntervalSince1970: 9),
            kind: .task,
            status: .succeeded,
            summary: "任务完成回放"
        )

        var projection = ConversationEventProjection()
        let acceptedTerminal = projection.ingest(terminal)
        #expect(acceptedTerminal)
        let acceptedTerminalReplay = projection.ingest(terminal)
        #expect(!acceptedTerminalReplay)
        let acceptedReplay = projection.ingest(replay)
        #expect(!acceptedReplay)
        #expect(projection.events == [terminal])
    }

    @Test("失败生命周期事件持久化冻结 retry envelope 与 toolCall 关联")
    func failedEventRoundTripsRetryEnvelope() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 2,
            scopeID: "scope-a"
        ))
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "session-a",
                turnID: 7,
                messageID: "task-9"
            ),
            operationID: "operation-projection",
            attempt: 2
        )
        let canonicalAttemptID = "attempt-projection-2"
        let projectionCall = LLMToolCall(
            id: "call-projection-1",
            name: "file_read",
            rawArguments: "{\"path\":\"/tmp/frozen\"}",
            arguments: ["path": "/tmp/frozen"]
        )
        let projectionFact = ToolExecutionFact(
            toolCallID: projectionCall.id,
            receiptID: "receipt-projection-1",
            toolName: projectionCall.name,
            status: .succeeded,
            attemptID: canonicalAttemptID,
            attemptNumber: 2,
            executionIdentity: executionIdentity,
            compositeKey: ToolExecutionCompositeKey(
                sessionID: "session-a",
                turnID: 7,
                messageID: "task-9",
                operationID: "operation-projection",
                attemptID: canonicalAttemptID,
                attemptNumber: 2,
                toolCallID: projectionCall.id
            )
        )
        let envelope = ChatRetryEnvelope(
            envelopeID: "retry-envelope-projection",
            inputText: "原始失败消息",
            sessionID: "session-a",
            conversationID: "conversation-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 2,
            providerID: "provider-original",
            modelID: "model-original",
            configurationFingerprint: "provider-config:frozen",
            policySnapshotID: "policy-original",
            grantSnapshotID: "grant-original",
            executionIdentity: executionIdentity,
            canonicalAttemptID: canonicalAttemptID,
            toolCalls: [projectionCall],
            partialMessages: [
                LLMMessage(role: .user, content: "原始失败消息"),
                LLMMessage(role: .assistant, content: "", toolCalls: [projectionCall]),
                LLMMessage(role: .tool, content: "冻结文件内容", toolCallID: projectionCall.id),
            ],
            toolExecutionFacts: [projectionFact],
            failureMessage: "服务请求失败",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let failed = ConversationEvent(
            id: "failure-event",
            identity: identity,
            sequence: 4,
            occurredAt: Date(timeIntervalSince1970: 20),
            kind: .task,
            status: .failed,
            summary: "失败，可重试",
            retryEnvelope: envelope
        )

        let projection = ConversationEventProjection(events: [failed])
        let data = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(ConversationEventProjection.self, from: data)

        #expect(decoded == projection)
        #expect(decoded.events.first?.retryEnvelope?.taskID == "task-9")
        #expect(decoded.events.first?.retryEnvelope?.toolCallIDs == ["call-projection-1"])
        #expect(decoded.events.first?.retryEnvelope?.policySnapshotID == "policy-original")
        #expect(decoded.events.first?.retryEnvelope?.grantSnapshotID == "grant-original")
        #expect(decoded.events.first?.retryEnvelope?.executionIdentity == executionIdentity)
        #expect(decoded.events.first?.retryEnvelope?.canonicalAttemptID == canonicalAttemptID)
        #expect(decoded.events.first?.retryEnvelope?.identityBinding == envelope.identityBinding)
    }

    @Test("失败事件拒绝与 session/turn/task/attempt 不匹配的 retry envelope")
    func failedEventRejectsMismatchedRetryEnvelopeIdentity() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-event",
            turnID: "turn-event",
            taskID: "task-event",
            attempt: 2,
            scopeID: "scope-event"
        ))
        let envelope = ChatRetryEnvelope(
            envelopeID: "mismatch-envelope",
            inputText: "失败",
            sessionID: "session-other",
            conversationID: "conversation-other",
            turnID: "turn-other",
            taskID: "task-other",
            attempt: 1,
            providerID: "provider",
            modelID: "model",
            configurationFingerprint: "fingerprint",
            policySnapshotID: "policy",
            grantSnapshotID: "grant",
            failureMessage: "failed"
        )
        let event = ConversationEvent(
            id: "mismatch-failure",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .task,
            status: .failed,
            summary: "失败",
            retryEnvelope: envelope
        )

        var projection = ConversationEventProjection()
        let acceptedEvent = projection.ingest(event)
        #expect(!acceptedEvent)
        #expect(projection.events.isEmpty)
    }

    @Test("工具 lifecycle 使用 canonical toolCallID/attempt/receipt 并提供只读投影")
    func structuredToolLifecycleUsesCanonicalFacts() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-tools",
            taskID: "task-tools",
            attempt: 2,
            scopeID: "scope-a"
        ))
        func event(
            id: String,
            sequence: Int64,
            status: ConversationEventStatus,
            summary: String
        ) -> ConversationEvent {
            ConversationEvent(
                id: id,
                identity: identity,
                sequence: sequence,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                kind: .tool,
                status: status,
                summary: summary,
                toolName: "file_read",
                toolCallID: "call-structured-1",
                receiptID: "tool-receipt-1"
            )
        }

        let requested = event(id: "tool-requested", sequence: 1, status: .requested, summary: "已请求")
        let duplicateRequested = event(id: "tool-requested-replay", sequence: 1, status: .requested, summary: "重复请求")
        let running = event(id: "tool-running", sequence: 2, status: .running, summary: "执行中")
        let succeeded = event(id: "tool-succeeded", sequence: 3, status: .succeeded, summary: "执行完成")
        let lateFailure = event(id: "tool-late-failure", sequence: 4, status: .failed, summary: "迟到失败")
        let blocked = ConversationEvent(
            id: "tool-blocked",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .blocked,
            summary: "被阻断",
            toolName: "file_write",
            toolCallID: "call-structured-2",
            receiptID: "tool-receipt-2"
        )
        let cancelled = ConversationEvent(
            id: "tool-cancelled",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .cancelled,
            summary: "已取消",
            toolName: "web_search",
            toolCallID: "call-structured-3",
            receiptID: "tool-receipt-3"
        )
        let failed = ConversationEvent(
            id: "tool-failed",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .failed,
            summary: "执行失败",
            toolName: "file_delete",
            toolCallID: "call-structured-4",
            receiptID: "tool-receipt-4",
            errorCategory: .tool
        )

        var projection = ConversationEventProjection()
        let acceptedRequested = projection.ingest(requested)
        #expect(acceptedRequested)
        let acceptedDuplicateRequested = projection.ingest(duplicateRequested)
        #expect(!acceptedDuplicateRequested)
        let acceptedRunning = projection.ingest(running)
        #expect(acceptedRunning)
        let acceptedSucceeded = projection.ingest(succeeded)
        #expect(acceptedSucceeded)
        let acceptedBlocked = projection.ingest(blocked)
        #expect(acceptedBlocked)
        let acceptedCancelled = projection.ingest(cancelled)
        #expect(acceptedCancelled)
        let acceptedFailed = projection.ingest(failed)
        #expect(acceptedFailed)
        let acceptedLateFailure = projection.ingest(lateFailure)
        #expect(!acceptedLateFailure)
        #expect(projection.toolLifecycleEvents.map(\.status) == [
            .blocked,
            .cancelled,
            .failed,
            .succeeded,
        ])
        let succeededFact = try #require(
            projection.toolLifecycleEvents.first { $0.toolCallID == "call-structured-1" }
        )
        #expect(succeededFact.identity.attempt == 2)
        #expect(succeededFact.receiptID == "tool-receipt-1")

        let data = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(ConversationEventProjection.self, from: data)
        #expect(decoded == projection)
    }

    @Test("approval history 只读保留 canonical receipt/decision 并幂等拒绝重复回放")
    func approvalHistoryProjectsReceiptFacts() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-approval",
            taskID: "task-approval",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let requested = ConversationEvent(
            id: "approval-requested",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .approval,
            status: .requested,
            summary: "等待审批",
            toolName: "file_write",
            toolCallID: "call-approval-1",
            receiptID: "approval-receipt-1",
            approvalDecision: .requested
        )
        let denied = ConversationEvent(
            id: "approval-denied",
            identity: identity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .approval,
            status: .failed,
            summary: "审批拒绝",
            toolName: "file_write",
            toolCallID: "call-approval-1",
            receiptID: "approval-receipt-2",
            approvalDecision: .denied,
            errorCategory: .authorization
        )
        let duplicateDenied = ConversationEvent(
            id: "approval-denied-replay",
            identity: identity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .approval,
            status: .failed,
            summary: "审批拒绝回放",
            toolName: "file_write",
            toolCallID: "call-approval-1",
            receiptID: "approval-receipt-2",
            approvalDecision: .denied,
            errorCategory: .authorization
        )

        var projection = ConversationEventProjection()
        let acceptedRequested = projection.ingest(requested)
        #expect(acceptedRequested)
        let acceptedDenied = projection.ingest(denied)
        #expect(acceptedDenied)
        let acceptedDuplicateDenied = projection.ingest(duplicateDenied)
        #expect(!acceptedDuplicateDenied)
        #expect(projection.approvalHistory.count == 2)
        #expect(projection.approvalHistory.map(\.receiptID) == [
            "approval-receipt-1",
            "approval-receipt-2",
        ])
        #expect(projection.approvalHistory.map(\.approvalDecision) == [.requested, .denied])

        let data = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(ConversationEventProjection.self, from: data)
        #expect(decoded.approvalHistory == projection.approvalHistory)
    }

    @Test("模型切换保留前后模型、耗时和审批复核状态")
    func modelDurationAndReviewFieldsAreStructured() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let modelSwitch = ConversationEvent(
            id: "model-switch",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .modelSwitch,
            status: .succeeded,
            summary: "模型已切换",
            providerID: "provider-a",
            fromModelID: "model-old",
            toModelID: "model-new"
        )
        let duration = ConversationEvent(
            id: "duration",
            identity: identity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .duration,
            status: .succeeded,
            summary: "运行耗时",
            elapsedMilliseconds: 1_250
        )
        let review = ConversationEvent(
            id: "approval",
            identity: identity,
            sequence: 3,
            occurredAt: Date(timeIntervalSince1970: 3),
            kind: .approval,
            status: .needsReview,
            summary: "需要用户复核",
            toolName: "file_write",
            toolCallID: "call-review-1",
            receiptID: "receipt-review-1",
            approvalDecision: .requested,
            errorCategory: .review
        )

        let projection = ConversationEventProjection(events: [review, duration, modelSwitch])

        #expect(projection.events[0].fromModelID == "model-old")
        #expect(projection.events[0].toModelID == "model-new")
        #expect(projection.events[1].elapsedMilliseconds == 1_250)
        #expect(projection.events[2].status == .needsReview)
        #expect(projection.events[2].toolName == "file_write")
        #expect(projection.events[2].errorCategory == .review)
    }

    @Test("缺少 canonical toolCallID 或 receipt 的工具审批事实拒绝写入")
    func nonCanonicalFactsAreRejectedBeforeEventIDFallback() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-canonical",
            taskID: "task-canonical",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let missingToolCallID = ConversationEvent(
            id: "tool-missing-call-id",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .tool,
            status: .requested,
            summary: "缺 call ID",
            receiptID: "receipt-canonical-1"
        )
        let missingReceipt = ConversationEvent(
            id: "tool-missing-receipt",
            identity: identity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .tool,
            status: .running,
            summary: "缺 receipt",
            toolCallID: "call-canonical-2"
        )
        let missingApprovalDecision = ConversationEvent(
            id: "approval-missing-decision",
            identity: identity,
            sequence: 3,
            occurredAt: Date(timeIntervalSince1970: 3),
            kind: .approval,
            status: .requested,
            summary: "缺审批决策",
            toolCallID: "call-canonical-3",
            receiptID: "receipt-canonical-3"
        )

        var projection = ConversationEventProjection()
        let acceptedMissingToolCallID = projection.ingest(missingToolCallID)
        #expect(!acceptedMissingToolCallID)
        let acceptedMissingReceipt = projection.ingest(missingReceipt)
        #expect(!acceptedMissingReceipt)
        let acceptedMissingApprovalDecision = projection.ingest(missingApprovalDecision)
        #expect(!acceptedMissingApprovalDecision)
        #expect(projection.events.isEmpty)
    }

    @Test("空身份、冲突身份和过期序列均拒绝写回")
    func invalidOrConflictingWritebacksAreRejected() throws {
        #expect(ConversationEventIdentity(
            sessionID: " ",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ) == nil)
        #expect(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 0,
            scopeID: "scope-a"
        ) == nil)

        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let otherIdentity = try #require(ConversationEventIdentity(
            sessionID: "session-b",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let first = ConversationEvent(
            id: "same-event",
            identity: identity,
            sequence: 2,
            occurredAt: Date(timeIntervalSince1970: 2),
            kind: .thinking,
            status: .running,
            summary: "第一条"
        )
        let conflicting = ConversationEvent(
            id: "same-event",
            identity: otherIdentity,
            sequence: 3,
            occurredAt: Date(timeIntervalSince1970: 3),
            kind: .thinking,
            status: .running,
            summary: "不同会话"
        )
        let stale = ConversationEvent(
            id: "same-event",
            identity: identity,
            sequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1),
            kind: .thinking,
            status: .running,
            summary: "过期事件"
        )

        var projection = ConversationEventProjection()
        let acceptedFirst = projection.ingest(first)
        let acceptedConflict = projection.ingest(conflicting)
        let acceptedStale = projection.ingest(stale)

        #expect(acceptedFirst)
        #expect(!acceptedConflict)
        #expect(!acceptedStale)
        #expect(projection.events == [first])
    }

    @Test("投影是可发送、可编码且按序列确定性回放的值")
    func projectionIsSendableCodableAndDeterministic() throws {
        let identity = try #require(ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ))
        let events = [
            ConversationEvent(
                id: "second",
                identity: identity,
                sequence: 2,
                occurredAt: Date(timeIntervalSince1970: 2),
                kind: .duration,
                status: .running,
                summary: "第二条"
            ),
            ConversationEvent(
                id: "first",
                identity: identity,
                sequence: 1,
                occurredAt: Date(timeIntervalSince1970: 1),
                kind: .thinking,
                status: .running,
                summary: "第一条"
            ),
        ]

        let projection = ConversationEventProjection(events: events)
        let sendableCapture: @Sendable () -> ConversationEventProjection = { projection }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sendableCapture())
        let decoded = try JSONDecoder().decode(ConversationEventProjection.self, from: data)

        #expect(decoded == projection)
        #expect(projection.events.map(\.id) == ["first", "second"])
    }
}
