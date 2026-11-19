import AppKit
import Foundation
import Observation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-THEME-04: both existing token layers must invalidate in the same provider
/// instance when the AppKit observation supplies a new system appearance.
/// No NSApplication/window is constructed and no system appearance is changed.
@Suite("系统外观变化传播到现有主题消费者", .serialized)
@MainActor
struct ThemeSystemAppearanceObservation1524Tests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme1524", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme1524-" + root.lastPathComponent
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

    @Test func oneProviderInvalidatesBothTokenLayersAndRestoresLight() throws {
        let center = try makeCenter()
        center.themePreset = .system
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        let lightTokens = provider.tokens
        let lightOverlay = provider.aj38
        let palette = provider.palette

        let semanticChanges = Counter()
        let overlayChanges = Counter()
        withObservationTracking { _ = provider.tokens } onChange: { semanticChanges.increment() }
        withObservationTracking { _ = provider.aj38 } onChange: { overlayChanges.increment() }
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))

        #expect(semanticChanges.count == 1)
        #expect(overlayChanges.count == 1)
        #expect(provider.mode == .dark)
        #expect(provider.tokens == ThemeTokenProvider.nativeSystemTokens(for: .dark))
        #expect(provider.aj38.backgroundPrimary == provider.tokens.background)
        #expect(provider.tokens != lightTokens)
        #expect(provider.aj38 != lightOverlay)
        #expect(provider.palette == palette)
        #expect(center.themePreset == .system)
        #expect(center.colorSchemePreference == nil)

        let reverseChanges = Counter()
        withObservationTracking {
            _ = provider.tokens
            _ = provider.aj38
        } onChange: { reverseChanges.increment() }
        provider.updateSystemAppearance(NSAppearance(named: .aqua))
        #expect(reverseChanges.count == 1)
        #expect(provider.mode == .light)
        #expect(provider.tokens == lightTokens)
        #expect(provider.aj38 == lightOverlay)
        #expect(provider.palette == palette)
        #expect(center.settingsMirror.general.themePreset == .system)
    }

    @Test func duplicateAppearanceDoesNotInvalidateAndHeadlessFallbackRemainsLight() throws {
        let center = try makeCenter()
        center.themePreset = .system
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        let changes = Counter()
        withObservationTracking { _ = provider.tokens } onChange: { changes.increment() }
        provider.updateSystemAppearance(NSAppearance(named: .darkAqua))
        #expect(changes.count == 0)
        provider.updateSystemAppearance(nil)
        #expect(changes.count == 1)
        #expect(ThemeTokenProvider.systemMode(for: nil) == .light)
        #expect(provider.tokens == ThemeTokenProvider.nativeSystemTokens(for: .light))
    }

    /// 产品主题自第 1 套配色起带深色版：明暗跟随系统，各取预设自己的浅/深两套（且走缓存的静态常量）。
    @Test(arguments: [ThemePreset.light])
    func productPresetFollowsSystemWithItsOwnLightAndDarkTokens(preset: ThemePreset) throws {
        let center = try makeCenter()
        center.themePreset = preset
        let provider = ThemeTokenProvider(center: center)
        for (name, isDark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true), (.aqua, false)] {
            provider.updateSystemAppearance(NSAppearance(named: name))
            #expect(provider.tokens == preset.semanticTokens(systemIsDark: isDark))
            #expect(provider.aj38 == (isDark ? Aj38Palette.readableDark : Aj38Palette.readableLight))
            // 不固定明暗：根视图不强制 preferredColorScheme，由系统决定窗口明暗。
            #expect(center.colorSchemePreference == nil)
            #expect(center.themePreset == preset)
            #expect(center.settingsMirror.general.themePreset == preset)
        }
    }
}
