import Foundation

// MARK: - C3-2 两层主题 token（学 ComfyUI design-system）
//
// ComfyUI 前端用两层 token：① palette（命名色阶，与亮/暗无关）
// ② semantic（--interface-* / --base-* 语义名，组件只引用这层）。
// 亮/暗切换仅重定义 semantic 层映射，palette 不变。
//
// MinisCore 只存 RGB 分量（无 UI 依赖），SwiftUI `Color` 由
// MinisCanvasApp 层转换（见 ThemeTokenProvider.swift）。

// MARK: - ThemeColor

/// 主题色值（RGB 分量 0~1，构造时收敛到合法区间）。
public struct ThemeColor: Equatable, Hashable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    public init(rgb: (r: Double, g: Double, b: Double)) {
        self.init(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    /// 相对亮度（0~1，标准 sRGB 相对亮度，用于亮/暗对比断言）。
    /// 注意：采用 sRGB 伽马解压后的线性值（WCAG 相对亮度），而非原始通道线性近似。
    public var luminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

// MARK: - ThemeMode

/// 亮/暗模式：只影响 semantic 层。
public enum ThemeMode: String, CaseIterable, Sendable {
    case light
    case dark
}

// MARK: - Palette 层

/// 每套主题的命名色阶（与亮/暗无关）。
///
/// 身份色（primary/accent）对齐 `accentRGB`；状态色（success/warning/
/// danger/info）是「语义绿/黄/红/青」在该主题下的具体取值——所有界面
/// 状态（QC 通过/失败、节点状态、错误提示）统一经 semantic 层引用，
/// 不再散落硬编码系统色。surface0/1/2 为深色背景层次（最深→突出），
/// text0/1/2 为深色文本层次（最强→弱化）；浅色模式的表面/文本取值
/// 放在 semantic 层（见 `semanticTokens(for:)`）。
public struct ThemePalette: Equatable, Sendable {
    public var primary: ThemeColor
    public var accent: ThemeColor
    public var success: ThemeColor
    public var warning: ThemeColor
    public var danger: ThemeColor
    public var info: ThemeColor
    public var surface0: ThemeColor
    public var surface1: ThemeColor
    public var surface2: ThemeColor
    public var text0: ThemeColor
    public var text1: ThemeColor
    public var text2: ThemeColor

    public init(
        primary: ThemeColor, accent: ThemeColor,
        success: ThemeColor, warning: ThemeColor, danger: ThemeColor, info: ThemeColor,
        surface0: ThemeColor, surface1: ThemeColor, surface2: ThemeColor,
        text0: ThemeColor, text1: ThemeColor, text2: ThemeColor
    ) {
        self.primary = primary
        self.accent = accent
        self.success = success
        self.warning = warning
        self.danger = danger
        self.info = info
        self.surface0 = surface0
        self.surface1 = surface1
        self.surface2 = surface2
        self.text0 = text0
        self.text1 = text1
        self.text2 = text2
    }
}

// MARK: - Semantic 层

/// 界面语义 token（组件只引用这层；亮/暗各一套映射）。
///
/// 状态色（status*）在亮/暗两套里引用同一 palette 值——「成功绿/警告黄/
/// 失败红/信息青」跨模式不变；亮暗只换背景/表面/文本/描边等中性语义。
public struct ThemeSemanticTokens: Equatable, Sendable {
    // 背景/表面
    public var background: ThemeColor
    public var sidebarBackground: ThemeColor
    public var surfaceRaised: ThemeColor
    public var stroke: ThemeColor
    // Interaction state colors are semantic so selection/focus/disabled do not
    // fall back to unrelated system colors in either appearance mode.
    public var selection: ThemeColor
    public var focusRing: ThemeColor
    public var disabled: ThemeColor
    // 文本
    public var textPrimary: ThemeColor
    public var textSecondary: ThemeColor
    public var textTertiary: ThemeColor
    // 状态（全 App 统一：QC 通过/失败、节点状态、错误提示）
    public var statusSuccess: ThemeColor
    public var statusWarning: ThemeColor
    public var statusDanger: ThemeColor
    public var statusInfo: ThemeColor
    /// 执行中（信息青；ComfyUI minimap running 色等价物）。
    public var statusRunning: ThemeColor
    /// 待执行/已缓存/已跳过（中性灰）。
    public var statusMuted: ThemeColor

    public init(
        background: ThemeColor, sidebarBackground: ThemeColor, surfaceRaised: ThemeColor,
        stroke: ThemeColor,
        selection: ThemeColor? = nil, focusRing: ThemeColor? = nil, disabled: ThemeColor? = nil,
        textPrimary: ThemeColor, textSecondary: ThemeColor, textTertiary: ThemeColor,
        statusSuccess: ThemeColor, statusWarning: ThemeColor, statusDanger: ThemeColor,
        statusInfo: ThemeColor, statusRunning: ThemeColor, statusMuted: ThemeColor
    ) {
        self.background = background
        self.sidebarBackground = sidebarBackground
        self.surfaceRaised = surfaceRaised
        self.stroke = stroke
        self.selection = selection ?? stroke
        self.focusRing = focusRing ?? stroke
        self.disabled = disabled ?? textTertiary
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.statusSuccess = statusSuccess
        self.statusWarning = statusWarning
        self.statusDanger = statusDanger
        self.statusInfo = statusInfo
        self.statusRunning = statusRunning
        self.statusMuted = statusMuted
    }
}

// MARK: - Typography semantic tokens

/// Stable roles consumed by the application typography provider.
///
/// The base size is persisted as an integer setting, but consumers should
/// resolve a semantic role instead of applying their own ad-hoc offset. The
/// two control roles are deliberately fixed: increasing readable content
/// must not resize toolbar chrome or destructive-action affordances.
public enum TypographyTokenRole: String, CaseIterable, Sendable {
    case body
    case headline
    case caption
    case caption2
    case monospaced
    case metric
    case sidebarTitle
    case sidebarItem
    case sidebarMeta
    case transcriptBody
    case composerBody
    case status
    case toolbar
    case dangerousAction
}

/// The one source of truth for mapping the persisted 12...20 pt preference to
/// semantic typography sizes. Values are kept in MinisCore so every app
/// surface can consume the same mapping without duplicating constants.
public struct TypographyTokenSet: Equatable, Sendable {
    public let baseFontSize: Int
    public let body: Double
    public let headline: Double
    public let caption: Double
    public let caption2: Double
    public let monospaced: Double
    public let metric: Double
    public let sidebarTitle: Double
    public let sidebarItem: Double
    public let sidebarMeta: Double
    public let transcriptBody: Double
    public let composerBody: Double
    public let status: Double
    public let toolbar: Double
    public let dangerousAction: Double

    public init(baseFontSize: Int) {
        let normalized = TypographySettings.clamp(baseFontSize)
        self.baseFontSize = normalized

        let base = Double(normalized)
        body = base
        headline = base + 2
        // Secondary roles keep a strict step below body at every supported
        // base size. The previous floors (12/11) collapsed body, caption,
        // sidebar meta, and status onto the same point size whenever the
        // user chose 12 or 13 pt, flattening the relative hierarchy the
        // setting is required to preserve. The floors now sit one and two
        // points under body so each role stays individually distinguishable
        // across the whole 12...20 range.
        caption = max(11, base - 2)
        caption2 = max(10, base - 3)
        monospaced = base
        metric = base + 2
        sidebarTitle = base + 1
        sidebarItem = base
        sidebarMeta = max(11, base - 2)
        transcriptBody = base
        composerBody = base
        status = max(11, base - 2)

        // Keep chrome and destructive actions stable as content scales.
        toolbar = 12
        dangerousAction = 12
    }

    /// Resolve every supported setting value through this deterministic map.
    public static func forBaseFontSize(_ baseFontSize: Int) -> TypographyTokenSet {
        TypographyTokenSet(baseFontSize: baseFontSize)
    }

    /// Return the resolved size for a semantic role without exposing storage
    /// details to consumers.
    public func size(for role: TypographyTokenRole) -> Double {
        switch role {
        case .body: body
        case .headline: headline
        case .caption: caption
        case .caption2: caption2
        case .monospaced: monospaced
        case .metric: metric
        case .sidebarTitle: sidebarTitle
        case .sidebarItem: sidebarItem
        case .sidebarMeta: sidebarMeta
        case .transcriptBody: transcriptBody
        case .composerBody: composerBody
        case .status: status
        case .toolbar: toolbar
        case .dangerousAction: dangerousAction
        }
    }
}

// MARK: - AccentTheme 扩展：palette + semantic（5 套色 × 亮/暗）

extension AccentTheme {
    /// palette 层：命名色阶（亮/暗无关）。primary 由 `accentRGB` 派生，恒一致。
    public var palette: ThemePalette {
        var p: ThemePalette
        switch self {
        case .pseudo: p = Self.pseudoPalette
        case .codex: p = Self.codexPalette
        case .graphite: p = Self.graphitePalette
        case .ocean: p = Self.oceanPalette
        case .crimson: p = Self.crimsonPalette
        case .emerald: p = Self.emeraldPalette
        }
        p.primary = ThemeColor(rgb: accentRGB)
        return p
    }

    /// semantic 层：按亮/暗模式取语义 token（亮暗只换本层，palette 不变）。
    public func semanticTokens(for mode: ThemeMode) -> ThemeSemanticTokens {
        let p = palette
        return switch mode {
        case .dark: Self.darkSemantic(palette: p)
        case .light: Self.lightSemantic(theme: self, palette: p)
        }
    }

    // MARK: 各主题 palette（身份色 + 深色中性阶）

    private static var pseudoPalette: ThemePalette {
        // 伪仙定版：赭橙强调（AJ-38 亮 #9D623D / 暗 #A0613C 取中间档）+ 极深冷灰中性阶 + 状态青。
        ThemePalette(
            primary: ThemeColor(r: 0.627, g: 0.380, b: 0.235),
            accent: ThemeColor(r: 0.70, g: 0.45, b: 0.29),
            success: ThemeColor(r: 0.42, g: 0.50, b: 0.37),
            warning: ThemeColor(r: 0.93, g: 0.74, b: 0.22),
            danger: ThemeColor(r: 0.55, g: 0.23, b: 0.17),
            info: ThemeColor(r: 0.47, g: 0.75, b: 0.78),
            surface0: ThemeColor(r: 0.04, g: 0.05, b: 0.06),
            surface1: ThemeColor(r: 0.078, g: 0.094, b: 0.11),
            surface2: ThemeColor(r: 0.10, g: 0.125, b: 0.145),
            text0: ThemeColor(r: 0.98, g: 0.976, b: 0.965),
            text1: ThemeColor(r: 0.71, g: 0.68, b: 0.64),
            text2: ThemeColor(r: 0.52, g: 0.50, b: 0.47)
        )
    }

    private static var codexPalette: ThemePalette {
        ThemePalette(
            primary: ThemeColor(r: 0.35, g: 0.78, b: 0.90),
            accent: ThemeColor(r: 0.45, g: 0.85, b: 0.95),
            success: ThemeColor(r: 0.30, g: 0.75, b: 0.45),
            warning: ThemeColor(r: 0.93, g: 0.74, b: 0.22),
            danger: ThemeColor(r: 0.93, g: 0.35, b: 0.38),
            info: ThemeColor(r: 0.32, g: 0.70, b: 0.88),
            surface0: ThemeColor(r: 0.07, g: 0.09, b: 0.11),
            surface1: ThemeColor(r: 0.11, g: 0.13, b: 0.16),
            surface2: ThemeColor(r: 0.16, g: 0.18, b: 0.22),
            text0: ThemeColor(r: 0.93, g: 0.95, b: 0.97),
            text1: ThemeColor(r: 0.72, g: 0.75, b: 0.79),
            text2: ThemeColor(r: 0.52, g: 0.55, b: 0.59)
        )
    }

    private static var graphitePalette: ThemePalette {
        ThemePalette(
            primary: ThemeColor(r: 0.65, g: 0.67, b: 0.71),
            accent: ThemeColor(r: 0.78, g: 0.80, b: 0.84),
            success: ThemeColor(r: 0.33, g: 0.72, b: 0.48),
            warning: ThemeColor(r: 0.90, g: 0.72, b: 0.25),
            danger: ThemeColor(r: 0.90, g: 0.40, b: 0.40),
            info: ThemeColor(r: 0.45, g: 0.68, b: 0.85),
            surface0: ThemeColor(r: 0.08, g: 0.08, b: 0.09),
            surface1: ThemeColor(r: 0.12, g: 0.12, b: 0.14),
            surface2: ThemeColor(r: 0.17, g: 0.17, b: 0.20),
            text0: ThemeColor(r: 0.92, g: 0.92, b: 0.94),
            text1: ThemeColor(r: 0.70, g: 0.71, b: 0.74),
            text2: ThemeColor(r: 0.50, g: 0.51, b: 0.54)
        )
    }

    private static var oceanPalette: ThemePalette {
        ThemePalette(
            primary: ThemeColor(r: 0.20, g: 0.52, b: 0.94),
            accent: ThemeColor(r: 0.35, g: 0.62, b: 0.98),
            success: ThemeColor(r: 0.28, g: 0.72, b: 0.44),
            warning: ThemeColor(r: 0.92, g: 0.72, b: 0.20),
            danger: ThemeColor(r: 0.92, g: 0.34, b: 0.36),
            info: ThemeColor(r: 0.25, g: 0.62, b: 0.92),
            surface0: ThemeColor(r: 0.06, g: 0.08, b: 0.13),
            surface1: ThemeColor(r: 0.09, g: 0.12, b: 0.19),
            surface2: ThemeColor(r: 0.13, g: 0.17, b: 0.26),
            text0: ThemeColor(r: 0.92, g: 0.95, b: 0.99),
            text1: ThemeColor(r: 0.68, g: 0.74, b: 0.84),
            text2: ThemeColor(r: 0.48, g: 0.54, b: 0.64)
        )
    }

    private static var crimsonPalette: ThemePalette {
        ThemePalette(
            primary: ThemeColor(r: 0.92, g: 0.26, b: 0.34),
            accent: ThemeColor(r: 0.97, g: 0.42, b: 0.46),
            success: ThemeColor(r: 0.32, g: 0.73, b: 0.46),
            warning: ThemeColor(r: 0.94, g: 0.73, b: 0.22),
            danger: ThemeColor(r: 0.95, g: 0.30, b: 0.32),
            info: ThemeColor(r: 0.55, g: 0.62, b: 0.88),
            surface0: ThemeColor(r: 0.10, g: 0.07, b: 0.08),
            surface1: ThemeColor(r: 0.15, g: 0.10, b: 0.12),
            surface2: ThemeColor(r: 0.21, g: 0.15, b: 0.17),
            text0: ThemeColor(r: 0.97, g: 0.93, b: 0.94),
            text1: ThemeColor(r: 0.76, g: 0.70, b: 0.72),
            text2: ThemeColor(r: 0.56, g: 0.50, b: 0.52)
        )
    }

    private static var emeraldPalette: ThemePalette {
        ThemePalette(
            primary: ThemeColor(r: 0.15, g: 0.68, b: 0.46),
            accent: ThemeColor(r: 0.28, g: 0.78, b: 0.56),
            success: ThemeColor(r: 0.24, g: 0.70, b: 0.42),
            warning: ThemeColor(r: 0.91, g: 0.72, b: 0.20),
            danger: ThemeColor(r: 0.92, g: 0.33, b: 0.35),
            info: ThemeColor(r: 0.30, g: 0.68, b: 0.80),
            surface0: ThemeColor(r: 0.06, g: 0.10, b: 0.08),
            surface1: ThemeColor(r: 0.09, g: 0.14, b: 0.11),
            surface2: ThemeColor(r: 0.13, g: 0.19, b: 0.15),
            text0: ThemeColor(r: 0.93, g: 0.97, b: 0.94),
            text1: ThemeColor(r: 0.70, g: 0.77, b: 0.72),
            text2: ThemeColor(r: 0.50, g: 0.57, b: 0.52)
        )
    }

    // MARK: dark semantic（直接引用 palette 深色中性阶；状态色 = palette 状态色）

    private static func darkSemantic(palette p: ThemePalette) -> ThemeSemanticTokens {
        ThemeSemanticTokens(
            background: p.surface0,
            sidebarBackground: p.surface1,
            surfaceRaised: p.surface2,
            stroke: p.text2,
            selection: p.accent,
            focusRing: p.accent,
            disabled: p.text2,
            textPrimary: p.text0,
            textSecondary: p.text1,
            textTertiary: p.text2,
            statusSuccess: p.success,
            statusWarning: p.warning,
            statusDanger: p.danger,
            statusInfo: p.info,
            statusRunning: p.info,
            statusMuted: p.text2
        )
    }

    // MARK: light semantic（中性语义换浅色表，状态色保持 = palette 状态色）

    private static func lightSemantic(theme: AccentTheme, palette p: ThemePalette) -> ThemeSemanticTokens {
        let light = lightNeutrals(for: theme)
        return ThemeSemanticTokens(
            background: light.background,
            sidebarBackground: light.sidebar,
            surfaceRaised: light.raised,
            stroke: light.stroke,
            selection: p.accent,
            focusRing: p.accent,
            disabled: light.textTertiary,
            textPrimary: light.textPrimary,
            textSecondary: light.textSecondary,
            textTertiary: light.textTertiary,
            statusSuccess: p.success,
            statusWarning: p.warning,
            statusDanger: p.danger,
            statusInfo: p.info,
            statusRunning: p.info,
            statusMuted: light.textTertiary
        )
    }

    /// 浅色模式中性表（背景近白、带主题色微染；文本近黑）。
    private static func lightNeutrals(for theme: AccentTheme) -> (
        background: ThemeColor, sidebar: ThemeColor, raised: ThemeColor, stroke: ThemeColor,
        textPrimary: ThemeColor, textSecondary: ThemeColor, textTertiary: ThemeColor
    ) {
        switch theme {
        case .pseudo:
            // 伪仙（赭橙）：米白底带暖微染（对齐 AJ-38 亮色板 backgroundPrimary #FAF9F6）。
            return (
                ThemeColor(r: 0.98, g: 0.976, b: 0.965), ThemeColor(r: 0.945, g: 0.933, b: 0.905),
                ThemeColor(r: 1.00, g: 1.00, b: 1.00), ThemeColor(r: 0.84, g: 0.82, b: 0.78),
                ThemeColor(r: 0.22, g: 0.20, b: 0.18), ThemeColor(r: 0.45, g: 0.42, b: 0.38),
                ThemeColor(r: 0.62, g: 0.59, b: 0.55)
            )
        case .codex:
            return (
                ThemeColor(r: 0.97, g: 0.98, b: 0.99), ThemeColor(r: 0.94, g: 0.96, b: 0.98),
                ThemeColor(r: 1.00, g: 1.00, b: 1.00), ThemeColor(r: 0.80, g: 0.84, b: 0.88),
                ThemeColor(r: 0.09, g: 0.11, b: 0.14), ThemeColor(r: 0.38, g: 0.42, b: 0.47),
                ThemeColor(r: 0.55, g: 0.59, b: 0.64)
            )
        case .graphite:
            return (
                ThemeColor(r: 0.97, g: 0.97, b: 0.98), ThemeColor(r: 0.93, g: 0.93, b: 0.95),
                ThemeColor(r: 1.00, g: 1.00, b: 1.00), ThemeColor(r: 0.82, g: 0.82, b: 0.85),
                ThemeColor(r: 0.10, g: 0.10, b: 0.11), ThemeColor(r: 0.40, g: 0.40, b: 0.43),
                ThemeColor(r: 0.57, g: 0.57, b: 0.60)
            )
        case .ocean:
            return (
                ThemeColor(r: 0.96, g: 0.975, b: 1.00), ThemeColor(r: 0.92, g: 0.95, b: 0.99),
                ThemeColor(r: 1.00, g: 1.00, b: 1.00), ThemeColor(r: 0.78, g: 0.84, b: 0.92),
                ThemeColor(r: 0.08, g: 0.12, b: 0.18), ThemeColor(r: 0.35, g: 0.42, b: 0.52),
                ThemeColor(r: 0.52, g: 0.58, b: 0.68)
            )
        case .crimson:
            return (
                ThemeColor(r: 1.00, g: 0.975, b: 0.975), ThemeColor(r: 0.98, g: 0.94, b: 0.94),
                ThemeColor(r: 1.00, g: 1.00, b: 1.00), ThemeColor(r: 0.90, g: 0.80, b: 0.82),
                ThemeColor(r: 0.16, g: 0.09, b: 0.10), ThemeColor(r: 0.48, g: 0.38, b: 0.40),
                ThemeColor(r: 0.64, g: 0.55, b: 0.57)
            )
        case .emerald:
            return (
                ThemeColor(r: 0.965, g: 0.995, b: 0.975), ThemeColor(r: 0.92, g: 0.97, b: 0.93),
                ThemeColor(r: 1.00, g: 1.00, b: 1.00), ThemeColor(r: 0.78, g: 0.88, b: 0.82),
                ThemeColor(r: 0.08, g: 0.14, b: 0.10), ThemeColor(r: 0.36, g: 0.47, b: 0.40),
                ThemeColor(r: 0.53, g: 0.64, b: 0.57)
            )
        }
    }
}

// MARK: - ThemePreset 扩展：收敛后的完整 token 解析（SETTINGS-27 / THEME-01）

/// 收敛后的外观真值只有预设一个轴。本扩展**不引入任何新色值**：
/// 全部取值都经仓库既有符号
/// `AccentTheme.semanticTokens(for:)`（→ `lightSemantic` / `darkSemantic`
/// → 各 `*Palette` 中性阶）解析，调色板恒为 AJ-38 定版
/// `AccentTheme.pseudo`（`ThemePreset.canonicalAccentTheme`）。
///
/// 旧深色/高对比无live tokens；System的原生颜色在App层由AppKit解析。
extension ThemePreset {
    /// 预设绑定的调色板；未验收预设为 nil（不猜测色值）。
    public var palette: ThemePalette? {
        guard isAccepted else { return nil }
        return Self.canonicalAccentTheme.palette
    }

    /// 已验收预设的浅色侧取值来源（仓库既有 `lightSemantic`）。
    public static let lightTokenTheme: AccentTheme = canonicalAccentTheme

    /// 解析预设在实际明暗下的 semantic token。
    ///
    /// - Parameter systemIsDark: App 层从 macOS 真实明暗读出的判定，
    ///   仅对 `.system` 生效；`.light`/`.dark` 忽略它直接取固定明暗。
    /// - Returns: 已验收预设的完整 semantic token；未验收预设为 nil。
    public func semanticTokens(systemIsDark: Bool) -> ThemeSemanticTokens? {
        guard isAccepted else { return nil }
        switch resolvedMode(systemIsDark: systemIsDark) {
        case .light: return Self.readableLightTokens
        case .dark: return Self.readableDarkTokens
        }
    }

    // Derived immutable token values, not a second settings/cache authority.
    // Reuse donor 60998e584's approved A7-A light warning shade without importing
    // its partial result as a whole-role acceptance. The other failing roles are
    // shaded toward the existing readable primary text; raw palette is intact.
    private static let readableLightTokens: ThemeSemanticTokens = {
        var source = canonicalAccentTheme.semanticTokens(for: .light)
        source.statusWarning = ThemeColor(r: 157.0 / 255.0, g: 98.0 / 255.0, b: 61.0 / 255.0)
        return ThemeContrast.resolvingPresetContrast(source)
    }()

    private static let readableDarkTokens = ThemeContrast.resolvingPresetContrast(
        canonicalAccentTheme.semanticTokens(for: .dark)
    )

    /// 预设的生效明暗：固定明暗直接用，`.system` 交由 macOS 判定。
    public func resolvedMode(systemIsDark: Bool) -> ThemeMode {
        fixedMode ?? (systemIsDark ? .dark : .light)
    }

    /// 根视图 `.tint` 的身份色 RGB（全部预设同一 AJ-38 定版值）。
    public var accentRGB: (r: Double, g: Double, b: Double)? {
        guard isAccepted else { return nil }
        return Self.canonicalAccentTheme.accentRGB
    }
}
