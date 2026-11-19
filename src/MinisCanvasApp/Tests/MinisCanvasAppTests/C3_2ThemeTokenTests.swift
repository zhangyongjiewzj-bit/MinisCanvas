import XCTest
import Foundation
import AppKit
import MinisCore
import CanvasCore
@testable import MinisCanvasApp

// 1115批准范围：产品light +原生System。旧dark只作为迁移输入，不能再成为可选预设。
// 保留原7个消费者及精确token/调色板/状态映射断言；用实际外观更新路径验证原生明暗。
@MainActor
final class C3_2ThemeTokenTests: XCTestCase {
    private func makeCenter() throws -> (SettingsCenter, URL) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme2535", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2535-" + root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = SettingsCenter(
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
        return (center, root)
    }

    private func assertReadableStatusRoles834(_ tokens: ThemeSemanticTokens, file: StaticString = #filePath, line: UInt = #line) {
        for background in [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised] {
            for foreground in [tokens.statusSuccess, tokens.statusWarning, tokens.statusDanger, tokens.statusInfo, tokens.statusRunning, tokens.statusMuted] {
                XCTAssertTrue(ThemeContrast.evaluate(role: .status, foreground: foreground, background: background).passes, "原status门槛必须在实际token背景成立", file: file, line: line)
            }
        }
        XCTAssertEqual(tokens.nodeStatusColor(.running), tokens.statusRunning, file: file, line: line)
        XCTAssertEqual(tokens.nodeStatusColor(.succeeded), tokens.statusSuccess, file: file, line: line)
        XCTAssertEqual(tokens.nodeStatusColor(.failed), tokens.statusDanger, file: file, line: line)
    }

    func testModeResolvesExplicitAppearances() throws {
        let (center, _) = try makeCenter()
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        center.appearance = .light
        // F-1：固定浅色不跟随系统；系统是深色时产品主题仍用浅色那套。
        XCTAssertEqual(provider.mode, .light)
        XCTAssertEqual(center.themePreset, .light)
        XCTAssertEqual(provider.tokens, ThemePreset.light.semanticTokens(systemIsDark: false)!)

        center.appearance = .dark   // 固定深色：配色预设不变
        XCTAssertEqual(center.themePreset, .light)
        XCTAssertEqual(center.appearance, .dark)
        XCTAssertEqual(provider.mode, .dark)
        XCTAssertEqual(provider.tokens, ThemePreset.light.semanticTokens(systemIsDark: true)!)

        center.appearance = .system
        XCTAssertEqual(provider.mode, .dark)   // 系统是深色，产品主题跟随
        center.themePreset = .system
        XCTAssertEqual(provider.tokens, ThemeTokenProvider.nativeSystemTokens(for: .dark))

        center.themePreset = .light
        XCTAssertEqual(provider.mode, .dark)   // 系统仍是深色，产品主题跟随
        XCTAssertEqual(center.appearance, .system)
        XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme)
        center.themePreset = .dark // no retained selectable dark preset.
        XCTAssertEqual(center.themePreset, .system)
        XCTAssertEqual(center.settingsStore.settings.general.legacyThemePresetRawValue, "dark")
        let reopened = SettingsStore(directory: center.settingsDirectory)
        XCTAssertEqual(reopened.settings.general.themePreset, .system)
        XCTAssertEqual(reopened.settings.general.legacyThemePresetRawValue, "dark")
        XCTAssertEqual(provider.mode, .dark)
        XCTAssertEqual(center.appearance, .system)
        XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme)
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        XCTAssertEqual(provider.mode, .light)
        XCTAssertEqual(provider.tokens, ThemeTokenProvider.nativeSystemTokens(for: .light))
    }

    func testModeSystemUsesApprovedLightBaseline() throws {
        let (center, _) = try makeCenter()
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        center.themePreset = .system
        for theme in AccentTheme.allCases {
            center.accentTheme = theme
            XCTAssertEqual(provider.mode, .light)
            XCTAssertEqual(provider.tokens, ThemeTokenProvider.nativeSystemTokens(for: .light))
            XCTAssertEqual(center.themePreset, .system)
            XCTAssertEqual(center.accentTheme, ThemePreset.canonicalAccentTheme)
        }
        center.themePreset = .system
        XCTAssertEqual(provider.mode, .light)
        XCTAssertEqual(provider.tokens, ThemeTokenProvider.nativeSystemTokens(for: .light))
        XCTAssertNotEqual(provider.tokens.background, ThemePreset.light.semanticTokens(systemIsDark: false)!.background)
    }

    func testTokensTrackPresetSwitchAfterAccentConvergence() throws {
        let (center, _) = try makeCenter()
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        center.themePreset = .system
        center.accentTheme = .codex
        let darkTokens = provider.tokens
        let darkPalette = provider.palette
        XCTAssertEqual(center.themePreset, .system)
        XCTAssertEqual(provider.tokens, ThemeTokenProvider.nativeSystemTokens(for: .dark))
        XCTAssertEqual(provider.palette, AccentTheme.pseudo.palette)
        XCTAssertNotEqual(provider.palette.primary, AccentTheme.codex.palette.primary)
        center.accentTheme = .ocean
        XCTAssertEqual(provider.palette, AccentTheme.pseudo.palette)
        XCTAssertEqual(provider.tokens, darkTokens)
        XCTAssertNotEqual(provider.palette.primary, ThemeColor(rgb: AccentTheme.ocean.accentRGB))
        XCTAssertEqual(provider.palette.primary, ThemeColor(rgb: AccentTheme.pseudo.accentRGB))
        center.themePreset = .light
        XCTAssertNotEqual(provider.tokens.background, darkTokens.background)
        XCTAssertNotEqual(provider.tokens.textPrimary, darkTokens.textPrimary)
        assertReadableStatusRoles834(provider.tokens)
        assertReadableStatusRoles834(darkTokens)
        XCTAssertEqual(provider.palette, darkPalette)
    }

    func testTokensTrackAppearanceSwitch() throws {
        let (center, _) = try makeCenter()
        let provider = ThemeTokenProvider(center: center)
        center.accentTheme = .codex
        XCTAssertEqual(center.themePreset, .light)   // 主题色轴不改预设；默认是产品主题
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        center.appearance = .dark
        XCTAssertEqual(center.themePreset, .light)   // 明暗不改配色预设
        let darkTokens = provider.tokens
        let darkPalette = provider.palette
        center.appearance = .light
        XCTAssertEqual(center.themePreset, .light)
        let lightTokens = provider.tokens
        XCTAssertNotEqual(lightTokens.background, darkTokens.background)
        XCTAssertNotEqual(lightTokens.textPrimary, darkTokens.textPrimary)
        assertReadableStatusRoles834(lightTokens)
        assertReadableStatusRoles834(darkTokens)
        XCTAssertEqual(provider.palette, darkPalette)
    }

    func testProviderIsStatelessRecreatedProviderAgrees() throws {
        let (center, _) = try makeCenter()
        center.appearance = .light
        center.accentTheme = .emerald
        let a = ThemeTokenProvider(center: center)
        let b = ThemeTokenProvider(center: center)
        XCTAssertEqual(a.tokens, b.tokens)
        XCTAssertEqual(a.mode, b.mode)
        XCTAssertEqual(a.palette, b.palette)
    }

    func testNodeStatusColorMapping() throws {
        let (center, _) = try makeCenter()
        center.themePreset = .system   // 原生色里 running(青)/info(蓝) 是两个角色；产品主题里两者同色
        let provider = ThemeTokenProvider(center: center)
        for mode in [ThemeMode.light, .dark] {
            provider.updateSystemAppearance(NSAppearance(named: mode == .dark ? .darkAqua : .aqua))
            XCTAssertEqual(provider.tokens.nodeStatusColor(.pending), provider.tokens.statusMuted)
            XCTAssertEqual(provider.tokens.nodeStatusColor(.cached), provider.tokens.statusMuted)
            XCTAssertEqual(provider.tokens.nodeStatusColor(.skipped), provider.tokens.statusMuted)
            XCTAssertEqual(provider.tokens.nodeStatusColor(.running), provider.tokens.statusRunning)
            XCTAssertEqual(provider.tokens.nodeStatusColor(.succeeded), provider.tokens.statusSuccess)
            XCTAssertEqual(provider.tokens.nodeStatusColor(.failed), provider.tokens.statusDanger)
            // Native running(teal) and info(blue) are distinct semantic roles.
            XCTAssertNotEqual(provider.tokens.statusRunning, provider.tokens.statusInfo)
        }
    }

    func testNodeStatusColorMappingInvariantAcrossModes() throws {
        let (center, _) = try makeCenter()
        let provider = ThemeTokenProvider(center: center)
        center.accentTheme = .crimson
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        center.appearance = .dark
        let dark = provider.tokens
        let darkPalette = provider.palette
        center.appearance = .light
        let light = provider.tokens
        assertReadableStatusRoles834(light)
        assertReadableStatusRoles834(dark)
        XCTAssertEqual(provider.palette, darkPalette)
        for tokens in [light, dark] {
            XCTAssertEqual(tokens.nodeStatusColor(.pending), tokens.statusMuted)
            XCTAssertEqual(tokens.nodeStatusColor(.cached), tokens.statusMuted)
            XCTAssertEqual(tokens.nodeStatusColor(.skipped), tokens.statusMuted)
            for component in [tokens.statusMuted.r, tokens.statusMuted.g, tokens.statusMuted.b] {
                XCTAssertTrue((0.0...1.0).contains(component))
            }
        }
    }

    /// 流畅度第四轮：跟随系统的 token 按明暗缓存，重复读取不重算；失效后重算且结果一致。
    func testNativeSystemTokensAreCachedUntilInvalidated() {
        ThemeTokenProvider.invalidateNativeTokenCache()
        let dark = ThemeTokenProvider.nativeSystemTokens(for: .dark)
        let afterFirst = ThemeTokenProvider.nativeTokenComputeCount
        for _ in 0..<50 { XCTAssertEqual(ThemeTokenProvider.nativeSystemTokens(for: .dark), dark) }
        XCTAssertEqual(ThemeTokenProvider.nativeTokenComputeCount, afterFirst, "命中缓存不得重算")
        let light = ThemeTokenProvider.nativeSystemTokens(for: .light)
        XCTAssertNotEqual(light, dark)
        XCTAssertEqual(ThemeTokenProvider.nativeTokenComputeCount, afterFirst + 1, "另一明暗各算一次")
        ThemeTokenProvider.invalidateNativeTokenCache()
        XCTAssertEqual(ThemeTokenProvider.nativeSystemTokens(for: .dark), dark)
        XCTAssertEqual(ThemeTokenProvider.nativeTokenComputeCount, afterFirst + 2, "失效后重算一次且结果一致")
    }

    func testAppearanceSwitchRefreshesCachedSystemTokens() throws {
        let (center, _) = try makeCenter()
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        let light = provider.tokens
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        let dark = provider.tokens
        XCTAssertNotEqual(light, dark)
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        XCTAssertEqual(provider.tokens, light)
    }
}
