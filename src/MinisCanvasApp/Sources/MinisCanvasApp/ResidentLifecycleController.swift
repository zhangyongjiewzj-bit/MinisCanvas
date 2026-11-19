import AppKit
import Observation
import ServiceManagement
import IOKit.pwr_mgt
import MinisCore

/// Process-owned residency: closing a window does not end scheduling or work.
@MainActor @Observable
final class ResidentLifecycleController: NSObject {
    static let shared = ResidentLifecycleController()
    private(set) var loginStatus = SMAppService.mainApp.status
    private(set) var failureMessage: String?
    private(set) var isKeepingAwake = false
    var keepAwakeDuringWork: Bool {
        didSet {
            defaults.set(keepAwakeDuringWork, forKey: "resident.keepAwakeDuringWork")
            reconcileAssertion()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let createAssertion: () -> (IOReturn, IOPMAssertionID)
    @ObservationIgnored private let backgroundHasRunning: () -> Bool
    @ObservationIgnored private let releaseAssertion: (IOPMAssertionID) -> IOReturn
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var workload: (() -> Bool)?
    @ObservationIgnored private var openMainWindow: (() -> Void)?
    private var hasWork = false
    private var hasSchedulerEffects = false
    /// 定时任务当前是否正在执行（退出确认用）。
    var isSchedulerExecuting: Bool { hasSchedulerEffects }

    init(defaults: UserDefaults = .standard,
         createAssertion: @escaping () -> (IOReturn, IOPMAssertionID) = {
             var id: IOPMAssertionID = 0
             let result = IOPMAssertionCreateWithName(
                 kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                 "MinisCanvas 正在运行任务" as CFString, &id
             )
             return (result, id)
         },
         releaseAssertion: @escaping (IOPMAssertionID) -> IOReturn = { IOPMAssertionRelease($0) },
         backgroundHasRunning: @escaping () -> Bool = { BackgroundShellRegistry.shared.hasRunning }) {
        self.backgroundHasRunning = backgroundHasRunning
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        self.defaults = defaults
        keepAwakeDuringWork = defaults.object(forKey: "resident.keepAwakeDuringWork") as? Bool ?? true
        super.init()
    }

    /// 菜单栏单色 logo：与应用图标一致的倾斜环带（莫比乌斯环的简化线稿）。
    /// 模板图由系统按菜单栏深浅色自动着色；只在创建状态栏项时画一次。
    static func menuBarLogo() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: 9, yBy: 9)
            transform.rotate(byDegrees: -18)
            transform.concat()
            NSColor.black.setStroke()
            let outer = NSBezierPath(ovalIn: NSRect(x: -7.6, y: -4.6, width: 15.2, height: 9.2))
            outer.lineWidth = 1.7
            outer.stroke()
            // 内圈偏向右上，做出前宽后窄的环带透视。
            let inner = NSBezierPath(ovalIn: NSRect(x: -4.4, y: -1.0, width: 10.0, height: 4.6))
            inner.lineWidth = 1.1
            inner.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MinisCanvas"
        return image
    }

    func start(openMainWindow: @escaping () -> Void, onWake: @escaping @MainActor () -> Void, workload: @escaping () -> Bool) {
        guard statusItem == nil else { return }
        self.openMainWindow = openMainWindow
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarLogo()
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 MinisCanvas", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MinisCanvas", action: #selector(quitApplication), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onWake() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: BackgroundShellRegistry.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.backgroundActivityChanged() }
        }
        refreshLoginStatus()
        trackWorkload(workload)
    }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setLaunchAtLogin(_ enabled: Bool) {
        failureMessage = nil
        Task { @MainActor in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                failureMessage = "登录项修改失败：\(UserFacingErrorText.describe(error))"
            }
            refreshLoginStatus()
        }
    }

    func trackWorkload(_ source: @escaping () -> Bool) {
        workload = source
        observeWorkload()
    }

    func backgroundActivityChanged() { refreshWorkload() }

    private func observeWorkload() {
        guard workload != nil else { return }
        hasWork = withObservationTracking {
            workload?() ?? false
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeWorkload() }
        }
        refreshWorkload()
    }

    private func refreshWorkload() {
        guard workload != nil else { return }
        updateWorkload(hasWork: (workload?() ?? false) || backgroundHasRunning() || hasSchedulerEffects)
    }

    func schedulerExecutionChanged(isRunning: Bool) {
        hasSchedulerEffects = isRunning
        refreshWorkload()
    }

    func updateWorkload(hasWork: Bool) {
        self.hasWork = hasWork
        reconcileAssertion()
    }

    func reportStartupFailure(_ error: Error) {
        failureMessage = "后台任务恢复失败：\(UserFacingErrorText.describe(error))"
    }

    private func reconcileAssertion() {
        let needed = keepAwakeDuringWork && hasWork
        if needed && assertionID == 0 {
            let (result, id) = createAssertion()
            assertionID = id
            if result != kIOReturnSuccess {
                assertionID = 0
                failureMessage = "无法保持任务唤醒（系统错误 \(result)）"
            }
        } else if !needed && assertionID != 0 {
            let result = releaseAssertion(assertionID)
            if result == kIOReturnSuccess { assertionID = 0 }
            else { failureMessage = "释放任务唤醒失败（系统错误 \(result)）" }
        }
        isKeepingAwake = assertionID != 0
    }

    func shutdown() {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        workload = nil
        hasSchedulerEffects = false
        hasWork = false
        reconcileAssertion()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        openMainWindow = nil
    }

    @objc private func openWindow() { openMainWindow?() }
    @objc private func quitApplication() { NSApplication.shared.terminate(nil) }
}
