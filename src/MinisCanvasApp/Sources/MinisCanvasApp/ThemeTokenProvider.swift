import SwiftUI
import Observation
import AppKit
import MinisCore
import CanvasCore

// MARK: - C3-2 TokenProvider（两层主题 token 的 App 侧接线）
//
// palette（命名色阶，亮/暗无关）→ semantic（界面语义 token，亮/暗各一套）
// 两层分离；亮暗切换只换 semantic 层。
//
// SETTINGS-27/THEME-01 收敛后，本 Provider 的唯一输入是
// `SettingsCenter.themePreset`（不再读「外观模式 × 主题色」两个自由轴），
// 视图经 `@Environment(\.themeTokens)` 取用（未注入时回退系统色，测试/预览安全）。

/// 将 MinisCore 的 RGB 分量转成 SwiftUI `Color`。
extension ThemeColor {
    public var swiftUIColor: Color {
        Color(red: r, green: g, blue: b)
    }
}

@MainActor
@Observable
final class ThemeTokenProvider {
    let center: SettingsCenter

    // Reuse the system-appearance observation from donor a1314b529, keeping
    // themePreset as the sole settings truth. AppKit's effectiveAppearance is
    // not an Observation dependency: direct reads alone cannot invalidate the
    // existing environment consumers when the system changes appearance.
    private(set) var systemAppearanceMode: ThemeMode
    @ObservationIgnored private var effectiveAppearanceObservation: NSKeyValueObservation?

    init(center: SettingsCenter) {
        self.center = center
        self.systemAppearanceMode = Self.systemMode(for: NSApp?.effectiveAppearance)
        if let application = NSApp {
            effectiveAppearanceObservation = application.observe(
                \.effectiveAppearance, options: [.new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateSystemAppearance(NSApp?.effectiveAppearance)
                }
            }
        }
    }

    /// Resolve only the real AppKit appearance; headless previews retain the
    /// existing light fallback, independent of any ambient drawing appearance.
    static func systemMode(for appearance: NSAppearance?) -> ThemeMode {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The AppKit observation and focused tests consume the same update path.
    /// This is a live rendering input, never a persisted appearance setting.
    func updateSystemAppearance(_ appearance: NSAppearance?) {
        let nextMode = Self.systemMode(for: appearance)
        guard nextMode != systemAppearanceMode else { return }
        Self.invalidateNativeTokenCache()
        systemAppearanceMode = nextMode
    }

    // MARK: 解析（读 SettingsCenter 的 @Observable 属性 → 视图自动追踪）

    /// 生效预设。未验收值（例如被外部改坏的存储键）在渲染前再收敛一次，
    /// 因此不存在「预设不可读 → token 缺失」的路径。
    private var effectivePreset: ThemePreset {
        center.themePreset.isAccepted ? center.themePreset : .system
    }

    /// macOS 当前真实明暗。无 NSApp（单元测试/SwiftUI 预览）时按浅色处理，
    /// 与收敛前默认外观一致，不引入新的视觉结果。
    private var systemIsDark: Bool {
        systemAppearanceMode == .dark
    }

    /// 当前生效明暗：固定明暗预设直接映射；跟随系统读 macOS 状态。
    var mode: ThemeMode {
        switch center.appearance {
        case .light: .light
        case .dark: .dark
        case .system: effectivePreset.resolvedMode(systemIsDark: systemIsDark)
        }
    }

    /// 当前主题的 palette 层（亮/暗无关）；全部预设共用 AJ-38 定版伪仙。
    var palette: ThemePalette { effectivePreset.palette ?? AccentTheme.pseudo.palette }

    /// 当前生效的 semantic token（改预设即变）。
    var tokens: ThemeSemanticTokens {
        if effectivePreset == .system { return Self.nativeSystemTokens(for: mode) }
        // 预设的明暗由 `mode` 决定（固定浅色/深色时不看系统明暗）。
        return effectivePreset.semanticTokens(systemIsDark: mode == .dark)
            ?? AccentTheme.pseudo.semanticTokens(for: mode)
    }

    /// Native colors are resolved under the observed appearance, without
    /// changing NSApp/system appearance or storing another theme truth.
    static func nativeSystemTokens(for mode: ThemeMode) -> ThemeSemanticTokens {
        _ = invalidationObservers
        let key = nativeTokenCacheKey(for: mode)
        if let cached = nativeTokenCache[key] { return cached }
        nativeTokenComputeCount += 1
        let computed = computeNativeSystemTokens(for: mode)
        nativeTokenCache[key] = computed
        return computed
    }

    // 流畅度第四轮：跟随系统时每次读 token 都重转 14 个系统色并跑对比度修正
    // （流式输出期间主线程采样 48 个样本）。结果只取决于明暗、「提高对比度」开关与
    // 系统颜色（强调色等），按这三者缓存，系统颜色/外观/辅助功能显示选项变化时失效。
    private static var nativeTokenCache: [Int: ThemeSemanticTokens] = [:]
    /// 真实计算次数（测试用：命中缓存时不增加）。
    private(set) static var nativeTokenComputeCount = 0

    private static func nativeTokenCacheKey(for mode: ThemeMode) -> Int {
        (mode == .dark ? 1 : 0) | (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 0)
    }

    /// 清空系统色缓存。系统颜色、外观或辅助功能显示选项变化时调用。
    static func invalidateNativeTokenCache() {
        nativeTokenCache.removeAll()
    }

    /// 只注册一次；闭包不捕获实例。
    private static let invalidationObservers: Void = {
        let invalidate: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in ThemeTokenProvider.invalidateNativeTokenCache() }
        }
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main,
            using: invalidate)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
            queue: .main, using: invalidate)
    }()

    private static func computeNativeSystemTokens(for mode: ThemeMode) -> ThemeSemanticTokens {
        let appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        var result: ThemeSemanticTokens?
        let resolve = {
            let background = Self.nativeColor(.windowBackgroundColor)
            let sidebar = Self.nativeColor(.controlBackgroundColor)
            let raised = Self.nativeColor(.textBackgroundColor)
            let primary = Self.nativeColor(.labelColor, over: background)
            let raw = ThemeSemanticTokens(
                background: background, sidebarBackground: sidebar, surfaceRaised: raised,
                stroke: Self.nativeColor(.separatorColor, over: background),
                selection: Self.nativeColor(.selectedContentBackgroundColor),
                focusRing: Self.nativeColor(.keyboardFocusIndicatorColor, over: background),
                disabled: Self.nativeColor(.disabledControlTextColor, over: background),
                textPrimary: primary,
                textSecondary: Self.nativeColor(.secondaryLabelColor, over: background),
                textTertiary: Self.nativeColor(.tertiaryLabelColor, over: background),
                statusSuccess: Self.nativeColor(.systemGreen),
                statusWarning: Self.nativeColor(.systemOrange),
                statusDanger: Self.nativeColor(.systemRed),
                statusInfo: Self.nativeColor(.systemBlue),
                statusRunning: Self.nativeColor(.systemTeal),
                statusMuted: Self.nativeColor(.secondaryLabelColor, over: background)
            )
            // Same role minima as the product theme; native source colors are
            // inputs, not a contrast exemption or a second palette authority.
            result = ThemeContrast.resolvingPresetContrast(raw)
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(resolve) }
        else { resolve() }
        return result!
    }

    /// 跟随系统主题时的强调色：与产品主题统一为陶土橙（浅 #A84E2A / 深 #E08B68），
    /// 不再取系统强调色（系统蓝），避免同一界面一橙一蓝。
    static func systemThemeAccent(for mode: ThemeMode) -> ThemeColor {
        let theme = ThemePreset.canonicalAccentTheme
        return ThemeColor(rgb: mode == .dark ? theme.darkAccentRGB : theme.accentRGB)
    }

    private static func nativeColor(_ color: NSColor, over surface: ThemeColor? = nil) -> ThemeColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB)!
        let alpha = Double(rgb.alphaComponent)
        let base = surface ?? ThemeColor(r: 0, g: 0, b: 0)
        return ThemeColor(
            r: Double(rgb.redComponent) * alpha + base.r * (1 - alpha),
            g: Double(rgb.greenComponent) * alpha + base.g * (1 - alpha),
            b: Double(rgb.blueComponent) * alpha + base.b * (1 - alpha)
        )
    }

    // MARK: SwiftUI 便捷色（组件直接 `theme.xxx`）

    var accentColor: Color {
        effectivePreset.accentColor ?? AccentTheme.pseudo.color
    }
    var background: Color { tokens.background.swiftUIColor }
    var sidebarBackground: Color { tokens.sidebarBackground.swiftUIColor }
    var surfaceRaised: Color { tokens.surfaceRaised.swiftUIColor }
    var stroke: Color { tokens.stroke.swiftUIColor }
    var selection: Color { tokens.selection.swiftUIColor }
    var focusRing: Color { tokens.focusRing.swiftUIColor }
    var disabled: Color { tokens.disabled.swiftUIColor }
    var textPrimary: Color { tokens.textPrimary.swiftUIColor }
    var textSecondary: Color { tokens.textSecondary.swiftUIColor }
    var textTertiary: Color { tokens.textTertiary.swiftUIColor }
    var statusSuccess: Color { tokens.statusSuccess.swiftUIColor }
    var statusWarning: Color { tokens.statusWarning.swiftUIColor }
    var statusDanger: Color { tokens.statusDanger.swiftUIColor }
    var statusInfo: Color { tokens.statusInfo.swiftUIColor }
    var statusRunning: Color { tokens.statusRunning.swiftUIColor }
    var statusMuted: Color { tokens.statusMuted.swiftUIColor }

    // Small warning/failure copy is text, rather than the status glyph role.
    // Include the existing AJ-38 inspector surfaces in the same pure resolver.
    var statusWarningText: Color { readableStatusText(tokens.statusWarning).swiftUIColor }
    var statusDangerText: Color { readableStatusText(aj38.danger).swiftUIColor }

    func readableStatusText(_ color: ThemeColor) -> ThemeColor {
        let overlay = aj38
        let surfaces = [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised,
                        overlay.backgroundPrimary, overlay.backgroundSecondary]
        // InspectorSection paints borderSubtle at 10% over its parent face.
        let sectionSurfaces = surfaces.map { background in
            ThemeColor(r: overlay.borderSubtle.r * 0.10 + background.r * 0.90,
                       g: overlay.borderSubtle.g * 0.10 + background.g * 0.90,
                       b: overlay.borderSubtle.b * 0.10 + background.b * 0.90)
        }
        return tokens.readableStatusText(
            color, additionalBackgrounds: surfaces + sectionSurfaces
        )
    }

    // MARK: 节点状态 → 语义色（QC 通过/失败、执行中、缓存等全走 token）

    /// 节点状态映射：succeeded/QC 通过 = 成功绿，failed/QC 失败 = 失败红，
    /// running = 信息青，pending/cached/skipped = 中性灰。
    func nodeStatusColor(_ status: NodeStatus) -> Color {
        tokens.nodeStatusColor(status).swiftUIColor
    }
}

// MARK: - NodeStatus → semantic token 映射（App 层，因 NodeStatus 在 CanvasCore）

extension ThemeSemanticTokens {
    /// 节点状态 → 统一语义色（替代散落的 systemGreen/systemRed 硬编码）。
    func nodeStatusColor(_ status: NodeStatus) -> ThemeColor {
        switch status {
        case .pending, .cached, .skipped: statusMuted
        case .running: statusRunning
        case .succeeded: statusSuccess
        case .failed: statusDanger
        }
    }
}

// MARK: - Environment 注入（可选：未注入时视图回退系统色，保证测试/预览不崩）

private struct ThemeTokenProviderKey: EnvironmentKey {
    static let defaultValue: ThemeTokenProvider? = nil
}

extension EnvironmentValues {
    /// 当前主题 token 提供者（根视图 `.environment(themeTokens:)` 注入）。
    var themeTokens: ThemeTokenProvider? {
        get { self[ThemeTokenProviderKey.self] }
        set { self[ThemeTokenProviderKey.self] = newValue }
    }
}

/// 取不到主题对象时（静态函数、预览）使用的状态色后备值：第 1 套状态色，
/// 浅/深色各一值，由系统动态色随外观切换；各常量只建一次，不在 body 里新建。
enum AppStatusColor {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static let success = dynamic(light: 0x2A7549, dark: 0x6FC08F)
    static let warning = dynamic(light: 0x9A5B0F, dark: 0xE3A64F)
    static let danger = dynamic(light: 0xB3261E, dark: 0xF08072)
    static let info = dynamic(light: 0x2F6AAE, dark: 0x7AAEE8)
}

/// Resolve semantic status foregrounds against the active theme surfaces.
struct ReadableStatusForeground: ViewModifier {
    enum Status { case warning, danger, success }
    let status: Status
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .warning: theme?.statusWarningText ?? .orange
        case .danger: theme?.statusDangerText ?? .red
        case .success: theme.map { $0.readableStatusText($0.tokens.statusSuccess).swiftUIColor } ?? .green
        }
    }
}
