import AppKit
import ApplicationServices
import Foundation
import Darwin
import os
import SwiftUI
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// Synchronize callback and atexit snapshots without assuming either is actor-isolated.
private enum NativeTestMainLoopObservation {
    private struct State: Sendable {
        var mainThreadID: UInt64 = 0
        var entries = 0
        var exits = 0
        var depth = 0
        var maximumDepth = 0
        var unmatchedExits = 0
        var zeroDepthExits = 0
        var callbackRecords = 0
        var records = 0
        var exitStackEmitted = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    private static func threadID() -> UInt64 {
        var value: UInt64 = 0
        _ = pthread_threadid_np(nil, &value)
        return value
    }

    private static func summary(_ value: State) -> String {
        "entries=\(value.entries) exits=\(value.exits) depth=\(value.depth) maxDepth=\(value.maximumDepth) unmatchedExits=\(value.unmatchedExits) zeroDepthExits=\(value.zeroDepthExits) mainThreadID=\(value.mainThreadID) records=\(value.records)"
    }

    private static func emit(_ phase: String, detail: String) {
        let line = "NATIVE_MAIN_LOOP phase=\(phase) pid=\(getpid()) uptime=\(ProcessInfo.processInfo.systemUptime) currentThreadID=\(threadID()) isMainThread=\(Thread.isMainThread) \(detail)\n"
        line.utf8CString.withUnsafeBufferPointer { bytes in
            _ = write(STDERR_FILENO, bytes.baseAddress, bytes.count - 1)
        }
    }

    static func installed() {
        let current = threadID()
        let detail = state.withLock { value in
            value.mainThreadID = Thread.isMainThread ? current : 0
            value.records += 1
            return summary(value)
        }
        emit("observer-installed", detail: detail + " mode=default priorOuterEntry=UNKNOWN unmatchedExitAloneIsInsufficient=true")
    }

    static func callback(_ activity: CFRunLoopActivity) {
        let event = state.withLock { value -> (String?, Bool) in
            var firstUnmatched = false
            if activity == .entry {
                value.entries += 1
                value.depth += 1
                value.maximumDepth = max(value.maximumDepth, value.depth)
            } else if activity == .exit {
                value.exits += 1
                if value.depth > 0 {
                    value.depth -= 1
                    if value.depth == 0 { value.zeroDepthExits += 1 }
                } else {
                    value.unmatchedExits += 1
                    firstUnmatched = !value.exitStackEmitted
                    value.exitStackEmitted = true
                }
            }
            // Eight initial callbacks plus the first unmatched exit; later callbacks only count.
            let report = value.callbackRecords < 8 || firstUnmatched
            guard report, value.records < 16 else { return (nil, false) }
            value.callbackRecords += 1
            value.records += 1
            return (summary(value) + " firstUnmatched=\(firstUnmatched)", firstUnmatched)
        }
        if let detail = event.0 {
            emit(activity == .entry ? "entry" : "exit", detail: detail)
        }
        if event.1 { nativeTestHostExitStack("main-loop-first-unmatched-exit") }
    }

    static func boundary(_ phase: String) {
        guard phase == "companion-collect-return" || phase == "companion-body-end"
            || phase == "companion-defer-leave" || phase == "process-normal-exit"
            || phase == "application-will-terminate" else { return }
        // Only copy fixed state; the unsafe task handle never leaves this closure.
        let task = withUnsafeCurrentTask { current in
            (present: current != nil, cancelled: current?.isCancelled ?? false)
        }
        let detail = state.withLock { value -> String? in
            guard value.records < 16 else { return nil }
            value.records += 1
            return summary(value)
        }
        if let detail {
            emit(phase, detail: detail + " taskPresent=\(task.present) taskCancelled=\(task.cancelled)")
        }
    }
}

// Bounded test-host observations only; no lifecycle or exit interception.
func nativeTestHostBoundary(_ phase: String, detail: String = "") {
    let line = "NATIVE_HOST_BOUNDARY phase=\(phase) pid=\(getpid()) ppid=\(getppid()) uptime=\(ProcessInfo.processInfo.systemUptime) \(String(detail.prefix(768)))\n"
    line.utf8CString.withUnsafeBufferPointer { bytes in
        _ = write(STDERR_FILENO, bytes.baseAddress, bytes.count - 1)
    }
    NativeTestMainLoopObservation.boundary(phase)
}

private func nativeTestHostExitStack(_ phase: String) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 16)
    let count = frames.withUnsafeMutableBufferPointer { backtrace($0.baseAddress, Int32($0.count)) }
    guard count > 0, let symbols = frames.withUnsafeBufferPointer({ backtrace_symbols($0.baseAddress, count) }) else { return }
    defer { free(symbols) }
    for index in 0..<Int(count) {
        if let symbol = symbols[index] {
            nativeTestHostBoundary(phase + "-stack", detail: "frame=\(index) \(String(String(cString: symbol).prefix(256)))")
        }
    }
}

// Process exit can run off the main actor. A file-scope C callback avoids
// inheriting MainActor isolation from installExitObservation(_:).
private func nativeTestHostNormalExitObservation() {
    nativeTestHostBoundary("process-normal-exit")
    nativeTestHostExitStack("process-normal-exit")
}

// CF invokes this observer from nested AppKit/AX run loops too. Construct it
// outside the MainActor owner so its C block does not inherit an executor check.
// Observation state is already synchronized by NativeTestMainLoopObservation.
private func nativeTestHostMakeMainLoopObserver() -> CFRunLoopObserver? {
    CFRunLoopObserverCreateWithHandler(nil,
        CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue,
        true, 0) { _, activity in
            NativeTestMainLoopObservation.callback(activity)
        }
}

/// One process-local owner for native test host activation. A request and its
/// observed effect are reported separately. It does not start an App run loop.
@MainActor
enum NativeTestHostLifecycle {
    private static var originalPolicy: NSApplication.ActivationPolicy?
    private static var leases: [UUID: String] = [:]
    private static var windowLeases: [ObjectIdentifier: UUID] = [:]
    private static var launchDecisionConsumed = false
    private static var finishLaunchingCallCount = 0
    private static var finishLaunchingNotificationCount = 0
    private static var launchObserver: LaunchNotificationObserver?

    private static var exitObservationInstalled = false
    private static var mainLoopObserver: CFRunLoopObserver?
    private static var terminationObserver: TerminationNotificationObserver?

    @MainActor
    private final class TerminationNotificationObserver: NSObject {
        private var emitted = false
        @objc func willTerminate(_ notification: Notification) {
            guard !emitted else { return }
            emitted = true
            nativeTestHostBoundary("application-will-terminate")
            nativeTestHostExitStack("application-will-terminate")
        }
    }

    private static func installExitObservation(_ application: NSApplication) {
        guard !exitObservationInstalled else { return }
        exitObservationInstalled = true
        let loopObserver = nativeTestHostMakeMainLoopObserver()
        mainLoopObserver = loopObserver
        if let loopObserver {
            NativeTestMainLoopObservation.installed()
            CFRunLoopAddObserver(CFRunLoopGetMain(), loopObserver, CFRunLoopMode.defaultMode)
        } else {
            nativeTestHostBoundary("main-loop-observer-unavailable")
        }
        let observer = TerminationNotificationObserver()
        NotificationCenter.default.addObserver(observer,
            selector: #selector(TerminationNotificationObserver.willTerminate(_:)),
            name: NSApplication.willTerminateNotification, object: application)
        terminationObserver = observer
        let registration = atexit(nativeTestHostNormalExitObservation)
        nativeTestHostBoundary("exit-observer-installed", detail: "atexit_result=\(registration)")
        let main = Bundle.main
        let test = Bundle(for: TerminationNotificationObserver.self)
        nativeTestHostBoundary("host-identity", detail: "mainExecutable=\(String((main.executableURL?.path ?? "nil").prefix(256))) mainBundleID=\(String((main.bundleIdentifier ?? "nil").prefix(128)))")
        nativeTestHostBoundary("test-bundle-identity", detail: "testExecutable=\(String((test.executableURL?.path ?? "nil").prefix(256))) testBundleID=\(String((test.bundleIdentifier ?? "nil").prefix(128)))")
    }

    @MainActor
    private final class LaunchNotificationObserver: NSObject {
        @objc func didFinishLaunching(_ notification: Notification) {
            finishLaunchingNotificationCount += 1
            let application = NSApplication.shared
            print("NATIVE_HOST_LAUNCH phase=notification count=\(finishLaunchingNotificationCount) calls=\(finishLaunchingCallCount) finished=\(NSRunningApplication.current.isFinishedLaunching) isRunning=\(application.isRunning) isActive=\(application.isActive)")
        }
    }

    private static func observeLaunchAndDecideOnce(
        _ application: NSApplication,
        preexistingLeaseCount: Int
    ) {
        if launchObserver == nil {
            let observer = LaunchNotificationObserver()
            NotificationCenter.default.addObserver(
                observer,
                selector: #selector(LaunchNotificationObserver.didFinishLaunching(_:)),
                name: NSApplication.didFinishLaunchingNotification,
                object: application
            )
            launchObserver = observer
        }
        guard !launchDecisionConsumed else { return }
        // Consume the decision before inspecting guards or invoking AppKit. A refusal
        // or reentrant notification can never turn into a later second attempt.
        launchDecisionConsumed = true
        let finished = NSRunningApplication.current.isFinishedLaunching
        let running = application.isRunning
        let windowCount = application.windows.count
        // SwiftPM's testing helper can materialize one inert AppKit window before
        // this owner acquires its first lease. It is safe to finish launching only
        // when that window is neither visible nor key and is not leased by us.
        let preexistingWindowsAreInert = windowCount <= 1 && application.windows.allSatisfy { window in
            !window.isVisible && !window.isKeyWindow
                && windowLeases[ObjectIdentifier(window)] == nil
        }
        let delegateIsNil = application.delegate == nil
        let delegateType = application.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        let openSetting = UserDefaults.standard.object(forKey: "NSOpen")
        let openSettingIsEmpty: Bool
        if openSetting == nil {
            openSettingIsEmpty = true
        } else if let text = openSetting as? String {
            openSettingIsEmpty = text.isEmpty
        } else if let files = openSetting as? [Any] {
            openSettingIsEmpty = files.isEmpty
        } else {
            openSettingIsEmpty = false
        }
        let permitted = !running && !finished && finishLaunchingNotificationCount == 0
            && preexistingLeaseCount == 0 && preexistingWindowsAreInert
            && delegateIsNil && openSettingIsEmpty
        print("NATIVE_HOST_LAUNCH phase=decision consumed=\(launchDecisionConsumed) permitted=\(permitted) finished=\(finished) notifications=\(finishLaunchingNotificationCount) isRunning=\(running) isActive=\(application.isActive) priorLeases=\(preexistingLeaseCount) windows=\(windowCount) delegateType=\(delegateType) NSOpenEmpty=\(openSettingIsEmpty)")
        guard permitted else { return }
        finishLaunchingCallCount += 1
        application.finishLaunching()
        print("NATIVE_HOST_LAUNCH phase=returned calls=\(finishLaunchingCallCount) finished=\(NSRunningApplication.current.isFinishedLaunching) notifications=\(finishLaunchingNotificationCount) isRunning=\(application.isRunning) isActive=\(application.isActive)")
    }

    static func begin(_ label: String, requestActivation: Bool = true) -> UUID {
        let application = NSApplication.shared
        installExitObservation(application)
        let before = application.activationPolicy()
        let preexistingLeaseCount = leases.count
        if leases.isEmpty { originalPolicy = before }
        let token = UUID()
        leases[token] = label
        let policyResult: Bool? = before == .regular ? nil : application.setActivationPolicy(.regular)
        observeLaunchAndDecideOnce(application, preexistingLeaseCount: preexistingLeaseCount)
        if requestActivation {
            application.unhide(nil)
            application.activate(ignoringOtherApps: true)
        }
        let activationResult = application.isActive
        print("NATIVE_HOST_LIFECYCLE phase=acquire label=\(label) lease=\(token) count=\(leases.count) originalPolicy=\(originalPolicy?.rawValue ?? -1) beforePolicy=\(before.rawValue) currentPolicy=\(application.activationPolicy().rawValue) policyRequestResult=\(String(describing: policyResult)) activationRequestResult=\(activationResult) isRunning=\(application.isRunning) isActive=\(application.isActive)")
        return token
    }

    static func bind(_ token: UUID, to window: NSWindow) {
        precondition(leases[token] != nil && windowLeases[ObjectIdentifier(window)] == nil)
        windowLeases[ObjectIdentifier(window)] = token
        observe(window, phase: "created")
    }

    static func observe(_ window: NSWindow, phase: String) {
        let application = NSApplication.shared
        let token = windowLeases[ObjectIdentifier(window)]
        let label = token.flatMap { leases[$0] } ?? "UNBOUND"
        print("NATIVE_HOST_LIFECYCLE phase=\(phase) label=\(label) count=\(leases.count) originalPolicy=\(originalPolicy?.rawValue ?? -1) currentPolicy=\(application.activationPolicy().rawValue) isRunning=\(application.isRunning) isActive=\(application.isActive) canBecomeKey=\(window.canBecomeKey) isKey=\(window.isKeyWindow) visible=\(window.isVisible) windowFrame=\(window.frame) contentFrame=\(String(describing: window.contentView?.frame)) finished=\(NSRunningApplication.current.isFinishedLaunching) launchNotifications=\(finishLaunchingNotificationCount) launchCalls=\(finishLaunchingCallCount) launchDecisionConsumed=\(launchDecisionConsumed)")
        if phase == "sampled" {
            let bundleType = Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
            print("NATIVE_HOST_RUNTIME label=\(label) mainThread=\(Thread.isMainThread) applicationType=\(String(reflecting: type(of: application))) mainBundleIdentifier=\(String(describing: Bundle.main.bundleIdentifier)) mainBundleType=\(String(describing: bundleType)) runLoopMode=\(String(describing: RunLoop.current.currentMode?.rawValue))")
        }
    }

    /// Call after the actual window is ordered out, detached and closed.
    static func end(_ window: NSWindow) {
        observe(window, phase: "closed")
        guard let token = windowLeases.removeValue(forKey: ObjectIdentifier(window)),
              let label = leases.removeValue(forKey: token) else {
            Issue.record("native host cleanup has no matching lease")
            return
        }
        if leases.isEmpty, let observer = launchObserver {
            NotificationCenter.default.removeObserver(observer)
            launchObserver = nil
        }
        if leases.isEmpty, let policy = originalPolicy {
            let restored = NSApplication.shared.setActivationPolicy(policy)
            print("NATIVE_HOST_LIFECYCLE phase=restore label=\(label) count=0 requestedPolicy=\(policy.rawValue) restoreResult=\(restored) observedPolicy=\(NSApplication.shared.activationPolicy().rawValue) isRunning=\(NSApplication.shared.isRunning) isActive=\(NSApplication.shared.isActive)")
            originalPolicy = nil
        } else {
            print("NATIVE_HOST_LIFECYCLE phase=release label=\(label) count=\(leases.count)")
        }
    }

    // One outer test-only lease keeps the regular policy through both FileTree generations.
    // Called only after the two original per-window defers have retired all child leases.
    static func endSequence(_ token: UUID) {
        guard windowLeases.isEmpty, leases.count == 1, leases[token] != nil else {
            Issue.record("native sequence has an outstanding/unmatched window lease")
            return
        }
        leases.removeValue(forKey: token)
        if leases.isEmpty, let observer = launchObserver {
            NotificationCenter.default.removeObserver(observer); launchObserver = nil
        }
        if leases.isEmpty, let policy = originalPolicy {
            let restored = NSApplication.shared.setActivationPolicy(policy)
            print("NATIVE_HOST_LIFECYCLE phase=sequence-restore count=0 requestedPolicy=\(policy.rawValue) restoreResult=\(restored)")
            originalPolicy = nil
        }
    }
}
