import SwiftUI
import Observation
import MinisCore

/// Layout constants shared by the two production Composer consumers.
///
/// Typography settings control text scale, while these metrics keep the
/// controls, hit targets, and narrow-window wrapping consistent between the
/// companion pane and the global composer.
enum ComposerLayoutMetrics {
    static let stackSpacing: CGFloat = 8
    static let controlSpacing: CGFloat = 8
    static let outerPadding: CGFloat = 8
    static let iconButtonHitSize: CGFloat = 24
    static let cornerRadius: CGFloat = 8
}

/// UX-01 排版 token provider。
///
/// provider 只解释 SettingsCenter 的基准字号，不改动聊天、画布或 Provider
/// 的事实源。各组件可以逐步消费 token；图标、工具栏和危险操作不在此放大。
@MainActor
@Observable
final class TypographyTokenProvider {
    let center: SettingsCenter

    init(center: SettingsCenter) {
        self.center = center
    }

    /// Resolve the live persisted preference through MinisCore's single
    /// semantic mapping. Keeping this computed makes setting changes visible
    /// to every consumer without allowing a stale snapshot.
    private var tokenSet: TypographyTokenSet {
        .forBaseFontSize(center.uiBaseFontSize)
    }

    /// 当前基准字号（pt）。
    var baseFontSize: CGFloat {
        CGFloat(tokenSet.baseFontSize)
    }

    /// Mechanism-level content scale relative to the default typography base.
    ///
    /// Layout code that reserves space for text (row columns, capsules,
    /// minimum widths) should multiply its 14pt-era constants by this value
    /// instead of hard-coding per-surface font assumptions, so a larger
    /// user size widens the space that text needs. This is the single scale
    /// fact injected into the environment; surfaces consume it rather than
    /// re-deriving `baseFontSize / 14` locally.
    var contentScale: Double {
        Double(tokenSet.baseFontSize) / Double(TypographySettings.defaultBaseFontSize)
    }

    /// 标题略高于正文，保留清晰层级。
    var sidebarTitleSize: CGFloat {
        baseFontSize + 1
    }

    /// Shared semantic sizes. All production surfaces derive these from the
    /// single SettingsCenter fact so a size change invalidates every consumer.
    var bodySize: CGFloat { CGFloat(tokenSet.body) }
    var headlineSize: CGFloat { CGFloat(tokenSet.headline) }
    var captionSize: CGFloat { CGFloat(tokenSet.caption) }
    var caption2Size: CGFloat { CGFloat(tokenSet.caption2) }
    var monospacedSize: CGFloat { CGFloat(tokenSet.monospaced) }
    var metricSize: CGFloat { CGFloat(tokenSet.metric) }

    /// 会话列表正文与聊天正文保持同一基准字号。
    var sidebarItemSize: CGFloat {
        CGFloat(tokenSet.sidebarItem)
    }

    /// 辅助信息比正文低 2pt，并保留独立层级。
    var sidebarMetaSize: CGFloat {
        CGFloat(tokenSet.sidebarMeta)
    }

    /// 状态文字与辅助信息同级。
    var statusSize: CGFloat {
        CGFloat(tokenSet.status)
    }

    var transcriptBodySize: CGFloat {
        CGFloat(tokenSet.transcriptBody)
    }

    /// 正文基准字号叠加系统 Dynamic Type 比例。
    ///
    /// 设置页控制基准字号，辅助功能环境仍可在其上放大；默认 medium
    /// 保持 1.0，避免用户字号设置与系统可读性设置互相覆盖。
    func transcriptBodySize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        baseFontSize * Self.dynamicTypeScale(for: dynamicTypeSize)
    }

    static func dynamicTypeScale(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        switch dynamicTypeSize {
        case .xSmall: 11 / 13
        case .small: 12 / 13
        case .medium: 1
        case .large: 14 / 13
        case .xLarge: 16 / 13
        case .xxLarge: 18 / 13
        case .xxxLarge: 20 / 13
        case .accessibility1: 22 / 13
        case .accessibility2: 24 / 13
        case .accessibility3: 26 / 13
        case .accessibility4: 28 / 13
        case .accessibility5: 30 / 13
        @unknown default: 1
        }
    }

    var composerBodySize: CGFloat {
        CGFloat(tokenSet.composerBody)
    }

    /// Toolbar labels and destructive actions remain fixed-size chrome.
    var toolbarSize: CGFloat {
        CGFloat(tokenSet.toolbar)
    }

    var dangerousActionSize: CGFloat {
        CGFloat(tokenSet.dangerousAction)
    }

    /// Top bar and context-panel labels share the compact semantic role.
    var topBar: Font {
        .system(size: toolbarSize)
    }

    var contextBody: Font {
        caption
    }

    /// Composer controls stay readable while icon hit targets remain fixed.
    var composerControl: Font {
        caption
    }

    var dangerousAction: Font {
        .system(size: dangerousActionSize)
    }

    // SwiftUI 便捷 token；系统辅助功能放大仍由 SwiftUI 环境负责。
    var body: Font {
        .system(size: bodySize)
    }

    var headline: Font {
        .system(size: headlineSize, weight: .semibold)
    }

    var caption: Font {
        .system(size: captionSize)
    }

    var caption2: Font {
        .system(size: caption2Size)
    }

    var monospaced: Font {
        .system(size: monospacedSize, design: .monospaced)
    }

    var metric: Font {
        .system(size: metricSize, weight: .semibold, design: .rounded)
    }

    var sidebarTitle: Font {
        .system(size: sidebarTitleSize, weight: .semibold)
    }

    var sidebarItem: Font {
        .system(size: sidebarItemSize)
    }

    var sidebarMeta: Font {
        .system(size: sidebarMetaSize)
    }

    var transcriptBody: Font {
        .system(size: transcriptBodySize)
    }

    var composerBody: Font {
        .system(size: composerBodySize)
    }

    var status: Font {
        .system(size: statusSize)
    }

    /// Single role→Font entry for surfaces that store a semantic role instead
    /// of picking a convenience property. Keeping the switch here means new
    /// roles are added once in the mechanism and every consumer that passes
    /// the role gets the updated mapping without touching view files.
    func font(for role: TypographyTokenRole) -> Font {
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
        case .toolbar: .system(size: toolbarSize)
        case .dangerousAction: dangerousAction
        }
    }
}

private struct TypographyTokenProviderKey: EnvironmentKey {
    static let defaultValue: TypographyTokenProvider? = nil
}

private struct TypographyContentScaleKey: EnvironmentKey {
    /// 1.0 keeps layout constants at their default-base sizing when no
    /// provider has been injected yet (launch, detached test hosts).
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// 当前系统字号 token 提供者（由 App 根视图注入）。
    var typographyTokens: TypographyTokenProvider? {
        get { self[TypographyTokenProviderKey.self] }
        set { self[TypographyTokenProviderKey.self] = newValue }
    }

    /// Mechanism-level user font scale (base size ÷ default base size),
    /// injected next to `typographyTokens` at every presentation root.
    /// Layout-sensitive consumers multiply reserved widths/heights by this
    /// value so larger settings widen space as well as glyphs.
    var typographyContentScale: Double {
        get { self[TypographyContentScaleKey.self] }
        set { self[TypographyContentScaleKey.self] = newValue }
    }
}
