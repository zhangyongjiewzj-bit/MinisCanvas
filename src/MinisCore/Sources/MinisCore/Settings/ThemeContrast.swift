import Foundation

// MARK: - THEME-03 对比度合同（正文/辅助/禁用/选中/状态色与背景的稳定对比度门槛）
//
// 本文件是 MinisCore 侧唯一的**生产**对比度判定入口。此前仓库里只有
// `ThemeColor.luminance`（ThemeTokens.swift，标准 sRGB 相对亮度）加上散落在
// 视图与测试里的 ad-hoc 断言：没有任何命名 API 承载「哪个角色门槛是多少、
// 谁不达标」这件事，因此门槛会随视图代码漂移。
//
// 三条职责：
// 1. 复算：`relativeLuminance(of:)`（薄封装，复用 `ThemeColor.luminance`，不复制公式）
//    与 `contrastRatio(_:_:)`（WCAG 2.x 相对亮度比）。
// 2. 门槛：`Role.minimumRatio`——正文/辅助/禁用/选中/状态各一条稳定阈值。
// 3. 判定：`evaluate(role:foreground:background:)` / `evaluateAll(tokens:)` /
//    `violations(tokens:)` / `assertCompliant(...)`，以及生产 UI 直接消费的
//    面板面分离判定 `panelSurfaceDecision(mode:themedFace:canvasBackdrop:)`。
//
// 边界（有意不做，属于 SETTINGS-27 + THEME-01 + THEME-05 收敛线）：
// 不新增 dark/高对比 token 集、不加 `ThemePreset`、不动主题轴迁移；
// 本文件只读 token，不定义 token，因此改门槛不会改任何已批准的浅色像素。

// MARK: - 角色

/// 需求 THEME-03 点名的五类语义角色。每类携带一条稳定对比度门槛。
///
/// 门槛取值依据（写死在此处，避免各视图各自解释）：
/// - `body`/`secondary` = 4.5:1 —— WCAG 2.x 1.4.3 AA 常规文本（辅助文本仍是要读的
///   小号文本，不给 3:1 的大字号豁免）。
/// - `disabled` = 2.5:1 —— 1.4.3 明确豁免禁用控件，但「完全看不出这里有东西」不可接受，
///   因此合同只要求一条低于 3:1 的可见性地板。
/// - `selected` = 3.0:1 —— 1.4.11 非文本 UI 组件/状态图形。
/// - `status` = 3.0:1 —— 1.4.11：状态由颜色承载（成功绿/警告黄/失败红/信息青），
///   按图形对象而非正文文本衡量。
public enum ThemeContrastRole: String, CaseIterable, Sendable {
    /// 正文（semantic `textPrimary`）。
    case body
    /// 辅助文本（semantic `textSecondary`）。
    case secondary
    /// 禁用态（semantic `disabled`）。
    case disabled
    /// 选中态（semantic `selection`）。
    case selected
    /// 状态色（semantic `status*`，取该套里最弱的一支参与判定）。
    case status

    /// 该角色对背景要求的最低 WCAG 对比度（1.0 ... 21.0）。
    public var minimumRatio: Double {
        switch self {
        case .body: 4.5
        case .secondary: 4.5
        case .disabled: 2.5
        case .selected: 3.0
        case .status: 3.0
        }
    }

    /// 该角色在给定 token 集里覆盖的 semantic 色值。`status` 覆盖全部 6 支状态色，
    /// 判定按其中最弱一支（见 `ThemeContrast.evaluateAll(tokens:)`）。
    public func colors(in tokens: ThemeSemanticTokens) -> [ThemeColor] {
        switch self {
        case .body: [tokens.textPrimary]
        case .secondary: [tokens.textSecondary]
        case .disabled: [tokens.disabled]
        case .selected: [tokens.selection]
        case .status: [
            tokens.statusSuccess, tokens.statusWarning, tokens.statusDanger,
            tokens.statusInfo, tokens.statusRunning, tokens.statusMuted,
        ]
        }
    }
}

// MARK: - 判定结果

/// 一次角色对比度判定：实测比值 + 合同门槛 + 是否达标。
public struct ThemeContrastEvaluation: Equatable, Sendable {
    public let role: ThemeContrastRole
    /// 被判定的前景色（`status` 角色下是该套状态色里最弱的一支）。
    public let foreground: ThemeColor
    /// 判定基准背景。
    public let background: ThemeColor
    /// 实测 WCAG 对比度。
    public let ratio: Double
    /// 合同门槛（= `role.minimumRatio`）。
    public let minimumRatio: Double

    public init(
        role: ThemeContrastRole, foreground: ThemeColor,
        background: ThemeColor, ratio: Double, minimumRatio: Double
    ) {
        self.role = role
        self.foreground = foreground
        self.background = background
        self.ratio = ratio
        self.minimumRatio = minimumRatio
    }

    /// 达标判定使用 `>=`：门槛值本身算通过（浮点误差另有 `ratioTolerance`）。
    public var passes: Bool {
        ratio + ThemeContrast.ratioTolerance >= minimumRatio
    }
}

/// 面板面：合同允许的两类浮层底。MinisCore 无 UI 依赖，因此只回「用哪一类」，
/// 由 App 层映射成 SwiftUI `Color`（见 `FloatingMenu.swift`）。
public enum ThemePanelFace: Equatable, Sendable {
    /// 主题 palette 自己的底色。
    case themedPalette
    /// 系统窗口底（与画布背景可分离的浮层面）。
    case systemWindowBackground
}

/// `panelSurfaceDecision` 的完整判定结果：合同给出的面类型、不透明度，
/// 以及支撑该结论的实测分离度（可观测、可断言，不是黑盒）。
public struct ThemePanelSurfaceDecision: Equatable, Sendable {
    public let face: ThemePanelFace
    public let opacity: Double
    /// 实测：主题面板底 vs 画布背景的 WCAG 比值（同源时恰为 1.0）。
    public let measuredFaceSeparation: Double
    /// 合同要求的面分离地板。
    public let minimumFaceSeparation: Double
    /// 主题面板底是否足以从画布里分离出来。
    public let separationSatisfied: Bool
    /// true = 本判定走的是「暗色定案保持」分支（分离度已实测但不据此改面），
    /// 直到暗色 token 集随 THEME-02/04 落地后由收敛线重新裁决。
    public let usesSettledDarkPin: Bool

    public init(
        face: ThemePanelFace, opacity: Double, measuredFaceSeparation: Double,
        minimumFaceSeparation: Double, separationSatisfied: Bool, usesSettledDarkPin: Bool
    ) {
        self.face = face
        self.opacity = opacity
        self.measuredFaceSeparation = measuredFaceSeparation
        self.minimumFaceSeparation = minimumFaceSeparation
        self.separationSatisfied = separationSatisfied
        self.usesSettledDarkPin = usesSettledDarkPin
    }
}

// MARK: - 合同入口

/// THEME-03 生产对比度合同。全部为纯函数：无缓存、无 IO、无 UI 依赖。
public enum ThemeContrast {
    /// 浮点对比度判定容差：门槛比较只要求 1e-9 级别的稳定，避免 pow 末位差异翻转结论。
    public static let ratioTolerance: Double = 1e-9

    /// 面板面分离地板：主题浮层底与它叠在上面的画布底至少要有这么高的比值，
    /// 否则面板面在视觉上「不存在」（同源时比值恰为 1.0）。
    ///
    /// 取 1.25 而不是 3.0：面板边缘另有描边与投影承载，1.4.11 的 3:1 是给
    /// 单独可辨识组件的；这里只回答「面与底是否同色到不可分辨」。
    public static let panelFaceMinimumSeparation: Double = 1.25

    /// 走主题面时已批准的浮层不透明度（定案「50% 透明背景 + 不透明文字」）。
    public static let themedPanelFaceOpacity: Double = 0.5

    /// 合同判定需要系统面时的高不透明度（浅底深字、面板面清晰可辨）。
    public static let systemPanelFaceOpacity: Double = 0.9

    // MARK: 复算

    /// 相对亮度：直接复用 `ThemeColor.luminance`（标准 sRGB 线性化，见 ThemeTokens.swift），
    /// 本合同不复制公式，因此不存在两套亮度实现漂移的可能。
    public static func relativeLuminance(of color: ThemeColor) -> Double {
        color.luminance
    }

    /// WCAG 2.x 对比度：(L_亮 + 0.05) / (L_暗 + 0.05)，值域 1.0 ... 21.0。
    /// 对称、自比恒为 1.0。
    public static func contrastRatio(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let la = relativeLuminance(of: a)
        let lb = relativeLuminance(of: b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Keep the existing palette and choose the least shade movement toward an
    /// already readable text token. Only registered preset consumers call this;
    /// no threshold, background, preset identity, or persistence state changes.
    public static func foregroundMeetingContrast(
        _ source: ThemeColor, role: ThemeContrastRole,
        backgrounds: [ThemeColor], readableAnchor: ThemeColor
    ) -> ThemeColor {
        func passes(_ color: ThemeColor) -> Bool {
            backgrounds.allSatisfy {
                evaluate(role: role, foreground: color, background: $0).passes
            }
        }
        guard !backgrounds.isEmpty, !passes(source), passes(readableAnchor) else { return source }
        var low = 0.0
        var high = 1.0
        func shade(_ fraction: Double) -> ThemeColor {
            ThemeColor(
                r: source.r + (readableAnchor.r - source.r) * fraction,
                g: source.g + (readableAnchor.g - source.g) * fraction,
                b: source.b + (readableAnchor.b - source.b) * fraction
            )
        }
        for _ in 0..<32 {
            let midpoint = (low + high) / 2
            if passes(shade(midpoint)) { high = midpoint } else { low = midpoint }
        }
        return shade(high)
    }

    /// 白字气泡底色：已满足 `minimum` 就原样返回，否则向黑色移动到刚好达标。
    /// 用于深色下浅陶土强调色（#E08B68 叠白字约 2.6:1）；不改任何调色板常量。
    public static func fillMeetingWhiteText(_ source: ThemeColor, minimum: Double = 4.5) -> ThemeColor {
        let white = ThemeColor(r: 1, g: 1, b: 1)
        guard contrastRatio(white, source) + ratioTolerance < minimum else { return source }
        var low = 0.0
        var high = 1.0
        func shade(_ fraction: Double) -> ThemeColor {
            ThemeColor(r: source.r * (1 - fraction), g: source.g * (1 - fraction), b: source.b * (1 - fraction))
        }
        for _ in 0..<32 {
            let midpoint = (low + high) / 2
            if contrastRatio(white, shade(midpoint)) >= minimum { high = midpoint } else { low = midpoint }
        }
        return shade(high)
    }

    /// Resolve only foreground roles; palette and all surfaces remain unchanged.
    /// The three inputs are opaque token surfaces, not measurements of a window.
    public static func resolvingPresetContrast(_ source: ThemeSemanticTokens) -> ThemeSemanticTokens {
        let surfaces = [source.background, source.sidebarBackground, source.surfaceRaised]
        let anchor = source.textPrimary
        func resolved(_ color: ThemeColor, _ role: ThemeContrastRole) -> ThemeColor {
            foregroundMeetingContrast(color, role: role, backgrounds: surfaces, readableAnchor: anchor)
        }
        var result = source
        result.textPrimary = resolved(source.textPrimary, .body)
        result.textSecondary = resolved(source.textSecondary, .secondary)
        result.textTertiary = resolved(source.textTertiary, .secondary)
        result.disabled = resolved(source.disabled, .disabled)
        result.selection = resolved(source.selection, .selected)
        result.statusSuccess = resolved(source.statusSuccess, .status)
        result.statusWarning = resolved(source.statusWarning, .status)
        result.statusDanger = resolved(source.statusDanger, .status)
        result.statusInfo = resolved(source.statusInfo, .status)
        result.statusRunning = resolved(source.statusRunning, .status)
        result.statusMuted = resolved(source.statusMuted, .status)
        return result
    }

    /// 便捷入口：角色门槛。
    public static func minimumRatio(for role: ThemeContrastRole) -> Double {
        role.minimumRatio
    }

    // MARK: 判定

    /// 单角色判定入口（生产可调用）。
    public static func evaluate(
        role: ThemeContrastRole, foreground: ThemeColor, background: ThemeColor
    ) -> ThemeContrastEvaluation {
        ThemeContrastEvaluation(
            role: role,
            foreground: foreground,
            background: background,
            ratio: contrastRatio(foreground, background),
            minimumRatio: role.minimumRatio
        )
    }

    /// 单角色是否达标。
    public static func isCompliant(
        role: ThemeContrastRole, foreground: ThemeColor, background: ThemeColor
    ) -> Bool {
        evaluate(role: role, foreground: foreground, background: background).passes
    }

    /// 对一整套 semantic token 逐角色判定（背景 = 该套 token 自己的 `background`）。
    /// `status` 角色取该套状态色里实测最弱的一支，因此「状态达标」不会被
    /// 一支好色掩盖另一支坏色。
    public static func evaluateAll(
        tokens: ThemeSemanticTokens, background explicitBackground: ThemeColor? = nil
    ) -> [ThemeContrastEvaluation] {
        let background = explicitBackground ?? tokens.background
        return ThemeContrastRole.allCases.map { role in
            let candidates = role.colors(in: tokens)
            let weakest = candidates.map { ($0, contrastRatio($0, background)) }
                .min { $0.1 < $1.1 }
            let foreground = weakest?.0 ?? background
            return ThemeContrastEvaluation(
                role: role,
                foreground: foreground,
                background: background,
                ratio: weakest?.1 ?? 1.0,
                minimumRatio: role.minimumRatio
            )
        }
    }

    /// 逐角色判定后只留不达标的角色（供生产诊断与测试基线钉住）。
    public static func violations(
        tokens: ThemeSemanticTokens, background explicitBackground: ThemeColor? = nil
    ) -> [ThemeContrastEvaluation] {
        evaluateAll(tokens: tokens, background: explicitBackground).filter { !$0.passes }
    }

    /// 整套 token 是否全角色达标。
    public static func isFullyCompliant(
        tokens: ThemeSemanticTokens, background: ThemeColor? = nil
    ) -> Bool {
        violations(tokens: tokens, background: background).isEmpty
    }

    /// 生产断言入口：Debug 下不达标即失败；Release 下 `assert` 被编译掉，
    /// 绝不把视觉门槛变成线上崩溃面。返回值便于链式使用。
    @discardableResult
    public static func assertCompliant(
        _ evaluation: ThemeContrastEvaluation,
        _ comment: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ThemeContrastEvaluation {
        assert(
            evaluation.passes,
            "THEME-03 对比度合同不达标：\(evaluation.role.rawValue) 实测 "
            + String(format: "%.3f", evaluation.ratio)
            + " < 门槛 \(evaluation.minimumRatio)"
            + (comment().isEmpty ? "" : "（\(comment())）")
        )
        return evaluation
    }

    // MARK: 浮层面板面判定（FloatingMenu 生产消费者）

    /// 浮层面板底的对比度裁决。
    ///
    /// 亮色：先实测主题面板底与画布背景的分离度。同源（例如浮层直接用
    /// `backgroundPrimary` 叠在同样是 `backgroundPrimary` 的画布上）时比值 1.0，
    /// 低于 `panelFaceMinimumSeparation`，判「面板面隐形」，据此换用系统窗口底
    /// 并要求 `systemPanelFaceOpacity`。这是算出来的结论：日后浅色 token 一改、
    /// 分离度够了，同一条调用自动回到主题面，不需要再在视图里手写修正。
    ///
    /// 暗色：分离度同样实测并随结果返回（`measuredFaceSeparation` /
    /// `separationSatisfied` = false），但**不据此改面**——暗色尚无 token 集
    /// （`ThemePreset` 在候选基线零命中，暗色/高对比 token 属于 SETTINGS-27 +
    /// THEME-01 + THEME-05 收敛线，其 THEME-02/04 依赖仍被 hold），改面会在
    /// 未批准的暗色下产生新像素。因此走 `usesSettledDarkPin` 明示「定案保持」，
    /// 由该收敛线接手后统一裁决；此字段同时是可断言的观测点。
    public static func panelSurfaceDecision(
        mode: ThemeMode, themedFace: ThemeColor, canvasBackdrop: ThemeColor
    ) -> ThemePanelSurfaceDecision {
        let separation = contrastRatio(themedFace, canvasBackdrop)
        let satisfied = separation + ratioTolerance >= panelFaceMinimumSeparation
        switch mode {
        case .light:
            return ThemePanelSurfaceDecision(
                face: satisfied ? .themedPalette : .systemWindowBackground,
                opacity: satisfied ? themedPanelFaceOpacity : systemPanelFaceOpacity,
                measuredFaceSeparation: separation,
                minimumFaceSeparation: panelFaceMinimumSeparation,
                separationSatisfied: satisfied,
                usesSettledDarkPin: false
            )
        case .dark:
            return ThemePanelSurfaceDecision(
                face: .themedPalette,
                opacity: themedPanelFaceOpacity,
                measuredFaceSeparation: separation,
                minimumFaceSeparation: panelFaceMinimumSeparation,
                separationSatisfied: satisfied,
                usesSettledDarkPin: true
            )
        }
    }
}

// A status dot uses the 3:1 status gate; readable status copy uses the existing
// 4.5:1 auxiliary-text gate. Keep the graphical tokens unchanged.
extension ThemeSemanticTokens {
    public func readableStatusText(
        _ color: ThemeColor, additionalBackgrounds: [ThemeColor] = []
    ) -> ThemeColor {
        ThemeContrast.foregroundMeetingContrast(
            color, role: .secondary,
            backgrounds: [background, sidebarBackground, surfaceRaised] + additionalBackgrounds,
            readableAnchor: textPrimary
        )
    }
}
