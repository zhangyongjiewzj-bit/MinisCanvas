import Foundation
import os
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TOOL-16/17 true approval presentation observations")
@MainActor
struct P3AcceptanceM02ApprovalPresentationFactsTests {
    private typealias Recorder = OSAllocatedUnfairLock<[ApprovalLifecycleFact]>

    private func request(expiresAt: Date = Date().addingTimeInterval(60)) -> ApprovalRequest {
        ApprovalRequest(
            id: "call-1", requestID: "approval-1", callID: "call-1",
            toolName: "file_read", inputSummary: "合成读取请求",
            riskLevel: .high, requiresApproval: true,
            sessionID: "session-1", turnID: 7, taskID: "task-1",
            attemptID: "attempt-1", approvalScope: "scope-1",
            composerMode: "manual", messageID: "message-1",
            identityDigest: "digest-1", expiresAt: expiresAt
        )
    }

    private func context(recorder: Recorder) -> ApprovalPresentationContext {
        let turn = AgentTurnIdentity(
            sessionID: "session-1", turnID: 7, messageID: "message-1"
        )
        let execution = AgentExecutionIdentity(
            turn: turn, operationID: "operation-1", attempt: 1
        )
        let key = ToolExecutionCompositeKey(
            sessionID: "session-1", turnID: 7, messageID: "message-1",
            operationID: "operation-1", attemptID: "attempt-1",
            attemptNumber: 1, toolCallID: "call-1"
        )
        return ApprovalPresentationContext(
            compositeKey: key, executionIdentity: execution,
            toolName: "file_read", eventSink: { fact in
                recorder.withLock { $0.append(fact) }
            }
        )
    }

    private func begin(
        _ center: ApprovalPromptCenter,
        request: ApprovalRequest
    ) async -> Task<ApprovalDecision, Never> {
        let task = Task { await center.present(request) }
        for _ in 0..<100 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(center.pendingRequest?.requestID == request.requestID)
        return task
    }

    @Test("real accepted pending emits exactly one original-request fact")
    func acceptedPendingEmitsOnce() async {
        let center = ApprovalPromptCenter()
        let recorder = Recorder(initialState: [])
        let requested = request()
        await ApprovalPresentationContext.$current.withValue(context(recorder: recorder)) {
            let pending = await begin(center, request: requested)
            let facts = recorder.withLock { $0 }
            let fact = facts.first
            #expect(fact != nil)
            #expect(facts.count == 1)
            #expect(fact?.stage == .presented)
            #expect(fact?.requestID == requested.requestID)
            #expect(fact?.identityDigest == requested.identityDigest)
            #expect(fact?.compositeKey.toolCallID == requested.callID)
            #expect(fact?.executionIdentity.turn.messageID == "message-1")
            center.dismissPending()
            _ = await pending.value
            #expect(recorder.withLock { $0.count } == 1)
        }
    }

    @Test("overlap, consumed identity and expired guards emit no extra presented fact")
    func rejectedGuardsDoNotEmit() async {
        let center = ApprovalPromptCenter()
        let recorder = Recorder(initialState: [])
        let requested = request()
        await ApprovalPresentationContext.$current.withValue(context(recorder: recorder)) {
            let first = await begin(center, request: requested)
            #expect(recorder.withLock { $0.count } == 1)
            let overlap = await center.present(requested)
            #expect(!overlap.approved)
            #expect(recorder.withLock { $0.count } == 1)
            center.resolve(approved: true, confirmed: true, requestID: requested.id)
            _ = await first.value
            let duplicate = await center.present(requested)
            #expect(!duplicate.approved)
            #expect(recorder.withLock { $0.count } == 1)
            let expired = await center.present(request(expiresAt: .distantPast))
            #expect(!expired.approved)
            #expect(recorder.withLock { $0.count } == 1)
        }
    }

    @Test("a real pending request without a scoped identity emits no fact")
    func missingContextDoesNotEmit() async {
        let center = ApprovalPromptCenter()
        let recorder = Recorder(initialState: [])
        let pending = await begin(center, request: request())
        #expect(center.pendingRequest != nil)
        #expect(recorder.withLock { $0.isEmpty })
        center.dismissPending()
        _ = await pending.value
        #expect(recorder.withLock { $0.isEmpty })
    }
}
