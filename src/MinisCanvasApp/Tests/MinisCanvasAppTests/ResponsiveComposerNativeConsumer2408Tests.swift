import AppKit
import ApplicationServices
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// D-APP-21 / D-AX-08: measure the mounted ContentView -> chat pane ->
/// GlobalComposerView consumer. Policy-only tests and the isolated native
/// NSTextView delegate tests cannot establish these allocated AX frames.
/// Run only under the existing exclusive native UI host/lease.
@Suite("Responsive Composer production native consumer 2408", .serialized)
@MainActor
struct ResponsiveComposerNativeConsumer2408Tests {
    private let widths: [CGFloat] = [600, 800, 1_000, 1_280, 1_600]

    @Test("five content widths and every 12...20pt setting keep mounted Composer controls in bounds",
          arguments: Array(12...20))
    func mountedComposerConsumesAllocatedPaneAtEveryFont(fontSize: Int) throws {
        let fixture = try makeFixture(fontSize: fontSize)
        defer { close(fixture) }
        for width in widths {
            fixture.window.setContentSize(NSSize(width: width, height: 760))
            pump(fixture)
            let content = try #require(fixture.window.contentView)
            let contentFrame = fixture.window.convertToScreen(content.convert(content.bounds, to: nil))
            #expect(abs(contentFrame.width - width) <= 1)

            let surface = try measured("chat.surface", in: fixture.window)
            let composer = try measured("chat.composer", in: fixture.window)
            let primary = try measured("composer.primary-row.global", in: fixture.window)
            let input = try measured("composer.global.input", in: fixture.window)
            for (name, frame) in [
                ("surface", surface), ("composer", composer),
                ("primary", primary), ("input", input)
            ] {
                #expect(frame.width > 0 && frame.height > 0, "\(name) width=\(width) font=\(fontSize)")
                #expect(containsHorizontally(contentFrame, frame),
                        "\(name) escapes content width=\(width) font=\(fontSize): \(frame)")
            }
            #expect(containsHorizontally(surface, composer))
            #expect(containsHorizontally(composer, primary))
            #expect(containsHorizontally(composer, input))

            // These are the real mounted primary-row controls. Their frames
            // must fit the row after the sidebar budget and font are applied.
            for identifier in ["composer.model", "composer.attachments", "composer.plugins"] {
                let frame = try measured(identifier, in: fixture.window)
                #expect(containsHorizontally(primary, frame),
                        "\(identifier) clipped width=\(width) font=\(fontSize): \(frame)")
            }
            let editor = try #require(nativeEditor(in: fixture.controller.view),
                                      "production Composer NSTextView missing")
            #expect(abs((editor.font?.pointSize ?? -1) - fixture.typography.composerBodySize) <= 0.1,
                    "native editor did not consume live typography at \(fontSize)pt")
            print("RESPONSIVE_COMPOSER_NATIVE width=\(width) font=\(fontSize) surface=\(surface) composer=\(composer) input=\(input) editorFont=\(editor.font?.pointSize ?? -1)")
        }
    }

    @Test("compact overlays close before the mounted input regains focus and accepts text",
          arguments: [CGFloat(600), 800])
    func closingOverlayRestoresInputAndToolbarTree(width: CGFloat) async throws {
        let fixture = try makeFixture(fontSize: 20)
        defer { close(fixture) }
        fixture.window.setContentSize(NSSize(width: width, height: 760))
        pump(fixture)

        let toggles: [(id: String, open: String, close: String)] = width == 600
            ? [("toolbar.sidebar.session.toggle", "展开会话侧栏", "折叠会话侧栏"),
               ("toolbar.sidebar.context.toggle", "展开上下文面板", "折叠上下文面板")]
            : [("toolbar.sidebar.context.toggle", "展开上下文面板", "折叠上下文面板")]
        for toggle in toggles {
            let opener = try #require(NativeConsumerOwnedAX.find(
                in: fixture.window, identifier: toggle.id
            ), "overlay toolbar opener unavailable: \(toggle.open)")
            #expect(NativeConsumerOwnedAX.role(opener) == .button)
            #expect(NativeConsumerOwnedAX.label(opener)?.contains(toggle.open) == true)
            let commandMarker = fixture.bridge.commandTaskRegistrationSequence
            #expect(NativeConsumerOwnedAX.press(opener))
            try #require(fixture.bridge.commandTaskRegistrationSequence > commandMarker,
                         "AX opener must register its real command task")
            let commandTasks = try #require(fixture.bridge.commandTaskSnapshot(after: commandMarker))
            try #require(commandTasks.count == 1, "exactly one AX-derived command task must be joined")
            await commandTasks[0].value
            pump(fixture)
            let closer = try #require(NativeConsumerOwnedAX.find(
                in: fixture.window, identifier: toggle.id
            ), "overlay toolbar closer unavailable: \(toggle.close)")
            #expect(NativeConsumerOwnedAX.role(closer) == .button)
            #expect(NativeConsumerOwnedAX.label(closer)?.contains(toggle.close) == true)
            let closingMarker = fixture.bridge.commandTaskRegistrationSequence
            #expect(NativeConsumerOwnedAX.press(closer))
            try #require(fixture.bridge.commandTaskRegistrationSequence > closingMarker,
                         "AX closer must register its real command task")
            let closingTasks = try #require(fixture.bridge.commandTaskSnapshot(after: closingMarker))
            try #require(closingTasks.count == 1, "exactly one AX-derived close task must be joined")
            await closingTasks[0].value
            pump(fixture)
            let closed = try #require(NativeConsumerOwnedAX.find(
                in: fixture.window, identifier: toggle.id
            ), "overlay toolbar did not return to closed state")
            #expect(NativeConsumerOwnedAX.label(closed)?.contains(toggle.open) == true)
        }

        let composer = try measured("chat.composer", in: fixture.window)
        let input = try measured("composer.global.input", in: fixture.window)
        let toolbar = try measured("composer.primary-row.global", in: fixture.window)
        #expect(containsHorizontally(composer, input))
        #expect(containsHorizontally(composer, toolbar))
        let overflow = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "composer.policy.overflow"
        ), "compact allocated pane must expose policy overflow")
        #expect(NativeConsumerOwnedAX.role(overflow) == .button)
        #expect(containsHorizontally(toolbar, try measured("composer.policy.overflow", in: fixture.window)))

        let editor = try #require(nativeEditor(in: fixture.controller.view))
        #expect(fixture.window.makeFirstResponder(editor))
        #expect(fixture.window.firstResponder === editor)
        editor.insertText("布局输入", replacementRange: editor.selectedRange())
        pump(fixture)
        #expect(fixture.bridge.chat.draftText == "布局输入")
        #expect(fixture.window.firstResponder === editor)
        // Dispatch the production NSTextView's Tab command in its mounted
        // key-view loop. The detached three-view delegate fixture cannot
        // establish that this window offers a next responder after overlay use.
        editor.doCommand(by: NSSelectorFromString("insertTab:"))
        #expect(fixture.window.firstResponder !== editor,
                "Tab remained trapped in the mounted Composer after overlay close")
        #expect(fixture.bridge.chat.draftText == "布局输入")
        _ = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "composer.model"
        ), "toolbar model control disappeared after keyboard input")
    }

    @Test("confirmed bypass is visible with both sidebars open and the policy popover closed")
    func confirmedBypassIsVisibleAtDefaultWindowWidth() throws {
        let fixture = try makeFixture(fontSize: 13)
        defer { close(fixture) }
        fixture.window.setContentSize(NSSize(width: 1_280, height: 800))
        let chat = fixture.bridge.chat
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .bypassPermission, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        pump(fixture)

        let content = try #require(fixture.window.contentView)
        try #require(abs(content.bounds.width - 1_280) <= 1)
        for (identifier, label) in [
            ("toolbar.sidebar.session.toggle", "折叠会话侧栏"),
            ("toolbar.sidebar.context.toggle", "折叠上下文面板")
        ] {
            let toggle = try #require(NativeConsumerOwnedAX.find(
                in: fixture.window, identifier: identifier
            ))
            try #require(NativeConsumerOwnedAX.label(toggle)?.contains(label) == true)
        }
        _ = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "composer.policy.overflow"
        ))
        try #require(chat.composerPolicySelection.mode == .bypassPermission)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(
            in: fixture.window, prefix: "composer.bypass-active"
        ) == true)

        chat.composerPolicySelection.bypassModeConfirmed = true
        pump(fixture)
        try #require(chat.composerPolicySelection.bypassModeConfirmed)
        try #require(NativeConsumerOwnedAX.hasNoIdentifier(
            in: fixture.window, prefix: "composer.bypass-confirm"
        ) == true, "policy popover must stay closed")
        let badge = NativeConsumerOwnedAX.find(in: fixture.window, identifier: "composer.bypass-active")
        #expect(badge != nil, "confirmed bypass must be visible without opening the policy popover")
        if let badge {
            #expect(NativeConsumerOwnedAX.label(badge) == "绕过权限已生效")
            let frame = try #require(NativeConsumerOwnedAX.frame(badge))
            let composer = try measured("chat.composer", in: fixture.window)
            #expect(frame.width > 0 && frame.height > 0)
            #expect(containsHorizontally(composer, frame))
        }

        chat.composerPolicySelection.mode = .manual
        pump(fixture)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(
            in: fixture.window, prefix: "composer.bypass-active"
        ) == true)
    }

    @Test("collapsed policy popover shows the bypass risk confirmation inline, not as a sheet")
    func collapsedBypassRiskConfirmationIsInlineInPopover() throws {
        let fixture = try makeFixture(fontSize: 13)
        func popoverWindows() -> [NSWindow] {
            NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        }
        defer {
            // The policy popover is its own NSWindow; close it with the host.
            for popoverWindow in NSApp.windows where String(describing: type(of: popoverWindow)).contains("Popover") {
                popoverWindow.close()
            }
            close(fixture)
        }
        fixture.window.setContentSize(NSSize(width: 600, height: 760))
        let chat = fixture.bridge.chat
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .bypassPermission, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        pump(fixture)
        let overflow = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "composer.policy.overflow"
        ), "600pt pane must collapse the policy controls")
        try #require(NativeConsumerOwnedAX.press(overflow))
        // Popover content is a separate window outside the host's own AX tree,
        // so it is read through the app-wide lookup. Bounded retries (~20 x 0.3s).
        func waitFor(_ identifier: String) -> AnyObject? {
            var element: AnyObject?
            for _ in 0..<20 where element == nil {
                pump(fixture)
                element = NativeAppWideAXLookup.find(identifier: identifier)
            }
            return element
        }
        let confirmToggle = try #require(waitFor("composer.bypass-confirm"),
                                         "popover must expose the bypass confirmation checkbox")
        try #require(NativeConsumerOwnedAX.press(confirmToggle))

        // (b) the risk confirmation is reachable and lies inside the popover window.
        let riskConfirm = try #require(waitFor("skill-risk.bypass.confirm"),
                                       "risk confirmation must be reachable after ticking the checkbox")
        // (a) it is not a sheet. The defect was the risk form attached as a
        // `.sheet` to the popover window (inferred), so check the two windows
        // where it could appear: the host and the popover. Not NSApp.windows as
        // a whole: windows left by other suites may still carry sheets.
        let popover = try #require(popoverWindows().first, "policy popover window not visible")
        #expect(fixture.window.sheets.isEmpty && popover.sheets.isEmpty,
                "risk confirmation must not be presented as a sheet")
        let axFrame = try #require(NativeConsumerOwnedAX.frame(riskConfirm))
        let appKitFrame = try #require(UF03AXScreenCoordinates.appKitFrame(
            position: axFrame.origin, size: axFrame.size, zeroScreenFrame: NSScreen.screens.first?.frame))
        #expect(popover.frame.insetBy(dx: -1, dy: -1).contains(appKitFrame),
                "confirm button \(appKitFrame) lies outside the popover \(popover.frame)")

        // (c) cancel returns to the policy controls without confirming bypass.
        let cancel = try #require(waitFor("skill-risk.cancel"), "risk confirmation must offer a cancel button")
        try #require(NativeConsumerOwnedAX.press(cancel))
        var riskGone = false
        for _ in 0..<20 where !riskGone {
            pump(fixture)
            riskGone = NativeAppWideAXLookup.matches(identifier: "skill-risk.bypass.confirm")?.isEmpty == true
        }
        #expect(riskGone, "risk confirmation must disappear after cancel")
        #expect(waitFor("composer.bypass-confirm") != nil, "popover must return to the policy controls")
        #expect(chat.composerPolicySelection.bypassModeConfirmed == false)
        // Same two windows as (a); the popover is re-read since it was rebuilt.
        #expect(fixture.window.sheets.isEmpty && popoverWindows().allSatisfy { $0.sheets.isEmpty })
    }

    @Test("compact slash row shows the current conversation scope, retained message count and approval state")
    func compactSlashMenuShowsActualRetentionAndCurrentScope() throws {
        let fixture = try makeFixture(fontSize: 13)
        defer { close(fixture) }
        fixture.window.setContentSize(NSSize(width: 1_000, height: 760))
        let chat = fixture.bridge.chat
        let sessionID = try #require(chat.activeSessionID)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false
        )
        chat.draftText = "/compact"
        pump(fixture)

        let row = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "composer.slash.compact"
        ), "the production Composer must expose its compact slash row")
        #expect(NativeConsumerOwnedAX.role(row) == .button)
        let label = NativeConsumerOwnedAX.label(row) ?? ""
        let value = NativeConsumerOwnedAX.attribute(row, kAXValueAttribute as CFString) as? String ?? ""
        let displayed = label + " " + value
        #expect(displayed.contains("/compact"))
        #expect(displayed.contains("当前会话"))
        // The existing /compact execution defaults to three retained messages.
        // Keep this independent literal rather than deriving an oracle from
        // the menu formatter or its metadata.
        #expect(displayed.contains("保留最近 3 条"))
        // This fixture is an idle current session in manual/request mode;
        // the expectation is not a claim that every mode requires approval.
        #expect(value.contains("需审批"))
        #expect(chat.activeSessionID == sessionID)
        #expect(chat.draftText == "/compact")
        #expect(chat.pendingComposerCommand == nil && !chat.isActiveSessionStreaming)
    }

    @Test("Mock status opens the default model settings when an eligible model is already connected")
    func mockStatusRoutesReadyModelToGeneralSettings() async throws {
        let providerID = "R6G03_OFFLINE_API_KEY"
        let modelID = "r6g03-fixture-model"
        let transport = WP2ProviderSettingsTransport(responses: [
            .reachability: .init(statusCode: 200),
            .authentication: .init(statusCode: 200),
            .modelDiscovery: .init(statusCode: 200, modelIDs: [modelID]),
            .minimalModelRequest(modelID): .init(statusCode: 200)
        ])
        let fixture = try makeFixture(fontSize: 13, readinessTransport: transport)
        defer { close(fixture) }
        fixture.window.setContentSize(NSSize(width: 1_280, height: 800))
        let chat = fixture.bridge.chat
        let center = fixture.center
        chat.providerReadinessStore = center.providerReadinessStore
        chat.providerRecordsSource = { center.providerRecords }
        var openedPages: [String?] = []
        fixture.bridge.deepLinkHandler.onOpenSettings = { openedPages.append($0) }
        let defaultProviderID = fixture.center.defaultProviderID
        let defaultModelID = fixture.center.defaultModelID
        let sessionID = chat.activeSessionID

        pump(fixture)
        try #require(chat.isMockMode && chat.chatModelPickerItems.isEmpty)
        let connect = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "provider.connect-model"
        ))
        #expect(NativeConsumerOwnedAX.label(connect)?.contains("连接模型") == true)
        try #require(NativeConsumerOwnedAX.press(connect))
        #expect(openedPages == [ProviderConnectionRoute.id])
        openedPages.removeAll()

        try #require(center.saveProvider(
            name: providerID, apiKey: "synthetic-only",
            baseURL: "https://fixture.invalid/v1", modelNames: [modelID],
            protocolType: .openaiCompatible
        ))
        pump(fixture)
        try #require(!chat.canSelectChatModel(providerID: providerID, modelID: modelID))
        let configuredProviders = center.providerRecords
        let savedButUnready = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "provider.connect-model"
        ))
        #expect(NativeConsumerOwnedAX.label(savedButUnready)?.contains("连接模型") == true)

        // Keep the configured provider and bound closure in place. The
        // settings check publishes the readiness-only transition.
        _ = try #require(await center.checkProviderReadiness(forProviderName: providerID))
        pump(fixture)

        #expect(center.providerRecords == configuredProviders)
        try #require(chat.isMockMode)
        try #require(chat.canSelectChatModel(providerID: providerID, modelID: modelID))
        let chooseDefault = try #require(NativeConsumerOwnedAX.find(
            in: fixture.window, identifier: "provider.connect-model"
        ))
        let label = NativeConsumerOwnedAX.label(chooseDefault)
        #expect(label?.contains("选择默认模型") == true, "actual status label: \(label ?? "<missing>")")
        try #require(NativeConsumerOwnedAX.press(chooseDefault))
        #expect(openedPages == ["常规"])
        #expect(chat.isMockMode && chat.activeSessionID == sessionID)
        #expect(fixture.center.defaultProviderID == defaultProviderID)
        #expect(fixture.center.defaultModelID == defaultModelID)
    }

    private struct Fixture {
        let root: URL
        let defaultsSuite: String
        let defaults: UserDefaults
        let center: SettingsCenter
        let typography: TypographyTokenProvider
        let bridge: BridgeStore
        let controller: NSHostingController<AnyView>
        let window: NSWindow
    }

    private func makeFixture(
        fontSize: Int,
        readinessTransport: (any SettingsProviderReadinessTransport)? = nil
    ) throws -> Fixture {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.minisCoreDirectory.appendingPathComponent(
            "responsive-composer-2408-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsSuite = "responsive-composer-2408-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.set(MainPane.chat.rawValue, forKey: "minisCanvas.mainPane")
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking())
            ),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json")),
            providerReadinessTransport: readinessTransport,
            providerReadinessDeployment: readinessTransport == nil ? .remote : .mock,
            providerReadinessStore: readinessTransport.map { _ in
                ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
            }
        )
        center.uiBaseFontSize = fontSize
        let typography = TypographyTokenProvider(center: center)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: center.logManager,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions,
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.layoutMode = .split
        let controller = NSHostingController(rootView: AnyView(
            ContentView(bridge: bridge)
                .environment(center)
                .environment(\.typographyTokens, typography)
        ))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("ResponsiveComposer2408")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let fixture = Fixture(root: root, defaultsSuite: defaultsSuite, defaults: defaults,
                              center: center, typography: typography, bridge: bridge,
                              controller: controller, window: window)
        pump(fixture)
        return fixture
    }

    private func close(_ fixture: Fixture) {
        fixture.window.orderOut(nil)
        fixture.window.contentViewController = nil
        fixture.window.close()
        NativeTestHostLifecycle.end(fixture.window)
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func pump(_ fixture: Fixture) {
        for _ in 0..<30 {
            fixture.window.layoutIfNeeded()
            fixture.controller.view.layoutSubtreeIfNeeded()
            fixture.controller.view.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        NativeTestHostLifecycle.observe(fixture.window, phase: "sampled")
    }

    private func measured(_ identifier: String, in window: NSWindow) throws -> CGRect {
        let element = try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier),
                                   "AX identifier missing: \(identifier)")
        return try #require(NativeConsumerOwnedAX.frame(element), "AX frame missing: \(identifier)")
    }

    private func containsHorizontally(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - 2 && inner.maxX <= outer.maxX + 2
    }

    private func nativeEditor(in view: NSView) -> ComposerPasteAwareTextView? {
        for child in view.subviews {
            if let editor = child as? ComposerPasteAwareTextView { return editor }
            if let editor = nativeEditor(in: child) { return editor }
        }
        return nil
    }
}
