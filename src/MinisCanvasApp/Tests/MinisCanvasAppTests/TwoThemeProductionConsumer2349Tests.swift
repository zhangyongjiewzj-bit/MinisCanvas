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
        #expect(reopened.settings.general.appearance == .light)
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
                let expected: ThemePreset = appearance == .light ? .light : .system
                #expect(loaded.settings.general.themePreset == expected)
                #expect(loaded.settings.general.appearance == expected.appearanceProjection)
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
        #expect(center.colorSchemePreference == .light)
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
            var nativeAccent: ThemeColor?
            appearance.performAsCurrentDrawingAppearance {
                if let rgb = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                    nativeBackground = ThemeColor(r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent))
                }
                if let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                    nativeAccent = ThemeColor(r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent))
                }
            }
            #expect(provider.tokens.background == nativeBackground)
            #expect(provider.aj38.backgroundPrimary == provider.tokens.background)
            #expect(provider.aj38.backgroundSecondary == provider.tokens.sidebarBackground)
            #expect(provider.aj38.accent == nativeAccent)
            #expect(provider.aj38.accentHover == nativeAccent)
            #expect(provider.accentColor == Color(nsColor: .controlAccentColor))
            #expect(center.effectiveThemeAccentColor == Color(nsColor: .controlAccentColor))
            #expect(center.colorSchemePreference == nil)
            for surface in [provider.tokens.background, provider.tokens.sidebarBackground, provider.tokens.surfaceRaised] {
                #expect(ThemeContrast.violations(tokens: provider.tokens, background: surface).isEmpty)
            }
        }
        center.themePreset = .light
        let product = provider.tokens
        let overlay = provider.aj38
        #expect(product == ThemePreset.light.semanticTokens(systemIsDark: false))
        #expect(overlay == Aj38Palette.readableLight.withAccent(AccentTheme.pseudo.accentRGB))
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        #expect(provider.tokens == product)
        #expect(provider.aj38 == overlay)
        #expect(provider.mode == .light)
        #expect(center.colorSchemePreference == .light)
    }
}
