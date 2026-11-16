import AppKit
import ApplicationServices
import Foundation
import MinisCore
import Observation
import SwiftUI
import Testing
@testable import MinisCanvasApp

private final class MemorySearch2407Scope {
    var current = MemoryScope(sessionID: "display-A", projectID: "project-A")
}

@Observable
private final class MemorySearch2407Owner {
    var principal: MemoryTrustedPrincipal?
}

/// Exercises the Settings search control and its visible projection through an
/// owned native window. The Core display join has separate focused coverage.
@Suite("D-H5A Settings scoped search native consumer", .serialized)
@MainActor
struct MemorySearchSettings2407NativeConsumerTests {
    @Test("source, time and recall explanation follow the selected scope")
    func scopedResultIsVisibleWithoutCrossScopeLeak() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "memory-search2407", canvasRuntimeState: .disabled)
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let scope = MemorySearch2407Scope()
        let a = scope.current
        let b = MemoryScope(sessionID: "display-B", projectID: "project-B")
        let store = MemoryStore(directory: profile.memoryDirectory)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (id, selectedScope, source) in [
            ("display-2407-A", a, "chat://display-A/turn-1"),
            ("display-2407-B", b, "chat://display-B/turn-1")
        ] {
            _ = try store.addFact(
                id: id, text: "Swift works with 晴天", createdAt: timestamp,
                memoryScope: selectedScope, sourceProposalID: "proposal-\(id)",
                sourceRef: source,
                contentDigest: MemoryStore.contentDigest(for: "Swift works with 晴天"))
        }
        let defaults = profile.makeUserDefaults()
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: store,
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")))
        center.memoryScopeProvider = { scope.current }
        let originalMemoryBytes = try Data(contentsOf: store.fileURL)

        for (selectedScope, visibleID, hiddenID, visibleSource, hiddenSource) in [
            (a, "display-2407-A", "display-2407-B", "chat://display-A/turn-1", "chat://display-B/turn-1"),
            (b, "display-2407-B", "display-2407-A", "chat://display-B/turn-1", "chat://display-A/turn-1")
        ] {
            scope.current = selectedScope
            let window = host(center: center, defaults: defaults, profile: profile)
            defer { close(window) }
            let memoryTab = try node("settings-tab-memory", in: window)
            try #require(NativeConsumerOwnedAX.press(memoryTab))
            let field = try submitMemorySearch("Swift, 晴天", in: window)
            let submit = try node("settings.memory.search.submit", in: window)

            let result = try node("settings.memory.search.result.\(visibleID)", in: window,
                failure: Comment(rawValue: "Memory2407 synthetic search: queryLength=\((NativeConsumerOwnedAX.attribute(field, kAXValueAttribute as CFString) as? String)?.count ?? -1), submitEnabled=\((NativeConsumerOwnedAX.attribute(submit, kAXEnabledAttribute as CFString) as? Bool) == true), scopedCoreCount=\((try? MemorySearchDisplayConsumer(search: MemorySearch(store: store)).retrieve(keyword: "Swift, 晴天", scope: .session(selectedScope)).items.count) ?? -1), resultSummaryVisible=\((try? ownedTexts(in: window).contains { $0.hasPrefix("检索结果（") }) == true), searchErrorVisible=\((try? ownedTexts(in: window).contains { $0.hasPrefix("检索失败：") }) == true), memoryTabExpandedKnown=\(NativeConsumerOwnedAX.attribute(memoryTab, kAXExpandedAttribute as CFString) != nil), memoryTabExpanded=\((NativeConsumerOwnedAX.attribute(memoryTab, kAXExpandedAttribute as CFString) as? Bool) == true)"))
            let explanation = NativeConsumerOwnedAX.attribute(result, kAXValueAttribute as CFString) as? String
            #expect(explanation?.contains("命中 2 个检索词") == true)
            #expect(explanation?.contains("swift、晴天") == true)
            let text = try ownedTexts(in: window)
            #expect(text.contains("\(visibleSource) · 2023-11-14T22:13:20Z · 修订 1"))
            #expect(text.contains("本地检索命中 1 条；结果按命中词数、创建时间、修订号和事实 ID 稳定排序。"))
            #expect(text.contains(where: { $0.contains(hiddenSource) }) == false)
            #expect(NativeConsumerOwnedAX.hasNoIdentifier(
                in: window, prefix: "settings.memory.search.result.\(hiddenID)") == true)

            // Clear the actual edited search, not the facts or a shadow filter.
            let clear = try node("settings.memory.search.clear", in: window)
            try #require(NativeConsumerOwnedAX.press(clear))
            pump(window)
            let clearedField = try node("settings.memory.search", in: window)
            #expect(NativeConsumerOwnedAX.attribute(clearedField, kAXValueAttribute as CFString) as? String == "")
            let clearedSubmit = try node("settings.memory.search.submit", in: window)
            #expect(NativeConsumerOwnedAX.enabled(clearedSubmit) == false)
            #expect(NativeConsumerOwnedAX.hasNoIdentifier(
                in: window, prefix: "settings.memory.search.result.") == true)
            #expect(try Data(contentsOf: store.fileURL) == originalMemoryBytes)
        }
    }

    @Test func unassignedSearchShowsOnlyCurrentOwnersFactsAndGlobalDocument() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "memory-search-unassigned", canvasRuntimeState: .disabled)
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let scope = MemoryScope(sessionID: "owned-origin", projectID: "owned-project")
        let owner = MemorySearch2407Owner()
        let first = try #require(ProcessUIDMemoryPrincipalSource(readUID: { 501 }).trustedPrincipal())
        let second = try #require(ProcessUIDMemoryPrincipalSource(readUID: { 502 }).trustedPrincipal())
        owner.principal = first
        let store = MemoryStore(directory: profile.memoryDirectory)
        let files = MemoryFileStore(directory: store.directory)
        try files.writeGlobal("weather GLOBAL_S1_SEARCH")
        let personal = try store.addFact("weather PERSONAL_S1_SEARCH", memoryScope: scope,
            ownerUserID: first.userID, visibility: .personal, trustedPrincipal: first)
        let foreign = try store.addFact("weather OTHER_OWNER_S1_SEARCH", memoryScope: scope,
            ownerUserID: second.userID, visibility: .personal, trustedPrincipal: second)
        let project = try store.addFact("weather PROJECT_S1_SEARCH", memoryScope: scope, visibility: .project)
        let temporary = try store.addFact("weather TEMP_S1_SEARCH", memoryScope: scope, visibility: .temporary,
            temporaryLifetimeID: "synthetic-weather-lifetime")
        let defaults = profile.makeUserDefaults()
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: store, memoryFileStore: files,
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")))
        center.memoryScopeProvider = { nil }
        center.memoryTrustedPrincipalProvider = { owner.principal }
        let original = try Data(contentsOf: store.fileURL)
        let denied = try MemorySearchDisplayConsumer(search: MemorySearch(store: store))
            .retrieve(keyword: "weather", scope: nil)
        #expect(denied.items.isEmpty && denied.explanation.contains("检索已拒绝"))

        let window = host(center: center, defaults: defaults, profile: profile)
        defer { close(window) }
        try #require(window.isVisible && window.isKeyWindow)
        try #require(NativeConsumerOwnedAX.press(try node("settings-tab-memory", in: window)))
        try submitMemorySearch("weather", in: window)
        pump(window)
        let searchText = try ownedTexts(in: window)
        try #require(searchText.contains("未提供有效的记忆作用域，检索已拒绝。")
            || searchText.contains(where: { $0.hasPrefix("检索结果（") }))
        #expect(NativeConsumerOwnedAX.find(in: window, identifier: "settings.memory.search.result.\(personal.id)") != nil)
        #expect(NativeConsumerOwnedAX.find(in: window, identifier: "settings.memory.search.document.global") != nil)
        for hidden in [foreign.id, project.id, temporary.id] {
            #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "settings.memory.search.result.\(hidden)") == true)
        }

        owner.principal = second
        try #require(center.memoryTrustedPrincipalProvider?() == second)
        pump(window)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "settings.memory.search.result.\(personal.id)") == true)
        try #require(NativeConsumerOwnedAX.press(try node("settings.memory.search.submit", in: window)))
        pump(window)
        #expect(NativeConsumerOwnedAX.find(in: window, identifier: "settings.memory.search.result.\(foreign.id)") != nil)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "settings.memory.search.result.\(personal.id)") == true)
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @discardableResult
    private func submitMemorySearch(_ query: String, in window: NSWindow) throws -> AnyObject {
        let field = try node("settings.memory.search", in: window)
        let axField = try #require(NativeConsumerOwnedAX.element(field))
        var settable = DarwinBoolean(false)
        try #require(AXUIElementIsAttributeSettable(
            axField, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue)
        // Commit through the same owned native editor as the existing
        // restart-provenance consumer; setting AXValue alone is not an edit.
        try #require(AXUIElementSetAttributeValue(
            axField, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success)
        let fieldFocused = NativeConsumerOwnedAX.attribute(field, kAXFocusedAttribute as CFString) as? NSNumber
        try #require(fieldFocused?.boolValue == true)
        let focusedEditor = try #require(window.firstResponder as? NSTextView)
        try #require(focusedEditor.isFieldEditor && focusedEditor.window === window)
        let nativeField = try #require(focusedEditor.delegate as? NSTextField)
        try #require(nativeField.window === window && nativeField.currentEditor() === focusedEditor)
        try #require(window.makeFirstResponder(nativeField))
        nativeField.selectText(nil)
        let editor = try #require(nativeField.currentEditor() as? NSTextView)
        try #require(editor === focusedEditor)
        editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try #require(window.makeFirstResponder(nil))
        #expect(NativeConsumerOwnedAX.attribute(field, kAXValueAttribute as CFString) as? String == query)
        let submit = try node("settings.memory.search.submit", in: window)
        _ = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "settings.memory.search.clear"),
            "confirmed edit must reach the real nonempty search binding")
        try #require(NativeConsumerOwnedAX.enabled(submit) == true,
            "confirmed edit must enable the actual search button")
        try #require(NativeConsumerOwnedAX.press(submit))
        return field
    }

    @Test("shortcut row exposes its canonical slash, palette name and current binding")
    func shortcutRowShowsCanonicalSlashPaletteNameAndCurrentBinding() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "settings29-shortcut-row", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let defaults = profile.makeUserDefaults()
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")))
        let shortcuts = ShortcutStore(defaults: defaults)
        try #require(shortcuts.setBinding(ShortcutBinding(key: "8", modifiers: .commandShift),
            for: .compactContext) == nil)
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: center.sessionStore, canvasRuntimeState: .disabled,
            memoryStore: center.memoryStore, canvasFeatureLane: .phase3NonCanvas)
        // Qualify the independent, already registered command facts. The UI
        // expectation below is not computed by a new Settings row formatter.
        let palette = try #require(bridge.commandRegistry.command(id: "ui.chat.compact"))
        try #require(AppCommandCatalog.shortcutAction(forCommandID: palette.id) == .compactContext)
        try #require(palette.title == "压缩上下文" && palette.aliases.contains("compact"))
        try #require(CommandRegistry.composerCommandMetadata.contains { $0.id == "compact" })
        try #require(bridge.commandRegistry.command(id: "compact")?.id == "compact")

        let window = host(center: center, defaults: defaults, profile: profile)
        defer { close(window) }
        try #require(window.isVisible && window.isKeyWindow)
        let tab = try node("settings-tab-shortcuts", in: window)
        try #require(NativeConsumerOwnedAX.press(tab))
        _ = try node("settings.shortcuts.search", in: window)
        let record = try node("settings.shortcuts.compactContext.record", in: window)
        let rowFrame = try #require(NativeConsumerOwnedAX.frame(record))
        try #require(rowFrame.width > 0 && rowFrame.height > 0)
        _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: window, exactText: "压缩当前会话"))
        let binding = try node("settings.shortcuts.compactContext.binding", in: window)
        try #require(NativeConsumerOwnedAX.attribute(binding, kAXValueAttribute as CFString) as? String == "⇧⌘8",
            "qualify the existing row and its real current Store binding before testing missing metadata")

        let slash = try node("settings.shortcuts.compactContext.slash", in: window,
            failure: "the qualified shortcut row must display its actual App named command")
        #expect(NativeConsumerOwnedAX.role(slash) == .staticText)
        let slashText = NativeConsumerOwnedAX.attribute(slash, kAXValueAttribute as CFString) as? String ?? ""
        #expect(slashText.contains("/ui.chat.compact"))
        #expect(!slashText.contains("/compact"), "the Core direct ID is a separate authorization route")
        let paletteName = try node("settings.shortcuts.compactContext.palette-command", in: window,
            failure: "the same row must display the actual canonical command-palette name")
        #expect(NativeConsumerOwnedAX.role(paletteName) == .staticText)
        #expect((NativeConsumerOwnedAX.attribute(paletteName, kAXValueAttribute as CFString) as? String)?.contains("压缩上下文") == true)
    }

    private func host(center: SettingsCenter, defaults: UserDefaults,
                      profile: RuntimeIsolationProfile) -> NSWindow {
        let controller = NSHostingController(rootView: AnyView(SettingsView(
            center: center,
            shortcutStore: ShortcutStore(defaults: defaults),
            skillsStore: SkillsStore(
                appStore: center.skillStore,
                stateFileURL: profile.rootDirectory.appendingPathComponent("skills-state.json"),
                loadImmediately: false),
            schedulerStore: SchedulerTaskStore(defaults: defaults))
            .environment(\.typographyTokens, TypographyTokenProvider(center: center))))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("MemorySearchSettings2407")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_000, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        window.setAccessibilityIdentifier("memory-search2407-\(UUID().uuidString)")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        pump(window)
        return window
    }

    private func close(_ window: NSWindow) {
        guard window.contentViewController != nil else { return }
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }

    private func pump(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
    }

    private func node(_ identifier: String, in window: NSWindow,
                      failure: @autoclosure () -> Comment = "Owned synthetic AX target was not found") throws -> AnyObject {
        for _ in 0..<20 {
            pump(window)
            if let result = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
                return result
            }
        }
        return try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier), failure())
    }

    /// Read only the AX subtree of this exact owned window. An incomplete read
    /// is an observation failure, never evidence that another scope is absent.
    private func ownedTexts(in window: NSWindow) throws -> [String] {
        let application = AXUIElementCreateApplication(getpid())
        try #require(AXUIElementSetMessagingTimeout(application, 0.05) == .success)
        var rawWindows: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &rawWindows) == .success)
        let windows = try #require(rawWindows as? [AXUIElement])
        let identifier = window.accessibilityIdentifier()
        let owners = windows.filter {
            _ = AXUIElementSetMessagingTimeout($0, 0.05)
            return NativeConsumerOwnedAX.attribute($0, kAXIdentifierAttribute as CFString) as? String == identifier
        }
        let owner = try #require(owners.count == 1 ? owners.first : nil)
        var queue = [owner]
        var visited: [AXUIElement] = []
        var values: [String] = []
        var index = 0
        while index < queue.count {
            try #require(index < 2_048)
            let node = queue[index]
            index += 1
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            _ = AXUIElementSetMessagingTimeout(node, 0.05)
            if let value = NativeConsumerOwnedAX.attribute(node, kAXValueAttribute as CFString) as? String {
                values.append(value)
            }
            var rawChildren: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawChildren)
            if status == .attributeUnsupported || status == .noValue { continue }
            try #require(status == .success)
            let children = try #require(rawChildren as? [AXUIElement])
            queue.append(contentsOf: children)
        }
        return values
    }
}
