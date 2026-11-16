import AppKit
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("2390 approval risk copy consumes text contrast", .serialized)
@MainActor
struct ApprovalRiskText2390Tests {
    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme2390", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2390-" + root.lastPathComponent
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


    @Test(arguments: ["product", "aqua", "darkAqua"])
    func renderedRiskCopyMeetsTextGateIncludingBadge(name: String) throws {
        let center = try makeCenter()
        center.themePreset = name == "product" ? .light : .system
        let theme = ThemeTokenProvider(center: center)
        theme.updateSystemAppearance(NSAppearance(named: name == "darkAqua" ? .darkAqua : .aqua))
        let original = theme.tokens
        let surfaces = [original.background, original.sidebarBackground, original.surfaceRaised,
                        theme.aj38.backgroundPrimary, theme.aj38.backgroundSecondary,
                        ThemeTokenProvider.nativeSystemTokens(for: theme.mode).background]
        for level in [ApprovalRiskLevel.low, .medium, .high] {
            let graphic = ApprovalPromptView.riskToken(for: level, theme: theme)
            let text = ApprovalPromptView.riskTextToken(for: level, theme: theme)
            var rawMinimum = 21.0
            var textMinimum = 21.0
            for surface in surfaces {
                let badge = ThemeColor(r: graphic.r * 0.18 + surface.r * 0.82,
                                       g: graphic.g * 0.18 + surface.g * 0.82,
                                       b: graphic.b * 0.18 + surface.b * 0.82)
                rawMinimum = min(rawMinimum, ThemeContrast.contrastRatio(graphic, badge))
                textMinimum = min(textMinimum, ThemeContrast.contrastRatio(text, badge), ThemeContrast.contrastRatio(text, surface))
                #expect(ThemeContrast.evaluate(role: .secondary, foreground: text, background: surface).passes)
                #expect(ThemeContrast.evaluate(role: .secondary, foreground: text, background: badge).passes)
            }
            print("RISK_TEXT name=\(name) level=\(level) rawBadgeMin=\(rawMinimum) textMin=\(textMinimum) gate=4.5")
            #expect(ThemeContrast.evaluate(role: .status, foreground: graphic, background: original.background).passes)
        }
        #expect(theme.tokens == original)
        #expect(center.themePreset == (name == "product" ? .light : .system))
    }

    @Test func graphicalWarningIsARealNegativeControlForSmallRiskCopy() throws {
        let center = try makeCenter()
        center.themePreset = .light
        let theme = ThemeTokenProvider(center: center)
        let warning = ApprovalPromptView.riskToken(for: .medium, theme: theme)
        #expect(ThemeContrast.evaluate(role: .status, foreground: warning, background: theme.tokens.background).passes)
        let surface = theme.tokens.background
        let badge = ThemeColor(r: warning.r * 0.18 + surface.r * 0.82,
                               g: warning.g * 0.18 + surface.g * 0.82,
                               b: warning.b * 0.18 + surface.b * 0.82)
        #expect(!ThemeContrast.evaluate(role: .secondary, foreground: warning, background: badge).passes)
        #expect(!ThemeContrast.evaluate(role: .secondary, foreground: theme.tokens.background, background: theme.tokens.background).passes)
    }
}
