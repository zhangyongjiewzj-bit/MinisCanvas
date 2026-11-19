import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

// P3-SET-01 · lane 155 (QODER-DEV-W12-SET01-DESCRIPTOR-COVERAGE-AND-
// SINGLE-CLOSE-ENTRY-155): closure side of the coverage ruling.
//
// Lane 148 shipped the orphan gate plus a 36-entry frozen tolerance list.
// Lane 155 adjudicated every tolerance:
//   R1 — 34 bindings now resolve to canonical descriptors (25 new
//        binding-granularity rows plus `uiBindings` proxies on the existing
//        `browser` / `__miniscanvas.safetyControl` aggregates and the renamed
//        fields `browserViewportMode` / `terminalPolicySettings` /
//        `privacyLogLevel` / `liveLogLevel`). Only structurally
//        non-persistent bindings stay tolerated.
//   R2 — real SettingsView close/cancel, notification navigation and owned
//        sheet termination behavior. Private App initial-page cleanup and
//        entry-point composition require the separately listed package journey.
//
// This suite does not inspect source text. Native execution belongs to the
// qualified exact-R13 intake; parse alone is not a runtime result.

/// The 34 lane-148 tolerances that closed to canonical descriptors in lane 155.
private let lane155BoundTolerances: Set<String> = [
    "userAgentPreset", "customUserAgent", "browserViewportMode",
    "customViewportWidth", "customViewportHeight", "idleTabTimeoutMinutes",
    "safeModeEnabled", "killSwitchEnabled", "uiBaseFontSize",
    "approvalPolicy", "autoCompactThreshold", "autoDeleteOldSessions",
    "availableModelWhitelist", "chatOutputMode", "collectAnalytics",
    "composerPolicy", "concurrentToolLimit", "defaultModelID",
    "defaultProviderID", "fallbackEnabled", "language", "liveLogLevel",
    "maxLoopIterations", "memoryEnabled", "globalInstructionsEnabled", "modelSpeedTier",
    "newMessageInterruptsGeneration", "persona", "personaEnabled",
    "privacyLogLevel", "redactEnvValues", "sessionRetentionDays",
    "subModelID", "terminalPolicySettings", "toolTimeoutSeconds"
]

/// Lane-155 descriptor rulings bind their SettingsCenter proxy names to the
/// descriptor that owns the persisted state. These pairings are the ruling
/// itself; deleting a pairing must fail here, not silently in the gate.
private let lane155ProxyPairings: [(key: String, proxies: [String])] = [
    ("browser", ["userAgentPreset", "customUserAgent", "browserViewportMode",
                 "customViewportWidth", "customViewportHeight", "idleTabTimeoutMinutes"]),
    ("__miniscanvas.safetyControl", ["safeModeEnabled", "killSwitchEnabled"]),
    ("agent.approvalPolicy", ["toolsDisabled"]),
    ("agent.terminalPolicy", ["terminalPolicySettings"]),
    ("agent.approvalTimeoutSeconds", ["expirationInterval"]),
    ("privacy.logLevel", ["privacyLogLevel", "liveLogLevel"])
]

@Suite("P3-SET-01 descriptor coverage and single close entry 155")
struct SettingsDescriptorCoverageCloseEntry155Tests {

    private func canonical(_ key: String) -> PersistentStateDescriptor? {
        SettingsStateClassification.canonicalDescriptor(for: key)
    }

    @Test
    func everyLane155ToleranceNowResolvesToACanonicalDescriptor() {
        let descriptors = SettingsStateClassification.descriptors(for: .canonicalSetting)
        for name in lane155BoundTolerances {
            let matches = descriptors.filter {
                $0.settingsKey == name
                    || $0.settingsKey?.split(separator: ".").last.map(String.init) == name
                    || $0.uiBindings.contains(name)
            }
            #expect(
                !matches.isEmpty,
                "P3-SET-01 lane 155: tolerance '\(name)' was deleted from the frozen list but no canonical descriptor resolves it"
            )
        }
    }

    @Test
    @MainActor
    func bindingProxyDeclarationsMatchTheLane155Ruling() throws {
        for (key, proxies) in lane155ProxyPairings {
            let descriptor = try #require(
                canonical(key),
                "P3-SET-01 lane 155: descriptor for '\(key)' vanished"
            )
            #expect(
                Set(descriptor.uiBindings) == Set(proxies),
                "proxy declaration drift on '\(key)': \(descriptor.uiBindings.sorted())"
            )
        }
        // A proxy name must belong to exactly one descriptor; two rows
        // claiming one UI binding would re-open the second-truth problem.
        var seen = Set<String>()
        for descriptor in SettingsStateClassification.descriptors(for: .canonicalSetting) {
            for proxy in descriptor.uiBindings {
                #expect(!seen.contains(proxy), "'\(proxy)' claimed by more than one canonical descriptor")
                seen.insert(proxy)
            }
        }
        // These are real compiled property references, not declarations found
        // in a text file. A removed/renamed property is a compile-time failure;
        // descriptor additions must still resolve to a concrete target.
        let targets: [String: PartialKeyPath<SettingsCenter>] = [
            "userAgentPreset": \.userAgentPreset,
            "customUserAgent": \.customUserAgent,
            "browserViewportMode": \.browserViewportMode,
            "customViewportWidth": \.customViewportWidth,
            "customViewportHeight": \.customViewportHeight,
            "idleTabTimeoutMinutes": \.idleTabTimeoutMinutes,
            "safeModeEnabled": \.safeModeEnabled,
            "allowLocalAgentSessionRead": \.allowLocalAgentSessionRead,
            "killSwitchEnabled": \.killSwitchEnabled,
            "toolsDisabled": \.toolsDisabled,
            "legacyAutomaticApprovalCompatibilityActive": \.legacyAutomaticApprovalCompatibilityActive,
            "legacyApprovalPolicyNoticePending": \.legacyApprovalPolicyNoticePending,
            "legacyApprovalScopeNoticePending": \.legacyApprovalScopeNoticePending,
            "shellCommandTimeoutSeconds": \.shellCommandTimeoutSeconds,
            "maxTokensPerSession": \.maxTokensPerSession,
            "tokenBudgetUnlimited": \.tokenBudgetUnlimited,
            "maxLoopIterationsNoticePending": \.maxLoopIterationsNoticePending,
            "stripModelShellCredentials": \.stripModelShellCredentials,
            "modelShellNoninteractive": \.modelShellNoninteractive,
            "browserWriteEnabled": \.browserWriteEnabled,
            "fileCheckpointsEnabled": \.fileCheckpointsEnabled,
            "backgroundAutoContinueEnabled": \.backgroundAutoContinueEnabled,
            "childMutationsEnabled": \.childMutationsEnabled,
            "childDeletionAutoReviewEnabled": \.childDeletionAutoReviewEnabled,
            "terminalPolicySettings": \.terminalPolicySettings,
            "expirationInterval": \.approvalTimeoutSecondsSetting,
            "privacyLogLevel": \.privacyLogLevel,
            "liveLogLevel": \.liveLogLevel,
            "fileAccessAllowedRoot": \.fileAccessAllowedRoot,
            "fileAccessDeniedRoots": \.fileAccessDeniedRoots,
            "mountedFolderPaths": \.mountedFolderPaths,
        ]
        #expect(Set(targets.keys) == seen, "descriptor proxies must match the compiled SettingsCenter surface")
        for proxy in seen {
            _ = try #require(targets[proxy], "uiBindings proxy '\(proxy)' has no compiled SettingsCenter property")
        }
    }

    @Test
    @MainActor
    func everyLane155DescriptorSurfaceIsReachableFromProductionProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01Coverage155-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        let projection = center.settingsAppliedStateProjection
        let surfaced = Set(projection.liveAppliedSettingKeys).union(projection.restartRequiredSettingKeys)
        // The projection is built from the descriptor table by SettingsCenter
        // itself, so each new key surfacing here is production reachability,
        // not test-only wiring (consumer: SettingsAppliedStateBanner).
        for key in [
            "general.defaultProviderID", "general.defaultModelID", "general.subModelID",
            "general.modelSpeedTier", "general.chatOutputMode", "general.language",
            "agent.maxLoopIterations", "agent.toolTimeoutSeconds", "agent.shellCommandTimeoutSeconds", "agent.concurrentToolLimit",
            "agent.autoCompactThreshold", "agent.fallbackEnabled", "agent.memoryEnabled", "agent.globalInstructionsEnabled", "agent.fileCheckpointsEnabled",
            "agent.approvalPolicy", "agent.availableModelWhitelist",
            "agent.newMessageInterruptsGeneration", "agent.composerPolicy",
            "agent.personaEnabled", "agent.persona", "agent.terminalPolicy",
            "privacy.redactEnvValues", "privacy.collectAnalytics", "privacy.logLevel",
            "storage.sessionRetentionDays", "storage.autoDeleteOldSessions",
            "typography.uiBaseFontSize"
        ] {
            #expect(surfaced.contains(key), "lane 155 descriptor '\(key)' never reaches the applied-state projection")
            #expect(canonical(key) != nil, "lane 155 descriptor '\(key)' vanished")
        }
    }

    @Test
    func lane155CanonicalRowsCarryCompleteDeclarations() {
        for descriptor in SettingsStateClassification.descriptors(for: .canonicalSetting) {
            #expect(!descriptor.scope.isEmpty, "\(descriptor.settingsKey ?? "?"): empty scope")
            #expect(!descriptor.defaultValue.isEmpty, "\(descriptor.settingsKey ?? "?"): empty default")
            #expect(!descriptor.persistence.isEmpty, "\(descriptor.settingsKey ?? "?"): empty persistence")
            #expect(!descriptor.restart.isEmpty, "\(descriptor.settingsKey ?? "?"): empty restart")
            #expect(!descriptor.reset.isEmpty, "\(descriptor.settingsKey ?? "?"): empty reset")
            #expect(!descriptor.validation.isEmpty, "\(descriptor.settingsKey ?? "?"): empty validation")
            #expect(!descriptor.consumer.isEmpty, "\(descriptor.settingsKey ?? "?"): empty consumer")
            // R1 acceptance binding: every canonical row declares both a key
            // and an effective source (P3 matrix test enforces uniqueness;
            // this enforces lane 155's coverage contract per row).
            #expect(descriptor.settingsKey != nil)
            #expect(descriptor.effectiveSource != nil)
        }
    }

    /// Actual consumers, with an owned native sheet. No assertion infers
    /// behavior from spelling/formatting of MinisCanvasApp or SettingsView.
    @Test
    @MainActor
    func settingsSurfaceClosesOnlyThroughTheCanonicalDismissPath() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let native = SettingsNativeInteractionConsumerTests()
            let center = fixture.makeCenter()
            let shortcuts = ShortcutStore(defaults: fixture.defaults)
            let skills = SkillsStore(appStore: center.skillStore,
                stateFileURL: fixture.root.appendingPathComponent("close155-skills.json"), loadImmediately: false)
            let scheduler = SchedulerTaskStore(defaults: fixture.defaults)
            let presentation = Lane155SheetPresentation()
            let controller = NSHostingController(rootView: Lane155SettingsSheetHost(
                presentation: presentation, center: center, shortcuts: shortcuts,
                skills: skills, scheduler: scheduler))
            controller.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            let lease = NativeTestHostLifecycle.begin("Close155")
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            window.setAccessibilityIdentifier("close155-host-" + UUID().uuidString)
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            defer {
                presentation.isPresented = false
                native.pumpSettingsRunLoop()
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
                NativeTestHostLifecycle.end(window)
            }
            @MainActor
            func waitFor(_ condition: @MainActor () -> Bool) -> Bool {
                for _ in 0..<40 {
                    window.layoutIfNeeded()
                    controller.view.layoutSubtreeIfNeeded()
                    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                    native.pumpSettingsRunLoop()
                    if condition() { return true }
                }
                return false
            }
            @MainActor
            func openSettings() throws -> NSWindow {
                presentation.isPresented = true
                try #require(waitFor { window.attachedSheet != nil }, "real SwiftUI Settings sheet did not attach")
                let sheet = try #require(window.attachedSheet)
                sheet.makeKeyAndOrderFront(nil)
                try #require(waitFor {
                    native.findSettingsAX(in: window, identifier: "settings.close") != nil
                }, "production settings.close action did not become accessible")
                return sheet
            }
            @MainActor
            func requireClosed() throws {
                try #require(waitFor { window.attachedSheet == nil }, "Settings action did not dismiss its actual sheet")
                #expect(!presentation.isPresented)
                #expect(window.isVisible, "closing Settings must keep the owning window")
            }

            // The real production title button must drive SwiftUI dismiss.
            _ = try openSettings()
            let close = try #require(native.findSettingsAX(in: window, identifier: "settings.close"))
            try #require(native.settingsAXPress(close, in: window))
            try requireClosed()

            // Send a real Escape key to the owned sheet; no test close callback
            // supplies its outcome. SettingsView owns cancelAction/escapeShortcut.
            let sheet = try openSettings()
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.postEvent(escape, atStart: true)
            try requireClosed()

            // Exercise the production notification navigation binding, with OS
            // delivery disabled and synthetic sessions in the owned fixture.
            let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: fixture.defaults,
                logManager: center.logManager,
                workflowStore: WorkflowStore(storeDirectory: fixture.root.appendingPathComponent("workflows")),
                sessionBadgeStore: fixture.badges,
                sessionStore: SessionStore(directory: fixture.root.appendingPathComponent("notification-sessions")),
                canvasRuntimeState: .disabled,
                memoryStore: MemoryStore(directory: fixture.root.appendingPathComponent("notification-memory")),
                canvasFeatureLane: .phase3NonCanvas)
            let target = bridge.chat.applyNewSession(title: "Close155 notification target")
            let previous = bridge.chat.applyNewSession(title: "Close155 previous session")
            #expect(target != previous)
            let notificationEffects = SystemNotificationEffects(
                requestAuthorization: { Issue.record("Close155 must not request OS notification permission"); return false },
                authorizationStatus: { Issue.record("Close155 must not read OS notification permission"); return .unknown },
                deliver: { _, _, _ in Issue.record("Close155 must not deliver OS notifications"); return false },
                isApplicationActive: { false }, remove: { _ in }, installResponseHandlers: { _, _ in })
            let notifications = SystemNotificationController(defaults: fixture.defaults,
                canUseSystemNotifications: false, effects: notificationEffects)
            defer { notifications.cancelForApplicationExit() }
            SystemNotificationAppBindings.bind(notifications, bridge: bridge,
                isSettingsVisible: { presentation.isPresented }, closeSettings: { presentation.isPresented = false })
            _ = try openSettings()
            let navigate = try #require(notifications.onOpenTarget)
            navigate(.session(sessionID: target.uuidString))
            try requireClosed()
            #expect(bridge.chat.activeSessionID == target)
            #expect(!notifications.isModuleActive)

            // Test the actual Quit coordinator against the native attached
            // sheet, substituting only terminate/scheduling effects. Private App
            // menu-to-preparer wiring remains a separate package journey.
            _ = try openSettings()
            var terminations = 0
            var deferred: [AppTerminationRequest.Action] = []
            let quit = AppTerminationRequest(hasAttachedSheet: { window.attachedSheet != nil },
                terminate: { terminations += 1 }, observeSheetEnd: { action in
                    let token = NotificationCenter.default.addObserver(
                        forName: NSWindow.didEndSheetNotification, object: window, queue: .main
                    ) { _ in MainActor.assumeIsolated { action() } }
                    return { NotificationCenter.default.removeObserver(token) }
                }, scheduleResume: { action in deferred.append(action); return {} },
                scheduleTimeout: { _ in {} })
            quit.request { presentation.isPresented = false; return true }
            #expect(terminations == 0, "changing presentation state alone cannot forward Quit")
            try requireClosed()
            let resumes = deferred
            deferred.removeAll()
            resumes.forEach { $0() }
            #expect(terminations == 1)
            #expect(quit.outcome == .forwarded)
        }
    }
}

/// Tests-only presentation ownership. It hosts production SettingsView; it
/// deliberately has no copied App initialPageID/onDismiss cleanup callback.
@MainActor
@Observable
private final class Lane155SheetPresentation {
    var isPresented = false
}

@MainActor
private struct Lane155SettingsSheetHost: View {
    @Bindable var presentation: Lane155SheetPresentation
    let center: SettingsCenter
    let shortcuts: ShortcutStore
    let skills: SkillsStore
    let scheduler: SchedulerTaskStore

    var body: some View {
        Color.clear.frame(width: 960, height: 760)
            .sheet(isPresented: $presentation.isPresented) {
                SettingsView(center: center, shortcutStore: shortcuts, skillsStore: skills,
                    schedulerStore: scheduler)
                    .environment(shortcuts)
                    .environment(center)
                    .environment(\.typographyTokens, TypographyTokenProvider(center: center))
            }
    }
}
