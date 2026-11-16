import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Original THEME05 consumer boundary: write the old file before constructing
/// the settings owner, then consume that migrated owner through the renderer.
/// This is fresh object assembly, not a process restart or a package UI proof.
@Suite("RECOVERY original legacy theme cold consumer", .serialized)
@MainActor
struct RecoveryLegacyThemeColdConsumer0400Tests {
    private func center(root: URL, defaults: UserDefaults) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("recovery0400-usage-" + root.lastPathComponent)),
            shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
    }

    @Test func legacyFileMigratesBeforeThemeOwnerConstructionAndSecondColdProjection() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("recovery0400-" + UUID().uuidString)
        var checked = 0
        for appearance in Appearance.allCases {
            for accent in AccentTheme.allCases {
                let pairRoot = root.appendingPathComponent("pair-\(checked)")
                let directory = pairRoot.appendingPathComponent("settings")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent(SettingsStore.fileName)
                let input: [String: Any] = ["settingsVersion": 3,
                    "general": ["appearance": appearance.rawValue, "accentTheme": accent.rawValue]]
                let original = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                try original.write(to: file, options: .atomic)
                try original.write(to: pairRoot.appendingPathComponent("original-v3.bytes"))
                let suite = formal.userDefaultsSuiteName + ".recovery0400." + UUID().uuidString
                let firstDefaults = try #require(UserDefaults(suiteName: suite))
                // No settings update is performed. The production initializer must
                // persist its migration before its ordinary settings mirror is used.
                let first = center(root: pairRoot, defaults: firstDefaults)
                let expected = ThemePreset.nearest(for: appearance, accentTheme: accent)
                let firstGeneral = first.settingsMirror.general
                #expect(first.themePreset == expected)
                #expect(ThemePreset.selectable.contains(first.themePreset))
                #expect(firstGeneral == first.settingsStore.settings.general)
                #expect(first.appearance == expected.appearanceProjection)
                #expect(first.accentTheme == ThemePreset.canonicalAccentTheme)
                let oldCombination = "\(appearance.rawValue)|\(accent.rawValue)"
                // Canonical light/system + pseudo have no displaced legacy axes.
                // All other sixteen old combinations must preserve their exact raw marker.
                let expectedLegacyMarker: String? = ["system|pseudo", "light|pseudo"].contains(oldCombination)
                    ? nil : oldCombination
                #expect(firstGeneral.legacyThemePresetRawValue == expectedLegacyMarker)
                #expect(first.settingsStore.lastMigrationProvenance?.fromVersion == 3)
                #expect(first.settingsStore.lastMigrationProvenance?.toVersion == AppSettings.currentVersion)
                #expect(first.settingsStore.lastPersistenceError == nil)
                let renderer = ThemeTokenProvider(center: first)
                #expect(renderer.center === first)
                #expect(renderer.mode == expected.resolvedMode(systemIsDark: renderer.systemAppearanceMode == .dark))
                #expect(ThemeContrast.violations(tokens: renderer.tokens, background: renderer.tokens.background).isEmpty)
                if expected == .light {
                    #expect(renderer.tokens == ThemePreset.light.semanticTokens(systemIsDark: false))
                }
                let persisted = try Data(contentsOf: file)
                #expect(persisted != original)
                let object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
                #expect(object["settingsVersion"] as? Int == AppSettings.currentVersion)
                let general = try #require(object["general"] as? [String: Any])
                #expect(general["themePreset"] as? String == expected.rawValue)
                let secondDefaults = try #require(UserDefaults(suiteName: suite))
                let second = center(root: pairRoot, defaults: secondDefaults)
                #expect(second !== first)
                #expect(second.settingsStore !== first.settingsStore)
                #expect(second.settingsMirror.general == firstGeneral)
                #expect(second.themePreset == expected)
                #expect(second.settingsStore.lastMigrationProvenance?.fromVersion == AppSettings.currentVersion)
                #expect(second.settingsStore.lastPersistenceError == nil)
                let secondRenderer = ThemeTokenProvider(center: second)
                #expect(secondRenderer.center === second)
                #expect(secondRenderer.mode == renderer.mode)
                #expect(secondRenderer.tokens == renderer.tokens)
                #expect(try Data(contentsOf: file) == persisted,
                    "The cold consumer must not restore legacy axes or migrate again")
                #expect(try Data(contentsOf: pairRoot.appendingPathComponent("original-v3.bytes")) == original)
                checked += 1
            }
        }
        #expect(checked == 18)
        print("RECOVERY0400 legacyPairs=\(checked) root=\(root.path)")
    }
}
