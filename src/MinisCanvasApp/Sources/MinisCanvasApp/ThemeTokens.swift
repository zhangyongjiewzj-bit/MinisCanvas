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
        statusWarning: ThemeColor = ThemeColor(r: 154.0 / 255.0, g: 91.0 / 255.0, b: 15.0 / 255.0)
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
    /// 亮色模式（第 1 套「暖中性 + 陶土橙」）：暖白底 + 近黑字 + 陶土橙强调。
    static let light = Aj38Palette(
        // 背景：底 #FAF9F5 / 侧栏 #F3F1EB
        backgroundPrimary: hexColor(0xFAF9F5),
        backgroundSecondary: hexColor(0xF3F1EB),
        // 文本：正文 #1F1E1D / 次要字 #5E5D59
        textPrimary: hexColor(0x1F1E1D),
        textSecondary: hexColor(0x5E5D59),
        // 描边：#E3E0D7
        borderSubtle: hexColor(0xE3E0D7),
        // 强调：陶土橙 #A84E2A
        accent: hexColor(0xA84E2A),
        accentHover: hexColor(0xA84E2A),
        // 状态：成功 #2A7549 / 危险 #B3261E / 警告 #9A5B0F
        success: hexColor(0x2A7549),
        danger: hexColor(0xB3261E),
        statusWarning: hexColor(0x9A5B0F)
    )

    /// 暗色模式（第 1 套深色）：暖深灰底 + 暖白字。
    static let dark = Aj38Palette(
        // 背景：底 #1F1E1C / 侧栏 #262522
        backgroundPrimary: hexColor(0x1F1E1C),
        backgroundSecondary: hexColor(0x262522),
        // 文本：正文 #ECEAE4 / 次要字 #B5B2A9
        textPrimary: hexColor(0xECEAE4),
        textSecondary: hexColor(0xB5B2A9),
        // 描边：#3A3935
        borderSubtle: hexColor(0x3A3935),
        // 强调：#E08B68
        accent: hexColor(0xE08B68),
        accentHover: hexColor(0xE08B68),
        // 状态：成功 #6FC08F / 危险 #F08072 / 警告 #E3A64F
        success: hexColor(0x6FC08F),
        danger: hexColor(0xF08072),
        statusWarning: hexColor(0xE3A64F)
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
            let accent = Self.systemThemeAccent(for: mode)
            return Aj38Palette(
                backgroundPrimary: native.background, backgroundSecondary: native.sidebarBackground,
                textPrimary: native.textPrimary, textSecondary: native.textSecondary,
                borderSubtle: native.stroke, accent: accent, accentHover: accent,
                success: native.statusSuccess, danger: native.statusDanger, statusWarning: native.statusWarning
            )
        }
        // 产品主题：浅/深两套都是预先算好的静态常量（readableLight/readableDark），不在读取时新建。
        return mode == .dark ? Aj38Palette.readableDark : Aj38Palette.readableLight
    }
}
