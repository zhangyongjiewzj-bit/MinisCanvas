import AppKit
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("2510 numeric validation caption production color", .serialized)
@MainActor
struct NumericValidationText2510Tests {
    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "numeric2510", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "numeric2510-" + root.lastPathComponent
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

    private func color(_ value: Color, mode: ThemeMode) -> ThemeColor {
        var environment = EnvironmentValues()
        environment.colorScheme = mode == .dark ? .dark : .light
        let resolved = value.resolve(in: environment)
        return ThemeColor(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue))
    }

    // UI2515, 02c/light, PID56189: flat non-glyph Form row sample 4000/4000
    // RGB247/247/247. Field blob d0c1211a is unchanged in the source baseline.
    // Screenshot SHA b67b619b0d1f631f12bfdc0ec387b2c9d1be7b6677207cc4b6b2081f8dbdc2db.
    // Measurement SHA f9b5768a28af22e6b0087b791c41fb6366cea6de3996073a827bc4eb48ed6df4.
    // This is a measured old-package input to the current shared color consumer,
    // not current-PKG UI acceptance or evidence of System.Dark Form background.
    @Test func productionCaptionMeetsBodyGateOnMeasuredProductFormRow() throws {
        let center = try makeCenter()
        center.themePreset = .light
        let theme = ThemeTokenProvider(center: center)
        theme.updateSystemAppearance(NSAppearance(named: .aqua))
        let before = center.settingsStore.settings.general
        let background = ThemeColor(r: 247.0 / 255, g: 247.0 / 255, b: 247.0 / 255)
        let foreground = color(ValidatedNumericSettingField.validationErrorColor(theme: theme), mode: theme.mode)
        let result = ThemeContrast.evaluate(role: .body, foreground: foreground, background: background)
        print("NUMERIC_ERROR measuredOldLightRow ratio=\(result.ratio) minimum=\(ThemeContrastRole.body.minimumRatio)")
        #expect(result.passes)
        #expect(ValidatedNumericSettingField.integerError(for: "oops", in: 8...32) == "请输入整数")
        #expect(ValidatedNumericSettingField.integerValue("oops", in: 8...32) == nil)
        #expect(center.settingsStore.settings.general == before)
    }

    @Test(arguments: [ThemeMode.light, .dark])
    func originalRedFailsMeasuredHistoricalRows(mode: ThemeMode) {
        // Dark sample is old02c fixed.dark, NOT current System.Dark field evidence.
        let background = mode == .light
            ? ThemeColor(r: 247.0 / 255, g: 247.0 / 255, b: 247.0 / 255)
            : ThemeColor(r: 54.0 / 255, g: 44.0 / 255, b: 43.0 / 255)
        let original = color(.red, mode: mode)
        #expect(!ThemeContrast.evaluate(role: .body, foreground: original, background: background).passes)
        #expect(!ThemeContrast.evaluate(role: .body, foreground: background, background: background).passes)
    }

    @Test(arguments: [ThemeMode.light, .dark])
    func retainedSystemUsesExistingReadableStatusResolver(mode: ThemeMode) throws {
        let center = try makeCenter()
        center.themePreset = .system
        let theme = ThemeTokenProvider(center: center)
        theme.updateSystemAppearance(NSAppearance(named: mode == .dark ? .darkAqua : .aqua))
        let tokens = theme.tokens
        #expect(ValidatedNumericSettingField.validationErrorColor(theme: theme)
            == theme.readableStatusText(tokens.statusDanger).swiftUIColor)
        #expect(theme.tokens == tokens)
        #expect(center.themePreset == .system)
    }

    @Test func noProviderPreviewKeepsOriginalErrorRole() {
        #expect(ValidatedNumericSettingField.validationErrorColor(theme: nil) == .red)
    }
}
