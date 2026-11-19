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
    /// 浅色取 `accentRGB`、深色取 `darkAccentRGB`；用系统动态色，随外观自动切换，
    /// 不依赖视图刷新，也不在 body 里新建。
    public var color: Color {
        let light = accentRGB
        let dark = darkAccentRGB
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        })
    }
}

extension ThemePreset {
    /// 预设的身份强调色（AJ-38 定版伪仙）；未验收预设为 nil，
    /// 调用方因此拿不到一个「看起来能用但其实没被批准」的颜色。
    public var accentColor: Color? {
        guard isAccepted else { return nil }
        return Self.productAccentColor
    }

    /// 只建一次的动态强调色（浅 #A84E2A / 深 #E08B68）。
    private static let productAccentColor: Color = canonicalAccentTheme.color
}

extension SettingsCenter {
    /// 根视图 `.preferredColorScheme` 的取值：
    /// 跟随系统 → nil（真实交给 macOS 决定明暗），
    /// 浅色 / 深色 → 对应模式。
    var colorSchemePreference: ColorScheme? {
        // 明暗是独立选择（浅色 / 深色 / 跟随系统），与配色预设无关。
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// AppKit 文本视图（对话正文、输入框）的选中背景与插入点默认走系统强调色（系统蓝），
// SwiftUI 的 .tint 管不到它们；这里给出与产品强调色同源的动态 NSColor，
// 在创建文本视图时只设置一次，随明暗外观自动切换，不在绘制路径里计算。
enum ThemeNativeTextColors {
    /// 产品强调色（浅 #A84E2A / 深 #E08B68）的动态 NSColor。
    static let accent: NSColor = {
        let accentTheme = ThemePreset.canonicalAccentTheme
        let light = accentTheme.accentRGB
        let dark = accentTheme.darkAccentRGB
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
    }()

    /// 选中文字的背景：强调色半透明，保证选中文字仍可读。
    static let selectionBackground: NSColor = accent.withAlphaComponent(0.35)

    @MainActor static func apply(to textView: NSTextView) {
        textView.selectedTextAttributes = [.backgroundColor: selectionBackground]
        textView.insertionPointColor = accent
    }
}

// 两个主题共用陶土橙强调色；跟随系统主题只换背景/文字等原生色，不再用系统蓝。
extension SettingsCenter {
    var effectiveThemeAccentColor: Color {
        ThemePreset.light.accentColor ?? .accentColor
    }
}
