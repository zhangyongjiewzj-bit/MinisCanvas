import AppKit
import Foundation
import MinisCore

/// Metadata-only links from existing production facts to O05. This does not
/// approve, restart, execute or create tasks, and never parses model text.
@MainActor
enum SystemNotificationAppBindings {
    static func deliverNextGoalReminder(
        _ notifications: SystemNotificationController, chat: ChatStore,
        now: @MainActor () -> Date = { Date() },
        wait: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        guard notifications.canDeliverGoalReminders,
              let next = chat.conversationGoalReminderDates.min(by: { $0.value < $1.value }) else { return }
        do {
            try await wait(.seconds(max(0, next.value.timeIntervalSince(now()))))
            try Task.checkCancellation()
        } catch { return }
        guard notifications.canDeliverGoalReminders,
              let goal = chat.consumeConversationGoalReminder(
                  sessionID: next.key, expectedDueAt: next.value, now: now()
              ), let nextDueAt = goal.reminderDueAt else { return }
        let delivery = notifications.record(.init(
            key: "goal-reminder:" + goal.id.uuidString + ":" + String(next.value.timeIntervalSinceReferenceDate),
            category: .approvals,
            target: .goalReminder(sessionID: goal.sessionID.uuidString, goalID: goal.id, nextDueAt: nextDueAt),
            outcome: .attention
        ))
        await delivery?.value
    }

    static func bind(_ notifications: SystemNotificationController, bridge: BridgeStore,
        isSettingsVisible: @escaping @MainActor () -> Bool,
        closeSettings: @escaping @MainActor () -> Void) {
        notifications.isTargetViewed = { [weak bridge] target in
            guard let bridge, !isSettingsVisible(), bridge.layoutMode != .canvas,
                  let window = NSApp.keyWindow, window.isVisible,
                  window.sheetParent == nil, window.attachedSheet == nil,
                  let sessionID = target.sessionID else { return false }
            return bridge.chat.activeSessionID?.uuidString == sessionID
        }
        notifications.isTargetCurrent = { [weak bridge] target in
            guard let bridge else { return false }
            switch target {
            case .approval(let id, let lifecycleID, _):
                return bridge.chat.userQuestions.matches(requestID: id, lifecycleID: lifecycleID)
                    || bridge.chat.mcpElicitations.matches(requestID: id, lifecycleID: lifecycleID)
                    || (bridge.approvalCenter.pendingRequest?.requestID == id
                        && bridge.approvalCenter.pendingRequestLifecycleID == lifecycleID)
            case .session(let id): return bridge.chat.sessions.contains { $0.id.uuidString == id }
            case .goalReminder(let id, let goalID, let nextDueAt):
                guard let sessionID = UUID(uuidString: id),
                      bridge.chat.conversationGoalReminderDates[sessionID] == nextDueAt,
                      let goal = bridge.chat.sessionStore?.loadSession(id: id)?.goal else { return false }
                return goal.id == goalID && goal.reminderDueAt == nextDueAt
            case .task(let taskID, let runID, _):
                return bridge.taskCenterControlConsumer.receiptRows().contains { $0.taskID == taskID && $0.runID == runID }
            }
        }
        notifications.onOpenTarget = { [weak bridge] target in
            guard let bridge else { return }
            NSApp.activate()
            switch target {
            case .approval(let id, let lifecycleID, let sessionID):
                if bridge.chat.userQuestions.matches(requestID: id, lifecycleID: lifecycleID)
                    || bridge.chat.mcpElicitations.matches(requestID: id, lifecycleID: lifecycleID) {
                    closeSettings()
                    if let sessionID { bridge.deepLinkHandler.handle(.openSession(id: sessionID)) }
                    return
                }
                let center = bridge.approvalCenter
                guard center.pendingRequest?.requestID == id,
                      center.pendingRequestLifecycleID == lifecycleID else { return }
                closeSettings()
                if let sessionID { bridge.deepLinkHandler.handle(.openSession(id: sessionID)) }
                if center.isPresentationSuspended {
                    for row in bridge.taskCenterControlConsumer.receiptRows() {
                        if let navigation = bridge.taskCenterControlConsumer.approvalNavigation(for: row, pendingRequest: center.pendingRequest),
                           navigation.requestID == id {
                            _ = center.requestTaskCenterResume(navigation, consumer: bridge.taskCenterControlConsumer)
                            return
                        }
                    }
                } else { center.fallBackToDialog() }
            case .session(let id), .goalReminder(let id, _, _):
                closeSettings()
                bridge.deepLinkHandler.handle(.openSession(id: id))
            case .task(let taskID, let runID, _):
                guard let row = bridge.taskCenterControlConsumer.receiptRows().first(where: {
                    $0.taskID == taskID && $0.runID == runID
                }) else { return }
                closeSettings()
                bridge.taskCenterOpenIntent = TaskCenterOpenIntent(toolbarOpener: false, initialTaskStableID: row.stableID)
            }
        }
        let refreshPending: @MainActor () -> Void = { [weak notifications, weak bridge] in
            guard let notifications, let bridge else { return }
            var entries: [(requestID: String, lifecycleID: UUID, sessionID: String?)] = []
            if let request = bridge.approvalCenter.pendingRequest,
               let lifecycleID = bridge.approvalCenter.pendingRequestLifecycleID {
                entries.append((request.requestID, lifecycleID, request.sessionID))
            }
            for question in bridge.chat.userQuestions.pending.values {
                entries.append((bridge.chat.userQuestions.notificationID(question.id), question.id,
                    question.sessionID.uuidString))
            }
            for form in bridge.chat.mcpElicitations.pending.values {
                entries.append((bridge.chat.mcpElicitations.notificationID(form.id), form.id,
                    form.sessionID.uuidString))
            }
            notifications.updatePendingApprovals(entries)
        }
        bridge.approvalCenter.onPendingRequestChanged = { _, _ in refreshPending() }
        bridge.chat.userQuestions.onPendingRequestsChanged = refreshPending
        bridge.chat.mcpElicitations.onPendingRequestsChanged = refreshPending
        refreshPending()
        bridge.chat.onResponseNotification = { [weak notifications] sessionID, executionID, failed in
            _ = notifications?.record(.init(key: "chat:" + sessionID.uuidString + ":" + executionID, category: .tasks,
                target: .session(sessionID: sessionID.uuidString), outcome: failed ? .failed : .completed))
        }
        bridge.agentTaskStore.setTerminalObserver { [weak notifications] event in
            guard event.outcome != .cancelled else { return }
            Task { @MainActor [weak notifications] in
                _ = notifications?.record(.init(key: "task:" + event.runID + ":" + event.attemptID, category: .tasks,
                    target: .task(taskID: event.taskID, runID: event.runID, sourceSessionID: event.sourceSessionID),
                    outcome: event.outcome == .completed ? .completed : .failed))
            }
        }
        bridge.chat.observeBackgroundShellCompletions(in: .shared)
        notifications.startResponseHandling()
    }
}
