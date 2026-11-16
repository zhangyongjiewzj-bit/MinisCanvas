import Foundation
import Observation
import AppKit
import UserNotifications

enum SystemNotificationAuthorizationStatus: Equatable { case unknown, notDetermined, denied, authorized }
enum SystemNotificationCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case approvals, tasks
    var id: String { rawValue }
    var label: String {
        switch self {
        case .approvals: "审批与澄清待办"
        case .tasks: "任务及子智能体完成、失败与定时补跑"
        }
    }
}

/// Only existing canonical IDs travel internally. No command, path, title,
/// transcript or tool input is included in a system notification payload.
enum SystemNotificationTarget: Equatable, Sendable {
    case approval(requestID: String, lifecycleID: UUID, sessionID: String?)
    case session(sessionID: String)
    case goalReminder(sessionID: String, goalID: UUID, nextDueAt: Date)
    case task(taskID: String, runID: String, sourceSessionID: String?)
    var sessionID: String? {
        switch self {
        case .approval(_, _, let id): id
        case .session(let id), .goalReminder(let id, _, _): id
        case .task(_, _, let id): id
        }
    }
}

struct SystemNotificationEvent: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case attention, completed, failed, caughtUp }
    let key: String
    let category: SystemNotificationCategory
    let target: SystemNotificationTarget
    let outcome: Outcome
    var title: String {
        switch outcome {
        case .attention: "MinisCanvas 有事项等待处理"
        case .completed: "MinisCanvas 任务已完成"
        case .failed: "MinisCanvas 任务未完成"
        case .caughtUp: "MinisCanvas 定时任务已加入补跑"
        }
    }
    var body: String {
        switch outcome {
        case .attention: "有 1 个事项等待处理，请打开应用查看。"
        case .caughtUp: "最近一次错过的定时任务已加入补跑，请打开应用查看状态。"
        case .completed, .failed: "打开 MinisCanvas 查看结果。"
        }
    }
}

/// The delegate is installed only by the production App composition. Clicks
/// carry an opaque, in-memory identifier and re-enter existing App navigation.
@MainActor
private final class SystemNotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (@MainActor (String) -> Void)?
    var shouldPresent: (@MainActor (String) -> Bool)?
    weak var previousDelegate: (any UNUserNotificationCenterDelegate)?
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let id = response.notification.request.identifier
        await MainActor.run { self.onOpen?(id) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        let allowed = await MainActor.run { self.shouldPresent?(id) == true }
        return allowed ? [.banner, .sound] : []
    }
}

@MainActor
struct SystemNotificationEffects {
    var requestAuthorization: @MainActor () async -> Bool
    var authorizationStatus: @MainActor () async -> SystemNotificationAuthorizationStatus
    var deliver: @MainActor (String, SystemNotificationEvent, @MainActor () -> Bool) async -> Bool
    var isApplicationActive: @MainActor () -> Bool
    var remove: @MainActor ([String]) -> Void
    var installResponseHandlers: @MainActor (@escaping @MainActor (String) -> Void,
        @escaping @MainActor (String) -> Bool) -> Void
    var uninstallResponseHandlers: @MainActor () -> Void = {}
    var setPendingApprovalBadge: @MainActor (String?) -> Void = { _ in }

    static var live: Self {
        let router = SystemNotificationResponseRouter()
        return Self(requestAuthorization: {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }, authorizationStatus: {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional: return .authorized
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            @unknown default: return .unknown
            }
        }, deliver: { id, event, isStillCurrent in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  isStillCurrent(), !Task.isCancelled else { return false }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            // No category actions and no userInfo: approvals stay in the App.
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            do {
                try Task.checkCancellation()
                guard isStillCurrent() else { return false }
                try await center.add(request)
                guard isStillCurrent(), !Task.isCancelled else {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    center.removeDeliveredNotifications(withIdentifiers: [id])
                    return false
                }
                return true
            } catch { return false }
        }, isApplicationActive: { NSApp.isActive }, remove: { ids in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }, installResponseHandlers: { onOpen, shouldPresent in
            router.onOpen = onOpen
            router.shouldPresent = shouldPresent
            let center = UNUserNotificationCenter.current()
            if center.delegate !== router { router.previousDelegate = center.delegate }
            center.delegate = router
        }, uninstallResponseHandlers: {
            router.onOpen = nil
            router.shouldPresent = nil
            let center = UNUserNotificationCenter.current()
            // Restore only while we still own the slot. Never clear or replace
            // a delegate another component installed after ours.
            if center.delegate === router { center.delegate = router.previousDelegate }
            router.previousDelegate = nil
        }, setPendingApprovalBadge: { label in
            NSApp.dockTile.badgeLabel = label
        })
    }
}

@MainActor
@Observable
final class SystemNotificationController {
    private static let legacyKey = "miniscanvas.systemCompletionNotifications.enabled"
    private let defaults: UserDefaults
    private let canUseSystemNotifications: Bool
    private let effects: SystemNotificationEffects
    private var authorizationGeneration: UInt64 = 0
    private var generation: UInt64 = 0
    private var isShuttingDown = false
    private var responseHandlingStarted = false
    private var pendingApprovals: [UUID: String] = [:]
    private var records: [String: SystemNotificationEvent] = [:]
    private var recordOrder: [String] = []
    private var seenEventKeys: [String] = []
    @ObservationIgnored private var deliveryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var isTargetViewed: @MainActor (SystemNotificationTarget) -> Bool = { _ in false }
    @ObservationIgnored var isTargetCurrent: @MainActor (SystemNotificationTarget) -> Bool = { _ in true }
    @ObservationIgnored var onOpenTarget: (@MainActor (SystemNotificationTarget) -> Void)?
    private(set) var enabledCategories: Set<SystemNotificationCategory>
    private(set) var authorizationStatus: SystemNotificationAuthorizationStatus = .unknown
    private(set) var isRequesting = false
    private(set) var pendingApprovalCount = 0
    private(set) var message: String

    init(defaults: UserDefaults, canUseSystemNotifications: Bool, effects: SystemNotificationEffects = .live) {
        self.defaults = defaults
        self.canUseSystemNotifications = canUseSystemNotifications
        self.effects = effects
        // Defaults ON remains a proposal, not approved activation. Preserve
        // explicit per-category choices; the old completion key applies only
        // to tasks. Missing preferences remain OFF and never ask the OS.
        let legacy = defaults.object(forKey: Self.legacyKey) as? Bool
        let initialCategories = Set(SystemNotificationCategory.allCases.filter {
            (defaults.object(forKey: Self.key($0)) as? Bool) ?? ($0 == .tasks ? legacy ?? false : false)
        })
        enabledCategories = initialCategories
        message = !canUseSystemNotifications
            ? "隔离或受限运行环境不会读取系统授权、发送通知。"
            : initialCategories.isEmpty ? "通知功能已关闭；系统权限未改变，未再检查。"
            : "系统通知权限尚未检查；分类开关不会申请权限。"
    }
    private static func key(_ category: SystemNotificationCategory) -> String {
        "miniscanvas.systemNotifications." + category.rawValue
    }
    /// The two preferences are the module switch; no extra persisted flag/store.
    var isModuleActive: Bool { !enabledCategories.isEmpty }
    var canDeliverGoalReminders: Bool { canUseSystemNotifications && !isShuttingDown && isEnabled(.approvals) }
    var canRequestAuthorization: Bool { canUseSystemNotifications && isModuleActive && !isRequesting && !isShuttingDown }
    func isEnabled(_ category: SystemNotificationCategory) -> Bool { enabledCategories.contains(category) }

    func setEnabled(_ category: SystemNotificationCategory, _ enabled: Bool) {
        let wasActive = isModuleActive
        if enabled { enabledCategories.insert(category) } else { enabledCategories.remove(category) }
        defaults.set(enabled, forKey: Self.key(category))
        if category == .approvals { updatePendingApprovalBadge() }
        if !enabled { removeRecords(records.filter { $0.value.category == category }.map(\.key)) }
        if wasActive && !isModuleActive {
            deactivateSystemEffects()
            return
        }
        if !wasActive && isModuleActive {
            if canUseSystemNotifications { message = "系统通知权限尚未检查；分类开关不会申请权限。" }
            startResponseHandling()
        }
    }
    func startResponseHandling() {
        guard canUseSystemNotifications, isModuleActive, !isShuttingDown, !responseHandlingStarted else { return }
        responseHandlingStarted = true
        effects.installResponseHandlers({ [weak self] id in self?.openNotification(id: id) },
            { [weak self] id in self?.mayPresent(id: id) == true })
    }
    func refreshAuthorizationStatus() async {
        guard canUseSystemNotifications, isModuleActive, !isShuttingDown, !Task.isCancelled else { return }
        let ticket = generation
        let status = await effects.authorizationStatus()
        guard isModuleActive, ticket == generation, !isShuttingDown, !Task.isCancelled else { return }
        authorizationStatus = status
        switch status {
        case .unknown: message = "系统通知权限未知。"
        case .notDetermined: message = "尚未获得系统通知授权；只有点击授权按钮才会申请。"
        case .denied: message = "系统已禁止通知，去系统设置开启。"
        case .authorized: message = "系统已允许通知；分类开关与系统权限分别控制。"
        }
    }
    /// Exclusively the explicit settings permission button calls this method.
    func enableFromUserAction() async {
        guard canRequestAuthorization, !Task.isCancelled else { return }
        authorizationGeneration &+= 1
        let ticket = authorizationGeneration
        isRequesting = true
        defer { isRequesting = false }
        _ = await effects.requestAuthorization()
        guard ticket == authorizationGeneration, !isShuttingDown, !Task.isCancelled else { return }
        await refreshAuthorizationStatus()
        // Permission result never flips any category or saved user preference.
    }
    func cancelAuthorizationRequest() { authorizationGeneration &+= 1 }

    @discardableResult
    func updatePendingApprovals(_ approvals: [(requestID: String, lifecycleID: UUID, sessionID: String?)]) -> [Task<Void, Never>] {
        guard !isShuttingDown else { return [] }
        let priorIDs = Set(pendingApprovals.keys)
        pendingApprovals = Dictionary(approvals.map { ($0.lifecycleID, $0.requestID) }, uniquingKeysWith: { a, _ in a })
        pendingApprovalCount = pendingApprovals.count
        updatePendingApprovalBadge()
        let removed = priorIDs.subtracting(pendingApprovals.keys)
        removeRecords(records.filter { item in
            if case .approval(_, let lifecycleID, _) = item.value.target { return removed.contains(lifecycleID) }
            return false
        }.map(\.key))
        // The existing waiter, unlike a reusable public ID or a rendered card,
        // identifies one whole pending lifecycle. Return the same delivery work
        // handles as record so callers can join dispatch without timing guesses.
        return approvals.filter { !priorIDs.contains($0.lifecycleID) }.compactMap { approval in
            record(.init(key: "approval:" + approval.lifecycleID.uuidString, category: .approvals,
                target: .approval(requestID: approval.requestID, lifecycleID: approval.lifecycleID,
                    sessionID: approval.sessionID), outcome: .attention))
        }
    }
    @discardableResult
    func record(_ event: SystemNotificationEvent) -> Task<Void, Never>? {
        guard canUseSystemNotifications, !isShuttingDown, !Task.isCancelled,
              isEnabled(event.category), isTargetCurrent(event.target), !seenEventKeys.contains(event.key) else { return nil }
        seenEventKeys.append(event.key)
        if seenEventKeys.count > 512 { seenEventKeys.removeFirst(seenEventKeys.count - 512) }
        guard !(effects.isApplicationActive() && isTargetViewed(event.target)) else { return nil }
        let id = "miniscanvas-event-" + UUID().uuidString
        records[id] = event
        recordOrder.append(id)
        if recordOrder.count > 200 { removeRecords(Array(recordOrder.prefix(recordOrder.count - 200))) }
        let ticket = generation
        let task = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.generation == ticket, self.mayPresent(id: id) else {
                self.deliveryTasks.removeValue(forKey: id)
                return
            }
            _ = await self.effects.deliver(id, event) { [weak self] in
                guard let self else { return false }
                return self.generation == ticket && !Task.isCancelled && self.mayPresent(id: id)
            }
            self.deliveryTasks.removeValue(forKey: id)
        }
        deliveryTasks[id] = task
        return task
    }
    func openNotification(id: String) {
        guard !isShuttingDown, let event = records[id], isTargetCurrent(event.target) else { return }
        if case .approval(let requestID, let lifecycleID, _) = event.target,
           pendingApprovals[lifecycleID] != requestID { removeRecords([id]); return }
        onOpenTarget?(event.target) // App revalidates live target before navigation.
        removeRecords([id])
    }
    func mayPresent(id: String) -> Bool {
        guard canUseSystemNotifications, !isShuttingDown, let event = records[id],
              isEnabled(event.category), isTargetCurrent(event.target) else { return false }
        if case .approval(let requestID, let lifecycleID, _) = event.target,
           pendingApprovals[lifecycleID] != requestID { return false }
        return !(effects.isApplicationActive() && isTargetViewed(event.target))
    }
    func applicationBecameActive() {
        guard canUseSystemNotifications, isModuleActive, !isShuttingDown else { return }
        // Keep unviewed-session notifications; remove only targets now viewed.
        if effects.isApplicationActive() {
            removeRecords(records.filter { isTargetViewed($0.value.target) }.map(\.key))
        }
    }
    @discardableResult
    func cancelForApplicationExit() -> Task<Void, Never>? {
        let inFlight = Array(deliveryTasks.values)
        let hadSystemWork = isModuleActive || responseHandlingStarted || !records.isEmpty
        isShuttingDown = true
        updatePendingApprovalBadge()
        if hadSystemWork { deactivateSystemEffects() }
        else { generation &+= 1; cancelAuthorizationRequest() }
        // Never alter saved category preferences or OS authorization at exit.
        guard !inFlight.isEmpty else { return nil }
        return Task { for task in inFlight { await task.value } }
    }
    private func updatePendingApprovalBadge() {
        guard canUseSystemNotifications else { return }
        let count = !isShuttingDown && isEnabled(.approvals) ? pendingApprovalCount : 0
        effects.setPendingApprovalBadge(count > 0 ? String(count) : nil)
    }
    private func deactivateSystemEffects() {
        generation &+= 1
        cancelAuthorizationRequest()
        removeRecords(Array(records.keys))
        authorizationStatus = .unknown
        if canUseSystemNotifications {
            if responseHandlingStarted { effects.uninstallResponseHandlers() }
            message = "通知功能已关闭；系统权限未改变，未再检查。"
        }
        responseHandlingStarted = false
    }
    private func removeRecords(_ ids: [String]) {
        // Cancellation is logical; keep each physical operation joinable until
        // its existing task footer retires it, including an uncooperative OS add.
        for id in ids { deliveryTasks[id]?.cancel(); records.removeValue(forKey: id) }
        let removed = Set(ids)
        recordOrder.removeAll { removed.contains($0) }
        if canUseSystemNotifications, !ids.isEmpty { effects.remove(ids) }
    }
}
