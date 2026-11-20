import SwiftUI
import AppKit
import Observation
import MinisCore

// MARK: - 半透明浮动右键菜单（替代系统原生 contextMenu）
//
// 背景：SwiftUI 原生 .contextMenu 在 macOS 渲染为系统 NSMenu，无 API 调节背景透明度。
// 用户诉求：右键菜单背景透明度 50%、文字不透明（当前系统菜单观感「突兀、厚重」）。
// 方案：自定义浮动菜单面板（深色 50% 透明背景 + 不透明文字 + 圆角阴影），
// 通过 NSView 桥接捕获 rightMouseDown，在窗口坐标处弹出；点击外部 / Esc 关闭。

/// 菜单项模型（button / divider / submenu-手风琴展开）
struct FloatingMenuItem: Identifiable {
    enum Kind {
        case button(title: String, icon: String?, role: ButtonRole?, help: String?, action: () -> Void)
        case divider
        case submenu(title: String, icon: String?, items: [FloatingMenuItem])
    }
    let id = UUID()
    let kind: Kind
    /// Only callers with an approved semantic ID opt into the existing catalog.
    /// A legacy SF name is never inferred to be a catalog ID.
    let catalogIcon: MinisIcon?
    /// 置灰且不可点击（原因由调用方在标题或 help 中给出）。
    let isDisabled: Bool

    init(kind: Kind, catalogIcon: MinisIcon? = nil, isDisabled: Bool = false) {
        self.kind = kind
        self.catalogIcon = catalogIcon
        self.isDisabled = isDisabled
    }
}

/// 全局浮动菜单宿主：持有当前菜单内容 + 弹出位置（窗口坐标）
@MainActor
@Observable
final class FloatingMenuHost {
    static let shared = FloatingMenuHost()
    private init() {}

    var isPresented = false
    var items: [FloatingMenuItem] = []
    /// 弹出锚点（窗口坐标）
    var windowPoint: CGPoint = .zero

    func present(_ items: [FloatingMenuItem], at windowPoint: CGPoint) {
        self.items = items
        self.windowPoint = windowPoint
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        items = []
    }

    // MARK: - 全局右键 Monitor（修复「右键菜单打不开」）
    //
    // 背景（探针实证）：SwiftUI NSHostingView 在自身事件分发路径下不会调用
    // background/overlay 层 NSViewRepresentable 的 AppKit hitTest —— CatcherView.hitTest
    // 永远轮不到，右键事件直接穿透，菜单永不弹出（编译/测试覆盖不到，上线即炸）。
    // 修复：App 启动时安装全局 local monitor，在事件处理期间（NSApp.currentEvent ==
    // rightMouseDown）手动 contentView.hitTest 驱动 CatcherView 命中，命中即触发 onRightClick
    // 并吞掉事件（返回 nil），避免系统上下文菜单等其他右键行为。
    private static var rightClickMonitor: Any?

    /// App 启动时调用一次（MinisCanvasAppMain.init）。
    static func installRightClickMonitor() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            let point = event.locationInWindow
            // AJ-62 修复：不再用 contentView.hitTest 驱动命中。SwiftUI 的 background/overlay
            // 容器不透传 AppKit hitTest（见 RightClickCatcher 注释——事件分发路径下 background
            // 层 representable 的 hitTest 不会被调用；手动 hitTest 与事件分发走同一容器 hitTest
            // 逻辑，同样到不了 CatcherView，22:05 包实证全界面右键失效）。改为递归遍历
            // contentView 视图树，按类型找 CatcherView 实例 + frame 包含判定——CatcherView 由
            // SwiftUI 布局挂载，必然在 subviews 树中（否则不渲染），不依赖任何 SwiftUI 命中透传。
            if let catcher = findBestCatcher(containing: point, in: content) {
                catcher.fire(event)
                return nil // 吞掉：菜单已弹出
            }
            return event
        }
    }

    /// 递归遍历视图树，找 frame 包含右键点的最具体 CatcherView（多挂点重叠时取 frame 面积
    /// 最小者：如节点卡片 ⊂ 画布空白，右键节点应弹节点菜单而非空白菜单）。
    /// 坐标转换沿共同祖先链（contentView → catcher），不依赖 window 链：窗口坐标先经
    /// contentView.convert(_:from: nil) 转内容区坐标（contentView 必有 window，转换可靠），
    /// 再逐 catcher convert(from: content) 转本地坐标。
    static func findBestCatcher(
        containing windowPoint: NSPoint, in root: NSView
    ) -> RightClickCatcher.CatcherView? {
        let rootPoint = root.convert(windowPoint, from: nil)
        var best: RightClickCatcher.CatcherView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0,
                  view.visibleRect.contains(view.convert(rootPoint, from: root)) else { return }
            if let catcher = view as? RightClickCatcher.CatcherView {
                let local = catcher.convert(rootPoint, from: root)
                if catcher.bounds.contains(local) {
                    let area = catcher.bounds.width * catcher.bounds.height
                    if area < bestArea {
                        bestArea = area
                        best = catcher
                    }
                }
            }
            for sub in view.subviews.reversed() {
                visit(sub)
            }
        }
        visit(root)
        return best
    }
}

/// 右键捕获桥：NSView 只拦截 rightMouseDown，其余鼠标事件透传给下层 SwiftUI 手势。
/// hitTest 仅在当前事件为右键时命中自己，避免挡住左键拖拽/点击。
/// ⚠️ 已知限制（探针实证 + AJ-62 回归复核）：SwiftUI NSHostingView 自身事件分发路径下，
/// background/overlay 层 NSViewRepresentable 的 AppKit hitTest 不会被调用 → 必须由全局右键
/// Monitor（FloatingMenuHost.installRightClickMonitor，见上）驱动命中。
/// AJ-62 修复：monitor 不再用 contentView.hitTest（SwiftUI 容器不透传 background 层，
/// 22:05 包实证全界面右键失效），改为递归遍历视图树按类型找 CatcherView 实例 + frame
/// 包含判定——本视图由 SwiftUI 布局挂载，必然在视图树中。hitTest/rightMouseDown 保留为
/// 备胎路径（若未来挂点改前景挂载，AppKit 事件可直接到达）。
struct RightClickCatcher: NSViewRepresentable {
    /// 参数1：窗口坐标（FloatingMenuOverlay 定位用）；参数2：本视图本地坐标（画布 world 转换用）
    let onRightClick: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint, CGPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            fire(event)
        }

        /// Monitor 与 AppKit 事件路径共用：窗口坐标（内容区原点）+ 本视图本地坐标
        fileprivate func fire(_ event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onRightClick?(event.locationInWindow, local)
        }
    }
}

// MARK: - 菜单面板

/// 菜单实际高度上报（子菜单展开后变化，clamp 用）
private struct MenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 顶层浮动菜单层：挂 ContentView 根 overlay；点击外部 / Esc 关闭
struct FloatingMenuOverlay: View {
    @State private var host = FloatingMenuHost.shared
    /// 面板实际高度（GeometryReader 实测，含展开子菜单）
    @State private var menuHeight: CGFloat = 0

    /// 菜单左上角锚点（SwiftUI 左上原点坐标）。窗口坐标先翻转为 SwiftUI 原点；
    /// 四边防溢出：x 右缘留 8pt、左缘 8pt；y 底部留 8pt、顶部 8pt——
    /// 空间不足时菜单整体收入窗口内（G10 P2-2 修复，实测高度 clamp）。
    /// 纯函数，可单测。
    nonisolated static func anchorOffset(windowPoint: CGPoint, size: CGSize, menuSize: CGSize) -> CGSize {
        let menuW = menuSize.width > 0 ? menuSize.width : 232
        let menuH = menuSize.height > 0 ? menuSize.height : 0
        let x = min(windowPoint.x + 8, max(8, size.width - menuW - 8))
        let y = min(size.height - windowPoint.y + 8, max(8, size.height - menuH - 8))
        return CGSize(width: x, height: y)
    }

    /// 按菜单项估出的面板高度（子菜单按收起算）：行高 13pt 字 + 上下各 5pt、
    /// 分隔线 1pt + 上下各 2pt、行间距 2pt、面板内边距上下各 5pt。
    /// 11/19 包上实测：会话右键菜单（15 行）在窗口下半部弹出时整块伸出窗口底部，
    /// 运行时量到的高度没有进 clamp；clamp 取「实测、估算」中较大者，量不到也不会伸出窗口。
    nonisolated static func estimatedPanelHeight(_ items: [FloatingMenuItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let rowHeight: CGFloat = 26
        let dividerHeight: CGFloat = 5
        let content = items.reduce(CGFloat(0)) { total, item in
            if case .divider = item.kind { return total + dividerHeight }
            return total + rowHeight
        }
        return content + CGFloat(items.count - 1) * 2 + 10
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // 透明拦截层：点击外部关闭（仅菜单显示时存在）
                if host.isPresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { host.dismiss() }
                }
                if host.isPresented {
                    FloatingMenuPanel(items: host.items) {
                        host.dismiss()
                    }
                    .frame(width: 232)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: MenuHeightKey.self, value: g.size.height)
                        }
                    )
                    .onPreferenceChange(MenuHeightKey.self) { menuHeight = $0 }
                    .offset(Self.anchorOffset(windowPoint: host.windowPoint,
                                              size: size,
                                              menuSize: CGSize(width: 232, height: max(
                                                  menuHeight, Self.estimatedPanelHeight(host.items)))))
                    .onExitCommand { host.dismiss() }
                    .escapeShortcut(closePopover: host.escapeDismissalAction())
                }
            }
        }
        .allowsHitTesting(host.isPresented)
    }
}

/// 菜单面板：50% 透明背景 + 不透明文字 + 圆角阴影
struct FloatingMenuPanel: View {
    let items: [FloatingMenuItem]
    var onPick: () -> Void

    @Environment(\.themeTokens) private var theme
    @State private var expandedSubmenuID: UUID?

    /// 面板背景：THEME-03 对比度合同裁决（`MinisCore.ThemeContrast`）。
    ///
    /// 此前这里是一段 ad-hoc 的「双外观对比度修正」（波3-4线）：视图自己认定亮色下
    /// 与画布同源的米白 backgroundPrimary（#FAF9F6 @50% 叠在同样 #FAF9F6 的画布底上
    /// ≈ 同色 → 面板隐形），并把「换系统窗口底 + 0.9 不透明度」写成字面量。
    /// 现在规则归生产合同持有：视图只提供判定输入（当前外观、候选面板底、它叠在上面的
    /// 画布底），是否换底、用多大不透明度一律读 `panelSurfaceDecision` 的返回值——
    /// 返回值还带实测分离度，可断言。浅色 token 日后若与画布底真正分离达标
    /// （≥ `ThemeContrast.panelFaceMinimumSeparation`），同一条调用会自动回到主题面。
    ///
    /// A7-A：两种外观下的最终像素与改前逐字相同（亮 = 系统窗口底 @0.9，
    /// 暗 = 主题米白/深底 @0.5）。改的是规则归属，不是外观。
    private var panelBackground: Color {
        guard let theme else {
            // 未注入 provider（预览/测试）：没有 token 可判定，保持系统底原样。
            return Color(nsColor: .windowBackgroundColor).opacity(0.5)
        }
        let surface = Self.surfaceDecision(theme: theme)
        switch surface.face {
        case .themedPalette:
            return theme.aj38.backgroundPrimary.swiftUIColor.opacity(surface.opacity)
        case .systemWindowBackground:
            return Color(nsColor: .windowBackgroundColor).opacity(surface.opacity)
        }
    }

    /// Same face/opacity decision consumed by the rendered panel and risk copy.
    static func surfaceDecision(theme: ThemeTokenProvider) -> ThemePanelSurfaceDecision {
        ThemeContrast.panelSurfaceDecision(
            mode: theme.mode, themedFace: theme.aj38.backgroundPrimary,
            canvasBackdrop: theme.aj38.backgroundPrimary)
    }

    /// Composite the existing panel and hover fills over the existing host
    /// surfaces. This projects the rendering inputs; it is not another policy.
    static func textBackgrounds(theme: ThemeTokenProvider) -> [ThemeColor] {
        let decision = surfaceDecision(theme: theme)
        let overlay = theme.aj38
        let nativeWindow = ThemeTokenProvider.nativeSystemTokens(for: theme.mode).background
        let face = decision.face == .themedPalette ? overlay.backgroundPrimary : nativeWindow
        let tokens = theme.tokens
        let backdrops = [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised,
                         overlay.backgroundPrimary, overlay.backgroundSecondary, nativeWindow]
        let panels = backdrops.map { background in
            ThemeColor(r: face.r * decision.opacity + background.r * (1 - decision.opacity),
                       g: face.g * decision.opacity + background.g * (1 - decision.opacity),
                       b: face.b * decision.opacity + background.b * (1 - decision.opacity))
        }
        let hover = panels.map { panel in
            ThemeColor(r: overlay.accent.r * 0.22 + panel.r * 0.78,
                       g: overlay.accent.g * 0.22 + panel.g * 0.78,
                       b: overlay.accent.b * 0.22 + panel.b * 0.78)
        }
        return panels + hover
    }

    private var panelBorder: Color {
        (theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)).opacity(0.5)
    }

    /// 行文字：像素仍是 token 自己（改前 `?? labelColor` 的回退语义保持不变），
    /// 但 `body`（正文）角色门槛现在由 THEME-03 生产合同实跑一次。
    /// `assertCompliant` 只在 Debug 下失败，Release 编译掉，不引入线上崩溃面。
    private var rowText: Color {
        guard let theme else { return Color(nsColor: .labelColor) }
        ThemeContrast.assertCompliant(
            ThemeContrast.evaluate(
                role: .body,
                foreground: theme.aj38.textPrimary,
                background: theme.aj38.backgroundPrimary
            ),
            "浮动菜单正文 vs 面板底"
        )
        return theme.aj38.textPrimary.swiftUIColor
    }

    private var rowHover: Color {
        (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.22)
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(panelBackground)
                .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(panelBorder, lineWidth: 0.5)
        )
        .font(.system(size: 13))
    }

    /// The same item-to-row consumer used by the rendered button branch.
    func buttonRow(for item: FloatingMenuItem) -> FloatingMenuRow? {
        guard case .button(let title, let icon, let role, let help, let action) = item.kind else {
            return nil
        }
        return FloatingMenuRow(title: title, icon: icon, role: role, help: help,
                               hoverColor: rowHover, textColor: rowText,
                               catalogIcon: item.catalogIcon, isDisabled: item.isDisabled) {
            action()
            onPick()
        }
    }

    @ViewBuilder
    private func row(for item: FloatingMenuItem) -> some View {
        switch item.kind {
        case .button:
            buttonRow(for: item)
        case .divider:
            Divider()
                .overlay(panelBorder)
                .padding(.vertical, 2)
        case .submenu(let title, let icon, let subItems):
            VStack(spacing: 2) {
                FloatingMenuRow(title: title, icon: icon, role: nil, help: nil,
                                hoverColor: rowHover, textColor: rowText,
                                catalogIcon: item.catalogIcon,
                                trailing: AnyView(MinisIconView(
                                    expandedSubmenuID == item.id ? .caretDown : .caretRight, size: 12
                                )
                                    .foregroundPalette(rowText.opacity(0.6))
                                    .font(.system(size: 10))
                                    .accessibilityHidden(true))) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        if expandedSubmenuID == item.id {
                            expandedSubmenuID = nil
                        } else {
                            expandedSubmenuID = item.id
                        }
                    }
                }
                if expandedSubmenuID == item.id {
                    VStack(spacing: 2) {
                        ForEach(subItems) { sub in
                            AnyView(row(for: sub))
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }
}

/// 单行菜单项：hover 高亮 + 不透明文字
struct FloatingMenuRow: View {
    let title: String
    let icon: String?
    let catalogIcon: MinisIcon?
    let role: ButtonRole?
    let help: String?
    let hoverColor: Color
    let textColor: Color
    var trailing: AnyView?
    var isDisabled: Bool
    var action: () -> Void

    @Environment(\.themeTokens) private var theme
    @State private var hovering = false

    init(title: String, icon: String?, role: ButtonRole?, help: String?,
         hoverColor: Color, textColor: Color,
         catalogIcon: MinisIcon? = nil, trailing: AnyView? = nil, isDisabled: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.catalogIcon = catalogIcon
        self.role = role
        self.help = help
        self.hoverColor = hoverColor
        self.textColor = textColor
        self.trailing = trailing
        self.isDisabled = isDisabled
        self.action = action
    }

    enum IconPresentation: Equatable {
        case catalog(MinisIcon)
        case system(String)
        case none
    }

    /// Consumed directly by body; no SF-to-catalog translation or second registry.
    var iconPresentation: IconPresentation {
        if let catalogIcon { return .catalog(catalogIcon) }
        if let icon { return .system(icon) }
        return .none
    }

    var catalogIconState: MinisIconState { role == .destructive ? .danger : .normal }

    static func destructiveTextToken(theme: ThemeTokenProvider) -> ThemeColor {
        let tokens = theme.tokens
        return tokens.readableStatusText(
            tokens.statusDanger, additionalBackgrounds: FloatingMenuPanel.textBackgrounds(theme: theme))
    }

    static func titleColor(role: ButtonRole?, textColor: Color, theme: ThemeTokenProvider?) -> Color {
        guard role == .destructive else { return textColor }
        guard let theme else { return .red }
        return destructiveTextToken(theme: theme).swiftUIColor
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                switch iconPresentation {
                case .catalog(let icon):
                    MinisIconView(icon, state: catalogIconState, size: 12)
                        .frame(width: 16)
                case .system(let icon):
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 16)
                        .foregroundStyle(role == .destructive ? (theme?.statusDanger ?? AppStatusColor.danger).opacity(0.9) : textColor.opacity(0.75))
                case .none:
                    EmptyView()
                }
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(Self.titleColor(role: role, textColor: textColor, theme: theme))
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? hoverColor : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}
