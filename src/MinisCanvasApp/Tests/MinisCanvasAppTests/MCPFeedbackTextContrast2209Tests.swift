import Foundation
import AppKit
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-THEME-03 actual MCP caption feedback token")
@MainActor
struct MCPFeedbackTextContrast2209Tests {
    @Test(arguments: ThemePreset.selectable, [false, true])
    func captionConsumerMeetsTextGateInEveryPreset(preset: ThemePreset, systemIsDark: Bool) throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "theme2209", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2209-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
        center.themePreset = preset
        let provider = ThemeTokenProvider(center: center)
        provider.updateSystemAppearance(NSAppearance(named: systemIsDark ? .darkAqua : .aqua))
        #expect(provider.mode == preset.resolvedMode(systemIsDark: systemIsDark))
        let original = provider.tokens
        let originalOverlay = provider.aj38
        let faces = [original.background, original.sidebarBackground, original.surfaceRaised,
                     originalOverlay.backgroundPrimary, originalOverlay.backgroundSecondary]
        // The existing text resolver also covers the inspector's 10% section face.
        let backgrounds = faces + faces.map { background in
            ThemeColor(r: originalOverlay.borderSubtle.r * 0.10 + background.r * 0.90,
                       g: originalOverlay.borderSubtle.g * 0.10 + background.g * 0.90,
                       b: originalOverlay.borderSubtle.b * 0.10 + background.b * 0.90)
        }
        for surface in [original.background, original.sidebarBackground, original.surfaceRaised] {
            // The four whole presets already satisfy their five graphical/text roles.
            #expect(ThemeContrast.violations(tokens: original, background: surface).isEmpty)
        }
        for succeeded in [false, true] {
            // Actual producer used by both MCP labels, with no duplicate palette.
            let color = MCPManagerView.feedbackTextToken(succeeded: succeeded, theme: provider)
            let source = succeeded ? original.statusSuccess : original.statusDanger
            for surface in backgrounds {
                #expect(ThemeContrast.evaluate(role: .secondary, foreground: color, background: surface).passes)
            }
            #expect(!ThemeContrast.evaluate(role: .secondary, foreground: color, background: color).passes)
            if backgrounds.allSatisfy({ ThemeContrast.evaluate(role: .secondary, foreground: source, background: $0).passes }) {
                #expect(color == source)
            }
            // A 3:1 status foreground is not necessarily a readable caption.
            if provider.mode == .light && succeeded {
                #expect(!backgrounds.allSatisfy {
                    ThemeContrast.evaluate(role: .secondary, foreground: source, background: $0).passes
                })
                for surface in [original.background, original.sidebarBackground, original.surfaceRaised] {
                    #expect(ThemeContrast.evaluate(role: .status, foreground: source, background: surface).passes)
                }
            }
        }
        #expect(provider.tokens == original)
        #expect(provider.aj38 == originalOverlay)
        #expect(center.themePreset == preset)
        #expect(center.settingsStore.settings.general.themePreset == preset)
        #expect(ThemeContrastRole.secondary.minimumRatio == 4.5)
        #expect(ThemeContrastRole.status.minimumRatio == 3.0)
    }
}
