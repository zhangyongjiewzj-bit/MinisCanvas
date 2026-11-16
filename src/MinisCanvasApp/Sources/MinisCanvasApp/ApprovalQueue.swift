import Foundation
import Observation
import MinisCore

/// Prioritizes interactive presentation ahead of queued unattended requests in the existing prompt
/// center. Waiters retain their original request and caller; no approval,
/// receipt, deadline or authorization is created by this queue.
@MainActor
@Observable
final class ApprovalQueue {
    private struct ChildKey: Equatable {
        let sessionID: String
        let taskID: String
        let runID: String
        let attemptID: String
    }
    private struct VerifiedChild {
        let key: ChildKey
        let expiresAt: Date
    }
    private struct Waiter {
        let id: UUID
        let request: ApprovalRequest
        let origin: ApprovalExecutionOrigin
        let childKey: ChildKey?
        let continuation: CheckedContinuation<Bool, Never>
    }
    @ObservationIgnored private var waiters: [Waiter] = []
    private var activeOrigin: ApprovalExecutionOrigin?
    private var activeChildKey: ChildKey?
    private var isShuttingDown = false
    private(set) var queuedRequests: [ApprovalRequest] = []

    func present(_ request: ApprovalRequest, in center: ApprovalPromptCenter) async -> ApprovalDecision {
        guard !isShuttingDown else {
            return ApprovalDecision(approved: false, reason: "应用退出", status: .cancelled,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
        let origin = ApprovalExecutionOriginContext.current
        let verifiedChild = verifiedChild(for: request)
        let childKey = verifiedChild?.key
        // Only canonical live child approvals may wait behind another
        // interactive request. Display-only source fields cannot qualify.
        let duplicateChild = childKey.map { key in
            activeChildKey == key || waiters.contains(where: { $0.childKey == key })
        } ?? false
        if duplicateChild || (!origin.isUnattended && childKey == nil
            && (activeOrigin == .interactive || waiters.contains(where: { $0.origin == .interactive }))) {
            return ApprovalDecision(approved: false, reason: "已有审批请求在处理中",
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if activeOrigin == nil {
                    activeOrigin = origin
                    activeChildKey = childKey
                    continuation.resume(returning: true)
                } else {
                    let waiter = Waiter(id: waiterID, request: request, origin: origin,
                        childKey: childKey, continuation: continuation)
                    if origin.isUnattended { waiters.append(waiter) }
                    else { waiters.insert(waiter, at: 0) }
                    queuedRequests = waiters.map(\.request)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiterID) }
        }
        guard acquired else {
            return ApprovalDecision(approved: false, reason: "审批调用任务已取消", status: .cancelled,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
        defer { release() }
        // Waiting never extends authority. Reuse the live canonical pending
        // binding after acquiring the slot, then leave expiry/receipt handling
        // to the unchanged center and Core gate.
        if let childKey, self.verifiedChild(for: request)?.key != childKey {
            return ApprovalDecision(approved: false, reason: "子任务审批绑定已失效",
                status: verifiedChild.map { $0.expiresAt <= Date() } == true ? .expired : .cancelled,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
        return await center.present(request)
    }

    /// The Core child delegate installs this pending navigation only after
    /// validating the actual run/attempt and child boundary. Model tool input
    /// cannot populate the runtime TaskLocal or the store's pending map.
    private func verifiedChild(for request: ApprovalRequest) -> VerifiedChild? {
        guard case .childTask(let taskID, let parentID)? = request.source,
              let runtime = AgentExecutionContext.current,
              let child = runtime.childToolRuntimeBinding,
              let store = runtime.taskStore,
              let pending = store.currentPendingApprovalBinding(taskID: taskID, parentID: parentID),
              runtime.childRuntimeSnapshot?.matches(child.boundary) == true,
              child.boundary.identity.childTaskID == taskID,
              child.locator.taskID == taskID, child.locator.parentID == parentID,
              pending.taskRunID == child.locator.runID,
              pending.taskAttemptID == child.locator.attemptID,
              pending.childSessionID == child.boundary.identity.childSessionID,
              pending.approvalRequestID == request.requestID,
              pending.approvalBindingDigest == request.identityDigest,
              request.sessionID == pending.childSessionID,
              request.taskID == taskID else { return nil }
        if let binding = request.binding {
            guard binding.isValid,
                  pending.approvalRunID == request.runID,
                  pending.approvalAttemptID == request.attemptID,
                  pending.expiresAt == request.expiresAt else { return nil }
        } else {
            // Composer requests intentionally have no legacy authorization
            // binding. Match the original runtime snapshot and the navigation
            // already verified by Core; do not manufacture a binding for them.
            guard request.requiresApproval,
                  runtime.offeredToolNames?.contains(request.toolName) == true,
                  let snapshot = runtime.composerSnapshot, let facts = runtime.composerPolicyFacts,
                  snapshot.sessionID == pending.childSessionID,
                  snapshot.turnID == child.boundary.identity.cancelGeneration,
                  snapshot.taskID == taskID,
                  request.turnID == snapshot.turnID, request.attemptID == snapshot.attemptID,
                  request.messageID == snapshot.messageID, request.composerMode == snapshot.mode.rawValue,
                  request.approvalScope == snapshot.approvalScope.rawValue,
                  request.policyRevision == snapshot.policyRevision, request.grantEpoch == snapshot.grantEpoch,
                  facts.workspaceID == snapshot.workspaceID, facts.revision == snapshot.policyRevision,
                  facts.grantEpoch == snapshot.grantEpoch, !facts.revoked, !facts.leaseID.isEmpty,
                  facts.expiresAt.timeIntervalSinceReferenceDate.isFinite, facts.expiresAt > Date(),
                  let presentation = ApprovalPresentationContext.current,
                  presentation.makeFact(for: request, stage: .presented) != nil,
                  pending.approvalRunID == presentation.compositeKey.operationID,
                  pending.approvalAttemptID == presentation.compositeKey.attemptID,
                  pending.expiresAt == (request.expiresAt.map { min($0, facts.expiresAt) } ?? facts.expiresAt)
            else { return nil }
        }
        return VerifiedChild(key: ChildKey(sessionID: pending.childSessionID, taskID: taskID,
            runID: pending.taskRunID, attemptID: pending.taskAttemptID), expiresAt: pending.expiresAt)
    }

    func cancelPendingForApplicationExit() {
        isShuttingDown = true
        let pending = waiters
        waiters.removeAll()
        queuedRequests = []
        for waiter in pending { waiter.continuation.resume(returning: false) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        queuedRequests = waiters.map(\.request)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        guard !waiters.isEmpty else { activeOrigin = nil; activeChildKey = nil; return }
        let waiter = waiters.removeFirst()
        activeOrigin = waiter.origin
        activeChildKey = waiter.childKey
        queuedRequests = waiters.map(\.request)
        waiter.continuation.resume(returning: true)
    }
}
