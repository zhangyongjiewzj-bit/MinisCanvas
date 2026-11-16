import Foundation
import Testing
@testable import MinisCore

@Suite("Theme status copy preserves the text contrast role")
struct ThemeStatusText1774Tests {
    private func hex(_ value: Int) -> ThemeColor {
        ThemeColor(r: Double((value >> 16) & 255) / 255,
                   g: Double((value >> 8) & 255) / 255,
                   b: Double(value & 255) / 255)
    }

    // These existing AJ-38 endpoints are pinned by the production-source guard
    // below. The test does not instantiate an App, native view or SettingsCenter.
    private func inspectorSurfaces(_ tokens: ThemeSemanticTokens, dark: Bool) -> [ThemeColor] {
        let primary = hex(dark ? 0x14181C : 0xFAF9F6)
        let secondary = hex(dark ? 0x0A0D10 : 0xF1EEE7)
        let border = hex(dark ? 0x39342F : 0xB4AEA4)
        let faces = [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised, primary, secondary]
        return faces + faces.map { background in
            ThemeColor(r: border.r * 0.10 + background.r * 0.90,
                       g: border.g * 0.10 + background.g * 0.90,
                       b: border.b * 0.10 + background.b * 0.90)
        }
    }

    @Test(arguments: ThemePreset.selectable, [false, true])
    func statusCopyMeetsTextGateForEveryPreset(preset: ThemePreset, systemIsDark: Bool) throws {
        let original = try #require(preset.semanticTokens(systemIsDark: systemIsDark))
        let dark = preset.resolvedMode(systemIsDark: systemIsDark) == .dark
        let surfaces = inspectorSurfaces(original, dark: dark)
        let overlayPrimary = hex(dark ? 0xFAF9F6 : 0x39342F)
        let overlayDanger = ThemeContrast.foregroundMeetingContrast(
            hex(0x8C3A2B), role: preset == .highContrast ? .body : .status,
            backgrounds: [hex(dark ? 0x14181C : 0xFAF9F6), hex(dark ? 0x0A0D10 : 0xF1EEE7)],
            readableAnchor: overlayPrimary
        )
        for source in [original.statusWarning, overlayDanger] {
            let readable = original.readableStatusText(source, additionalBackgrounds: surfaces)
            for surface in surfaces {
                #expect(ThemeContrast.evaluate(role: .secondary, foreground: readable, background: surface).passes)
            }
            // An already compliant source must remain byte-for-byte intact.
            if surfaces.allSatisfy({ ThemeContrast.evaluate(role: .secondary, foreground: source, background: $0).passes }) {
                #expect(readable == source)
            }
        }
        // This derived text consumer cannot mutate graphical status tokens.
        #expect(preset.semanticTokens(systemIsDark: systemIsDark) == original)
        #expect(ThemeContrastRole.secondary.minimumRatio == 4.5)
        #expect(ThemeContrastRole.status.minimumRatio == 3.0)
    }

    @Test
    func graphicalDangerIsARealNegativeControlForSmallDarkText() throws {
        // 退休 dark 不再提供 live tokens；可选 System 的暗侧保留同一角色负控。
        #expect(ThemePreset.dark.semanticTokens(systemIsDark: true) == nil)
        #expect(ThemePreset.highContrast.semanticTokens(systemIsDark: true) == nil)
        let tokens = try #require(ThemePreset.system.semanticTokens(systemIsDark: true))
        let background = hex(0x14181C)
        let original = ThemeContrast.foregroundMeetingContrast(
            hex(0x8C3A2B), role: .status,
            backgrounds: [background, hex(0x0A0D10)], readableAnchor: hex(0xFAF9F6)
        )
        #expect(ThemeContrast.evaluate(role: .status, foreground: original, background: background).passes)
        #expect(!ThemeContrast.evaluate(role: .secondary, foreground: original, background: background).passes)
        let readable = tokens.readableStatusText(original, additionalBackgrounds: inspectorSurfaces(tokens, dark: true))
        #expect(readable != original)
        #expect(ThemeContrast.evaluate(role: .secondary, foreground: readable, background: background).passes)
        // A same-color copy defeats even the repaired role; the predicate must reject it.
        #expect(!ThemeContrast.evaluate(role: .secondary, foreground: readable, background: readable).passes)
    }

    @Test
    func budgetLabelsConsumeTheTextResolverInsteadOfGraphicalStatusColors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let view = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/ChatInspectorView.swift")
        let section = try #require(view.range(of: "private var overviewSection:"))
        let end = try #require(view.range(of: "private var sourceSection:", range: section.upperBound..<view.endIndex))
        let overview = String(view[section.lowerBound..<end.lowerBound])
        #expect(overview.contains(".foregroundStyle(theme?.statusDangerText ?? .red)"))
        #expect(overview.contains(".foregroundStyle(theme?.statusWarningText ?? .orange)"))
        #expect(!overview.contains(".foregroundStyle(theme?.aj38.danger.swiftUIColor"))
        #expect(!overview.contains(".foregroundStyle(theme?.statusWarning ??"))
        let provider = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ThemeTokenProvider.swift")
        #expect(provider.contains("var statusDangerText: Color { readableStatusText(aj38.danger).swiftUIColor }"))
        #expect(provider.contains("var statusWarningText: Color { readableStatusText(tokens.statusWarning).swiftUIColor }"))
        #expect(provider.contains("return tokens.readableStatusText("))
        #expect(provider.contains("additionalBackgrounds: surfaces + sectionSurfaces"))
        let overlay = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ThemeTokens.swift")
        for existing in ["0x14181C", "0x0A0D10", "0xFAF9F6", "0xF1EEE7", "0x39342F", "0xB4AEA4", "0x8C3A2B"] {
            #expect(overlay.contains(existing))
        }
        let inspector = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/InspectorSection.swift")
        #expect(inspector.contains(".overlay(alignment: .bottom) { Divider().accessibilityHidden(true) }"))
    }
}
