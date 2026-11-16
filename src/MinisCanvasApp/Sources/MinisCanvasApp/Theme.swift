import SwiftUI
import AppKit
import MinisCore

// MARK: - E13 主题多模式接线（App 侧）
//
// MinisCore 只存 RGB 分量（无 UI 依赖），这里转换为 SwiftUI `Color`，
// 并把收敛后的 `ThemePreset` 映射为 `ColorScheme?`（nil = 跟随系统）。
//
// SETTINGS-27/THEME-01：本文件的输入已经是单一预设，不再是
// `Appearance` × `AccentTheme` 两个独立轴。

extension AccentTheme {
    /// SwiftUI 主强调色（来自 MinisCore RGB 分量）。
    public var color: Color {
        Color(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b)
    }
}

extension ThemePreset {
    /// 预设的身份强调色（AJ-38 定版伪仙）；未验收预设为 nil，
    /// 调用方因此拿不到一个「看起来能用但其实没被批准」的颜色。
    public var accentColor: Color? {
        guard let rgb = accentRGB else { return nil }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension SettingsCenter {
    /// 根视图 `.preferredColorScheme` 的取值：
    /// 跟随系统 → nil（真实交给 macOS 决定明暗），
    /// 浅色 / 深色 → 对应模式。
    var colorSchemePreference: ColorScheme? {
        switch themePreset.isAccepted ? themePreset : ThemePreset.system {
        case .system: nil
        case .light: .light
        case .dark, .highContrast: nil
        }
    }
}

// System keeps the platform accent; only the product theme fixes its identity.
extension SettingsCenter {
    var effectiveThemeAccentColor: Color {
        themePreset.current == .system ? Color(nsColor: .controlAccentColor) : ThemePreset.light.accentColor ?? .accentColor
    }
}
