import Foundation
import Testing
@testable import MinisCore

@Suite("M04 canonical tool phase consumer")
struct P3AcceptanceM04_ToolLifecyclePhaseConsumerTests {
    private func fixture() -> (
        AgentExecutionIdentity,
        ToolExecutionCompositeKey,
        ToolExecutionFact
    ) {
        let execution = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "session-a", turnID: 7, messageID: "message-a"),
            operationID: "operation-a",
            attempt: 1
        )
        let key = ToolExecutionCompositeKey(
            sessionID: "session-a",
            turnID: 7,
            messageID: "message-a",
            operationID: "operation-a",
            attemptID: "attempt-a",
            attemptNumber: 1,
            toolCallID: "call-a"
        )
        let fact = ToolExecutionFact(
            toolCallID: "call-a",
            receiptID: "receipt-a",
            toolName: "file_read",
            status: .succeeded,
            attemptID: "attempt-a",
            attemptNumber: 1,
            executionIdentity: execution,
            compositeKey: key,
            elapsedMilliseconds: 42
        )
        return (execution, key, fact)
    }

    @Test("queued and running share one journal record with terminal receipt and duration")
    func phaseThenTerminal() async {
        let (execution, key, fact) = fixture()
        let consumer = ToolLifecycleConsumer()
        let queued = ToolExecutionPhaseFact(
            compositeKey: key, executionIdentity: execution, toolName: "file_read",
            phase: .queued, occurredAt: Date(timeIntervalSince1970: 1)
        )
        let running = ToolExecutionPhaseFact(
            compositeKey: key, executionIdentity: execution, toolName: "file_read",
            phase: .running, occurredAt: Date(timeIntervalSince1970: 2)
        )
        #expect(await consumer.ingestToolExecutionPhase(
            queued, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        ))
        #expect(consumer.events.count == 1)
        #expect(consumer.events.first?.status == .queued)
        #expect(consumer.events.first?.receiptID == nil)
        #expect(await consumer.ingestToolExecutionPhase(
            running, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        ))
        #expect(consumer.events.count == 1)
        #expect(consumer.events.first?.status == .running)
        #expect(await consumer.ingestToolExecutionFact(
            fact, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a",
            occurredAt: Date(timeIntervalSince1970: 3)
        ))
        #expect(consumer.events.count == 1)
        #expect(consumer.events.first?.status == .succeeded)
        #expect(consumer.events.first?.receiptID == "receipt-a")
        #expect(consumer.events.first?.elapsedMilliseconds == 42)
        #expect(!(await consumer.ingestToolExecutionPhase(
            queued, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        )))
    }

    @Test("phase identity and order reject stale or forged progress")
    func phaseIdentityAndOrder() async {
        let (execution, key, _) = fixture()
        let consumer = ToolLifecycleConsumer()
        let running = ToolExecutionPhaseFact(
            compositeKey: key, executionIdentity: execution, toolName: "file_read",
            phase: .running, occurredAt: Date(timeIntervalSince1970: 2)
        )
        #expect(!(await consumer.ingestToolExecutionPhase(
            running, eventID: "other-call", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        )))
        let queued = ToolExecutionPhaseFact(
            compositeKey: key, executionIdentity: execution, toolName: "file_read",
            phase: .queued, occurredAt: Date(timeIntervalSince1970: 1)
        )
        #expect(await consumer.ingestToolExecutionPhase(
            queued, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        ))
        #expect(await consumer.ingestToolExecutionPhase(
            running, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        ))
        #expect(!(await consumer.ingestToolExecutionPhase(
            queued, eventID: "call-a", eventName: "file_read", taskID: "task-a",
            expectedAttemptID: "attempt-a", scopeID: "scope-a"
        )))
        #expect(consumer.events.first?.status == .running)
    }

    @Test("old fact JSON without duration decodes as unknown")
    func oldFactHasNoDuration() throws {
        let (_, _, fact) = fixture()
        let encoded = try JSONEncoder().encode(fact)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "elapsedMilliseconds")
        let oldJSON = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(ToolExecutionFact.self, from: oldJSON)
        #expect(restored.elapsedMilliseconds == nil)
    }
}

@Suite("M04 observed approval lifecycle")
struct P3AcceptanceM04_ApprovalLifecycleConsumerTests {
    private func fixture() -> (ApprovalPresentationContext, ApprovalRequest) {
        let execution = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "session-a", turnID: 7, messageID: "message-a"),
            operationID: "operation-a", attempt: 1
        )
        let key = ToolExecutionCompositeKey(
            sessionID: "session-a", turnID: 7, messageID: "message-a",
            operationID: "operation-a", attemptID: "operation-a:attempt:1",
            attemptNumber: 1, toolCallID: "call-a"
        )
        let context = ApprovalPresentationContext(
            compositeKey: key, executionIdentity: execution,
            toolName: "file_write", eventSink: { _ in }
        )
        return (context, request())
    }

    private func request(
        sessionID: String = "session-a",
        turnID: Int = 7,
        messageID: String = "operation-a",
        runID: String = "operation-a",
        attemptID: String = "operation-a:attempt:1",
        callID: String = "call-a",
        toolName: String = "file_write",
        identityDigest: String? = nil
    ) -> ApprovalRequest {
        let bound = ApprovalAuthorizationContext(
            actorID: "actor-a", sessionID: sessionID, turnID: turnID,
            taskID: "task-a", runID: runID, attemptID: attemptID,
            effectID: callID, scope: "request", payloadDigest: "payload-a",
            expiresAt: Date(timeIntervalSince1970: 1000),
            policyRevision: "policy-a", grantEpoch: "generation-a", toolName: toolName
        )
        return ApprovalRequest(
            id: "request-a", requestID: "request-a", callID: callID,
            toolName: toolName, inputSummary: "synthetic input", riskLevel: .high,
            requiresApproval: true, sessionID: sessionID, turnID: turnID,
            taskID: "task-a", attemptID: attemptID, approvalScope: "request",
            messageID: messageID, policyRevision: bound.policyRevision,
            grantEpoch: bound.grantEpoch, inputDigest: bound.payloadDigest,
            identityDigest: identityDigest ?? bound.identityDigest,
            actorID: bound.actorID, runID: runID, effectID: callID,
            expiresAt: bound.expiresAt
        )
    }

    private func fact(
        _ context: ApprovalPresentationContext,
        _ request: ApprovalRequest,
        _ stage: ApprovalLifecycleStage,
        at second: TimeInterval
    ) throws -> ApprovalLifecycleFact {
        try #require(context.makeFact(
            for: request, stage: stage,
            occurredAt: Date(timeIntervalSince1970: second)
        ))
    }

    @Test("an authority result cannot invent UI waiting; real pending then denial is one record")
    func presentedThenDenied() async throws {
        let (context, request) = fixture()
        let consumer = ToolLifecycleConsumer()
        let denied = try fact(context, request, .authorityDenied, at: 11)
        #expect(!(await consumer.ingestApprovalLifecycleFact(denied)))
        #expect(consumer.events.isEmpty)
        let presented = try fact(context, request, .presented, at: 10)
        #expect(await consumer.ingestApprovalLifecycleFact(presented))
        #expect(consumer.events.count == 1)
        #expect(consumer.events.first?.status == .waiting)
        #expect(consumer.events.first?.approvalDecision == .requested)
        #expect(consumer.toolLifecycleEvents.isEmpty)
        #expect(await consumer.ingestApprovalLifecycleFact(denied))
        #expect(consumer.events.count == 1)
        #expect(consumer.events.first?.status == .failed)
        #expect(consumer.events.first?.approvalDecision == .denied)
        #expect(consumer.toolLifecycleEvents.isEmpty)
        #expect(!(await consumer.ingestApprovalLifecycleFact(presented)))
        #expect(!(await consumer.ingestApprovalLifecycleFact(denied)))
    }

    /// 用户 11/21 会话 BE8372C4：审批卡过期后查不到拦的是哪条命令；审批事件要带上脱敏的目标摘要。
    @Test("approval events keep the redacted target so an expired card can be traced")
    func approvalEventsKeepTheRedactedTarget() async throws {
        let (context, request) = fixture()
        let consumer = ToolLifecycleConsumer()
        let display = "cd [local path] && rm -rf render"
        #expect(await consumer.ingestApprovalLifecycleFact(try fact(context, request, .presented, at: 10),
                                                           targetDisplay: display))
        #expect(consumer.events.first?.toolTargetDisplay == display)
        #expect(await consumer.ingestApprovalLifecycleFact(try fact(context, request, .authorityExpired, at: 11),
                                                           targetDisplay: display))
        #expect(consumer.events.first?.status == .failed)
        #expect(consumer.events.first?.toolTargetDisplay == display)
    }

    @Test("only the frozen session, turn, message, operation, attempt, call and digest map")
    func exactRequestBinding() {
        let (context, _) = fixture()
        let now = Date(timeIntervalSince1970: 10)
        #expect(context.makeFact(for: request(sessionID: "other"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(turnID: 8), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(messageID: "other"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(runID: "other"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(attemptID: "other"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(callID: "other"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(toolName: "shell_execute"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(identityDigest: "wrong"), stage: .presented, occurredAt: now) == nil)
        #expect(context.makeFact(for: request(), stage: .presented, occurredAt: Date(timeIntervalSince1970: 1001)) == nil)
    }

    @Test("cancel and revoke remain distinct; neither creates a tool execution receipt")
    func cancellationAndRevocation() async throws {
        let (context, request) = fixture()
        for (stage, expected, expectedStatus) in [
            (ApprovalLifecycleStage.authorityExpired, ConversationApprovalDecision.expired, ConversationEventStatus.failed),
            (.authorityCancelled, .cancelled, .cancelled),
            (.authorityRevoked, .revoked, .blocked),
        ] {
            let consumer = ToolLifecycleConsumer()
            let presented = try fact(context, request, .presented, at: 10)
            let terminal = try fact(context, request, stage, at: 11)
            #expect(await consumer.ingestApprovalLifecycleFact(presented))
            #expect(await consumer.ingestApprovalLifecycleFact(terminal))
            #expect(consumer.events.first?.approvalDecision == expected)
            #expect(consumer.events.first?.status == expectedStatus)
            #expect(consumer.toolLifecycleEvents.isEmpty)
        }
    }

    @Test("Gate and Composer requests on one call keep separate digests and decisions")
    func distinctRequestsOnSameCompositeKey() async throws {
        let (context, gateRequest) = fixture()
        let consumer = ToolLifecycleConsumer()
        let gatePresented = try fact(context, gateRequest, .presented, at: 10)
        let gateDenied = try fact(context, gateRequest, .authorityDenied, at: 11)
        #expect(await consumer.ingestApprovalLifecycleFact(gatePresented))
        #expect(await consumer.ingestApprovalLifecycleFact(gateDenied))
        let composerRequest = ApprovalRequest(
            id: "request-a", requestID: "request-a", callID: "call-a",
            toolName: "file_write", inputSummary: "synthetic input", riskLevel: .high,
            requiresApproval: true, sessionID: "session-a", turnID: 7,
            taskID: "task-a", attemptID: "operation-a:attempt:1",
            approvalScope: "request", composerMode: "plan",
            messageID: "message-a", identityDigest: "composer-digest"
        )
        let composerPresented = try fact(context, composerRequest, .presented, at: 12)
        let composerCancelled = try fact(context, composerRequest, .authorityCancelled, at: 13)
        #expect(await consumer.ingestApprovalLifecycleFact(composerPresented))
        #expect(await consumer.ingestApprovalLifecycleFact(composerCancelled))
        #expect(consumer.events.count == 2)
        #expect(Set(consumer.events.map(\.id)).count == 2)
        #expect(Set(consumer.events.compactMap(\.approvalIdentityDigest))
            == Set([gatePresented.identityDigest, composerPresented.identityDigest]))
        #expect(!(await consumer.ingestApprovalLifecycleFact(gatePresented)))
        #expect(consumer.toolLifecycleEvents.isEmpty)
    }

    @Test("durable orphaned waiting is explicitly closed on new startup, never approved")
    func recoveredPendingIsInterrupted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-approval-recovery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("journal")) }
        let (context, request) = fixture()
        let first = try ToolLifecycleConsumer(persistenceURL: url)
        let presented = try fact(context, request, .presented, at: 10)
        #expect(await first.ingestApprovalLifecycleFact(presented))
        let restarted = try ToolLifecycleConsumer(persistenceURL: url)
        #expect(restarted.events.first?.status == .waiting)
        #expect(await restarted.invalidateRecoveredApprovalWaiting() == 1)
        #expect(restarted.events.first?.status == .stopped)
        #expect(restarted.events.first?.approvalDecision == .interrupted)
        #expect(restarted.toolLifecycleEvents.isEmpty)
        let loadedAgain = try ToolLifecycleConsumer(persistenceURL: url)
        #expect(loadedAgain.events.first?.status == .stopped)
        #expect(loadedAgain.events.first?.approvalDecision != .approved)
        let staleApproval = try fact(context, request, .authorityApproved, at: 11)
        #expect(!(await loadedAgain.ingestApprovalLifecycleFact(staleApproval)))
    }
}
