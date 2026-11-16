import AppKit
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("2414 floating menu destructive text consumer", .serialized)
@MainActor
struct FloatingMenuDestructiveText2414Tests {
    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme2414", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2414-" + root.lastPathComponent
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
    func productionDeleteTitleMeetsBodyGateOnPanelAndHover(name: String) throws {
        let center = try makeCenter()
        center.themePreset = name == "product" ? .light : .system
        let theme = ThemeTokenProvider(center: center)
        theme.updateSystemAppearance(NSAppearance(named: name == "darkAqua" ? .darkAqua : .aqua))
        let original = theme.tokens
        let overlay = theme.aj38
        let decision = FloatingMenuPanel.surfaceDecision(theme: theme)
        #expect(decision.face == (name == "darkAqua" ? .themedPalette : .systemWindowBackground))
        #expect(decision.opacity == (name == "darkAqua" ? ThemeContrast.themedPanelFaceOpacity : ThemeContrast.systemPanelFaceOpacity))
        var environment = EnvironmentValues()
        environment.colorScheme = theme.mode == .dark ? .dark : .light
        let red = Color.red.resolve(in: environment)
        let originalRed = ThemeColor(r: Double(red.red), g: Double(red.green), b: Double(red.blue))
        let text = FloatingMenuRow.destructiveTextToken(theme: theme)
        let backgrounds = FloatingMenuPanel.textBackgrounds(theme: theme)
        #expect(backgrounds.count == 12)
        let oldMinimum = backgrounds.map { ThemeContrast.contrastRatio(originalRed, $0) }.min()!
        let minimum = backgrounds.map { ThemeContrast.contrastRatio(text, $0) }.min()!
        print("DELETE_TEXT name=\(name) rawRedMin=\(oldMinimum) textMin=\(minimum) gate=4.5")
        for background in backgrounds {
            #expect(ThemeContrast.evaluate(role: .body, foreground: text, background: background).passes)
        }
        #expect(FloatingMenuRow.titleColor(role: .destructive, textColor: .blue, theme: theme) == text.swiftUIColor)
        #expect(FloatingMenuRow.titleColor(role: nil, textColor: .blue, theme: theme) == .blue)
        #expect(theme.tokens == original)
        #expect(theme.aj38 == overlay)
    }

    @Test func originalNativeRedFailsTextGateOnActualLightPanel() throws {
        let center = try makeCenter()
        center.themePreset = .system
        let theme = ThemeTokenProvider(center: center)
        theme.updateSystemAppearance(NSAppearance(named: .aqua))
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let red = Color.red.resolve(in: environment)
        let old = ThemeColor(r: Double(red.red), g: Double(red.green), b: Double(red.blue))
        let backgrounds = FloatingMenuPanel.textBackgrounds(theme: theme)
        #expect(backgrounds.contains { !ThemeContrast.evaluate(role: .body, foreground: old, background: $0).passes })
        #expect(!ThemeContrast.evaluate(role: .body, foreground: backgrounds[0], background: backgrounds[0]).passes)
    }

    @Test func ordinaryTitlesAndHeadlessPreviewFallbackKeepOriginalChoice() {
        #expect(FloatingMenuRow.titleColor(role: nil, textColor: .blue, theme: nil) == .blue)
        #expect(FloatingMenuRow.titleColor(role: .cancel, textColor: .blue, theme: nil) == .blue)
        #expect(FloatingMenuRow.titleColor(role: .destructive, textColor: .blue, theme: nil) == .red)
    }
}
