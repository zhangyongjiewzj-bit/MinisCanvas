import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Ordinary cold reopen of the settings and shortcut domains, with no backup import.
@Suite("D-RECOVERY-03 cold reopen namespace", .serialized)
@MainActor
struct Recovery03ColdReopenNamespaceTests {
    private func center(at root: URL) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("recovery03-usage-\(root.lastPathComponent)")),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
    }

    private func bridge(at root: URL, defaults: UserDefaults, center: SettingsCenter) -> BridgeStore {
        BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("sessions")),
            agentTaskStore: AgentTaskStore(),
            contextManifestStore: ContextManifestStore(),
            memoryStore: center.memoryStore,
            canvasFeatureLane: .phase3NonCanvas
        )
    }

    @Test("new stores consume their own saved settings and shortcuts, never a different namespace")
    func coldReopenKeepsSettingsAndShortcutsInTheirNamespace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerRoot = root.appendingPathComponent("owner", isDirectory: true)
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        let ownerSuite = "recovery03-owner-\(UUID().uuidString)"
        let otherSuite = "recovery03-other-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: ownerSuite)?.removePersistentDomain(forName: ownerSuite)
            UserDefaults(suiteName: otherSuite)?.removePersistentDomain(forName: otherSuite)
        }
        let writerDefaults = try #require(UserDefaults(suiteName: ownerSuite))
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        do {
            let writer = center(at: ownerRoot)
            writer.defaultProviderID = ProviderType.openAI.rawValue
            writer.defaultModelID = modelID
            writer.themePreset = .light
            let binding = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
            #expect(ShortcutStore(defaults: writerDefaults).setBinding(binding, for: .newSession) == nil)
        }
        writerDefaults.synchronize()

        // Fresh SettingsCenter and UserDefaults objects model the next process's readers.
        let reopened = center(at: ownerRoot)
        let reopenedDefaults = try #require(UserDefaults(suiteName: ownerSuite))
        let reopenedBridge = bridge(at: ownerRoot, defaults: reopenedDefaults, center: reopened)
        #expect(reopened.defaultProviderID == ProviderType.openAI.rawValue)
        #expect(reopened.defaultModelID == modelID)
        #expect(reopened.themePreset == .light)
        #expect(reopened.colorSchemePreference == nil)   // 产品主题跟随系统明暗，不固定浅色
        #expect(ThemeTokenProvider(center: reopened).mode == .light)
        #expect(reopenedBridge.shortcutStore.binding(for: .newSession)
            == ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command))
        #expect(reopenedBridge.paletteDisplay["session.new"]?.shortcut == "⌘G")

        // Change one namespace at a time: a different settings root must not
        // inherit preferences, and a different defaults suite must not inherit keys.
        let unrelatedDefaults = try #require(UserDefaults(suiteName: otherSuite))
        let unrelatedBridge = bridge(at: ownerRoot, defaults: unrelatedDefaults, center: reopened)
        #expect(unrelatedBridge.shortcutStore.binding(for: .newSession)
            == ShortcutAction.newSession.defaultBinding)
        #expect(unrelatedBridge.paletteDisplay["session.new"]?.shortcut == "⌘N")
        let unrelated = center(at: otherRoot)
        #expect(unrelated.defaultProviderID == nil)
        #expect(unrelated.defaultModelID == nil)
        #expect(unrelated.themePreset == .light)   // 默认主题 = 产品主题
        // Retired theme names remain readable, but cannot become effective
        // settings again after a cold reopen.
        unrelated.themePreset = .dark
        #expect(unrelated.themePreset == .system)
        #expect(center(at: otherRoot).themePreset == .system)
    }
}
