import AppKit
import MinisCore

/// D-APP-21: opens the ordinary ContentView with real SettingsCenter values.
/// `--responsive-field-scenario <600|800|1000|1280|1600> <12...20>
/// <accepted ThemePreset raw value> <none|left|right|both>`.
/// Each case uses a fresh packaged-field profile; no production profile can
/// consume these arguments or the panel intent stored in its private defaults.
struct ResponsiveFieldScenario: Equatable, Sendable {
    static let activationArgument = "--responsive-field-scenario"
    static let widths = [600, 800, 1000, 1280, 1600]

    enum Panels: String, Sendable {
        case none, left, right, both

        var leftOpen: Bool { self == .left || self == .both }
        var rightOpen: Bool { self == .right || self == .both }
    }

    let width: Int
    let fontSize: Int
    let theme: ThemePreset
    let panels: Panels

    static func resolveOrFail(
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments
    ) -> Self? {
        let positions = arguments.indices.filter { arguments[$0] == activationArgument }
        guard let position = positions.first else { return nil }
        precondition(positions.count == 1, "Responsive field scenario must be unique")
        precondition(profile.mode == .packagedField,
                     "Responsive field scenario requires a packaged-field profile")
        precondition(arguments.count >= position + 5,
                     "Responsive field scenario requires width font theme panels")
        guard let width = Int(arguments[position + 1]), widths.contains(width),
              let fontSize = Int(arguments[position + 2]),
              TypographySettings.uiBaseFontSizeRange.contains(fontSize),
              let theme = ThemePreset(rawValue: arguments[position + 3]),
              ThemePresetCatalogPickerGate.selectableThemePresets.contains(theme),
              let panels = Panels(rawValue: arguments[position + 4]) else {
            preconditionFailure("Invalid responsive field scenario")
        }
        return Self(width: width, fontSize: fontSize, theme: theme, panels: panels)
    }

    @MainActor
    func apply(to settings: SettingsCenter, defaults: UserDefaults) {
        settings.uiBaseFontSize = fontSize
        settings.themePreset = theme
        precondition(settings.uiBaseFontSize == fontSize && settings.themePreset == theme,
                     "Responsive field scenario settings were not persisted")
        defaults.set(!panels.leftOpen, forKey: "minisCanvas.sessionSidebarCollapsed")
        defaults.set(!panels.rightOpen, forKey: "minisCanvas.contextPanelCollapsed")
        defaults.set(MainPane.chat.rawValue, forKey: "minisCanvas.mainPane")
    }

    @MainActor
    func apply(to window: NSWindow) {
        // An unavailable 1600pt desktop is an unmet scenario, not a 1600pt PASS.
        guard let screen = window.screen ?? NSScreen.main,
              screen.visibleFrame.width >= CGFloat(width) else {
            window.title = "D-APP-21：\(width) pt 屏幕宽度不可用"
            return
        }
        window.setContentSize(NSSize(
            width: CGFloat(width),
            height: max(620, window.contentRect(forFrameRect: window.frame).height)
        ))
        let actualWidth = window.contentRect(forFrameRect: window.frame).width
        if abs(actualWidth - CGFloat(width)) > 1 {
            window.title = "D-APP-21：目标 \(width) pt，实际 \(Int(actualWidth)) pt"
        }
    }
}
