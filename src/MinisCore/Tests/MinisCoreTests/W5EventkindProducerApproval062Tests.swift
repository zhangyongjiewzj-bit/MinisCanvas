import Foundation
import Testing
@testable import MinisCore

// Lane W5-EVENTKIND-PRODUCER-062: `.approval` had a projection contract and an
// `approvalHistory` reader, but the only production `ConversationEvent`
// construction site in the repository emitted `kind: .tool`
// (ToolLifecycleConsumer.ingestOnWriter). A kind with no producer can never
// render and can never be audited. These tests pin the producer half:
//   * every terminal approval decision (approved / denied / expired /
//     cancelled) publishes exactly one `.approval` event with its decision,
//     status and error category,
//   * the non-terminal L3 "needs review" fact stays non-terminal and can still
//     advance once the user confirms,
//   * pairs the approval gate itself would not honor publish nothing at all,
//   * fields an approval fact cannot carry (elapsed, retry envelope, provider,
//     model, error category on success) stay nil instead of being fabricated.

@Suite("W5-062 approval event producer")
struct W5EventkindProducerApproval062Tests {

    // MARK: - Terminal decisions

    @Test("审批通过产生 terminal .approval 事件且 approvalHistory 有生产消费者")
    func approvedDecisionProjectsTerminalApprovalEvent() async throws {
        let consumer = ToolLifecycleConsumer()
        let request = makeRequest(callID: "call-approved-1", requestID: "approval-1")
        let decision = ApprovalDecision(
            approved: true,
            reason: "Approved",
            confirmed: true,
            requestID: "approval-1"
        )

        let accepted = await consumer.ingestApprovalDecision(
            decision,
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 100)
        )
        #expect(accepted)

        // The previously dead reader now has production content.
        let history = consumer.readOnlyProjection.approvalHistory
        #expect(history.count == 1)
        let event = try #require(history.first)
        #expect(event.kind == .approval)
        #expect(event.status == .succeeded)
        #expect(event.status.isTerminal)
        #expect(event.approvalDecision == .approved)
        #expect(event.receiptID == "approval-1")
        #expect(event.toolCallID == "call-approved-1")
        #expect(event.toolName == "file_write")
        #expect(event.identity.sessionID == "session-one")
        #expect(event.identity.turnID == "7")
        #expect(event.identity.taskID == "task-one")
        #expect(event.identity.attempt == 1)
        #expect(event.identity.scopeID == "scope-one")
        #expect(event.summary == "审批通过：file_write")

        let display = ConversationEventProjection.display(for: event)
        #expect(display.kindLabel == "审批")
        #expect(display.statusLabel == "完成")
        #expect(display.errorCategory == nil)

        // Tool projection and approval history stay separate views.
        #expect(consumer.toolLifecycleEvents.isEmpty)
        #expect(consumer.readOnlyProjection.toolLifecycleEvents.isEmpty)
    }

    @Test("审批拒绝产生 failed .approval 事件并带 authorization 类别")
    func deniedDecisionProjectsFailureEvent() async throws {
        let consumer = ToolLifecycleConsumer()
        let request = makeRequest(callID: "call-denied-1", requestID: "approval-deny")
        let decision = ApprovalDecision(
            approved: false,
            reason: "不要写入 /Users/me/secret sk-abcdefghijklmnop",
            requestID: "approval-deny"
        )

        let accepted = await consumer.ingestApprovalDecision(
            decision,
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 101)
        )
        #expect(accepted)
        let event = try #require(consumer.readOnlyProjection.approvalHistory.first)
        #expect(event.status == .failed)
        #expect(event.status.isTerminal)
        #expect(event.approvalDecision == .denied)
        #expect(event.errorCategory == .authorization)
        #expect(event.summary == "审批拒绝：file_write")
        // A decision reason is user text and never enters the audited summary.
        #expect(!event.summary.contains("sk-abcdefghijklmnop"))
        #expect(!event.summary.contains("secret"))
    }

    @Test("审批过期与审批取消各自产生对应的 terminal 事实")
    func expiredAndCancelledDecisionsKeepTheirOwnFacts() async throws {
        let consumer = ToolLifecycleConsumer()
        let expiredRequest = makeRequest(callID: "call-expired", requestID: "approval-expired")
        let acceptedExpired = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: false, status: .expired, requestID: "approval-expired"),
            for: expiredRequest,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 102)
        )
        #expect(acceptedExpired)
        let cancelledRequest = makeRequest(callID: "call-cancelled", requestID: "approval-cancelled")
        let acceptedCancelled = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: false, status: .cancelled, requestID: "approval-cancelled"),
            for: cancelledRequest,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 103)
        )
        #expect(acceptedCancelled)

        let history = consumer.readOnlyProjection.approvalHistory
        #expect(history.map(\.approvalDecision) == [.expired, .cancelled])
        #expect(history.map(\.status) == [.failed, .cancelled])
        #expect(history.map(\.errorCategory) == [.timeout, .cancelled])
        #expect(history.map(\.summary) == ["审批已过期：file_write", "审批已取消：file_write"])
    }

    // MARK: - Non-terminal decision

    @Test("L3 缺少二次确认只记录 needsReview，不记录为已通过")
    func unconfirmedSecondConfirmationStaysNonTerminal() async throws {
        let consumer = ToolLifecycleConsumer()
        let request = makeRequest(
            callID: "call-l3",
            requestID: "approval-l3",
            requiresSecondConfirmation: true
        )
        let decision = ApprovalDecision(
            approved: true,
            reason: "Approved",
            confirmed: false,
            requestID: "approval-l3"
        )

        let accepted = await consumer.ingestApprovalDecision(
            decision,
            for: request,
            attempt: 2,
            occurredAt: Date(timeIntervalSince1970: 104)
        )
        #expect(accepted)
        let event = try #require(consumer.readOnlyProjection.approvalHistory.first)
        #expect(event.approvalDecision == .requested)
        #expect(event.status == .needsReview)
        #expect(!event.status.isTerminal)
        #expect(event.errorCategory == .review)
        #expect(event.identity.attempt == 2)
        #expect(
            ConversationEventProjection.display(for: event).statusLabel == "需要复核"
        )

        // The same receipt identity can later advance once the user confirms.
        let confirmedAccepted = await consumer.ingestApprovalDecision(
            ApprovalDecision(
                approved: true,
                confirmed: true,
                requestID: "approval-l3"
            ),
            for: request,
            attempt: 2,
            occurredAt: Date(timeIntervalSince1970: 105)
        )
        #expect(confirmedAccepted)
        let history = consumer.readOnlyProjection.approvalHistory
        #expect(history.count == 1)
        #expect(history.first?.status == .succeeded)
        #expect(history.first?.approvalDecision == .approved)
    }

    // MARK: - No fabricated values

    @Test("审批事件不携带耗时与重试信封")
    func approvalEventsCarryNoElapsedOrRetryEnvelope() async throws {
        let consumer = ToolLifecycleConsumer()
        let request = makeRequest(callID: "call-nil-fields", requestID: "approval-nil")
        let accepted = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-nil"),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 106)
        )
        #expect(accepted)
        let event = try #require(consumer.readOnlyProjection.approvalHistory.first)
        #expect(event.elapsedMilliseconds == nil)
        #expect(event.retryEnvelope == nil)
        #expect(event.providerID == nil)
        #expect(event.modelID == nil)
        #expect(event.fromModelID == nil)
        #expect(event.toModelID == nil)
        #expect(
            ConversationEventProjection.display(for: event).elapsed == "未记录"
        )
    }

    @Test("未要求审批的调用与身份不全的历史请求不产生任何事件")
    func unaskedAndIdentityLessRequestsPublishNothing() async throws {
        let consumer = ToolLifecycleConsumer()

        let neverGated = makeRequest(
            callID: "call-ungated",
            requestID: "approval-ungated",
            requiresApproval: false
        )
        let acceptedUnasked = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-ungated"),
            for: neverGated,
            attempt: 1
        )
        #expect(!acceptedUnasked)

        // A legacy request without conversation identity must not gain one.
        let legacy = ApprovalRequest(
            id: "call-legacy",
            toolName: "file_write",
            inputSummary: "写入文件",
            riskLevel: .medium,
            requiresApproval: true
        )
        let acceptedLegacy = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true),
            for: legacy,
            attempt: 1
        )
        #expect(!acceptedLegacy)

        let acceptedZeroAttempt = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-zero"),
            for: makeRequest(callID: "call-zero", requestID: "approval-zero"),
            attempt: 0
        )
        #expect(!acceptedZeroAttempt)

        let acceptedLoopIdentity = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-loop"),
            for: makeRequest(callID: "agent-loop", requestID: "approval-loop"),
            attempt: 1
        )
        #expect(!acceptedLoopIdentity)

        #expect(consumer.events.isEmpty)
        #expect(consumer.readOnlyProjection.approvalHistory.isEmpty)
    }

    @Test("gate 不会承认的审批配对一律不投影")
    func pairThatTheGateWouldNotHonorPublishesNothing() async throws {
        let consumer = ToolLifecycleConsumer()
        let request = makeRequest(callID: "call-mismatch", requestID: "approval-real")

        // Decision names a different request.
        let acceptedForeignRequestID = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-other"),
            for: request,
            attempt: 1
        )
        #expect(!acceptedForeignRequestID)

        // Decision carries a digest the request never had.
        let acceptedForeignDigest = await consumer.ingestApprovalDecision(
            ApprovalDecision(
                approved: true,
                confirmed: true,
                requestID: "approval-real",
                bindingDigest: String(repeating: "0", count: 64)
            ),
            for: request,
            attempt: 1
        )
        #expect(!acceptedForeignDigest)

        // Contradictory pair: approved flag with a non-approved status.
        let acceptedContradiction = await consumer.ingestApprovalDecision(
            ApprovalDecision(
                approved: true,
                confirmed: true,
                status: .denied,
                requestID: "approval-real"
            ),
            for: request,
            attempt: 1
        )
        #expect(!acceptedContradiction)

        // A grant that had already expired at the event time is not an approval.
        let expiring = makeRequest(
            callID: "call-expiring",
            requestID: "approval-expiring",
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let acceptedAfterExpiry = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-expiring"),
            for: expiring,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 200)
        )
        #expect(!acceptedAfterExpiry)

        // `.revoked` has no faithful ConversationApprovalDecision case.
        let acceptedRevoked = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: false, status: .revoked, requestID: "approval-real"),
            for: request,
            attempt: 1
        )
        #expect(!acceptedRevoked)

        #expect(consumer.events.isEmpty)
    }

    @Test("durable 请求必须携带 gate 授权的 request/digest 配对")
    func boundRequestRequiresItsOwnDigest() async throws {
        let context = ApprovalAuthorizationContext(
            actorID: "actor-one",
            sessionID: "session-one",
            turnID: 7,
            taskID: "task-one",
            runID: "run-one",
            attemptID: "attempt-one",
            effectID: "effect-one",
            scope: "scope-one",
            payloadDigest: "digest-payload",
            expiresAt: Date(timeIntervalSince1970: 10_000),
            policyRevision: "policy-1",
            grantEpoch: "epoch-1",
            toolName: "file_write"
        )
        let request = ApprovalRequest(
            id: "effect-one",
            requestID: "approval-bound",
            callID: "call-bound",
            toolName: "file_write",
            inputSummary: "写入文件",
            riskLevel: .high,
            requiresApproval: true,
            requiresSecondConfirmation: true,
            sessionID: context.sessionID,
            turnID: context.turnID,
            taskID: context.taskID,
            attemptID: context.attemptID,
            approvalScope: context.scope,
            messageID: context.runID,
            policyRevision: context.policyRevision,
            grantEpoch: context.grantEpoch,
            inputDigest: context.payloadDigest,
            identityDigest: context.identityDigest,
            actorID: context.actorID,
            runID: context.runID,
            effectID: context.effectID,
            expiresAt: context.expiresAt
        )
        // Sanity: this really is a durable (bound) request.
        #expect(request.binding?.identityDigest == context.identityDigest)

        let consumer = ToolLifecycleConsumer()

        // L3 without the second confirmation: pending review, not approved.
        let acceptedUnconfirmed = await consumer.ingestApprovalDecision(
            ApprovalDecision(
                approved: true,
                confirmed: false,
                requestID: "approval-bound",
                bindingDigest: context.identityDigest
            ),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 500)
        )
        #expect(acceptedUnconfirmed)
        let pending = try #require(consumer.readOnlyProjection.approvalHistory.first)
        #expect(pending.status == .needsReview)
        #expect(pending.approvalDecision == .requested)

        // A bound decision must carry the request's own digest.
        let acceptedWithoutDigest = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: true, confirmed: true, requestID: "approval-bound"),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 501)
        )
        #expect(!acceptedWithoutDigest)

        let acceptedBound = await consumer.ingestApprovalDecision(
            ApprovalDecision(
                approved: true,
                confirmed: true,
                status: .approved,
                requestID: "approval-bound",
                bindingDigest: context.identityDigest
            ),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 502)
        )
        #expect(acceptedBound)
        let history = consumer.readOnlyProjection.approvalHistory
        #expect(history.count == 1)
        let event = try #require(history.first)
        #expect(event.approvalDecision == .approved)
        #expect(event.status == .succeeded)
        #expect(event.receiptID == "approval-bound")
        #expect(event.toolCallID == "call-bound")
        #expect(event.elapsedMilliseconds == nil)
    }

    // MARK: - Idempotence, persistence and the untouched tool path

    @Test("同一 receipt 的重放保持幂等")
    func replayOfSameReceiptIsIdempotent() async throws {
        let consumer = ToolLifecycleConsumer()
        let request = makeRequest(callID: "call-replay", requestID: "approval-replay")
        let decision = ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: "approval-replay"
        )
        let accepted = await consumer.ingestApprovalDecision(
            decision,
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 600)
        )
        #expect(accepted)

        // Identical transport identity and time: the same callback, not a new fact.
        let replayed = await consumer.ingestApprovalDecision(
            decision,
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 600)
        )
        #expect(!replayed)

        // A terminal approval cannot be rewritten by a later "different" verdict.
        let rewritten = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: false, status: .denied, requestID: "approval-replay"),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 601)
        )
        #expect(!rewritten)

        let history = consumer.readOnlyProjection.approvalHistory
        #expect(history.count == 1)
        #expect(history.first?.status == .succeeded)
    }

    @Test("durable journal 保留审批决定且不补写耗时")
    func durableJournalRoundTripsApproval() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let consumer = try ToolLifecycleConsumer(persistenceURL: url)
        let request = makeRequest(callID: "call-durable", requestID: "approval-durable")
        let accepted = await consumer.ingestApprovalDecision(
            ApprovalDecision(approved: false, status: .denied, requestID: "approval-durable"),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 700)
        )
        #expect(accepted)

        let reloaded = try ToolLifecycleConsumer(persistenceURL: url)
        let event = try #require(reloaded.readOnlyProjection.approvalHistory.first)
        #expect(reloaded.events == consumer.events)
        #expect(event.kind == .approval)
        #expect(event.approvalDecision == .denied)
        #expect(event.errorCategory == .authorization)
        #expect(event.elapsedMilliseconds == nil)
        #expect(
            ConversationEventProjection.display(for: event).elapsed == "未记录"
        )
    }

    @Test("新增审批生产者不改变工具事件的 kind 与耗时行为")
    func toolEventPathIsUnaffected() async throws {
        let consumer = ToolLifecycleConsumer()
        let fact = makeFact(toolCallID: "call-tool-1", receiptID: "receipt-tool-1")
        let acceptedTool = await consumer.ingestToolExecutionFact(
            fact,
            eventID: "call-tool-1",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 800)
        )
        #expect(acceptedTool)

        let request = makeRequest(
            callID: "call-tool-1",
            requestID: "approval-for-same-call",
            toolName: "file_read"
        )
        let acceptedApproval = await consumer.ingestApprovalDecision(
            ApprovalDecision(
                approved: true,
                confirmed: true,
                requestID: "approval-for-same-call"
            ),
            for: request,
            attempt: 1,
            occurredAt: Date(timeIntervalSince1970: 801)
        )
        #expect(acceptedApproval)

        #expect(consumer.toolLifecycleEvents.count == 1)
        #expect(consumer.toolLifecycleEvents.first?.kind == .tool)
        // Bare-fact ingestion still records no elapsed for the tool event.
        #expect(consumer.toolLifecycleEvents.first?.elapsedMilliseconds == nil)
        #expect(consumer.readOnlyProjection.approvalHistory.count == 1)
        #expect(consumer.events.count == 2)
        #expect(consumer.events.map(\.sequence) == [1, 2])
        #expect(consumer.events.map(\.kind) == [.tool, .approval])
    }

    // MARK: - Helpers

    private func makeRequest(
        callID: String,
        requestID: String,
        toolName: String = "file_write",
        requiresApproval: Bool = true,
        requiresSecondConfirmation: Bool = false,
        expiresAt: Date? = nil
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: requestID,
            requestID: requestID,
            callID: callID,
            toolName: toolName,
            inputSummary: "写入文件",
            riskLevel: requiresSecondConfirmation ? .high : .medium,
            requiresApproval: requiresApproval,
            requiresSecondConfirmation: requiresSecondConfirmation,
            sessionID: "session-one",
            turnID: 7,
            taskID: "task-one",
            attemptID: "attempt-one",
            approvalScope: "scope-one",
            expiresAt: expiresAt
        )
    }

    private func makeFact(
        toolCallID: String,
        receiptID: String
    ) -> ToolExecutionFact {
        let turn = AgentTurnIdentity(
            sessionID: "session-one",
            turnID: 7,
            messageID: "message-one"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "operation-one",
            attempt: 1
        )
        let compositeKey = ToolExecutionCompositeKey(
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            messageID: turn.messageID,
            operationID: executionIdentity.operationID,
            attemptID: "attempt-one",
            attemptNumber: 1,
            toolCallID: toolCallID
        )
        return ToolExecutionFact(
            toolCallID: toolCallID,
            receiptID: receiptID,
            toolName: "file_read",
            status: .succeeded,
            attemptID: "attempt-one",
            attemptNumber: 1,
            executionIdentity: executionIdentity,
            compositeKey: compositeKey
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("w5-062-approval-event-\(UUID().uuidString).json")
    }
}
