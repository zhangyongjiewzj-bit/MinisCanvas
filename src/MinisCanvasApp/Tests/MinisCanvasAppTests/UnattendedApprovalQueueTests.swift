import Foundation
import Observation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Unattended approval presentation queue")
@MainActor
struct UnattendedApprovalQueueTests {
    private func request(_ id: String) -> ApprovalRequest {
        ApprovalRequest(id: id, toolName: "shell", inputSummary: "synthetic command",
            riskLevel: .high, requiresApproval: true)
    }

    @Test func unattendedWaitsThenResumesOriginalRequestWithExplicitDecision() async {
        let center = ApprovalPromptCenter()
        let queue = ApprovalQueue()
        let firstRequest = request("first")
        let secondRequest = request("second")
        var first: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in
                if id == firstRequest.id { continuation.resume() }
            }
            first = Task { await ApprovalExecutionOriginContext.$current.withValue(.scheduledTask) {
                await queue.present(firstRequest, in: center)
            } }
        }
        var second: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = queue.queuedRequests } onChange: { continuation.resume() }
            second = Task { await ApprovalExecutionOriginContext.$current.withValue(.backgroundSubtask) {
                await queue.present(secondRequest, in: center)
            } }
        }
        #expect(center.pendingRequest?.id == "first")
        #expect(queue.queuedRequests.map(\.id) == ["second"])
        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in
                if id == secondRequest.id { continuation.resume() }
            }
            center.resolve(approved: false, confirmed: false, requestID: "first")
        }
        #expect(await first?.value.approved == false)
        #expect(center.pendingRequest?.id == secondRequest.id)
        #expect(queue.queuedRequests.isEmpty)
        center.resolve(approved: true, confirmed: true, requestID: "second")
        let decision = await second?.value
        #expect(decision?.approved == true)
        #expect(decision?.requestID == secondRequest.requestID)
    }

    @Test func cancellationRemovesQueuedWaiterWithoutResolvingActiveApproval() async {
        let center = ApprovalPromptCenter()
        let queue = ApprovalQueue()
        var active: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in if id == "active" { continuation.resume() } }
            active = Task { await queue.present(request("active"), in: center) }
        }
        var waiting: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = queue.queuedRequests } onChange: { continuation.resume() }
            waiting = Task { await ApprovalExecutionOriginContext.$current.withValue(.scheduledTask) {
                await queue.present(request("waiting"), in: center)
            } }
        }
        waiting?.cancel()
        #expect(await waiting?.value.status == .cancelled)
        #expect(queue.queuedRequests.isEmpty)
        #expect(center.pendingRequest?.id == "active")
        center.resolve(approved: false, confirmed: false, requestID: "active")
        _ = await active?.value
    }

    @Test func returningInteractiveApprovalPrecedesQueuedUnattendedWork() async {
        let center = ApprovalPromptCenter()
        let queue = ApprovalQueue()
        var active: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in if id == "scheduled-active" { continuation.resume() } }
            active = Task { await ApprovalExecutionOriginContext.$current.withValue(.scheduledTask) {
                await queue.present(request("scheduled-active"), in: center)
            } }
        }
        var background: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = queue.queuedRequests } onChange: { continuation.resume() }
            background = Task { await ApprovalExecutionOriginContext.$current.withValue(.backgroundSubtask) {
                await queue.present(request("background-waiting"), in: center)
            } }
        }
        var interactive: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = queue.queuedRequests } onChange: { continuation.resume() }
            interactive = Task { await ApprovalExecutionOriginContext.$current.withValue(.interactive) {
                await queue.present(request("interactive-next"), in: center)
            } }
        }
        #expect(queue.queuedRequests.map(\.id) == ["interactive-next", "background-waiting"])
        #expect(center.pendingRequest?.id == "scheduled-active")
        let overlap = await queue.present(request("interactive-overlap"), in: center)
        #expect(overlap.approved == false)
        #expect(overlap.reason == "已有审批请求在处理中")

        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in if id == "interactive-next" { continuation.resume() } }
            center.resolve(approved: false, confirmed: false, requestID: "scheduled-active")
        }
        _ = await active?.value
        #expect(center.pendingRequest?.id == "interactive-next")
        let activeOverlap = await queue.present(request("second-active-interactive"), in: center)
        #expect(activeOverlap.approved == false)
        #expect(center.pendingRequest?.id == "interactive-next")
        #expect(queue.queuedRequests.map(\.id) == ["background-waiting"])
        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in if id == "background-waiting" { continuation.resume() } }
            center.resolve(approved: true, confirmed: true, requestID: "interactive-next")
        }
        #expect(await interactive?.value.approved == true)
        #expect(center.pendingRequest?.id == "background-waiting")
        center.resolve(approved: false, confirmed: false, requestID: "background-waiting")
        _ = await background?.value
    }

    @Test func displayOnlyChildSourceCannotBypassInteractiveOverlapRejection() async {
        let center = ApprovalPromptCenter()
        let queue = ApprovalQueue()
        var active: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { continuation in
            center.onPendingRequestChanged = { id, _ in if id == "active" { continuation.resume() } }
            active = Task { await queue.present(request("active"), in: center) }
        }
        var forged = request("model-child-claim")
        forged.source = .childTask(taskID: "claimed-child", parentID: "claimed-parent")
        let decision = await queue.present(forged, in: center)
        #expect(!decision.approved && decision.reason == "已有审批请求在处理中")
        #expect(queue.queuedRequests.isEmpty && center.pendingRequest?.id == "active")
        center.resolve(approved: false, confirmed: false, requestID: "active")
        _ = await active?.value
    }

}
