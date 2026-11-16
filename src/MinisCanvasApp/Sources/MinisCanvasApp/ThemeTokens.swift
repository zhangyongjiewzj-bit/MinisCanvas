import SwiftUI
import MinisCore

// MARK: - AJ-38 伪仙色板叠加层（App 侧）
//
// 原则：在现有 themeTokens（MinisCore ThemeSemanticTokens + App 侧
// ThemeTokenProvider）之上**叠加新增**，不推倒重来。独立成 `Aj38Palette`
// 结构体，不修改 MinisCore 共享核心，也不改动现有语义 token —— 可回退、
// 可增量铺开。默认值 = 现有行为（未显式使用本色板时，UI 观感不变）。
//
// 色卡来源：伪仙基础/伪仙色卡.png 顶行（Swift CGContext 逐像素采样，2026-08-04）。
// 色板值见 docs/plans/AJ38_配色token表.md。

/// 16 进制色值 → RGB 分量（0~1）。供伪仙色板常量使用。
private func hexColor(_ hex: UInt32) -> ThemeColor {
    ThemeColor(
        r: Double((hex >> 16) & 0xFF) / 255.0,
        g: Double((hex >> 8) & 0xFF) / 255.0,
        b: Double(hex & 0xFF) / 255.0
    )
}

/// AJ-38 伪仙色板（叠加层）：亮/暗各一套语义色。
///
/// 与现有 `ThemeSemanticTokens` 独立，字段命名对齐 token 表：
/// backgroundPrimary/backgroundSecondary/textPrimary/textSecondary/
/// borderSubtle/accent/accentHover/success/danger。
struct Aj38Palette: Equatable, Sendable {
    var backgroundPrimary: ThemeColor
    var backgroundSecondary: ThemeColor
    var textPrimary: ThemeColor
    var textSecondary: ThemeColor
    var borderSubtle: ThemeColor
    var accent: ThemeColor
    var accentHover: ThemeColor
    var success: ThemeColor
    var danger: ThemeColor
    var statusWarning: ThemeColor

    init(
        backgroundPrimary: ThemeColor, backgroundSecondary: ThemeColor,
        textPrimary: ThemeColor, textSecondary: ThemeColor,
        borderSubtle: ThemeColor,
        accent: ThemeColor, accentHover: ThemeColor,
        success: ThemeColor, danger: ThemeColor,
        statusWarning: ThemeColor = ThemeColor(r: 157.0 / 255.0, g: 98.0 / 255.0, b: 61.0 / 255.0)
    ) {
        self.backgroundPrimary = backgroundPrimary
        self.backgroundSecondary = backgroundSecondary
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.borderSubtle = borderSubtle
        self.accent = accent
        self.accentHover = accentHover
        self.success = success
        self.danger = danger
        self.statusWarning = statusWarning
    }
}

extension Aj38Palette {
    /// 亮色模式：米白底 + 深炭字 + 赭橙强调。
    static let light = Aj38Palette(
        // 背景：米白 #FAF9F6 / 米白·深一度 #F1EEE7
        backgroundPrimary: hexColor(0xFAF9F6),
        backgroundSecondary: hexColor(0xF1EEE7),
        // 文本：深炭 #39342F / 橄榄灰 #636659
        textPrimary: hexColor(0x39342F),
        textSecondary: hexColor(0x636659),
        // 描边：暖灰 #B4AEA4
        borderSubtle: hexColor(0xB4AEA4),
        // 强调：赭橙 #9D623D / hover #A0613C
        accent: hexColor(0x9D623D),
        accentHover: hexColor(0xA0613C),
        // 状态：橄榄绿 #6B7F5E / 深赭红 #8C3A2B
        success: hexColor(0x6B7F5E),
        danger: hexColor(0x8C3A2B)
    )

    /// 暗色模式：极深冷灰底 + 米白字。
    static let dark = Aj38Palette(
        // 背景：极深冷灰 #14181C / 极深 #0A0D10
        backgroundPrimary: hexColor(0x14181C),
        backgroundSecondary: hexColor(0x0A0D10),
        // 文本：米白 #FAF9F6 / 暖灰 #B4AEA4
        textPrimary: hexColor(0xFAF9F6),
        textSecondary: hexColor(0xB4AEA4),
        // 描边：深炭 #39342F
        borderSubtle: hexColor(0x39342F),
        // 强调：赭橙·亮一档 #A0613C / hover #9C5F39
        accent: hexColor(0xA0613C),
        accentHover: hexColor(0x9C5F39),
        // 状态：橄榄绿 / 深赭红（跨模式不变）
        success: hexColor(0x6B7F5E),
        danger: hexColor(0x8C3A2B)
    )
}

// MARK: - 接线：ThemeTokenProvider → 当前模式下的伪仙色板

extension Aj38Palette {
    /// 替换强调色（E13 主题色跟随）：返回 accent/accentHover 换成主题 RGB 的新色板，
    /// 其余语义色（背景/文字/描边/状态）保持伪仙定版不动。
    func withAccent(_ rgb: (r: Double, g: Double, b: Double)) -> Aj38Palette {
        Aj38Palette(
            backgroundPrimary: backgroundPrimary,
            backgroundSecondary: backgroundSecondary,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            borderSubtle: borderSubtle,
            accent: ThemeColor(r: rgb.r, g: rgb.g, b: rgb.b),
            accentHover: ThemeColor(r: rgb.r, g: rgb.g, b: rgb.b),
            success: success,
            danger: danger, statusWarning: statusWarning
        )
    }
}

extension Aj38Palette {
    static let readableLight = light.resolvingForegroundContrast()
    static let readableDark = dark.resolvingForegroundContrast()

    /// Preserve the approved overlay palette/surfaces and repair only foreground
    /// roles that fail the same production contract consumed by the main tokens.
    func resolvingForegroundContrast() -> Aj38Palette {
        let surfaces = [backgroundPrimary, backgroundSecondary]
        var result = self
        result.textSecondary = ThemeContrast.foregroundMeetingContrast(
            textSecondary, role: .secondary, backgrounds: surfaces, readableAnchor: textPrimary)
        result.success = ThemeContrast.foregroundMeetingContrast(
            success, role: .status, backgrounds: surfaces, readableAnchor: textPrimary)
        result.danger = ThemeContrast.foregroundMeetingContrast(
            danger, role: .status, backgrounds: surfaces, readableAnchor: textPrimary)
        return result
    }
}

extension ThemeTokenProvider {
    /// Existing product identity or native System projection, from one provider.
    var aj38: Aj38Palette {
        if center.themePreset.current == .system {
            let native = tokens
            let accent = Self.nativeSystemAccent(for: mode)
            return Aj38Palette(
                backgroundPrimary: native.background, backgroundSecondary: native.sidebarBackground,
                textPrimary: native.textPrimary, textSecondary: native.textSecondary,
                borderSubtle: native.stroke, accent: accent, accentHover: accent,
                success: native.statusSuccess, danger: native.statusDanger, statusWarning: native.statusWarning
            )
        }
        return Aj38Palette.readableLight.withAccent(ThemePreset.canonicalAccentTheme.accentRGB)
    }
}
