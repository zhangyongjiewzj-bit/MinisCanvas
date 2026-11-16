import AppKit
import ApplicationServices
import Foundation
import MinisCore
import Observation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// Native consumer coverage for `ValidatedNumericSettingField`.
///
/// These tests deliberately host the production SwiftUI field in an AppKit
/// window and drive the hosted NSTextField through key and responder events.
/// Existing tests use an isolated model; the single-field page-removal cases
/// use a real SettingsCenter backed by a disposable synthetic directory.
@Suite("Validated numeric native consumer", .serialized)
@MainActor
struct ValidatedNumericSettingNativeConsumerTests {
    fileprivate static let fieldID = "native.numeric.input"
    fileprivate static let otherFieldID = "native.numeric.other"
    fileprivate static let errorID = "native.numeric.input.error"

    @Test("native Tab blur commits a valid value exactly once")
    func nativeTabBlurCommitsValidValueOnce() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "hosted numeric NSTextField was not found")
            return
        }

        fixture.replaceInput("16", in: field)
        fixture.sendTab(to: field)

        #expect(fixture.model.value == 16)
        #expect(fixture.model.persistedValue == 16)
        #expect(fixture.model.writeCount == 1)
    }

    @Test("native editing-end notification commits even while SwiftUI focus remains active")
    func nativeEditingEndNotificationCommitsFocusedDraft() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "hosted numeric NSTextField was not found")
            return
        }

        fixture.replaceInput("17", in: field)
        #expect(fixture.model.value == 12)

        // Exercise the AppKit fallback edge directly. This keeps the test
        // meaningful even when a hosted SwiftUI FocusState update is delayed.
        NotificationCenter.default.post(
            name: NSControl.textDidEndEditingNotification,
            object: field
        )
        fixture.pump()

        #expect(fixture.model.value == 17)
        #expect(fixture.model.persistedValue == 17)
        #expect(fixture.model.writeCount == 1)
    }

    @Test("foreign control editing end cannot commit this field's draft")
    func foreignEditingEndDoesNotCommitNumericDraft() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID),
              let other = fixture.textField(identifier: Self.otherFieldID) else {
            #expect(Bool(false), "hosted numeric controls were not found")
            return
        }

        fixture.replaceInput("17", in: field)
        #expect(fixture.model.value == 12)
        NotificationCenter.default.post(
            name: NSControl.textDidEndEditingNotification,
            object: other
        )
        fixture.pump()
        #expect(fixture.model.value == 12)
        #expect(fixture.model.writeCount == 0)

        NotificationCenter.default.post(
            name: NSControl.textDidEndEditingNotification,
            object: field
        )
        fixture.pump()
        #expect(fixture.model.value == 17)
        #expect(fixture.model.persistedValue == 17)
        #expect(fixture.model.writeCount == 1)

        fixture.replaceInput("21", in: field)
        fixture.sendEscape(to: field)
        #expect(fixture.model.value == 17)
        #expect(fixture.model.persistedValue == 17)
        #expect(fixture.model.writeCount == 1)
    }

    @Test("native Shift-Tab and other-control focus loss commit through responder events")
    func nativeShiftTabAndOtherControlBlurCommit() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID),
              let other = fixture.textField(identifier: Self.otherFieldID) else {
            #expect(Bool(false), "hosted numeric controls were not found")
            return
        }

        fixture.replaceInput("18", in: field)
        #expect(fixture.window.makeFirstResponder(other))
        fixture.pump()
        #expect(fixture.model.value == 18)
        #expect(fixture.model.writeCount == 1)

        #expect(fixture.window.makeFirstResponder(other))
        fixture.sendShiftTab(to: other)
        fixture.replaceInput("19", in: field)
        fixture.sendReturn(to: field)

        #expect(fixture.model.value == 19)
        #expect(fixture.model.persistedValue == 19)
        #expect(fixture.model.writeCount == 2)
    }

    @Test("native Return submits once and Escape restores the latest persisted value")
    func nativeReturnAndEscapePreserveWriteBoundary() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "hosted numeric NSTextField was not found")
            return
        }

        fixture.replaceInput("20", in: field)
        fixture.sendReturn(to: field)
        #expect(fixture.model.value == 20)
        #expect(fixture.model.writeCount == 1)

        fixture.replaceInput("21", in: field)
        fixture.sendEscape(to: field)
        #expect(fixture.model.value == 20)
        #expect(fixture.model.persistedValue == 20)
        #expect(fixture.model.writeCount == 1)
    }

    @Test("native invalid empty and out-of-range input retain the last valid value and expose an error")
    func nativeInvalidInputRetainsLastValidValue() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "hosted numeric NSTextField was not found")
            return
        }

        fixture.replaceInput("999", in: field)
        fixture.sendTab(to: field)
        #expect(fixture.model.value == 12)
        #expect(fixture.model.writeCount == 0)
        #expect(fixture.hasAccessibilityIdentifier(Self.errorID))

        fixture.replaceInput("", in: field)
        fixture.sendReturn(to: field)
        #expect(fixture.model.value == 12)
        #expect(fixture.model.writeCount == 0)

        fixture.replaceInput("-1", in: field)
        fixture.sendReturn(to: field)
        #expect(fixture.model.value == 12)
        #expect(fixture.model.persistedValue == 12)
        #expect(fixture.model.writeCount == 0)
    }

    @Test("native external refresh updates an idle field but does not overwrite a focused draft")
    func nativeExternalRefreshPreservesFocusedDraft() {
        let fixture = HostedNumericSettingFixture()
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "hosted numeric NSTextField was not found")
            return
        }

        fixture.model.replaceExternally(with: 24)
        fixture.resizeWindow()
        fixture.pump()
        #expect(field.stringValue == "24")
        #expect(fixture.model.writeCount == 0)

        fixture.replaceInput("25", in: field)
        fixture.model.replaceExternally(with: 30)
        fixture.resizeWindow()
        fixture.pump()
        #expect(field.stringValue == "25")
        fixture.sendEscape(to: field)
        #expect(field.stringValue == "30")
        #expect(fixture.model.value == 30)
        #expect(fixture.model.writeCount == 0)
    }

    @Test("single numeric field commits a valid draft before its Settings page disappears")
    func singleFieldPageRemovalPersistsThroughSettingsCenter() throws {
        let directory = try makeTypographyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults(suiteName: directory.lastPathComponent)?
            .removePersistentDomain(forName: directory.lastPathComponent) }
        let center = makeTypographyCenter(directory: directory)
        let fixture = HostedNumericSettingFixture(realCenter: center, singleFieldOnly: true)
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "single hosted numeric field was not found")
            return
        }

        fixture.replaceInput("16", in: field)
        #expect(center.uiBaseFontSize == 14)
        fixture.model.isFieldVisible = false
        fixture.pump()
        #expect(center.uiBaseFontSize == 16)
        #expect(center.settingsStore.settings.typography.uiBaseFontSize == 16)
        #expect(SettingsStore(directory: directory).settings.typography.uiBaseFontSize == 16)

        fixture.model.isFieldVisible = true
        fixture.pump()
        #expect(fixture.textField(identifier: Self.fieldID)?.stringValue == "16")
    }

    @Test("focused dirty typography draft cannot overwrite an explicit reset on page removal")
    func focusedDirtyTypographyDraftDoesNotUndoReset() throws {
        let directory = try makeTypographyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults(suiteName: directory.lastPathComponent)?
            .removePersistentDomain(forName: directory.lastPathComponent) }
        let center = makeTypographyCenter(directory: directory)
        let fixture = HostedNumericSettingFixture(realCenter: center, singleFieldOnly: true)
        defer { fixture.close() }
        let field = try #require(fixture.textField(identifier: Self.fieldID))

        fixture.replaceInput("16", in: field)
        fixture.sendReturn(to: field)
        #expect(center.uiBaseFontSize == 16)
        #expect(SettingsStore(directory: directory).settings.typography.uiBaseFontSize == 16)

        fixture.replaceInput("20", in: field)
        #expect(field.stringValue == "20")
        #expect(center.uiBaseFontSize == 16)
        #expect(fixture.window.firstResponder === field.currentEditor())

        fixture.resetTypographyToDefaults()
        #expect(center.uiBaseFontSize == 14)
        #expect(field.stringValue == "14")

        fixture.model.isFieldVisible = false
        fixture.pump()
        #expect(center.uiBaseFontSize == 14)
        #expect(SettingsStore(directory: directory).settings.typography.uiBaseFontSize == 14)

        fixture.model.isFieldVisible = true
        fixture.pump()
        #expect(fixture.textField(identifier: Self.fieldID)?.stringValue == "14")
    }

    @Test("focused draft resets even when typography was already at its default")
    func focusedDraftResetsAtUnchangedDefault() throws {
        let directory = try makeTypographyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults(suiteName: directory.lastPathComponent)?
            .removePersistentDomain(forName: directory.lastPathComponent) }
        let center = makeTypographyCenter(directory: directory)
        let fixture = HostedNumericSettingFixture(realCenter: center, singleFieldOnly: true)
        defer { fixture.close() }
        let field = try #require(fixture.textField(identifier: Self.fieldID))

        fixture.replaceInput("20", in: field)
        #expect(center.uiBaseFontSize == 14)
        #expect(field.stringValue == "20")
        fixture.resetTypographyToDefaults()
        #expect(field.stringValue == "14")
        fixture.model.isFieldVisible = false
        fixture.pump()
        #expect(SettingsStore(directory: directory).settings.typography.uiBaseFontSize == 14)
    }

    @Test("single numeric field rejects an invalid draft and preserves Escape on page removal")
    func singleFieldPageRemovalKeepsInvalidAndEscapeUncommitted() throws {
        let directory = try makeTypographyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { UserDefaults(suiteName: directory.lastPathComponent)?
            .removePersistentDomain(forName: directory.lastPathComponent) }
        let center = makeTypographyCenter(directory: directory)
        let fixture = HostedNumericSettingFixture(realCenter: center, singleFieldOnly: true)
        defer { fixture.close() }
        guard let field = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "single hosted numeric field was not found")
            return
        }

        fixture.replaceInput("21", in: field)
        fixture.model.isFieldVisible = false
        fixture.pump()
        #expect(center.uiBaseFontSize == 14)
        #expect(SettingsStore(directory: directory).settings.typography.uiBaseFontSize == 14)

        fixture.model.isFieldVisible = true
        fixture.pump()
        guard let remounted = fixture.textField(identifier: Self.fieldID) else {
            #expect(Bool(false), "remounted numeric field was not found")
            return
        }
        fixture.replaceInput("16", in: remounted)
        fixture.sendEscape(to: remounted)
        fixture.model.isFieldVisible = false
        fixture.pump()
        #expect(center.uiBaseFontSize == 14)
        #expect(SettingsStore(directory: directory).settings.typography.uiBaseFontSize == 14)
    }

    private func makeTypographyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("F13-SingleField-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTypographyCenter(directory: URL) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory, keychain: keychain),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50),
            mcpManager: MCPServerManager(
                fileURL: directory.appendingPathComponent("mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(
                skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)
            ),
            usageStore: UsageStore(domain: .suite(directory.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
    }
}

@MainActor
@Observable
private final class NativeNumericSettingModel {
    private var storedValue = 12
    var value: Int {
        get { storedValue }
        set {
            storedValue = newValue
            persistedValue = newValue
            writeCount += 1
        }
    }

    private(set) var persistedValue = 12
    private(set) var writeCount = 0
    var otherText = ""
    var realCenter: SettingsCenter?
    var singleFieldOnly = false
    var isFieldVisible = true
    var typographyResetToken = 0

    func replaceExternally(with value: Int) {
        storedValue = value
        persistedValue = value
    }
}

@MainActor
private struct NativeNumericSettingRoot: View {
    @Bindable var model: NativeNumericSettingModel

    init(model: NativeNumericSettingModel) {
        _model = Bindable(wrappedValue: model)
    }

    private var numericValue: Binding<Int> {
        if let center = model.realCenter {
            return Binding(
                get: { center.uiBaseFontSize },
                set: { center.uiBaseFontSize = $0 }
            )
        }
        return $model.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isFieldVisible {
                ValidatedNumericSettingField(
                    "数值",
                    value: numericValue,
                    in: model.realCenter == nil ? 1...100 : TypographySettings.uiBaseFontSizeRange,
                    accessibilityIdentifier: ValidatedNumericSettingNativeConsumerTests.fieldID,
                    resetToken: model.typographyResetToken
                )
            }
            if !model.singleFieldOnly {
                TextField("其它控件", text: $model.otherText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(ValidatedNumericSettingNativeConsumerTests.otherFieldID)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }
}

@MainActor
private final class HostedNumericSettingFixture {
    let model = NativeNumericSettingModel()
    let window: NSWindow
    private let hostingController: NSHostingController<NativeNumericSettingRoot>

    init(realCenter: SettingsCenter? = nil, singleFieldOnly: Bool = false) {
        let hostLease = NativeTestHostLifecycle.begin("NumericSetting")
        model.realCenter = realCenter
        model.singleFieldOnly = singleFieldOnly
        hostingController = NSHostingController(
            rootView: NativeNumericSettingRoot(model: model)
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        NativeTestHostLifecycle.bind(hostLease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        pump()
        // 宿主轴的单变量修复（settings-consumers-043 首错 :98 诊断）。R11..R18C
        // 原始日志一致显示：即使补上 30 轮 layout→display→runloop 就绪轮询，本宿主
        // 遍历仍 swiftUIAXNodes=0、observed=[] —— 连无条件渲染的 native.numeric.input
        // 都不在可访问性树里，说明宿主没有向进程内 selector 遍历 vend SwiftUI 子树，
        // 而不是产品没有渲染错误面。仓库内唯一实测成功路径（SchedulerControlSettingsTests
        // :573-597 与 TypographyPackageFieldJourney.makeHostedProbePreparation/
        // exposeOwnedWindow :3371-3521）是：先给自家窗口打上唯一 accessibilityIdentifier，
        // 再做一次有界、只读、仅针对本进程 pid 的公共 AXUIElement 曝光读取；曝光后同形
        // 本地遍历立即 vend 出 SwiftUI.AccessibilityNode。此处仅补该次宿主曝光读取；
        // 断言、标识符与遍历强度一律未改动，曝光失败时行为与改前逐字节一致。
        let ownerIdentifier = "native-numeric-host-163-" + UUID().uuidString
        window.setAccessibilityIdentifier(ownerIdentifier)
        let exposureStatus = exposeOwnedWindowForAccessibility(
            window, ownerIdentifier: ownerIdentifier
        )
        print("NUMERIC_NATIVE_HOST_EXPOSURE \(exposureStatus)")
        pump()
        #expect(window.makeFirstResponder(nil))
        pump()
        NativeTestHostLifecycle.observe(window, phase: "sampled")
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }

    /// 只读、有界、仅针对本进程自家 pid 的公共 AXUIElement 曝光：
    /// app 元素 → kAXWindowsAttribute → 按窗口 accessibilityIdentifier 唯一匹配自家
    /// 宿主 → 对其做一次 kAXChildrenAttribute 读取。与
    /// TypographyPackageFieldJourney.exposeOwnedWindow（:3429-3521）及
    /// SchedulerControlSettingsTests 宿主同款读取序一致。该读取永不向遍历提供替代
    /// 节点、不放宽任何断言：若曝光失败，hasAccessibilityIdentifier 仍返回 false，
    /// :98 的 #expect 仍如实失败。
    private func exposeOwnedWindowForAccessibility(
        _ window: NSWindow, ownerIdentifier: String
    ) -> String {
        let application = AXUIElementCreateApplication(getpid())
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else {
            return "status=APP_MESSAGING_TIMEOUT_UNSET"
        }
        var windowCount = 0
        guard AXUIElementGetAttributeValueCount(
            application, kAXWindowsAttribute as CFString, &windowCount
        ) == .success, (1...16).contains(windowCount) else {
            return "status=OWN_WINDOWS_UNREADABLE windowCount=\(windowCount)"
        }
        var rawWindows: CFArray?
        guard AXUIElementCopyAttributeValues(
            application, kAXWindowsAttribute as CFString, 0, windowCount, &rawWindows
        ) == .success, let windows = rawWindows as? [AXUIElement] else {
            return "status=OWN_WINDOWS_COPY_FAILED"
        }
        var owner: AXUIElement?
        var matches = 0
        for element in windows.prefix(16) {
            _ = AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXIdentifierAttribute as CFString, &value
            ) == .success, (value as? String) == ownerIdentifier {
                matches += 1
                owner = element
            }
        }
        guard matches == 1, let owner else {
            return "status=OWNER_NOT_UNIQUE matches=\(matches) windows=\(windows.count)"
        }
        var childCount = 0
        guard AXUIElementGetAttributeValueCount(
            owner, kAXChildrenAttribute as CFString, &childCount
        ) == .success else {
            return "status=OWNER_CHILDREN_UNREADABLE ownerMatches=\(matches)"
        }
        if childCount > 0 {
            var children: CFArray?
            _ = AXUIElementCopyAttributeValues(
                owner, kAXChildrenAttribute as CFString, 0, min(childCount, 4), &children
            )
        }
        return "status=EXPOSED children=\(childCount) windows=\(windows.count)"
    }

    func resizeWindow() {
        window.setContentSize(NSSize(width: 460, height: 240))
        window.layoutIfNeeded()
        hostingController.view.layoutSubtreeIfNeeded()
    }

    func resetTypographyToDefaults() {
        model.realCenter?.resetTypographyToDefaults()
        model.typographyResetToken &+= 1
        resizeWindow()
        pump()
    }

    func textField(identifier: String) -> NSTextField? {
        let field = findView(in: hostingController.view, identifier: identifier) as? NSTextField
        if field == nil {
            func describe(_ view: NSView, depth: Int) {
                guard depth < 12 else { return }
                print("NUMERIC_NATIVE_VIEW depth=\(depth) type=\(type(of: view)) frame=\(view.frame) id=\(view.accessibilityIdentifier())")
                for child in view.subviews { describe(child, depth: depth + 1) }
            }
            describe(hostingController.view, depth: 0)
        }
        return field
    }

    /// True only when a currently rendered element exposes exactly `identifier`
    /// through the native accessibility machinery.
    ///
    /// The walk must be rooted at the NSWindow, not just at the hosting view.
    /// Measured evidence in this repo:
    /// - hosting-view-rooted walk (R10 raw
    ///   pkg-int-026A/raw/r10-test-settings-consumers-043.raw.log, line 70):
    ///   `NUMERIC_NATIVE_AX_MISSING ... visited=23 samples=` — the 23 AppKit
    ///   wrapper views vend no SwiftUI accessibility proxies at all, so even
    ///   real rendered `.accessibilityIdentifier` values are invisible;
    /// - window-rooted walk (raw/test-baseline-native-ax-probe.raw.log):
    ///   reaches SwiftUI private proxies (`SwiftUI.AccessibilityNode`,
    ///   `SwiftUIPopupButton`) and found the SwiftUI-attached identifier
    ///   "open-task-center" by identifier.
    /// This mirrors the discovery shape of
    /// TaskCenterNativeAccessibilityConsumerTests.findAX(_:identifier:).
    /// The assertion itself is unchanged in strength: only an element that is
    /// really rendered and really carries this exact identifier can pass.
    /// Install the host projection before the walk instead of asking once.
    ///
    /// Measured gap (R11 raw r11-test-settings-consumers-043.raw.log line 70):
    /// `NUMERIC_NATIVE_AX_MISSING identifier=native.numeric.input.error
    /// visited=59 observed=[] samples=` — across every visited object not one
    /// carried an identifier or a label, so this host had vended no SwiftUI
    /// accessibility node at all, including for the four unconditionally
    /// rendered identifiers (`native.numeric.input`, its `.stepper`, its
    /// `.container`, and `native.numeric.other`). That failure is upstream of
    /// the queried element: the previous `layout → display → pump` prelude
    /// asked exactly once, before SwiftUI committed its accessibility tree.
    /// The hosts in this repo that do read real SwiftUI identifiers repeat
    /// layout + display + a run-loop slice and re-probe — see
    /// AdaptiveDividerNativeConsumerTests.mountAndLayout :74-81 and the
    /// accepted `settings.surface` readiness loop in
    /// SettingsNativeInteractionConsumerTests. The same install sequence and
    /// the same 30-slice budget are applied here, without the in-loop probe
    /// (this host's sentinel would recurse); the walk below then runs once
    /// against the settled tree. Assertion strength is untouched: when
    /// nothing projects, the walk still returns false and the `#expect` at :98
    /// still fails honestly.
    func hasAccessibilityIdentifier(_ identifier: String) -> Bool {
        for _ in 0..<30 {
            window.layoutIfNeeded()
            hostingController.view.layoutSubtreeIfNeeded()
            hostingController.view.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        var visited = Set<ObjectIdentifier>()
        var diagnostics: [String] = []
        var observedIdentifiers: [String] = []
        var swiftUIAccessibilityNodeCount = 0
        func noteIdentifier(_ candidate: String) {
            guard !candidate.isEmpty,
                  observedIdentifiers.count < 32,
                  !observedIdentifiers.contains(candidate) else { return }
            observedIdentifiers.append(candidate)
        }
        func contains(_ object: AnyObject) -> Bool {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
            if String(describing: type(of: object)).contains("AccessibilityNode") {
                swiftUIAccessibilityNodeCount += 1
            }
            if let selectorIdentifier = rawAXGetter(
                object,
                selectorName: "accessibilityIdentifier"
            ) as? String,
               !selectorIdentifier.isEmpty {
                if selectorIdentifier == identifier { return true }
                noteIdentifier(selectorIdentifier)
            }
            if let rawIdentifier = UF03LegacyAttribute(object as? NSObject, .identifier) as? String,
               !rawIdentifier.isEmpty {
                if rawIdentifier == identifier { return true }
                noteIdentifier(rawIdentifier)
            }
            if let protocolIdentifier = (object as? NSAccessibilityProtocol)?.accessibilityIdentifier(),
               !protocolIdentifier.isEmpty {
                if protocolIdentifier == identifier { return true }
                noteIdentifier(protocolIdentifier)
            }

            // SwiftUI can expose private proxy objects in these NSArrays. Avoid
            // AppKit's typed child getters because their Swift bridge traps
            // before the test can inspect a proxy with another runtime class.
            let ordered = rawAXChildren(
                of: object,
                attribute: .childrenInNavigationOrderAttribute
            )
            var children = ordered.isEmpty
                ? rawAXChildren(of: object, attribute: .children)
                : ordered
            if let view = object as? NSView { children += view.subviews }
            if let window = object as? NSWindow, let content = window.contentView {
                children.append(content.superview ?? content)
            }
            if diagnostics.count < 16,
               let line = axDiagnosticLine(
                   object,
                   childCount: flattenAXChildren(children).count
               ) {
                diagnostics.append(line)
            }
            return flattenAXChildren(children).contains { contains($0 as AnyObject) }
        }
        let hostingView = hostingController.view
        let windowRoots: [AnyObject] = [
            window,
            window.contentView?.superview ?? hostingView,
        ]
        let result = (windowRoots + [hostingView]).contains { contains($0) }
        if !result {
            print("NUMERIC_NATIVE_AX_MISSING identifier=\(identifier) visited=\(visited.count) swiftUIAXNodes=\(swiftUIAccessibilityNodeCount) observed=[\(observedIdentifiers.joined(separator: ","))] samples=\(diagnostics.joined(separator: " || "))")
        }
        return result
    }

    func replaceInput(_ text: String, in field: NSTextField) {
        #expect(window.makeFirstResponder(field))
        field.selectText(nil)
        pump()
        #expect(field.currentEditor() != nil, "native field editor was not established")
        if text.isEmpty {
            sendKey(keyCode: 51, characters: "")
        } else {
            for character in text {
                guard let keyCode = Self.digitKeyCodes[character] else { continue }
                sendKey(keyCode: keyCode, characters: String(character))
            }
        }
        pump()
    }

    func sendTab(to responder: NSResponder) {
        prepareForKeyEvent(responder)
        sendKey(keyCode: 48, characters: "\t")
    }

    func sendShiftTab(to responder: NSResponder) {
        prepareForKeyEvent(responder)
        sendKey(keyCode: 48, modifiers: [.shift], characters: "\t")
    }

    func sendReturn(to responder: NSResponder) {
        prepareForKeyEvent(responder)
        sendKey(keyCode: 36, characters: "\r")
    }

    func sendEscape(to responder: NSResponder) {
        prepareForKeyEvent(responder)
        sendKey(keyCode: 53, characters: "\u{1b}")
    }

    func pump() {
        for _ in 0..<4 {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func prepareForKeyEvent(_ responder: NSResponder) {
        if let field = responder as? NSTextField, field.currentEditor() != nil {
            return
        }
        #expect(window.makeFirstResponder(responder))
        if let field = responder as? NSTextField {
            field.selectText(nil)
            pump()
        }
    }

    private func sendKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            #expect(Bool(false), "could not construct native key event")
            return
        }
        window.sendEvent(event)
        pump()
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if let field = root as? NSTextField {
            // SwiftUI vends the identifier through its AX wrapper on some
            // macOS versions; the native text field retains the real title.
            let title = identifier == ValidatedNumericSettingNativeConsumerTests.fieldID ? "数值" : "其它控件"
            if field.accessibilityIdentifier() == identifier || field.placeholderString == title {
                return field
            }
        }
        for child in root.subviews {
            if let match = findView(in: child, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    private static let digitKeyCodes: [Character: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "-": 27
    ]
}

@MainActor
private func rawAXChildren(
    of object: AnyObject,
    attribute: NSAccessibility.Attribute
) -> [Any] {
    let unignoredFromObject = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
    let selectorName = attribute == .childrenInNavigationOrderAttribute
        ? "accessibilityChildrenInNavigationOrder"
        : "accessibilityChildren"
    guard let value = rawAXGetter(object, selectorName: selectorName)
        ?? UF03LegacyAttribute(object as? NSObject, attribute) else {
        return unignoredFromObject
    }
    if let values = value as? NSArray {
        let raw = values.map { $0 }
        return raw + NSAccessibility.unignoredChildren(from: raw) + unignoredFromObject
    }
    return [value] + NSAccessibility.unignoredChildrenForOnlyChild(from: value) + unignoredFromObject
}

@MainActor
private func rawAXGetter(_ object: AnyObject, selectorName: String) -> Any? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector),
          let result = object.perform(selector) else { return nil }
    return result.takeUnretainedValue()
}

@MainActor
private func axDiagnosticLine(_ object: AnyObject, childCount: Int) -> String? {
    let dynamicID = rawAXGetter(object, selectorName: "accessibilityIdentifier") as? String
    let legacyID = UF03LegacyAttribute(object as? NSObject, .identifier) as? String
    let protocolID = (object as? NSAccessibilityProtocol)?.accessibilityIdentifier()
    let dynamicLabel = rawAXGetter(object, selectorName: "accessibilityLabel") as? String
    let legacyLabel = UF03LegacyAttribute(object as? NSObject, .description) as? String
    let role = rawAXGetter(object, selectorName: "accessibilityRole")
        ?? UF03LegacyAttribute(object as? NSObject, .role)
    let meaningful = [dynamicID, legacyID, protocolID, dynamicLabel, legacyLabel]
        .contains { !($0 ?? "").isEmpty }
    guard meaningful else { return nil }
    let objectValue = object as? NSObject
    let ordered = objectValue?.responds(
        to: NSSelectorFromString("accessibilityChildrenInNavigationOrder")
    ) ?? false
    let children = objectValue?.responds(
        to: NSSelectorFromString("accessibilityChildren")
    ) ?? false
    return "type=\(type(of: object)) dynamicID=\(dynamicID ?? "") legacyID=\(legacyID ?? "") protocolID=\(protocolID ?? "") dynamicLabel=\(dynamicLabel ?? "") legacyLabel=\(legacyLabel ?? "") role=\(String(describing: role)) ordered=\(ordered) children=\(children) childCount=\(childCount)"
}

private func flattenAXChildren(_ children: [Any]) -> [Any] {
    children.flatMap { child in
        if let nested = child as? [Any] { return flattenAXChildren(nested) }
        if let nested = child as? NSArray { return flattenAXChildren(nested.map { $0 }) }
        return [child]
    }
}
