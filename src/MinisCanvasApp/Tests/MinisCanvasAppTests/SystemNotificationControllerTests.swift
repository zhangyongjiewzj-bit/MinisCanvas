import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@MainActor
struct SystemNotificationControllerTests {
    @MainActor private final class Spy {
        var requests = 0, statusReads = 0, installations = 0, uninstallations = 0
        var deliveryCalls = 0, activityReads = 0
        var permission = SystemNotificationAuthorizationStatus.unknown
        var active = false
        var delivered: [(String, SystemNotificationEvent)] = []
        var removed: [String] = []
        var pauseDelivery: (@MainActor () async -> Void)?
        var open: (@MainActor (String) -> Void)?
        var effects: SystemNotificationEffects {
            .init(requestAuthorization: { self.requests += 1; return self.permission == .authorized },
                authorizationStatus: { self.statusReads += 1; return self.permission },
                deliver: { id, event, current in
                    self.deliveryCalls += 1
                    if let pause = self.pauseDelivery { await pause() }
                    guard self.permission == .authorized, current() else { return false }
                    self.delivered.append((id, event)); return true
                }, isApplicationActive: { self.activityReads += 1; return self.active },
                remove: { self.removed += $0 }, installResponseHandlers: { open, _ in
                    self.installations += 1; self.open = open
                }, uninstallResponseHandlers: { self.uninstallations += 1; self.open = nil })
        }
    }
    private func withSuite(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "miniscanvas-notification-test-\(UUID().uuidString)"
        try #require(name.hasPrefix("miniscanvas-notification-test-"))
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }
    private func enable(_ defaults: UserDefaults) {
        defaults.set(true, forKey: "miniscanvas.systemNotifications.tasks")
        defaults.set(true, forKey: "miniscanvas.systemNotifications.approvals")
    }
    private func event(_ key: String, outcome: SystemNotificationEvent.Outcome = .completed) -> SystemNotificationEvent {
        .init(key: key, category: .tasks, target: .session(sessionID: "synthetic-session"), outcome: outcome)
    }

    @Test func dueGoalBlockerUsesExistingOptInLocalNotification() async throws {
        try await withSuite { defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SessionStore(directory: directory)
            let sessionID = UUID()
            _ = try store.createSession(id: sessionID.uuidString)
            let goal = try store.startConversationGoal(sessionID: sessionID, objective: "Private goal")
            let blocker = try #require(ConversationGoalBlocker(summary: "Private summary", reason: "Missing draft",
                options: ["Upload": "Attach draft"], userAction: "Attach draft"))
            let start = Date(timeIntervalSince1970: 100_000)
            _ = try store.recordConversationGoalReport(
                sessionID: sessionID, goalID: goal.id, report: .blocker(blocker), now: start
            )
            let chat = ChatStore(preferencesDefaults: defaults)
            try #require(chat.attachPersistence(store))
            let spy = Spy()
            spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            await SystemNotificationAppBindings.deliverNextGoalReminder(
                controller, chat: chat, now: { start }, wait: { _ in }
            )
            #expect(spy.delivered.isEmpty)
            #expect(store.loadSession(id: sessionID.uuidString)?.goal?.reminderDueAt == start)
            controller.setEnabled(.approvals, true)
            await SystemNotificationAppBindings.deliverNextGoalReminder(
                controller, chat: chat, now: { start }, wait: { _ in }
            )
            let event = try #require(spy.delivered.first?.1)
            #expect(spy.delivered.count == 1)
            #expect(event.category == .approvals)
            #expect(event.target.sessionID == sessionID.uuidString)
            #expect(!event.title.contains("Private") && !event.body.contains("Private"))
            #expect(chat.conversationGoal(for: sessionID)?.hasUnacknowledgedBlockerReminder == true)

            // A viewed target suppresses the OS banner. The same reminder still
            // advances the durable goal-tray indicator under the existing opt-in.
            let second = start.addingTimeInterval(60 * 60)
            let resetAt = start.addingTimeInterval(1)
            _ = try store.updateConversationGoalReminder(sessionID: sessionID, goalID: goal.id, now: resetAt)
            let reopenedChat = ChatStore(preferencesDefaults: defaults)
            try #require(reopenedChat.attachPersistence(store))
            #expect(reopenedChat.conversationGoal(for: sessionID)?.hasUnacknowledgedBlockerReminder == false)
            spy.active = true
            controller.isTargetViewed = { _ in true }
            let resetFirst = resetAt.addingTimeInterval(30 * 60)
            await SystemNotificationAppBindings.deliverNextGoalReminder(
                controller, chat: reopenedChat, now: { resetFirst }, wait: { _ in }
            )
            #expect(spy.delivered.count == 1)
            #expect(reopenedChat.conversationGoal(for: sessionID)?.hasUnacknowledgedBlockerReminder == true)
            #expect(store.loadSession(id: sessionID.uuidString)?.goal?.reminderDueAt == second.addingTimeInterval(30 * 60 + 1))
            #expect(spy.requests == 0)
        }
    }

    @Test func missingPreferencesStayOffAndColdClosedHasNoSystemEffects() async throws {
        try await withSuite { defaults in
            let spy = Spy(); spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            #expect(SystemNotificationCategory.allCases.count == 2)
            #expect(!controller.isModuleActive)
            controller.startResponseHandling()
            await controller.refreshAuthorizationStatus()
            await controller.enableFromUserAction()
            controller.updatePendingApprovals([("synthetic-approval", UUID(), "synthetic-session")])
            await controller.record(event("closed"))?.value
            controller.applicationBecameActive()
            #expect(controller.cancelForApplicationExit() == nil)
            #expect(spy.requests == 0 && spy.statusReads == 0 && spy.installations == 0)
            #expect(spy.deliveryCalls == 0 && spy.activityReads == 0 && spy.removed.isEmpty)
            #expect(spy.uninstallations == 0)
        }
    }
    @Test func explicitSavedChoicesAndLegacyCompletionChoiceArePreserved() async throws {
        try await withSuite { defaults in
            defaults.set(true, forKey: "miniscanvas.systemCompletionNotifications.enabled")
            defaults.set(false, forKey: "miniscanvas.systemNotifications.approvals")
            let spy = Spy()
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            #expect(controller.isEnabled(.tasks) && !controller.isEnabled(.approvals))
            controller.setEnabled(.tasks, false)
            controller.setEnabled(.approvals, true)
            controller.cancelForApplicationExit()
            let reopened = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            #expect(!reopened.isEnabled(.tasks) && reopened.isEnabled(.approvals))
            #expect(spy.requests == 0)
        }
    }
    @Test func onlyUserActionRequestsPermissionAndStatusNeverPretendsAuthorized() async throws {
        try await withSuite { defaults in
            enable(defaults)
            let spy = Spy()
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            #expect(controller.authorizationStatus == .unknown)
            await controller.record(event("unknown"))?.value
            #expect(spy.delivered.isEmpty && spy.requests == 0)
            spy.permission = .denied
            await controller.refreshAuthorizationStatus()
            #expect(controller.authorizationStatus == .denied && spy.requests == 0)
            await controller.enableFromUserAction()
            #expect(spy.requests == 1 && controller.authorizationStatus == .denied)
            #expect(controller.isEnabled(.tasks) && controller.isEnabled(.approvals))
        }
    }
    @Test func isolatedFieldAndBlockedCompositionCannotReachInjectedOSBackend() async throws {
        try await withSuite { defaults in
            enable(defaults)
            let spy = Spy(); spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: false, effects: spy.effects)
            controller.startResponseHandling()
            await controller.enableFromUserAction()
            await controller.refreshAuthorizationStatus()
            controller.updatePendingApprovals([("synthetic", UUID(), nil)])
            await controller.record(event("isolated"))?.value
            controller.applicationBecameActive()
            controller.cancelForApplicationExit()
            #expect(spy.requests == 0 && spy.statusReads == 0 && spy.installations == 0)
            #expect(spy.deliveryCalls == 0 && spy.activityReads == 0 && spy.removed.isEmpty)
        }
    }
    @Test func terminalEventsDeduplicateAndViewedForegroundOrDisabledCategoryDoNotPost() async throws {
        try await withSuite { defaults in
            enable(defaults)
            let spy = Spy(); spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            await controller.record(event("success"))?.value
            await controller.record(event("success"))?.value
            await controller.record(event("failed", outcome: .failed))?.value
            #expect(spy.delivered.count == 2)
            #expect(!spy.delivered[0].1.body.contains("synthetic-session"))
            spy.active = true; controller.isTargetViewed = { _ in true }
            await controller.record(event("viewed"))?.value
            #expect(spy.delivered.count == 2)
            controller.setEnabled(.tasks, false)
            spy.active = false
            await controller.record(event("disabled"))?.value
            #expect(spy.delivered.count == 2)
        }
    }
    @Test func approvalSettlementInvalidatesNotificationClickAndLateDelivery() async throws {
        try await withSuite { defaults in
            enable(defaults)
            let spy = Spy(); spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            var opened = false
            controller.onOpenTarget = { _ in opened = true }
            controller.startResponseHandling()
            controller.updatePendingApprovals([("synthetic-approval", UUID(), nil)])
            // Close the actual pending identity before its queued delivery starts.
            controller.updatePendingApprovals([])
            if let drain = controller.cancelForApplicationExit() { await drain.value }
            #expect(spy.delivered.isEmpty && controller.pendingApprovalCount == 0)
            spy.open?("stale-id")
            #expect(!opened)
        }
    }
    @Test func warmAllOffCancelsOwnedDeliveryAndReenableRestoresExistingChain() async throws {
        try await withSuite { defaults in
            enable(defaults)
            let spy = Spy(); spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            controller.startResponseHandling()
            let queued = controller.record(event("queued"))
            controller.setEnabled(.tasks, false)
            controller.setEnabled(.approvals, false)
            await queued?.value
            #expect(spy.delivered.isEmpty && spy.deliveryCalls == 0)
            #expect(spy.installations == 1 && spy.uninstallations == 1)
            let reads = spy.statusReads
            await controller.refreshAuthorizationStatus()
            #expect(spy.statusReads == reads)
            controller.setEnabled(.tasks, true)
            await controller.record(event("reopened"))?.value
            #expect(spy.installations == 2 && spy.delivered.count == 1 && spy.requests == 0)
        }
    }
    @Test func exitDrainsUncooperativeInFlightDeliveryWithoutLateNotification() async throws {
        try await withSuite { defaults in
            enable(defaults)
            let spy = Spy(); spy.permission = .authorized
            let controller = SystemNotificationController(defaults: defaults, canUseSystemNotifications: true, effects: spy.effects)
            var release: CheckedContinuation<Void, Never>?
            await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
                spy.pauseDelivery = {
                    await withCheckedContinuation { continuation in
                        release = continuation; started.resume()
                    }
                }
                _ = controller.record(event("in-flight"))
            }
            controller.setEnabled(.tasks, false)
            controller.setEnabled(.approvals, false)
            let drain = try #require(controller.cancelForApplicationExit())
            #expect(spy.removed.count == 1 && spy.delivered.isEmpty)
            let continuation = try #require(release)
            continuation.resume()
            await drain.value
            #expect(spy.delivered.isEmpty)
        }
    }
}
