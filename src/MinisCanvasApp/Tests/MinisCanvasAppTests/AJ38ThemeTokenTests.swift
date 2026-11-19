import AppKit
import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-38 配色基础设施：伪仙色板叠加层 token 表测试
//
// 验证：亮/暗双模式各 9 个 token 均有值（非零、合法 RGB 区间），
// 且关键色与第 1 套「暖中性 + 陶土橙」token 表（浅 #FAF9F5 / #1F1E1D / #A84E2A，深 #1F1E1C / #ECEAE4 / #E08B68）一致。

@Suite("AJ-38 伪仙色板：亮暗双模式 token 表")
@MainActor
struct AJ38ThemeTokenTests {
    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme2484-aj38", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2484-aj38-" + root.lastPathComponent
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



    @Test func retiredHighContrastPersistsAsSystemAndKeepsItsOriginalRaw2349() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "theme2349-retired", canvasRuntimeState: .disabled)
        let store = SettingsStore(directory: profile.rootDirectory.appendingPathComponent("settings"))
        let result = store.update(\.general) { $0.setThemePreset(.highContrast) }
        if case .failure(let error) = result { Issue.record("synthetic write failed: \(error)") }
        let reopened = SettingsStore(directory: profile.rootDirectory.appendingPathComponent("settings"))
        #expect(reopened.settings.general.themePreset == .system)
        #expect(reopened.settings.general.appearance == .system)
        #expect(reopened.settings.general.legacyThemePresetRawValue == "highContrast")
        #expect(ThemePreset.highContrast.semanticTokens(systemIsDark: false) == nil)
        #expect(ThemePresetCatalogPickerGate.selectableThemePresets == [.light, .system])
    }

    // MARK: - 亮色模式

    @Test func lightPaletteHasAllTokens() {
        let p = Aj38Palette.light
        // 9 个 token 全部有值（RGB 分量非零）
        let all = [p.backgroundPrimary, p.backgroundSecondary, p.textPrimary,
                   p.textSecondary, p.borderSubtle, p.accent, p.accentHover,
                   p.success, p.danger]
        for c in all {
            #expect(c.r > 0 && c.g > 0 && c.b > 0)
            // 合法 RGB 区间
            #expect(c.r <= 1 && c.g <= 1 && c.b <= 1)
        }
    }

    @Test func lightBackgroundMatchesMilkWhite() {
        // 背景 #FAF9F5 暖白
        let p = Aj38Palette.light
        #expect(p.backgroundPrimary.r > 0.95 && p.backgroundPrimary.g > 0.95)
        #expect(p.backgroundPrimary.b > 0.95)
        #expect(p.backgroundPrimary.luminance > 0.9)
    }

    @Test func lightTextPrimaryMatchesDeepCharcoal() {
        // 主文字 #1F1E1D 近黑（低亮度）
        let p = Aj38Palette.light
        #expect(p.textPrimary.r < 0.3 && p.textPrimary.g < 0.3 && p.textPrimary.b < 0.3)
        #expect(p.textPrimary.luminance < 0.05)
    }

    @Test func lightAccentMatchesOchreOrange() {
        // 强调 #A84E2A 陶土橙（R 显著高于 G/B）
        let a = Aj38Palette.light.accent
        #expect(a.r > a.g && a.g > a.b)
        #expect(a.r > 0.6 && a.g > 0.3 && a.b > 0.15)
        #expect(a == ThemeColor(hex: 0xA84E2A))
    }

    @Test func lightStatusColors() {
        // 成功 #2A7549 绿（G 最高）；危险 #B3261E 红（R 最高）
        let p = Aj38Palette.light
        let s = p.success
        #expect(s.g > s.r && s.g > s.b)
        let d = p.danger
        #expect(d.r > d.g && d.g > d.b)
    }

    // MARK: - 暗色模式

    @Test func darkPaletteHasAllTokens() {
        let p = Aj38Palette.dark
        let all = [p.backgroundPrimary, p.backgroundSecondary, p.textPrimary,
                   p.textSecondary, p.borderSubtle, p.accent, p.accentHover,
                   p.success, p.danger]
        for c in all {
            #expect(c.r > 0 && c.g > 0 && c.b > 0)
            #expect(c.r <= 1 && c.g <= 1 && c.b <= 1)
        }
    }

    @Test func darkBackgroundIsDeepCoolGray() {
        // 背景 #1F1E1C 暖深灰（低亮度）
        let p = Aj38Palette.dark
        #expect(p.backgroundPrimary.r < 0.15 && p.backgroundPrimary.g < 0.15)
        #expect(p.backgroundPrimary.luminance < 0.1)
    }

    @Test func darkTextPrimaryIsMilkWhite() {
        // 暗色主文字 #ECEAE4 暖白（高亮度）
        let p = Aj38Palette.dark
        #expect(p.textPrimary.r > 0.9 && p.textPrimary.g > 0.9)
        #expect(p.textPrimary.luminance > 0.75)
    }

    @Test func darkTextAndBorderDivergence() {
        // 暗色：文字高亮、描边深炭 → 亮度差足够大（可读性）
        let p = Aj38Palette.dark
        #expect(p.textPrimary.luminance - p.borderSubtle.luminance > 0.5)
    }

    // MARK: - 接线：ThemeTokenProvider.mode → 亮/暗

    @Test func providerModeSwitchesPalette() throws {
        // User 1115 narrows the selectable truth to product light and native System.
        // Exercise the same observed input path without starting NSApplication or
        // changing system appearance; retired dark is not a fixed-mode selection.
        let center = try makeCenter()
        center.themePreset = .light
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        // 产品主题带深色版：系统深色时用深色那套，强调色是深色强调 #E08B68。
        let productDarkTokens = provider.tokens
        let productDarkOverlay = provider.aj38
        #expect(provider.mode == .dark)
        #expect(productDarkOverlay.accent == ThemeColor(rgb: AccentTheme.pseudo.darkAccentRGB))
        #expect(productDarkOverlay.backgroundPrimary.luminance < 0.1)
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        let productTokens = provider.tokens
        let productOverlay = provider.aj38
        #expect(provider.mode == .light)
        #expect(productTokens != productDarkTokens)
        #expect(productOverlay.accent == ThemeColor(rgb: AccentTheme.pseudo.accentRGB))
        #expect(productOverlay.backgroundPrimary.luminance > 0.9)
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        let productOverlayForSystemCompare = productDarkOverlay

        center.themePreset = .system
        #expect(provider.mode == .dark)
        #expect(provider.tokens == ThemeTokenProvider.nativeSystemTokens(for: .dark))
        #expect(provider.aj38.backgroundPrimary == provider.tokens.background)
        #expect(provider.aj38.accent == ThemeTokenProvider.systemThemeAccent(for: .dark))
        #expect(provider.aj38 != productOverlayForSystemCompare)
        #expect(center.colorSchemePreference == nil)

        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        #expect(provider.mode == .light)
        #expect(provider.tokens == ThemeTokenProvider.nativeSystemTokens(for: .light))
        #expect(provider.aj38.accent == ThemeTokenProvider.systemThemeAccent(for: .light))
        #expect(center.themePreset == .system)
        #expect(center.settingsStore.settings.general.themePreset == .system)

        center.themePreset = .light
        #expect(provider.tokens == productTokens)
        #expect(provider.aj38 == productOverlay)
        #expect(center.colorSchemePreference == nil)   // 产品主题跟随系统明暗
        #expect(ThemePresetCatalogPickerGate.selectableThemePresets == [.light, .system])
    }
    @Test(arguments: [ThemePreset.light, .system], [false, true])
    func actualProviderAndOverlayUseReadableForegrounds834(preset: ThemePreset, systemIsDark: Bool) throws {
        let center = try makeCenter()
        center.themePreset = preset
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: systemIsDark ? .darkAqua : .aqua))
        #expect(provider.mode == preset.resolvedMode(systemIsDark: systemIsDark))
        let tokens = provider.tokens
        let expectedTokens = preset == .system
            ? ThemeTokenProvider.nativeSystemTokens(for: provider.mode)
            : try #require(preset.semanticTokens(systemIsDark: systemIsDark))
        #expect(tokens == expectedTokens)
        for surface in [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised] {
            #expect(ThemeContrast.violations(tokens: tokens, background: surface).isEmpty)
        }
        let overlay = provider.aj38
        if preset == .light {
            let raw = systemIsDark ? Aj38Palette.dark : Aj38Palette.light
            #expect(overlay.backgroundPrimary == raw.backgroundPrimary)
            #expect(overlay.backgroundSecondary == raw.backgroundSecondary)
            #expect(overlay.textPrimary == raw.textPrimary)
            #expect(overlay.borderSubtle == raw.borderSubtle)
        } else {
            #expect(overlay.backgroundPrimary == tokens.background)
            #expect(overlay.backgroundSecondary == tokens.sidebarBackground)
            #expect(overlay.textPrimary == tokens.textPrimary)
            #expect(overlay.borderSubtle == tokens.stroke)
        }
        for surface in [overlay.backgroundPrimary, overlay.backgroundSecondary] {
            #expect(ThemeContrast.evaluate(role: .secondary, foreground: overlay.textSecondary, background: surface).passes)
            #expect(ThemeContrast.evaluate(role: .status, foreground: overlay.success, background: surface).passes)
            #expect(ThemeContrast.evaluate(role: .status, foreground: overlay.danger, background: surface).passes)
        }
        let expectedAccent = preset == .system
            ? ThemeTokenProvider.systemThemeAccent(for: provider.mode)
            : ThemeColor(rgb: provider.mode == .dark
                ? ThemePreset.canonicalAccentTheme.darkAccentRGB
                : ThemePreset.canonicalAccentTheme.accentRGB)
        #expect(overlay.accent == expectedAccent)
        // Owned settings consumer still persists the one selected preset, not a new axis.
        #expect(center.settingsStore.settings.general.themePreset == preset)
        let reopened = SettingsStore(directory: center.settingsStore.directory)
        #expect(reopened.settings.general.themePreset == preset)
        #expect(reopened.settings.general == center.settingsStore.settings.general)
    }

}
