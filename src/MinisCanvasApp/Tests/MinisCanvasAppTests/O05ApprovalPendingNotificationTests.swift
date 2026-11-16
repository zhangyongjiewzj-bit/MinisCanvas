import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
struct O05ApprovalPendingNotificationTests {
    @Test func sharedDelegateRejectsConcurrentRequestRatherThanHidingAQueueAndAllTerminalPathsClearCount() async throws {
        for ending in ["dismiss", "expire", "cancel", "exit"] {
            let suite = "minis-approval-notice-\(UUID().uuidString)"
            try #require(suite.hasPrefix("minis-approval-notice-"))
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let effects = SystemNotificationEffects(requestAuthorization: { Issue.record("Unexpected OS permission request"); return false },
                authorizationStatus: { .unknown }, deliver: { _, _, _ in false }, isApplicationActive: { false },
                remove: { _ in }, installResponseHandlers: { _, _ in })
            let notifications = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: effects)
            let center = ApprovalPromptCenter()
            let delegate = ApprovalPromptDelegate(center: center)
            let first = ApprovalRequest(id: "synthetic-child-A-\(ending)", toolName: "file_write",
                inputSummary: "synthetic metadata only", riskLevel: .high, requiresApproval: true)
            var firstTask: Task<ApprovalDecision, Never>?
            await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
                var didResume = false
                center.onPendingRequestChanged = { [weak center] id, sessionID in
                    if let id, let lifecycleID = center?.pendingRequestLifecycleID {
                        notifications.updatePendingApprovals([(id, lifecycleID, sessionID)])
                    } else { notifications.updatePendingApprovals([]) }
                    if id == first.requestID, !didResume { didResume = true; ready.resume() }
                }
                firstTask = Task { await delegate.requestApproval(first) }
            }
            #expect(notifications.pendingApprovalCount == 1)
            let second = ApprovalRequest(id: "synthetic-child-B-\(ending)", toolName: "file_write",
                inputSummary: "synthetic metadata only", riskLevel: .high, requiresApproval: true)
            let rejected = await delegate.requestApproval(second)
            #expect(!rejected.approved)
            #expect(rejected.reason == "已有审批请求在处理中")
            #expect(rejected.requestID == second.requestID)
            #expect(center.approvalQueue.queuedRequests.isEmpty)
            #expect(center.pendingRequest?.requestID == first.requestID)
            #expect(notifications.pendingApprovalCount == 1)
            switch ending {
            case "dismiss": center.dismissPending()
            case "expire": center.expirePending()
            case "cancel": firstTask?.cancel()
            default: center.rejectForApplicationExit()
            }
            let task = try #require(firstTask)
            #expect(!(await task.value).approved)
            #expect(center.pendingRequest == nil)
            #expect(notifications.pendingApprovalCount == 0)
            notifications.cancelForApplicationExit()
        }
    }

    @Test func secondConfirmationKeepsOneActualPendingRequestUntilFinalSettlement() async throws {
        let center = ApprovalPromptCenter()
        defer { center.onPendingRequestChanged = nil }
        let request = ApprovalRequest(id: "synthetic-L3", toolName: "shell_execute", inputSummary: "synthetic",
            riskLevel: .high, requiresApproval: true, requiresSecondConfirmation: true)
        var counts: [Int] = []
        var task: Task<ApprovalDecision, Never>?
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var didResume = false
            center.onPendingRequestChanged = { id, _ in
                counts.append(id == nil ? 0 : 1)
                if id == nil { #expect(!center.awaitingConfirmation) }
                if id != nil, !didResume { didResume = true; ready.resume() }
            }
            task = Task { await center.present(request) }
        }
        center.approvePending()
        #expect(center.awaitingConfirmation && counts == [1])
        center.confirmPending()
        let result = try #require(task)
        #expect((await result.value).approved)
        #expect(counts == [1, 0])
    }
    @Test func reusedPublicIDIsSeparateWaiterWhileFallbackKeepsNotificationIdentity() async throws {
        let suite = "minis-approval-reused-id-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "miniscanvas.systemNotifications.approvals")
        var delivered: [(String, SystemNotificationEvent)] = []
        var opened = 0
        let effects = SystemNotificationEffects(
            requestAuthorization: { Issue.record("Unexpected OS permission request"); return false },
            authorizationStatus: { Issue.record("Unexpected OS permission read"); return .unknown },
            deliver: { id, event, current in
                guard current() else { return false }
                delivered.append((id, event))
                return true
            }, isApplicationActive: { false }, remove: { _ in }, installResponseHandlers: { _, _ in })
        let notifications = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: effects)
        let center = ApprovalPromptCenter()
        defer { center.onPendingRequestChanged = nil; notifications.cancelForApplicationExit() }
        notifications.isTargetCurrent = { [weak center] target in
            guard case .approval(let requestID, let lifecycleID, _) = target else { return false }
            return center?.pendingRequest?.requestID == requestID
                && center?.pendingRequestLifecycleID == lifecycleID
        }
        notifications.onOpenTarget = { _ in opened += 1 } // Navigation only; never approves.
        var ready: CheckedContinuation<Void, Never>?
        var work: [Task<Void, Never>] = []
        center.onPendingRequestChanged = { [weak center] requestID, sessionID in
            if let requestID, let lifecycleID = center?.pendingRequestLifecycleID {
                work = notifications.updatePendingApprovals([(requestID, lifecycleID, sessionID)])
                let waiter = ready; ready = nil; waiter?.resume()
            } else { work = notifications.updatePendingApprovals([]) }
        }
        var lifecycles: [UUID] = []
        for iteration in 0..<2 {
            let request = ApprovalRequest(id: "same-public-id", toolName: "file_write",
                inputSummary: "synthetic tool input must never enter payload", riskLevel: .high, requiresApproval: true)
            var requestTask: Task<ApprovalDecision, Never>?
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                ready = waiter
                requestTask = Task { await center.present(request) }
            }
            let lifecycleID = try #require(center.pendingRequestLifecycleID)
            lifecycles.append(lifecycleID)
            for task in work { await task.value }
            #expect(delivered.count == iteration + 1)
            let posted = try #require(delivered.last)
            #expect(posted.1.title == "MinisCanvas 有事项等待处理")
            #expect(posted.1.body == "有 1 个事项等待处理，请打开应用查看。")
            for _ in 0..<3 {
                center.fallBackToDialog()
                #expect(center.pendingRequestLifecycleID == lifecycleID)
                #expect(notifications.updatePendingApprovals([(request.requestID, lifecycleID, request.sessionID)]).isEmpty)
            }
            #expect(delivered.count == iteration + 1)
            if iteration == 1 {
                notifications.openNotification(id: delivered[0].0)
                #expect(opened == 0) // Old lifecycle cannot navigate into a reused public ID.
                notifications.openNotification(id: posted.0)
                #expect(opened == 1)
                #expect(center.pendingRequest?.requestID == request.requestID)
            }
            center.dismissPending()
            let task = try #require(requestTask)
            #expect(!(await task.value).approved)
            #expect(center.pendingRequestLifecycleID == nil && notifications.pendingApprovalCount == 0)
            let priorOpens = opened
            notifications.openNotification(id: posted.0)
            #expect(opened == priorOpens)
            #expect(!notifications.mayPresent(id: posted.0))
        }
        #expect(lifecycles.count == 2 && lifecycles[0] != lifecycles[1])
        #expect(delivered.count == 2 && delivered[0].1.key != delivered[1].1.key)
    }

}
