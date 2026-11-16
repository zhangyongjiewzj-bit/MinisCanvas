import CoreFoundation
import AppKit
import ApplicationServices
import Foundation
import Darwin
import os
import SwiftUI
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center native close Task08 owned qualification", .serialized)
@MainActor
struct TaskCenterNativeCloseTask08OwnedQualificationTests {

    @Test
    func entryAndCloseAreNativeButtons() async throws {
        try await withOwnedTask08Fixture { fixture in
        let bridge = fixture.bridge
        let entryHost = makeHost(ContentView(bridge: bridge))
        defer { closeHost(entryHost) }

        let entry = try #require(findAX(entryHost.window, identifier: "open-task-center"))
        #expect(axRole(entry) == .button)
        #expect(axEnabled(entry))
        #expect(axLabel(entry) == "打开任务中心")
        #expect(axValue(entry) == "任务中心未打开")
        let commandMarker = bridge.commandTaskRegistrationSequence
        #expect(axPress(entry))
        guard let commandTasks = bridge.commandTaskSnapshot(after: commandMarker), commandTasks.count == 1 else {
            fixture.commandObservationFailed = true
            throw Task08OwnedFixtureError.commandDispatchNotObserved
        }
        for commandTask in commandTasks { await commandTask.value }
        fixture.observePresentationBoundary(window: entryHost.window, opener: entry, phase: "after-command-join")
        // Public press success alone is not an open/close consumer result.
        // Observe the real sheet owned by the entry host, then dismiss that sheet.
        var opened: AnyObject?
        for _ in 0..<12 {
            pumpAXRunLoop()
            opened = findAX(entryHost.window, identifier: "task-center-observation")
            if opened != nil { break }
        }
        fixture.observePresentationBoundary(window: entryHost.window, opener: entry, phase: "before-original-require")
        _ = try #require(opened, "按压入口后必须出现真实任务中心表面")
        let presentedClose = try #require(findAX(entryHost.window, identifier: "task-center-close"))
        #expect(axPress(presentedClose))
        var dismissed: Bool?
        for _ in 0..<12 {
            pumpAXRunLoop()
            dismissed = NativeConsumerOwnedAX.hasNoIdentifier(
                in: entryHost.window, prefix: "task-center-observation"
            )
            if dismissed == true { break }
        }
        let absence561_1 = dismissed == true
        try #require(absence561_1, "关闭后必须仍可完整读取宿主 AX 树")
        #expect(absence561_1)
        var openerFocused = false
        for _ in 0..<12 {
            pumpAXRunLoop()
            if let opener = findAX(entryHost.window, identifier: "open-task-center") {
                openerFocused = axFocused(opener)
            }
            if openerFocused { break }
        }
        #expect(openerFocused, "关闭真实 sheet 后，焦点必须回到原工具栏入口")

        let closeHarness = makeHost(TaskCenterObservationView(bridge: bridge))
        defer { closeHost(closeHarness) }
        let close = try #require(findAX(closeHarness.window, identifier: "task-center-close"))
        #expect(axRole(close) == .button)
        #expect(axEnabled(close))
        #expect(axLabel(close) == "关闭任务中心")
        #expect(axValue(close) == "返回当前窗口")
        #expect(axPress(close))
            }
    }

    @Test
    func escapeClosesThePresentedProductionTaskCenter() async throws {
        try await withOwnedTask08Fixture { fixture in
            let host = makeHost(ContentView(bridge: fixture.bridge))
            defer { closeHost(host) }
            let entry = try #require(findAX(host.window, identifier: "open-task-center"))
            let commandMarker = fixture.bridge.commandTaskRegistrationSequence
            try #require(axPress(entry))
            guard let commands = fixture.bridge.commandTaskSnapshot(after: commandMarker),
                  commands.count == 1 else {
                fixture.commandObservationFailed = true
                throw Task08OwnedFixtureError.commandDispatchNotObserved
            }
            for command in commands { await command.value }
            for _ in 0..<12 {
                pumpAXRunLoop()
                if findAX(host.window, identifier: "task-center-observation") != nil { break }
            }
            _ = try #require(findAX(host.window, identifier: "task-center-observation"),
                "The production entry must present Task Center before Escape is exercised")
            _ = try #require(findAX(host.window, identifier: "task-center-close"))
            let sheet = try #require(host.window.attachedSheet,
                "Escape must target the actual production sheet, not a replacement test view")
            let sheetBelongsToHost = sheet.sheetParent === host.window
            try #require(sheetBelongsToHost)
            sheet.makeKey()
            try #require(sheet.isKeyWindow && sheet.firstResponder != nil)
            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
            // Deliver once through this owned native window's responder chain.
            // Do not invoke the dismissal closure or an onExitCommand helper.
            sheet.sendEvent(escape)
            var closed = false
            for _ in 0..<12 {
                pumpAXRunLoop()
                closed = host.window.attachedSheet == nil && !sheet.isVisible
                    && NativeConsumerOwnedAX.hasNoIdentifier(
                        in: host.window, prefix: "task-center-observation") == true
                if closed { break }
            }
            #expect(closed, "A single Escape must dismiss the presented production Task Center")
        }
    }

    @Test
    func dockedProductionEntryOwnsCloseFocusAndAllThreeDismissalRoutes() async throws {
        try await withOwnedTask08Fixture { fixture in
            let host = makeHost(ContentView(bridge: fixture.bridge)
                .environment(fixture.bridge.shortcutStore), width: 1300)
            defer { closeHost(host) }
            let activationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !NSApplication.shared.isActive && ContinuousClock.now < activationDeadline {
                pumpAXRunLoop()
            }
            try #require(NSApplication.shared.isActive && host.window.isKeyWindow)
            var didReacquire = false
            for route in ["button", "escape", "commandW"] {
                if route == "escape" {
                    // Reproduce the whole-run unclaimed responder before reopening.
                    try #require(host.window.makeFirstResponder(host.window))
                    let isUnclaimedWindow = host.window.firstResponder === host.window
                    try #require(isUnclaimedWindow)
                }
                let entry = try #require(findAX(host.window, identifier: "open-task-center"))
                let marker = fixture.bridge.commandTaskRegistrationSequence
                try #require(axPress(entry))
                guard let commands = fixture.bridge.commandTaskSnapshot(after: marker), commands.count == 1 else {
                    fixture.commandObservationFailed = true
                    throw Task08OwnedFixtureError.commandDispatchNotObserved
                }
                for command in commands { await command.value }
                var close: AnyObject?
                var focused = false
                for _ in 0..<12 {
                    pumpAXRunLoop()
                    close = findAX(host.window, identifier: "task-center-close")
                    if let close {
                        focused = axFocused(close)
                    }
                    if focused { break }
                }
                _ = try #require(findAX(host.window, identifier: "task-center-undock"),
                    "The actual wide ContentView must choose its docked branch")
                try #require(host.window.attachedSheet == nil && !FloatingMenuHost.shared.isPresented)
                let activeBeforeReacquire = NSApplication.shared.isActive
                let keyBeforeReacquire = host.window.isKeyWindow
                let frontBeforeReacquire = NSWorkspace.shared.frontmostApplication
                print("TASK08_KEY_QUALIFICATION phase=before active=\(activeBeforeReacquire) key=\(keyBeforeReacquire) ownPID=\(ProcessInfo.processInfo.processIdentifier) frontPID=\(frontBeforeReacquire?.processIdentifier ?? -1) frontBundle=\(frontBeforeReacquire?.bundleIdentifier ?? "nil") reacquire=\(!activeBeforeReacquire && !didReacquire)")
                if !activeBeforeReacquire && !didReacquire {
                    didReacquire = true
                    NSApplication.shared.unhide(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    host.window.makeKey()
                    let reacquireDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while (!NSApplication.shared.isActive || !host.window.isKeyWindow)
                        && ContinuousClock.now < reacquireDeadline {
                        pumpAXRunLoop()
                    }
                }
                let frontAfterReacquire = NSWorkspace.shared.frontmostApplication
                print("TASK08_KEY_QUALIFICATION phase=after active=\(NSApplication.shared.isActive) key=\(host.window.isKeyWindow) ownPID=\(ProcessInfo.processInfo.processIdentifier) frontPID=\(frontAfterReacquire?.processIdentifier ?? -1) frontBundle=\(frontAfterReacquire?.bundleIdentifier ?? "nil") reacquire=\(didReacquire)")
                try #require(NSApplication.shared.isActive && host.window.isKeyWindow)
                try #require(host.window.firstResponder != nil)
                let action = try #require(close)
                #expect(axRole(action) == .button && axEnabled(action))
                #expect(axLabel(action) == "关闭任务中心")
                if route == "button" {
                    try #require(axPress(action))
                } else {
                    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: route == "commandW" ? [.command] : [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: host.window.windowNumber, context: nil,
                        characters: route == "commandW" ? "w" : "\u{1b}",
                        charactersIgnoringModifiers: route == "commandW" ? "w" : "\u{1b}",
                        isARepeat: false, keyCode: route == "commandW" ? 13 : 53))
#if DEBUG
                    if event.keyCode == 53 { print("TASK08_BEFORE_ESCAPE firstResponderClass=\(host.window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil")") }
#endif
                    host.window.sendEvent(event)
                }
                var closed = false
                for _ in 0..<12 {
                    pumpAXRunLoop()
                    closed = NativeConsumerOwnedAX.hasNoIdentifier(in: host.window, prefix: "task-center-close") == true
                        && NativeConsumerOwnedAX.hasNoIdentifier(in: host.window, prefix: "task-center-undock") == true
                    if closed { break }
                }
                #expect(closed && host.window.isVisible,
                    "Each original dismissal route must close the docked surface and retain its parent window; route=\(route), observed close focus=\(focused)")
                let reopenedEntry = try #require(findAX(host.window, identifier: "open-task-center"))
                #expect(axValue(reopenedEntry) == "任务中心未打开")
            }
        }
    }

    @Test
    func userReturningToTheNativeComposerKeepsIMEFocusInsteadOfClosingTheDock() async throws {
        try await withOwnedTask08Fixture { fixture in
            let host = makeHost(ContentView(bridge: fixture.bridge)
                .environment(fixture.bridge.shortcutStore), width: 1300)
            defer { closeHost(host) }
            let entry = try #require(findAX(host.window, identifier: "open-task-center"))
            let marker = fixture.bridge.commandTaskRegistrationSequence
            try #require(axPress(entry))
            guard let commands = fixture.bridge.commandTaskSnapshot(after: marker), commands.count == 1 else {
                fixture.commandObservationFailed = true
                throw Task08OwnedFixtureError.commandDispatchNotObserved
            }
            for command in commands { await command.value }
            for _ in 0..<12 { pumpAXRunLoop() }
            _ = try #require(findAX(host.window, identifier: "task-center-undock"))
            try #require(host.window.attachedSheet == nil && !FloatingMenuHost.shared.isPresented)
            try #require(NSApplication.shared.isActive && host.window.isKeyWindow)
            @MainActor func composer(in view: NSView) -> ComposerPasteAwareTextView? {
                if let input = view as? ComposerPasteAwareTextView { return input }
                return view.subviews.lazy.compactMap { composer(in: $0) }.first
            }
            let input = try #require(composer(in: host.view))
            // This is the user's subsequent return to the existing Composer,
            // never a Test repair of the close button's initial focus.
            try #require(host.window.makeFirstResponder(input))
            let composerOwnsFocusBeforeEscape1 = host.window.firstResponder === input
            try #require(composerOwnsFocusBeforeEscape1)
            input.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            try #require(input.hasMarkedText())
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
            host.window.sendEvent(escape)
            for _ in 0..<12 { pumpAXRunLoop() }
            let composerStillOwnsFocus = host.window.firstResponder === input
            #expect(composerStillOwnsFocus)
            #expect(!input.hasMarkedText(), "Escape must finish the native conversion, not merely swallow the key")
            _ = try #require(findAX(host.window, identifier: "task-center-undock"))
            _ = try #require(findAX(host.window, identifier: "task-center-close"))
            #expect(!fixture.bridge.chat.isActiveSessionGenerating)
            input.unmarkText()
        }
    }

    @Test
    func nativeComposerConsumesPreparingStopAndSlashEscapeBeforeDockedExit() async throws {
        try await withOwnedTask08Fixture { fixture in
            let chat = fixture.bridge.chat
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let previousPause = chat.turnPromptPreprocessPauseForTests
            let previousProvider = chat.streamingProviderOverride
            var running: Task<Void, Never>?
            var completion: Task<Void, Never>?
            let outcome: Result<Void, any Error>
            do {
                let host = makeHost(ContentView(bridge: fixture.bridge)
                    .environment(fixture.bridge.shortcutStore), width: 1300)
                defer { closeHost(host) }
                let entry = try #require(findAX(host.window, identifier: "open-task-center"))
                let marker = fixture.bridge.commandTaskRegistrationSequence
                try #require(axPress(entry))
                guard let commands = fixture.bridge.commandTaskSnapshot(after: marker), commands.count == 1 else {
                    fixture.commandObservationFailed = true
                    throw Task08OwnedFixtureError.commandDispatchNotObserved
                }
                for command in commands { await command.value }
                for _ in 0..<12 { pumpAXRunLoop() }
                _ = try #require(findAX(host.window, identifier: "task-center-undock"))
                try #require(host.window.attachedSheet == nil && !FloatingMenuHost.shared.isPresented)
                let activeBeforeReacquire = NSApplication.shared.isActive
                let keyBeforeReacquire = host.window.isKeyWindow
                let frontBeforeReacquire = NSWorkspace.shared.frontmostApplication
                print("TASK08_KEY_QUALIFICATION phase=before active=\(activeBeforeReacquire) key=\(keyBeforeReacquire) ownPID=\(ProcessInfo.processInfo.processIdentifier) frontPID=\(frontBeforeReacquire?.processIdentifier ?? -1) frontBundle=\(frontBeforeReacquire?.bundleIdentifier ?? "nil") reacquire=\(!activeBeforeReacquire)")
                if !activeBeforeReacquire {
                    NSApplication.shared.unhide(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    host.window.makeKey()
                    let reacquireDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while (!NSApplication.shared.isActive || !host.window.isKeyWindow)
                        && ContinuousClock.now < reacquireDeadline {
                        pumpAXRunLoop()
                    }
                }
                let frontAfterReacquire = NSWorkspace.shared.frontmostApplication
                print("TASK08_KEY_QUALIFICATION phase=after active=\(NSApplication.shared.isActive) key=\(host.window.isKeyWindow) ownPID=\(ProcessInfo.processInfo.processIdentifier) frontPID=\(frontAfterReacquire?.processIdentifier ?? -1) frontBundle=\(frontAfterReacquire?.bundleIdentifier ?? "nil") reacquire=\(!activeBeforeReacquire)")
                try #require(NSApplication.shared.isActive && host.window.isKeyWindow)
                @MainActor func composer(in view: NSView) -> ComposerPasteAwareTextView? {
                    if let input = view as? ComposerPasteAwareTextView { return input }
                    return view.subviews.lazy.compactMap { composer(in: $0) }.first
                }
                let input = try #require(composer(in: host.view))
                try #require(host.window.makeFirstResponder(input))
                let composerOwnsFocusBeforeEscape2 = host.window.firstResponder === input
                try #require(composerOwnsFocusBeforeEscape2)
                let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53))
                // Pause only the existing real turn preprocessor, before a
                // Provider call. The actual Composer event must retire this turn.
                chat.streamingProviderOverride = MockProvider.shared
                chat.turnPromptPreprocessPauseForTests = {
                    entered.continuation.yield(())
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                }
                chat.draftText = "合成停止对照，不执行任何工具。"
                let session = try #require(chat.activeSessionID)
                chat.submitComposer()
                let task = try #require(chat.turnTaskForTests(sessionID: session))
                running = task
                completion = Task { await task.value; entered.continuation.finish() }
                var started = entered.stream.makeAsyncIterator()
                _ = try #require(await started.next(), "The owned turn must enter the real preparation seam")
                try #require(chat.isActiveSessionGenerating)
                let composerOwnsFocusBeforeEscape3 = host.window.firstResponder === input
                try #require(composerOwnsFocusBeforeEscape3)
                host.window.sendEvent(escape)
                #expect(!chat.isActiveSessionGenerating,
                    "Composer must consume Escape as Stop before the ancestor can close the dock")
                _ = try #require(findAX(host.window, identifier: "task-center-undock"))
                release.continuation.finish()
                await task.value
                await completion?.value
                chat.turnPromptPreprocessPauseForTests = previousPause
                chat.draftText = "/co"
                for _ in 0..<12 {
                    pumpAXRunLoop()
                    if findAX(host.window, identifier: "composer.slash-completions") != nil { break }
                }
                _ = try #require(findAX(host.window, identifier: "composer.slash-completions"))
                try #require(host.window.makeFirstResponder(input))
                let composerOwnsFocusBeforeEscape4 = host.window.firstResponder === input
                try #require(composerOwnsFocusBeforeEscape4)
                try #require(NSApplication.shared.isActive && host.window.isKeyWindow)
                host.window.sendEvent(escape)
                for _ in 0..<12 { pumpAXRunLoop() }
                #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: host.window,
                    prefix: "composer.slash-completions") == true)
                #expect(chat.draftText == "/co" && !chat.isActiveSessionGenerating)
                _ = try #require(findAX(host.window, identifier: "task-center-undock"))
                _ = try #require(findAX(host.window, identifier: "task-center-close"))
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            // Even a failed entry/precondition releases every existing handle
            // before the owning fixture removes its isolated roots.
            release.continuation.finish()
            entered.continuation.finish()
            chat.turnPromptPreprocessPauseForTests = previousPause
            chat.stopAllStreamingForSafety()
            if let running { await running.value }
            if let completion { await completion.value }
            chat.streamingProviderOverride = previousProvider
            try outcome.get()
        }
    }

    @Test
    func responderOpenerReturnsAfterDismissal() async throws {
        try await withOwnedTask08Fixture { fixture in
        let host = makeHost(EmptyView())
        defer { closeHost(host) }
        let editor = NSTextField(frame: NSRect(x: 20, y: 20, width: 120, height: 24))
        host.view.addSubview(editor)
        @MainActor
        func originalEditorIsActive() -> Bool {
            guard editor.window === host.window,
                  let fieldEditor = editor.currentEditor(),
                  fieldEditor.isFieldEditor, fieldEditor.window === host.window,
                  let current = host.window.firstResponder else { return false }
            return current === fieldEditor
        }
        try #require(host.window.makeFirstResponder(editor))
        try #require(originalEditorIsActive())
        let focusReturn = TaskCenterOpenerFocus()
        let logicalOwnerMatchCount = focusReturn.capture(toolbarOpener: false, window: host.window)
        print("TASK08_LOGICAL_OWNER_MATCHES count=\(logicalOwnerMatchCount.map { String($0) } ?? "UNKNOWN")")
        #expect(logicalOwnerMatchCount == 1)
        try #require(host.window.makeFirstResponder(nil))
        #expect(!originalEditorIsActive())

        #expect(focusReturn.restore() == .responder)
        #expect(originalEditorIsActive())
            }
    }

}

@MainActor
private func makeHost<V: View>(_ rootView: V, width: CGFloat = 900) -> (window: NSWindow, view: NSView) {
    let hostLease = NativeTestHostLifecycle.begin("TaskCenter")
    let controller = NSHostingController(rootView: AnyView(rootView))
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    NativeTestHostLifecycle.bind(hostLease, to: window)
    Task08OwnedFixture.current?.windows.append(window)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(NSSize(width: width, height: 700))
    let view = controller.view
    view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
    window.orderFrontRegardless()
    _ = NSRunningApplication.current.activate(options: [])
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.display()
    pumpAXRunLoop()
    NativeTestHostLifecycle.observe(window, phase: "sampled")
    return (window, view)
}

@MainActor
private func closeHost(_ host: (window: NSWindow, view: NSView)) {
    do {
        try withOwnedTask08NativeRunLoopScope {
    let id = ObjectIdentifier(host.window)
    if Task08OwnedFixture.current?.closedWindows.contains(id) == true { return }
    for sheet in host.window.sheets {
        host.window.endSheet(sheet, returnCode: .cancel)
        sheet.orderOut(nil)
    }
    host.window.orderOut(nil)
    host.window.contentViewController = nil
    host.window.close()
    NativeTestHostLifecycle.end(host.window)
    Task08OwnedFixture.current?.closedWindows.insert(id)
        }
    } catch {
        Task08OwnedFixture.current?.windowCleanupErrors.append(error)
    }
}




private enum Task08OwnedFixtureError: Error {
    case nestedFixture, unexpectedWriterOrLiveWindow, cleanupDidNotRemoveRoot, commandDispatchNotObserved
    case windowCleanup([any Error])
    case combined(business: any Error, cleanup: any Error)
}

@MainActor
private final class Task08OwnedFixture {
    static var current: Task08OwnedFixture?
    let profile: RuntimeIsolationProfile
    let bridge: BridgeStore
    var windows: [NSWindow] = []
    var closedWindows: Set<ObjectIdentifier> = []
    var windowCleanupErrors: [any Error] = []
    var commandObservationFailed = false

    init() throws {
        guard Task08OwnedFixture.current == nil else { throw Task08OwnedFixtureError.nestedFixture }
        guard try FormalTestIsolationPaths.resolveCurrentProcess() != nil else {
            throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
        }
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "task08-native-owned", canvasRuntimeState: .disabled)
        self.profile = profile
        try qualifyTask08RootBeforeStores(profile)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let workflow = WorkflowStore(storeDirectory: root.appendingPathComponent("workflows"))
        bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: workflow,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            agentTaskStore: AgentTaskStore(),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            commandEnvStore: profile.makeEnvironmentStore(keychain: keychain),
            canonicalMCPManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")),
            canvasFeatureLane: .phase3NonCanvas)
        // This close/focus fixture opens no picker, sends no message and does not
        // attach production services. Even an accidental picker load sees only
        // this empty synthetic catalogue, never the user's skills directory.
        bridge.chat.pickerCatalogLoader = { [] }
    }

    func observePresentationBoundary(window: NSWindow, opener: AnyObject, phase: String) {
        let identifier = window.accessibilityIdentifier()
        let application = AXUIElementCreateApplication(getpid())
        _ = AXUIElementSetMessagingTimeout(application, 0.05)
        var rawWindows: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
        let all = (windowStatus == .success ? rawWindows as? [AXUIElement] : nil) ?? []
        let owners = all.filter {
            (NativeConsumerOwnedAX.attribute($0, kAXIdentifierAttribute as CFString) as? String) == identifier
        }
        var sheetStatus: AXError = .failure
        var projectedSheetCount = -1
        if owners.count == 1, let owner = owners.first {
            var rawSheets: CFTypeRef?
            sheetStatus = AXUIElementCopyAttributeValue(owner, "AXSheets" as CFString, &rawSheets)
            if sheetStatus == .success, let sheets = rawSheets as? [AXUIElement] { projectedSheetCount = sheets.count }
        }
        let value = axValue(opener) ?? "UNREADABLE"
        print("TASK08_PRESENTATION phase=\(phase) commandSequence=\(bridge.commandTaskRegistrationSequence) unfinishedCommands=\(bridge.hasUnfinishedOwnedCommandTasks) intentPresent=\(bridge.taskCenterOpenIntent != nil) openerValue=\(value) appKitSheetCount=\(window.sheets.count) appKitSheetsBound=\(window.sheets.allSatisfy { $0.sheetParent === window }) axWindowsStatus=\(windowStatus.rawValue) exactOwnerCount=\(owners.count) ownerAXSheetsStatus=\(sheetStatus.rawValue) ownerAXSheetsCount=\(projectedSheetCount)")
    }

    func finish() throws {
        for window in windows where !closedWindows.contains(ObjectIdentifier(window)) {
            if let view = window.contentView { closeHost((window, view)) }
        }
        if !windowCleanupErrors.isEmpty { throw Task08OwnedFixtureError.windowCleanup(windowCleanupErrors) }
        // The command that AXPress registered has been joined by its exact Task.value.
        // Never equate cancellation with completion: any unexpected owned task
        // or attached surface refuses deletion and preserves the precise root.
        guard !commandObservationFailed, !bridge.hasUnfinishedOwnedCommandTasks,
              windows.allSatisfy({ !$0.isVisible && $0.sheets.isEmpty && $0.contentViewController == nil }),
              !bridge.chat.isStreaming,
              !bridge.chat.hasStreamingTasksForSafety,
              bridge.chat.turnTaskForTests(sessionID: bridge.chat.activeSessionID) == nil,
              !bridge.chat.isPickerCatalogLoading,
              bridge.chat.usageStore == nil,
              bridge.chat.sessionStore == nil,
              bridge.orchestrationChildGovernor == nil,
              bridge.lastCanvasMutationTask == nil,
              bridge.lastAgentAdjustTask == nil,
              bridge.lastChildGovernorSafetyTask == nil,
              bridge.lastChildGovernorCheckpointTask == nil,
              !bridge.workflowChat.isRunning else {
            print("TASK08_OWNED_CLEANUP refused=true retained=\(profile.rootDirectory.path)")
            throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
        }
        try profile.validateDisposableTree()
        try profile.cleanupDisposableRoots()
        var absent = stat()
        guard lstat(profile.rootDirectory.path, &absent) == -1, errno == ENOENT else {
            throw Task08OwnedFixtureError.cleanupDidNotRemoveRoot
        }
        if let suite = profile.userDefaultsSuiteName,
           UserDefaults.standard.persistentDomain(forName: suite) != nil {
            throw Task08OwnedFixtureError.cleanupDidNotRemoveRoot
        }
        print("TASK08_OWNED_CLEANUP windows=0 unexpectedWriters=0 ENOENT=true root=\(profile.rootDirectory.path)")
    }
}

@MainActor
private func withOwnedTask08Fixture(_ body: (Task08OwnedFixture) async throws -> Void) async throws {
    let fixture = try Task08OwnedFixture()
    Task08OwnedFixture.current = fixture
    defer { Task08OwnedFixture.current = nil }
    let business: Result<Void, any Error>
    do { try await body(fixture); business = .success(()) }
    catch { business = .failure(error) }
    do { try fixture.finish() }
    catch {
        if case .failure(let original) = business {
            throw Task08OwnedFixtureError.combined(business: original, cleanup: error)
        }
        throw error
    }
    try business.get()
}

private enum Task08NativeRunLoopScopeError: Error {
    case notMainThread
    case fixtureCallbackNotDelivered
}

@MainActor
private final class Task08NativeRunLoopScopeState {
    var operation: (() throws -> Void)?
    var completion: Result<Void, any Error>?

    init(_ operation: @escaping () throws -> Void) {
        self.operation = operation
    }
}

/// Keep the native fixture's launch, window teardown and policy restoration
/// inside a run-loop invocation owned by this fixture. A stop requested there
/// must not unwind SwiftPM's outer async-main executor before Testing records
/// the method's completion. This does not change the test's assertions or
/// translate a missing callback/error into success.
@MainActor
func withOwnedTask08NativeRunLoopScope(_ body: () throws -> Void) throws {
    guard Thread.isMainThread else { throw Task08NativeRunLoopScopeError.notMainThread }
    try withoutActuallyEscaping(body) { escapedBody in
        let state = Task08NativeRunLoopScopeState(escapedBody)
        // If delivery fails, a retained CF block can no longer invoke the
        // nonescaping body after this scope has returned.
        defer { state.operation = nil }
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                guard let operation = state.operation else { return }
                state.operation = nil
                nativeTestHostBoundary("task08-owned-loop-fixture-enter")
                state.completion = Result { try operation() }
                nativeTestHostBoundary("task08-owned-loop-fixture-complete")
                // This callback runs inside the invocation below. Completion,
                // including throwing cleanup, ends that invocation immediately.
                CFRunLoopStop(loop)
            }
        }
        CFRunLoopWakeUp(loop)
        nativeTestHostBoundary("task08-owned-loop-enter")
        // A delivery deadline only: the completion callback stops this loop
        // immediately, rather than sleeping after the fixture has finished.
        let returned = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 10, false)
        nativeTestHostBoundary("task08-owned-loop-return", detail:
            "result=\(returned.rawValue) callbackCompleted=\(state.completion != nil)")
        guard let completion = state.completion else {
            throw Task08NativeRunLoopScopeError.fixtureCallbackNotDelivered
        }
        try completion.get()
    }
}


// Tests-only permission qualification on the real profile's captured inode, before any Store/Task.
@MainActor
private func qualifyTask08RootBeforeStores(_ profile: RuntimeIsolationProfile) throws {
    guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess(),
          let captured = profile.disposableRootIdentity else {
        throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
    }
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let root = profile.rootDirectory
    let prefix = "MinisCanvasAppTests-task08-native-owned-"
    guard root.deletingLastPathComponent().resolvingSymlinksInPath() == parent,
          root.lastPathComponent.hasPrefix(prefix),
          UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
        throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
    }
    var parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    var rootFD: Int32 = -1
    defer {
        if rootFD >= 0, close(rootFD) != 0 { Issue.record("Task08 root qualification FD close failed") }
        if parentFD >= 0, close(parentFD) != 0 { Issue.record("Task08 parent qualification FD close failed") }
    }
    guard parentFD >= 0 else { throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow }
    var parentInfo = stat()
    guard fstat(parentFD, &parentInfo) == 0,
          parentInfo.st_mode & S_IFMT == S_IFDIR,
          parentInfo.st_mode & 0o777 == 0o700,
          parentInfo.st_uid == geteuid(), UInt32(parentInfo.st_uid) == formal.rootOwner else {
        throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
    }
    rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootFD >= 0 else { throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow }
    var before = stat()
    guard fstat(rootFD, &before) == 0,
          before.st_mode & S_IFMT == S_IFDIR, before.st_uid == geteuid(),
          before.st_dev == parentInfo.st_dev, before.st_ino != parentInfo.st_ino,
          UInt64(before.st_dev) == captured.device, UInt64(before.st_ino) == captured.inode,
          [mode_t(0o755), mode_t(0o700)].contains(before.st_mode & 0o777) else {
        throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
    }
    try profile.validateDisposableTree()
    guard fchmod(rootFD, 0o700) == 0 else { throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow }
    var after = stat()
    guard fstat(rootFD, &after) == 0, after.st_dev == before.st_dev,
          after.st_ino == before.st_ino, after.st_uid == before.st_uid,
          after.st_mode & S_IFMT == S_IFDIR, after.st_mode & 0o777 == 0o700 else {
        throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow
    }
    try profile.validateDisposableRootIdentity()
    let rootClose = close(rootFD); rootFD = -1
    let parentClose = close(parentFD); parentFD = -1
    guard rootClose == 0, parentClose == 0 else { throw Task08OwnedFixtureError.unexpectedWriterOrLiveWindow }
    print("TASK08_ROOT_QUALIFIED_BEFORE_STORE dev=\(after.st_dev) inode=\(after.st_ino) uid=\(after.st_uid) beforeMode=\(before.st_mode & 0o777) afterMode=700")
}
