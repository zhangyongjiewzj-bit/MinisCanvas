import Foundation
import SwiftUI

/// Intrinsic control sizes are measured at the live typography size. The
/// shared row policy wraps controls instead of clipping them or shrinking text.
struct AdaptiveControlRowPlan: Equatable, Sendable {
    let frames: [CGRect]
    let size: CGSize
}

/// Shared by narrow panels and independent sheets. It receives the actual
/// allocated width, including widths below the main window's 600pt minimum.
struct AdaptiveControlRowLayout: Layout {
    var spacing: CGFloat = 8

    private func plan(width: CGFloat?, subviews: Subviews) -> AdaptiveControlRowPlan {
        let intrinsic = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? max(1, intrinsic.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, intrinsic.count - 1)))
        let measured = zip(subviews, intrinsic).map { subview, size in
            let bounded = min(max(0, size.width), available)
            let wrapped = subview.sizeThatFits(ProposedViewSize(width: bounded, height: nil))
            return CGSize(width: bounded, height: wrapped.height)
        }
        return allocationPlan(availableWidth: available, itemSizes: measured)
    }

    /// The production allocation boundary, also callable without a native host.
    func allocationPlan(availableWidth: CGFloat, itemSizes: [CGSize]) -> AdaptiveControlRowPlan {
        AdaptiveLayoutPolicy.controlRowPlan(
            availableWidth: availableWidth, itemSizes: itemSizes, spacing: spacing
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = plan(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

/// A7-A 主窗口统一宽度类。阈值来自批准开发包，不由具体页面自行猜测。
enum AdaptiveWidthClass: String, CaseIterable, Equatable, Sendable {
    case compact
    case medium
    case regular
    case wide
}

/// 面板在当前宽度类中的呈现方式。
enum AdaptivePanelPresentation: Equatable, Sendable {
    case overlay
    case persistent
    case persistentCollapsible
}

/// 主窗口在一个确定宽度下的完整布局裁决。
struct AdaptiveLayoutDecision: Equatable, Sendable {
    let widthClass: AdaptiveWidthClass
    let leftPanel: AdaptivePanelPresentation
    let rightPanel: AdaptivePanelPresentation
    let leftWidth: Double
    let rightWidth: Double
    let mainMinimumWidth: Double
    let showsSecondaryToolbarLabels: Bool
    /// Dynamic effective bounds for the current window/panel combination.
    /// These are layout facts, not persisted user preferences.
    let leftMaximumWidth: Double
    let rightMaximumWidth: Double

    init(
        widthClass: AdaptiveWidthClass,
        leftPanel: AdaptivePanelPresentation,
        rightPanel: AdaptivePanelPresentation,
        leftWidth: Double,
        rightWidth: Double,
        mainMinimumWidth: Double,
        showsSecondaryToolbarLabels: Bool,
        leftMaximumWidth: Double = .greatestFiniteMagnitude,
        rightMaximumWidth: Double = .greatestFiniteMagnitude
    ) {
        self.widthClass = widthClass
        self.leftPanel = leftPanel
        self.rightPanel = rightPanel
        self.leftWidth = leftWidth
        self.rightWidth = rightWidth
        self.mainMinimumWidth = mainMinimumWidth
        self.showsSecondaryToolbarLabels = showsSecondaryToolbarLabels
        self.leftMaximumWidth = leftMaximumWidth
        self.rightMaximumWidth = rightMaximumWidth
    }
}

/// 自适应布局的事件。用户显式折叠与窗口宽度触发的临时折叠必须分开记录，
/// 否则从 compact 回到 medium 时无法恢复策略要求的持久左栏。
enum AdaptiveLayoutEvent: Equatable, Sendable {
    case persistenceLoaded
    case widthClassChanged(AdaptiveWidthClass)
    case userSetSessionSidebarCollapsed(Bool)
    case userSetContextPanelCollapsed(Bool)
    case compactOverlayOpened(AdaptiveCompactOverlay)
}

enum AdaptiveCompactOverlay: Equatable, Sendable {
    case sessionSidebar
    case contextPanel
}

/// A7-A 的可执行状态；只有 `persistenceLoaded` 后宽度类事件才会施加自动折叠。
struct AdaptiveLayoutState: Equatable, Sendable {
    private(set) var widthClass: AdaptiveWidthClass?
    private(set) var persistenceLoaded: Bool
    private(set) var autoSessionSidebarCollapsed: Bool
    private(set) var autoContextPanelCollapsed: Bool
    private(set) var userSessionSidebarCollapsed: Bool
    private(set) var userContextPanelCollapsed: Bool

    init(
        widthClass: AdaptiveWidthClass? = nil,
        persistenceLoaded: Bool = false,
        autoSessionSidebarCollapsed: Bool = false,
        autoContextPanelCollapsed: Bool = false,
        userSessionSidebarCollapsed: Bool = false,
        userContextPanelCollapsed: Bool = false
    ) {
        self.widthClass = widthClass
        self.persistenceLoaded = persistenceLoaded
        self.autoSessionSidebarCollapsed = autoSessionSidebarCollapsed
        self.autoContextPanelCollapsed = autoContextPanelCollapsed
        self.userSessionSidebarCollapsed = userSessionSidebarCollapsed
        self.userContextPanelCollapsed = userContextPanelCollapsed
    }

    var sessionSidebarCollapsed: Bool {
        userSessionSidebarCollapsed || autoSessionSidebarCollapsed
    }

    var contextPanelVisible: Bool {
        !userContextPanelCollapsed && !autoContextPanelCollapsed
    }

    fileprivate mutating func markPersistenceLoaded() {
        persistenceLoaded = true
    }

    fileprivate mutating func setWidthClass(_ widthClass: AdaptiveWidthClass) {
        self.widthClass = widthClass
    }

    fileprivate mutating func setUserSessionSidebarCollapsed(_ collapsed: Bool) {
        userSessionSidebarCollapsed = collapsed
        autoSessionSidebarCollapsed = false
    }

    fileprivate mutating func setUserContextPanelCollapsed(_ collapsed: Bool) {
        userContextPanelCollapsed = collapsed
        autoContextPanelCollapsed = false
    }

    fileprivate mutating func setAutomaticPresentation(
        sessionSidebarCollapsed: Bool,
        contextPanelCollapsed: Bool
    ) {
        autoSessionSidebarCollapsed = sessionSidebarCollapsed
        autoContextPanelCollapsed = contextPanelCollapsed
    }
}

/// A7-A 唯一 transition reducer。纯值输入/输出，便于验证 resize、用户操作和初始化顺序。
enum AdaptiveLayoutReducer {
    static func reduce(
        _ state: AdaptiveLayoutState,
        _ event: AdaptiveLayoutEvent
    ) -> AdaptiveLayoutState {
        var next = state

        switch event {
        case .persistenceLoaded:
            next.markPersistenceLoaded()
            if let widthClass = next.widthClass {
                applyAutomaticPresentation(for: widthClass, to: &next)
            }
        case .widthClassChanged(let widthClass):
            let crossedWidthClass = next.widthClass != widthClass
            next.setWidthClass(widthClass)
            // 同一宽度类内的 GeometryReader 重算不是策略迁移；保留用户刚重新打开的 overlay。
            guard next.persistenceLoaded, crossedWidthClass else { return next }
            applyAutomaticPresentation(for: widthClass, to: &next)
        case .userSetSessionSidebarCollapsed(let collapsed):
            // 用户显式操作覆盖同一栏的自动折叠；不会被下一次同类重绘反向覆盖。
            next.setUserSessionSidebarCollapsed(collapsed)
        case .userSetContextPanelCollapsed(let collapsed):
            next.setUserContextPanelCollapsed(collapsed)
        case .compactOverlayOpened(let overlay):
            guard next.persistenceLoaded, next.widthClass == .compact else { return next }
            // Both panels are overlays at this width. Keep only the newly
            // requested one visible without changing either saved user choice.
            next.setAutomaticPresentation(
                sessionSidebarCollapsed: overlay == .contextPanel,
                contextPanelCollapsed: overlay == .sessionSidebar
            )
        }

        return next
    }

    private static func applyAutomaticPresentation(
        for widthClass: AdaptiveWidthClass,
        to state: inout AdaptiveLayoutState
    ) {
        switch widthClass {
        case .compact:
            state.setAutomaticPresentation(
                sessionSidebarCollapsed: true,
                contextPanelCollapsed: true
            )
        case .medium:
            // medium 恢复可调的持久左栏；右栏仍为 overlay，保持自动收起。
            state.setAutomaticPresentation(
                sessionSidebarCollapsed: false,
                contextPanelCollapsed: true
            )
        case .regular, .wide:
            state.setAutomaticPresentation(
                sessionSidebarCollapsed: false,
                contextPanelCollapsed: false
            )
        }
    }
}

/// A7-A 的唯一自适应策略源。
///
/// 右栏总是在左栏之前转为 overlay；用户保存的栏宽只在批准范围内生效，
/// 不通过缩小文字或挤压主操作来适配窄窗口。
enum AdaptiveLayoutPolicy {
    static let minimumSupportedWidth: Double = 600
    static let minimumPanelWidth: Double = 56
    static let persistentLeftMinimumWidth: Double = 220
    static let persistentRightMinimumWidth: Double = 248
    static let dividerWidth: Double = 1

    /// No parallel width-class thresholds: the budget is the pane's effective
    /// allocation from the global layout, and text retains its intrinsic size.
    static func controlRowPlan(
        availableWidth: CGFloat, itemSizes: [CGSize], spacing: CGFloat
    ) -> AdaptiveControlRowPlan {
        let width = availableWidth.isFinite && availableWidth > 0
            ? availableWidth : CGFloat(minimumSupportedWidth)
        let gap = spacing.isFinite ? max(0, spacing) : 0
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in itemSizes {
            let itemWidth = size.width.isFinite ? min(width, max(0, size.width)) : width
            let itemHeight = size.height.isFinite ? max(0, size.height) : 0
            if x > 0 && x + itemWidth > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: itemHeight))
            x += itemWidth + gap
            rowHeight = max(rowHeight, itemHeight)
        }
        return AdaptiveControlRowPlan(
            frames: frames,
            size: CGSize(width: width, height: frames.isEmpty ? 0 : y + rowHeight)
        )
    }

    static func widthClass(for width: Double) -> AdaptiveWidthClass {
        switch width {
        case ..<800:
            return .compact
        case ..<1_100:
            return .medium
        case ..<1_400:
            return .regular
        default:
            return .wide
        }
    }

    static func decision(
        for width: Double,
        preferredLeftWidth: Double,
        preferredRightWidth: Double
    ) -> AdaptiveLayoutDecision {
        let widthClass = widthClass(for: width)
        let boundedWidth = max(width, minimumSupportedWidth)

        func overlayWidth(
            _ preferred: Double,
            minimum: Double
        ) -> (width: Double, maximum: Double) {
            // Overlay panels do not reserve the main pane's width; their
            // effective maximum follows the current window rather than a
            // persisted hard cap.
            let maximum = max(minimum, boundedWidth - dividerWidth)
            return (
                preferred.clamped(to: minimum...maximum),
                maximum
            )
        }

        func persistentWidths(
            mainMinimum: Double,
            preferredLeft: Double,
            preferredRight: Double
        ) -> (left: Double, right: Double, leftMaximum: Double, rightMaximum: Double) {
            let available = max(
                persistentLeftMinimumWidth + persistentRightMinimumWidth,
                boundedWidth - mainMinimum - dividerWidth * 2
            )
            let leftMaximum = max(persistentLeftMinimumWidth, available - persistentRightMinimumWidth)
            let rightMaximum = max(persistentRightMinimumWidth, available - persistentLeftMinimumWidth)
            var left = preferredLeft.clamped(to: persistentLeftMinimumWidth...leftMaximum)
            var right = preferredRight.clamped(to: persistentRightMinimumWidth...rightMaximum)
            let overflow = left + right - available
            if overflow > 0 {
                let leftShrinkable = left - persistentLeftMinimumWidth
                let rightShrinkable = right - persistentRightMinimumWidth
                let totalShrinkable = leftShrinkable + rightShrinkable
                if totalShrinkable > 0 {
                    let leftReduction = min(
                        leftShrinkable,
                        overflow * leftShrinkable / totalShrinkable
                    )
                    let rightReduction = min(
                        rightShrinkable,
                        overflow - leftReduction
                    )
                    left -= leftReduction
                    right -= rightReduction
                    let remaining = overflow - leftReduction - rightReduction
                    if remaining > 0 {
                        left -= min(remaining, left - persistentLeftMinimumWidth)
                    }
                }
            }
            return (left, right, leftMaximum, rightMaximum)
        }

        switch widthClass {
        case .compact:
            let left = overlayWidth(
                preferredLeftWidth,
                minimum: persistentLeftMinimumWidth
            )
            let right = overlayWidth(
                preferredRightWidth,
                minimum: persistentRightMinimumWidth
            )
            return AdaptiveLayoutDecision(
                widthClass: widthClass,
                leftPanel: .overlay,
                rightPanel: .overlay,
                leftWidth: left.width,
                rightWidth: right.width,
                mainMinimumWidth: minimumSupportedWidth,
                showsSecondaryToolbarLabels: false,
                leftMaximumWidth: left.maximum,
                rightMaximumWidth: right.maximum
            )
        case .medium:
            let right = overlayWidth(
                preferredRightWidth,
                minimum: persistentRightMinimumWidth
            )
            let leftMaximum = max(
                persistentLeftMinimumWidth,
                boundedWidth - 520 - dividerWidth
            )
            return AdaptiveLayoutDecision(
                widthClass: widthClass,
                leftPanel: .persistent,
                rightPanel: .overlay,
                leftWidth: preferredLeftWidth.clamped(to: persistentLeftMinimumWidth...leftMaximum),
                rightWidth: right.width,
                mainMinimumWidth: 520,
                showsSecondaryToolbarLabels: false,
                leftMaximumWidth: leftMaximum,
                rightMaximumWidth: right.maximum
            )
        case .regular:
            let panels = persistentWidths(
                mainMinimum: 560,
                preferredLeft: preferredLeftWidth,
                preferredRight: preferredRightWidth
            )
            return AdaptiveLayoutDecision(
                widthClass: widthClass,
                leftPanel: .persistent,
                rightPanel: .persistentCollapsible,
                leftWidth: panels.left,
                rightWidth: panels.right,
                mainMinimumWidth: 560,
                showsSecondaryToolbarLabels: true,
                leftMaximumWidth: panels.leftMaximum,
                rightMaximumWidth: panels.rightMaximum
            )
        case .wide:
            let panels = persistentWidths(
                mainMinimum: 680,
                preferredLeft: preferredLeftWidth,
                preferredRight: preferredRightWidth
            )
            return AdaptiveLayoutDecision(
                widthClass: widthClass,
                leftPanel: .persistent,
                rightPanel: .persistentCollapsible,
                leftWidth: panels.left,
                rightWidth: panels.right,
                mainMinimumWidth: 680,
                showsSecondaryToolbarLabels: true,
                leftMaximumWidth: panels.leftMaximum,
                rightMaximumWidth: panels.rightMaximum
            )
        }
    }
}
