import AppKit
import SwiftUI
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("2349 two-theme production settings and native consumers", .serialized)
@MainActor
struct TwoThemeProductionConsumer2349Tests {
    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme2349", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2349-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
    }

    @Test func pickerAndCommandCannotRepublishRetiredValues() {
        #expect(ThemePreset.allCases == [.light, .system])
        #expect(ThemePresetCatalogPickerGate.selectableThemePresets == [.light, .system])
        for preset in [ThemePreset.dark, .highContrast] {
            #expect(!preset.isAccepted)
            #expect(BL6ThemePresetCatalogConsumer.publishedThemePresetValue(for: preset) == "system")
            #expect(BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
                storedRawValue: preset.rawValue, legacyAppearance: .light, legacyAccentTheme: .pseudo) == .system)
            #expect(preset.semanticTokens(systemIsDark: true) == nil)
        }
        #expect(BL6ThemePresetCatalogConsumer.convergedAppearancePreset(
            storedRawValue: "light", legacyAppearance: .dark, legacyAccentTheme: .pseudo) == .light)
    }

    @Test(arguments: ["dark", "highContrast"])
    func actualLegacyLoadSaveAndReopenPreserveOriginalWithoutReactivation(raw: String) throws {
        let center = try makeCenter()
        let directory = center.settingsStore.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var general = try #require(payload["general"] as? [String: Any])
        general["themePreset"] = raw
        general["appearance"] = "dark"
        payload["general"] = general
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent(SettingsStore.fileName), options: .atomic)
        let loaded = SettingsStore(directory: directory)
        #expect(loaded.settings.general.themePreset == .system)
        #expect(loaded.settings.general.legacyThemePresetRawValue == raw)
        let persisted = loaded.update(\.general) { $0.setThemePreset(.light) }
        if case .failure(let error) = persisted { Issue.record("synthetic persist failed: \(error)") }
        let reopened = SettingsStore(directory: directory)
        #expect(reopened.settings.general.themePreset == .light)
        #expect(reopened.settings.general.legacyThemePresetRawValue == raw)
        // F-1 起明暗（浅 / 深 / 跟随系统）是独立选择：带迁移标记的文件按存储值读取，
        // 旧配色词只收敛配色预设，不再抹掉明暗。
        #expect(reopened.settings.general.appearance == .dark)
        #expect(reopened.settings.general.accentTheme == .pseudo)
        #expect(ThemePreset(rawValue: raw)?.current == .system)
    }

    @Test func allEighteenOldCombinationsReopenInOnlyTwoThemes() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "theme2349-18", canvasRuntimeState: .disabled)
        var count = 0
        for appearance in Appearance.allCases {
            for accent in AccentTheme.allCases {
                let raw = ["settingsVersion": 3, "general": ["appearance": appearance.rawValue, "accentTheme": accent.rawValue]] as [String: Any]
                let directory = profile.rootDirectory.appendingPathComponent("pair-\(count)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONSerialization.data(withJSONObject: raw)
                try data.write(to: directory.appendingPathComponent(SettingsStore.fileName))
                let loaded = SettingsStore(directory: directory)
                // 无迁移标记的旧文件：旧「浅色」直接是产品主题；旧「深色/跟随系统」先收敛为跟随系统，
                // 再被一次性迁移改为产品主题。所以 18 种旧组合重新打开后都是产品主题。
                let expected: ThemePreset = .light
                #expect(loaded.settings.general.themePreset == expected)
                // F-1：旧「固定浅色」迁移后仍是浅色；其余旧组合跟随系统。
                #expect(loaded.settings.general.appearance == (appearance == .light ? .light : .system))
                let first = loaded.settings.general
                let write = loaded.update(\.general) { $0.setThemePreset(expected) }
                if case .failure(let error) = write { Issue.record("synthetic persist failed: \(error)") }
                let reopened = SettingsStore(directory: directory)
                #expect(reopened.settings.general == first)
                #expect(ThemePreset.selectable.contains(reopened.settings.general.themePreset))
                count += 1
            }
        }
        #expect(count == 18)
    }

    @Test func directSettingsCenterWriteCannotRetainHighContrastAcrossReopen() throws {
        let center = try makeCenter()
        center.themePreset = .highContrast
        #expect(center.themePreset == .system)
        #expect(center.colorSchemePreference == nil)
        #expect(center.settingsMirror.general.legacyThemePresetRawValue == "highContrast")
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings.general.themePreset == .system)
        #expect(reopened.settings.general.legacyThemePresetRawValue == "highContrast")
        center.themePreset = .light
        #expect(center.colorSchemePreference == nil)   // 产品主题带深色版，明暗跟随系统
        #expect(center.themePreset == .light)
    }

    @Test func sameProviderUsesNativeBackgroundsAndProductKeepsItsOwnIdentity() throws {
        let center = try makeCenter()
        center.themePreset = .system
        let provider = ThemeTokenProvider(center: center)
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let appearance = try #require(NSAppearance(named: name))
            provider.updateSystemAppearance(appearance)
            var nativeBackground: ThemeColor?
            appearance.performAsCurrentDrawingAppearance {
                if let rgb = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                    nativeBackground = ThemeColor(r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent))
                }
            }
            // 跟随系统主题的强调色统一为陶土橙，不取系统强调色。
            let terracotta = ThemeTokenProvider.systemThemeAccent(for: provider.mode)
            let productAccent = ThemeColor(rgb: provider.mode == .dark
                ? ThemePreset.canonicalAccentTheme.darkAccentRGB
                : ThemePreset.canonicalAccentTheme.accentRGB)
            #expect(terracotta == productAccent)
            #expect(provider.tokens.background == nativeBackground)
            #expect(provider.aj38.backgroundPrimary == provider.tokens.background)
            #expect(provider.aj38.backgroundSecondary == provider.tokens.sidebarBackground)
            #expect(provider.aj38.accent == productAccent)
            #expect(provider.aj38.accentHover == productAccent)
            #expect(provider.accentColor == ThemePreset.light.accentColor)
            #expect(center.effectiveThemeAccentColor == ThemePreset.light.accentColor)
            #expect(center.colorSchemePreference == nil)
            for surface in [provider.tokens.background, provider.tokens.sidebarBackground, provider.tokens.surfaceRaised] {
                #expect(ThemeContrast.violations(tokens: provider.tokens, background: surface).isEmpty)
            }
        }
        center.themePreset = .light
        let product = provider.tokens
        let overlay = provider.aj38
        #expect(product == ThemePreset.light.semanticTokens(systemIsDark: false))
        #expect(overlay == Aj38Palette.readableLight)
        // 产品主题带深色版：系统切到深色，tokens 与覆盖色板随之换成深色那套。
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        #expect(provider.tokens == ThemePreset.light.semanticTokens(systemIsDark: true))
        #expect(provider.tokens != product)
        #expect(provider.aj38 == Aj38Palette.readableDark)
        #expect(provider.mode == .dark)
        #expect(center.colorSchemePreference == nil)
    }
}
