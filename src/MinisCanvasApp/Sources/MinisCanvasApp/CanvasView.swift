import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import CanvasCore
import os

// MARK: - AJ-66 非有限值诊断（NaN/Infinity 防线共用的低成本日志）
//
// 仅在检测到 NaN/Infinity 时输出（正常路径零开销：只是一次 isFinite 比较）。
// 统一走 os.Logger（异步、非阻塞、不进测试 stdout），第一滴 NaN 的来源在运行期
// 未知——这里在每一个防线写点输出「函数名 + 当前 zoom/pan + 输入值」作抓手。
enum AJ66Diagnostics {
    private static let logger = Logger(subsystem: "com.miniscanvas.viewport", category: "AJ66")

    /// 输出非有限值诊断。zoom/pan 为检测时视口状态；input 为触发污染的输入值描述。
    static func logNonFinite(source: String, zoom: Double, pan: CGPoint, input: String) {
        logger.fault("AJ-66 非有限值 @ \(source, privacy: .public): zoom=\(zoom, privacy: .public) pan=(\(pan.x, privacy: .public), \(pan.y, privacy: .public)) input=\(input, privacy: .public)")
    }
}

// MARK: - 无限画布（N2：世界坐标 + 视口平移 + 渲染层缩放）

/// 视口变换（纯值类型，可单测）：世界坐标 ↔ 屏幕坐标。
/// `screen = world × zoom + pan`；节点 position / 端口锚点 / 连线控制点全部使用
/// 世界坐标（不随 zoom 变），`scaleEffect` 只作用渲染层——缩放后拖拽、连线几何不再换算错位。
struct ViewportTransform: Equatable {
    var zoom: Double
    var pan: CGPoint

    static let minZoom = 0.2
    // 放大上限 8x（原 3.0：大画布缩放无感——用户「缩放没有感知」反馈；
    // 8x 与 NodeMediaPreviewView 图片预览上限一致；scaleEffect 只作用渲染层不参与布局）
    static let maxZoom = 8.0

    init(zoom: Double = 1.0, pan: CGPoint = .zero) {
        self.zoom = zoom
        self.pan = pan
    }

    /// 世界坐标 → 屏幕坐标：screen = world × zoom + pan
    /// AJ-66 防线：结果非有限（zoom/pan/world 任一被污染）→ 退化 .zero + 诊断日志，
    /// 避免 NaN 经 min/max 传播进浮层定位（搜索面板 / reveal 脉冲环 / minimap）。
    func screen(_ world: Point) -> CGPoint {
        let result = CGPoint(x: world.x * zoom + pan.x, y: world.y * zoom + pan.y)
        guard result.x.isFinite, result.y.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "ViewportTransform.screen", zoom: zoom, pan: pan,
                                         input: "world=(\(world.x),\(world.y))")
            return .zero
        }
        return result
    }

    /// 屏幕坐标 → 世界坐标：world = (screen - pan) / zoom
    /// AJ-66 防线：结果非有限（含 zoom=0 除零 / 输入污染）→ 退化 .zero + 诊断日志，
    /// 所有写点（粘贴落点 / 双击搜索 / 右键建节点 / 框选）共用此防线，一次堵住。
    func world(_ screen: CGPoint) -> Point {
        let result = Point(x: (screen.x - pan.x) / zoom, y: (screen.y - pan.y) / zoom)
        guard result.x.isFinite, result.y.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "ViewportTransform.world", zoom: zoom, pan: pan,
                                         input: "screen=(\(screen.x),\(screen.y))")
            return .zero
        }
        return result
    }

    /// AJ-66 防线：非有限缩放请求直接拒绝（Swift min/max 遇 NaN 会传播，clampedZoom(NaN)
    /// 会产出 NaN 写进 viewport.zoom——污染后只能重启恢复）。拒绝 = 返回当前 zoom。
    func clampedZoom(_ z: Double) -> Double {
        guard z.isFinite else { return zoom }
        return min(max(z, Self.minZoom), Self.maxZoom)
    }

    /// 以屏幕坐标 anchor 为锚缩放：锚点下的世界点保持不动（光标 / 视口中心锚定），
    /// 缩放后平移重新夹到边界。
    /// AJ-66 防线：newZoom / anchor / 当前 zoom 任一非有限 → 拒绝（返回自身）+ 诊断日志。
    func zoomed(to newZoom: Double, anchor: CGPoint,
                canvasWidth: Double, canvasHeight: Double) -> ViewportTransform {
        guard newZoom.isFinite, anchor.x.isFinite, anchor.y.isFinite, zoom.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "ViewportTransform.zoomed", zoom: zoom, pan: pan,
                                         input: "newZoom=\(newZoom) anchor=(\(anchor.x),\(anchor.y))")
            return self
        }
        let clamped = clampedZoom(newZoom)
        guard zoom > 0.0001, abs(clamped - zoom) > 0.0001 else { return self }
        let logical = CGPoint(x: (anchor.x - pan.x) / zoom, y: (anchor.y - pan.y) / zoom)
        return ViewportTransform(
            zoom: clamped,
            pan: CGPoint(x: anchor.x - logical.x * clamped, y: anchor.y - logical.y * clamped)
        ).clampedPan(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    /// 平移 delta（屏幕坐标）→ 夹边界后的新视口
    func pannedBy(_ dx: Double, _ dy: Double,
                  canvasWidth: Double, canvasHeight: Double) -> ViewportTransform {
        clampedPan(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                   at: CGPoint(x: pan.x + dx, y: pan.y + dy))
    }

    /// 平移边界（松）：±60% 画布尺寸。画布 100000pt 时平移可达 ±60000pt，
    /// 远超旧 4000pt 固定画布限制——大画布内容不再够不着。
    func clampedPan(canvasWidth: Double, canvasHeight: Double, at target: CGPoint? = nil) -> ViewportTransform {
        let p = target ?? pan
        // AJ-66 防御：NaN/Infinity 落点直接拒绝（Swift 的 min/max 遇 NaN 会传播，
        // 一旦 pan 被污染，视口永久崩坏且只能重启恢复——用户报告「⌘V 后画布消失、
        // 重启才回来」与此吻合）。非有限输入 → 返回自身（视口保持不动）。
        guard p.x.isFinite, p.y.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "ViewportTransform.clampedPan", zoom: zoom, pan: pan,
                                         input: "target=(\(p.x),\(p.y))")
            return self
        }
        let limitX = canvasWidth * zoom * 0.6
        let limitY = canvasHeight * zoom * 0.6
        guard limitX.isFinite, limitY.isFinite, zoom.isFinite else {
            AJ66Diagnostics.logNonFinite(source: "ViewportTransform.clampedPan", zoom: zoom, pan: pan,
                                         input: "limits=(\(limitX),\(limitY))")
            return self
        }
        var next = self
        next.pan = CGPoint(x: min(max(p.x, -limitX), limitX),
                           y: min(max(p.y, -limitY), limitY))
        return next
    }
}

/// AJ-2：reveal 高亮动画请求——粘贴后渲染层围绕内容中心画一个扩散脉冲环，
/// 让用户一眼看到粘贴结果（不只平移视口，避免"粘贴后看不到节点"）。
/// center 为世界坐标内容中心；token 用于区分连续两次粘贴（换 token 重新触发动画）。
struct RevealFlash: Equatable {
    let center: Point
    let token: UUID
}

/// 画布主体：世界层（世界坐标渲染）+ 视口平移（pan）+ 渲染层缩放（scaleEffect）。
/// - 缩放：触控板捏合（视口中心锚定）+ Cmd+滚轮（光标锚定），范围 0.2x~3.0x
/// - 平移：拖拽空白 / 双指滚轮，边界松（±60% 画布尺寸）
/// - 节点 position 世界坐标不变，缩放只改渲染 scale → 拖拽/连线不再 /zoom 换算
struct CanvasView: View {
    let store: CanvasStore
    let mutationCoordinator: CanvasMutationCoordinator?

    @Environment(\.themeTokens) private var theme

    /// 逻辑画布尺寸（真无限 ≈ 足够大的世界层；旧实现固定 4000pt 整帧缩放）
    private let canvasWidth = 100_000.0
    private let canvasHeight = 100_000.0

    @State private var viewport = ViewportTransform()
    /// W3 viewport durable binding：是否已从 CanvasStore.viewportState 恢复过初始视口
    /// （只恢复一次，避免切画布/布局重算时反复覆盖用户的实时视口）
    @State private var didRestoreViewportFromStore = false
    /// 捏合缩放起点（onEnded 更新为当前 zoom，连续捏合不跳变）
    @State private var lastZoom: Double = 1.0
    /// 拖拽平移起点（屏幕坐标）
    @State private var dragPanStart: CGPoint?
    /// 节点拖拽起点（世界坐标）
    @State private var dragStart: Point?
    /// AJ-12 多选拖拽：拖动开始时快照各被拖节点的起始位置（相对位移 → 整组同步平移）
    @State private var dragStartPositions: [UUID: Point] = [:]
    /// AJ-21：框选建组矩形（世界坐标；Option 拖拽空白触发）
    @State private var marqueeStart: Point?
    @State private var marqueeCurrent: Point?
    /// 视口尺寸（锚定缩放 / fit 用）
    @State private var viewportSize: CGSize = .zero
    /// AJ-2：粘贴 reveal 时序兜底——视口尚未完成首次布局（viewportSize 仍为 .zero）
    /// 时收到的 reveal 请求先缓存于此，等布局完成（onAppear / onChange(geo.size)）再执行，
    /// 否则 targetPan 用 0 尺寸算出错误平移，节点被贴到视口外，用户感知"粘贴后看不到"。
    @State private var pendingReveal: RevealRequest?
    /// AJ-2：reveal 高亮动画状态——当前正在显示的扩散脉冲环 + 是否已触发向外扩散。
    @State private var revealFlash: RevealFlash?
    @State private var flashPulse = false
    /// F12-⑥ 最近一次鼠标悬停屏幕坐标（右键菜单创建节点落点；contextMenu 自身不传坐标）
    @State private var hoverScreenPoint: CGPoint = .zero
    /// AJ-16：minimap 开关（默认显示；⌘M 或右上角 ✕ 关闭，⌘M 重开）
    @State private var showMinimap = true

    init(
        store: CanvasStore,
        mutationCoordinator: CanvasMutationCoordinator? = nil
    ) {
        self.store = store
        self.mutationCoordinator = mutationCoordinator
    }

    // MARK: - AJ-2 粘贴 reveal 时序修复

    /// 纯函数（可单测）：解析 reveal 请求 → 目标视口。
    /// 若视口尚未完成首次布局（宽/高 ≤ 0，如首帧前或画布非当前可见 pane），返回 nil
    /// 表示「当前不可处理，应推迟」，避免用 0 尺寸算出错误 targetPan 把节点贴到视口外。
    static func resolveReveal(
        request: RevealRequest,
        viewportSize: CGSize,
        viewport: ViewportTransform,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> ViewportTransform? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        // AJ-66 防御：NaN/Infinity 揭示请求直接丢弃（同 clampedPan：污染视口后只能重启恢复）。
        // 粘贴 bbox 中心 / 世界坐标若有异常值，宁可不平移也不让视口崩坏。
        guard request.center.x.isFinite, request.center.y.isFinite,
              viewport.zoom.isFinite, viewport.pan.x.isFinite, viewport.pan.y.isFinite else { return nil }
        let targetPan = CGPoint(
            x: viewportSize.width / 2 - request.center.x * viewport.zoom,
            y: viewportSize.height / 2 - request.center.y * viewport.zoom)
        return viewport.clampedPan(
            canvasWidth: canvasWidth, canvasHeight: canvasHeight, at: targetPan)
    }

    /// AJ-2：⌘V 粘贴落点解析（纯函数，可单测）。鼠标在画布上（传 screen 坐标）→ 换算世界坐标；
    /// 鼠标不在画布上（screen 为 nil，catcher 已判出 bounds）→ 用视口中心世界坐标，
    /// 避免把节点贴到画布外。viewportSize 未布局（0）时视口中心退化为 pan 处世界点，
    /// 由后续 reveal 兜底居中。
    static func pasteTargetWorld(screen: CGPoint?, viewport: ViewportTransform, viewportSize: CGSize) -> Point {
        if let screen {
            return viewport.world(screen)
        }
        return viewport.world(CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
    }

    /// AJ-66：reveal 请求中心坐标有限才可处理（纯函数，可单测）。
    /// resolveReveal 的 nil 有两种含义——「视口未布局应推迟」与「请求/视口含 NaN 应丢弃」，
    /// handleReveal 用本函数在缓存前先区分：非有限请求直接丢弃，避免 NaN 请求被永远
    /// 缓存进 pendingReveal（每次布局变化都重试、永不清除）。
    static func revealRequestCenterIsFinite(_ request: RevealRequest) -> Bool {
        request.center.x.isFinite && request.center.y.isFinite
    }

    /// 处理 reveal：视口已就绪则立即平移并触发高亮动画；否则缓存为 pendingReveal，等布局完成再执行。
    private func handleReveal(_ request: RevealRequest) {
        guard Self.revealRequestCenterIsFinite(request) else {
            AJ66Diagnostics.logNonFinite(source: "CanvasView.handleReveal", zoom: viewport.zoom, pan: viewport.pan,
                                         input: "request.center=(\(request.center.x),\(request.center.y))")
            return
        }
        guard let resolved = Self.resolveReveal(
            request: request,
            viewportSize: viewportSize,
            viewport: viewport,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        ) else {
            pendingReveal = request
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            viewport = resolved
        }
        // AJ-2：触发粘贴高亮动画（扩散脉冲环）。换 token 即重置脉冲，连续粘贴也能重新播放。
        flashPulse = false
        revealFlash = RevealFlash(center: request.center, token: request.token)
    }

    /// 布局完成（onAppear / onChange(geo.size)）后调用：若曾缓存 reveal 且视口已就绪，补执行。
    private func flushPendingReveal() {
        guard let pending = pendingReveal,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        pendingReveal = nil
        handleReveal(pending)
    }

    /// W3 viewport durable binding：首次布局完成时从 CanvasStore.viewportState 恢复初始视口。
    /// 只执行一次（didRestoreViewportFromStore 守卫），避免切画布/几何变化时覆盖用户实时视口；
    /// store 无真实视口（默认 canvasSize 0）时不恢复，保持视图默认视口（UI 行为不变）。
    private func restoreViewportFromStoreIfNeeded() {
        guard !didRestoreViewportFromStore,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        didRestoreViewportFromStore = true
        guard let restored = store.restoredViewport(viewportSize: viewportSize) else { return }
        viewport = ViewportTransform(zoom: restored.zoom, pan: restored.pan)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // AJ-38：画布示范页——背景用伪仙色板 backgroundPrimary（亮/暗跟随模式；未注入回退系统窗口底色）
                (theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))

                // 世界层：节点/连线/网格全用世界坐标，缩放只作用渲染层
                worldLayer
                    .scaleEffect(viewport.zoom, anchor: .topLeading)
                    .offset(x: viewport.pan.x, y: viewport.pan.y)

                emptyHint
                zoomBadge
                revealFlashOverlay
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("无限画布")
            .accessibilityValue("\(store.graph.nodes.count) 个节点，缩放 \(Int(viewport.zoom * 100))%")
            .accessibilityHint("双击空白创建节点搜索；拖动空白平移画布，使用 Command 加滚轮缩放")
            // C5：双击空白弹节点搜索面板（学 ComfyUI showSearchBox，在双击世界坐标创建）；
            // 单击仍为取消选中（exclusively 保证双击时单击不触发）
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        store.presentNodeSearch(at: viewport.world(value.location))
                    }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in store.deselectAll() })
            )
            .gesture(backgroundDragGesture)
            .gesture(magnificationGesture)
            // F12-⑥ 空白处右键「添加节点」菜单（列 NodeTypeRegistry.specs 分组，
            // 在右键世界坐标处创建；ComfyUI 右键 add node 语义）
            // AJ-21：另加「创建分组」——把当前选中节点（含多选累积）框成一组。
            // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
            .background(RightClickCatcher { windowPoint, localPoint in
                FloatingMenuHost.shared.present(
                    [
                        FloatingMenuItem(kind: .button(title: "创建分组（选中节点）", icon: "square.stack", role: nil, help: "把当前选中的节点框成一个画布组（Option 拖拽空白可框选建组）") {
                            store.createGroupFromSelection()
                        }),
                        FloatingMenuItem(kind: .divider),
                    ] + store.addNodeMenuGroups().map { group in
                        FloatingMenuItem(kind: .submenu(title: group.group.rawValue, icon: groupIcon(for: group.group), items: group.specs.map { spec in
                            FloatingMenuItem(kind: .button(title: spec.title, icon: spec.iconName, role: nil, help: spec.summary) {
                                mutationCoordinator?.dispatch(
                                    .addNode(type: spec.type, position: viewport.world(localPoint))
                                )
                            })
                        }))
                    },
                    at: windowPoint
                )
            })
            .onContinuousHover { phase in
                if case .active(let location) = phase { hoverScreenPoint = location }
            }
            .onAppear {
                // P0-启动崩溃（2026-08-06）：geo.size 在 AppKit 布局 pass 内同步写 @State
                // → body 重建 → graphDidChange → setNeedsUpdateConstraints（布局周期内）
                // → NSException → 300 iterations → 崩溃。Task 延迟到布局外写状态。
                let size = geo.size
                Task { @MainActor in
                    viewportSize = size
                    restoreViewportFromStoreIfNeeded()
                    flushPendingReveal()
                }
            }
            .onChange(of: geo.size) { _, newSize in
                // 同 P0：窗口恢复期间 geo.size 连续变化，同步写 @State 会卡进布局周期，
                // 与 onAppear 同因。异步化后布局 pass 结束才写，循环消失。
                Task { @MainActor in
                    viewportSize = newSize
                    restoreViewportFromStoreIfNeeded()
                    flushPendingReveal()
                }
            }
            // W3 viewport durable binding：本地 viewport 每次变更经明确 seam 写入
            // CanvasStore.viewportState（唯一事实源，防抖落盘）；视图不另建事实源。
            .onChange(of: viewport) { _, newValue in
                store.commitViewport(
                    zoom: newValue.zoom,
                    pan: newValue.pan,
                    viewportSize: viewportSize,
                    canvasSize: Size(width: canvasWidth, height: canvasHeight)
                )
            }
            // U-3：粘贴揭示——store 发出 revealRequest 后，视口自动平移到粘贴内容
            // （落点可能在视口外：默认落点是固定世界坐标，用户平移/缩放后必出屏）
            .onChange(of: store.revealRequest) { _, request in
                guard let request else { return }
                // P0 同因加固：handleReveal 内部 withAnimation 改 viewport（@State），
                // 若在 AppKit 布局 pass 内同步执行同样触发 graphDidChange 循环；
                // 异步化到布局外执行。
                Task { @MainActor in
                    handleReveal(request)
                }
            }
            .overlay(alignment: .top) { executionBar }
            .overlay(alignment: .topLeading) { nodeSearchOverlay }
            .overlay(
                WheelEventCatcher(
                    onScroll: { dx, dy, precise in handleWheelScroll(dx: dx, dy: dy, precise: precise) },
                    onZoom: { dy, precise, anchor in handleWheelZoom(dy: dy, precise: precise, anchor: anchor) }
                )
                .allowsHitTesting(false)
            )
            // C5：⌘C/⌘V/⌘D/⌘Z 快捷键（本地 keyDown 监听，文本编辑焦点自动放行）
            .overlay {
                CanvasKeyboardCatcher(
                    // AJ-64/65：无选中节点时画布不拦截 Delete/⌘C/⌘D（事件放行给系统）
                    hasSelection: !store.selectedNodeIDs.isEmpty,
                    onCopy: { store.copySelection() },
                    onPaste: { screen in
                        // AJ-2：⌘V 落点——鼠标在画布上 → 用鼠标世界坐标；鼠标在画布外
                        // （工具栏/侧栏/窗口外，catcher 传 nil）→ 用当前视口中心，
                        // 避免把节点贴到画布外导致"粘贴后看不到"。
                        store.paste(at: Self.pasteTargetWorld(
                            screen: screen, viewport: viewport, viewportSize: viewportSize))
                    },
                    onDelete: {
                        let selectedNodeIDs = Array(store.selectedNodeIDs)
                        guard !selectedNodeIDs.isEmpty else { return }
                        mutationCoordinator?.dispatch(.removeNodes(ids: selectedNodeIDs))
                    },
                    onUndo: { store.undo() },
                    onSelectAll: { store.selectAllNodes() },
                    onEscape: { store.deselectAll() }
                )
                .allowsHitTesting(false)
            }
            // F12-④ 图片/视频结果预览 sheet（点击缩略图/播放入口弹出；无结果不弹）
            .sheet(isPresented: previewBinding) {
                if let nodeID = store.previewNodeID {
                    NodeMediaPreviewView(nodeID: nodeID, store: store)
                }
            }
            // AJ-16：右下角 minimap（小地图 + 视口跳转；⌘M 开关，右上角 ✕ 关闭）
            // zIndex(40) > 右侧文本编辑面板(30)/分镜表(31)：选中文本节点时不被面板遮挡，
            // 保证地图永远可见（用户反馈「地图没有」= 被 zIndex 更高的右侧面板盖住）。
            .overlay(alignment: .bottomTrailing) {
                if showMinimap {
                    MiniMapView(
                        store: store,
                        viewport: $viewport,
                        viewportSize: viewportSize,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight,
                        onClose: { showMinimap = false }
                    )
                    .padding(.trailing, 12)
                    .padding(.bottom, 48) // 避开底部缩放徽标
                    .zIndex(40)
                } else {
                    // 关闭后右下角常驻重开入口（防误关后找不到；⌘M 同样可重开）
                    Button {
                        showMinimap = true
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("显示迷你地图（⌘M）")
                    .accessibilityLabel("显示迷你地图")
                    .accessibilityHint("打开画布缩略导航；也可使用 ⌘M")
                    .padding(.trailing, 12)
                    .padding(.bottom, 48)
                    .zIndex(40)
                }
            }
            // AJ-16：⌘M 开关 minimap（隐藏按钮注册快捷键）
            .overlay(alignment: .topLeading) {
                Button("") { showMinimap.toggle() }
                    .keyboardShortcut("m", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            // A2：右侧文本大编辑面板（选中文本节点即显示；画布里太小，右侧编辑+可拉大）
            .overlay(alignment: .trailing) {
                if store.textInspectorNodeID != nil {
                    NodeTextInspectorView(store: store)
                        .padding(.trailing, 14)
                        .padding(.vertical, 40)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(30)
                }
            }
            // P2：分镜表工作台（工具栏「分镜表」按钮/双击分镜节点打开；选中行 = reveal 定位节点组，
            // 复用上方粘贴 reveal 机制；与右侧文本面板互斥——store 层 didSet 协调
            // （issues/p2_storyboard_interaction_20260805.md ①），不会同时叠盖）
            .overlay(alignment: .trailing) {
                if store.showStoryboardWorkbench {
                    StoryboardWorkbenchView(
                        store: store,
                        mutationCoordinator: mutationCoordinator
                    ) { store.closeStoryboardWorkbench() }
                        .padding(.trailing, 14)
                        .padding(.vertical, 40)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(31)
                }
            }
        }
        .clipped()
    }

    /// F12-④ 预览 sheet 绑定（由 store.previewNodeID 驱动；关闭回写 nil）
    private var previewBinding: Binding<Bool> {
        Binding(
            get: { store.previewNodeID != nil },
            set: { if !$0 { store.closePreview() } }
        )
    }

    // MARK: AJ-2 粘贴高亮动画（扩散脉冲环）

    /// 粘贴 reveal 后围绕内容中心绘制扩散脉冲环，让用户一眼看到粘贴结果。
    /// 屏幕坐标由 world → screen 换算（随视口平移/缩放实时跟随，无需进世界层）。
    @ViewBuilder
    private var revealFlashOverlay: some View {
        if let flash = revealFlash {
            let screen = viewport.screen(flash.center)
            let token = flash.token
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.95), lineWidth: 3)
                    .frame(width: 36, height: 36)
                    .scaleEffect(flashPulse ? 3.0 : 0.5)
                    .opacity(flashPulse ? 0 : 1)
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                    .scaleEffect(flashPulse ? 2.4 : 0.7)
                    .opacity(flashPulse ? 0 : 0.9)
            }
            .position(x: screen.x, y: screen.y)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.8)) {
                    flashPulse = true
                }
                // 动画结束后移除脉冲环（token 防串扰：期间又粘贴则保留新环）
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 850_000_000)
                    if revealFlash?.token == token { revealFlash = nil }
                }
            }
        }
    }

    // MARK: C5 节点搜索面板（屏幕坐标浮层，不随渲染层缩放）

    /// 搜索面板屏幕坐标 X（世界 → 屏幕，夹在视口内防溢出；面板宽 300）
    private var searchPanelScreenX: CGFloat {
        let p = viewport.screen(store.nodeSearchPosition)
        return min(max(p.x, 160), max(160, viewportSize.width - 160))
    }

    private var searchPanelScreenY: CGFloat {
        let p = viewport.screen(store.nodeSearchPosition)
        return min(max(p.y, 170), max(170, viewportSize.height - 170))
    }

    /// 搜索面板浮层：全画布透明关闭层 + 面板定位到双击处（ComfyUI popover 跟随鼠标语义）
    @ViewBuilder
    private var nodeSearchOverlay: some View {
        if store.isNodeSearchPresented {
            ZStack(alignment: .topLeading) {
                // 点击面板外任意处关闭（ComfyUI showSearchBox 移出/ESC 关闭同语义）
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissNodeSearch() }
                NodeSearchPanelView(store: store)
                    .position(x: searchPanelScreenX, y: searchPanelScreenY)
            }
            .transition(.opacity)
        }
    }

    // MARK: 世界层（逻辑坐标，整体变换）

    private var worldLayer: some View {
        ZStack {
            groupsLayer
            edgesLayer
            nodesLayer
            pendingEdgeLayer
            marqueeLayer
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    // MARK: 执行区（画布上方工具栏条：08-06 用户反馈「执行按钮太深」→ 执行界面放画布上方）

    /// 顶部执行工具栏：空闲时常驻「▶ 运行选中节点 / ▶▶ 运行全部」；运行时切换为
    /// 进度条 + 停止按钮（C2-2 ComfyUI 进度条 + 中断按钮等价物）。
    /// 「运行选中节点」= store.runGraph(from: selectedNodeIDs)（P0 局部重跑语义，
    /// 只跑选中节点及其下游，上游复用上次结果）；「运行全部」= store.runGraph()。
    @ViewBuilder
    private var executionBar: some View {
        Group {
            if let progress = store.executionProgress, store.isRunning {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("执行中 \(progress.value)/\(progress.max)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    if let title = progress.currentNodeTitle {
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button {
                        store.cancelRun()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(theme?.statusDanger ?? .red)
                    .help("中断执行：当前节点完成后停止，剩余节点跳过")
                }
            } else {
                // 空闲：常驻执行入口（无选中时「运行选中节点」置灰，防空集合空跑）
                HStack(spacing: 8) {
                    Button {
                        mutationCoordinator?.dispatch(
                            .runGraph(nodeIDs: Array(store.selectedNodeIDs))
                        )
                    } label: {
                        Label("运行选中节点", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                    .disabled(store.selectedNodeIDs.isEmpty)
                    .help("运行选中节点及其下游（未选中节点时不可用）")

                    Button {
                        mutationCoordinator?.dispatch(.runGraph(nodeIDs: nil))
                    } label: {
                        Label("运行全部", systemImage: "play.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.graph.nodes.isEmpty)
                    .help("按依赖顺序运行整张画布")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 缩放（捏合 / Cmd+滚轮）

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let anchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                viewport = viewport.zoomed(to: lastZoom * value, anchor: anchor,
                                           canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            }
            .onEnded { _ in
                lastZoom = viewport.zoom
            }
    }

    /// Cmd+滚轮缩放（dy>0 向上滚动 → 放大；光标锚定，缩放中心不漂移）
    private func handleWheelZoom(dy: CGFloat, precise: Bool, anchor: CGPoint) {
        guard dy != 0 else { return }
        let normalized = precise ? dy : dy * 10
        let factor = pow(1.01, normalized)
        viewport = viewport.zoomed(to: viewport.zoom * factor, anchor: anchor,
                                   canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        lastZoom = viewport.zoom
    }

    /// 滚轮平移（双指滚动自带系统惯性）
    private func handleWheelScroll(dx: CGFloat, dy: CGFloat, precise: Bool) {
        let factor = precise ? 1.0 : 12.0
        viewport = viewport.pannedBy(dx * factor, dy * factor,
                                     canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    // MARK: 自动缩放全图（fit：双击缩放徽标复位 / 模板生成后兜底）

    /// 计算全部节点包围盒，按视口比例缩放并居中（含节点高度，留 15% 边距）。纯函数，可单测。
    /// AJ-66 防线：任一节点位置非有限（历史 NaN 数据）→ 返回 nil（不动视口）——否则 NaN
    /// 经 min/max 传播进 targetZoom/pan，viewport 被污染后只能重启恢复。
    static func fitViewport(for nodes: [CanvasNode], viewportSize: CGSize,
                            canvasWidth: Double, canvasHeight: Double,
                            currentZoom: Double) -> ViewportTransform? {
        guard !nodes.isEmpty, viewportSize.width > 0, viewportSize.height > 0,
              viewportSize.width.isFinite, viewportSize.height.isFinite else { return nil }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for node in nodes {
            guard node.position.x.isFinite, node.position.y.isFinite else {
                AJ66Diagnostics.logNonFinite(source: "CanvasView.fitViewport", zoom: currentZoom, pan: .zero,
                                             input: "node.position=(\(node.position.x),\(node.position.y))")
                return nil
            }
            let height = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + NodeMetrics.nodeWidth)
            maxY = max(maxY, node.position.y + height)
        }
        let boundsWidth = max(maxX - minX, 240)
        let boundsHeight = max(maxY - minY, 140)
        let targetZoom = ViewportTransform(zoom: currentZoom).clampedZoom(
            min(viewportSize.width / boundsWidth, viewportSize.height / boundsHeight) * 0.85
        )
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        return ViewportTransform(
            zoom: targetZoom,
            pan: CGPoint(x: viewportSize.width / 2 - centerX * targetZoom,
                         y: viewportSize.height / 2 - centerY * targetZoom)
        ).clampedPan(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    private func fitToContent() {
        guard let fitted = Self.fitViewport(for: store.graph.nodes, viewportSize: viewportSize,
                                            canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                            currentZoom: viewport.zoom) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            viewport = fitted
        }
    }

    // MARK: 背景手势（空白拖拽平移 / Option 框选建组 / Shift 框选多选 / 点空白取消选中）

    private var backgroundDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // AJ-21：Option 拖拽空白 → 框选建组；AJ-12：Shift 拖拽空白 → 框选多选
                // （均记录世界坐标矩形，松手区分处理）
                let mods = NSEvent.modifierFlags.intersection([.shift, .option])
                if mods == [.option] || mods == [.shift] {
                    if marqueeStart == nil {
                        marqueeStart = viewport.world(value.startLocation)
                    }
                    marqueeCurrent = viewport.world(value.location)
                    return
                }
                // 普通拖拽 → 平移
                if dragPanStart == nil { dragPanStart = viewport.pan }
                guard let start = dragPanStart else { return }
                viewport = ViewportTransform(zoom: viewport.zoom,
                                             pan: CGPoint(x: start.x + value.translation.width,
                                                          y: start.y + value.translation.height))
                    .clampedPan(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            }
            .onEnded { _ in
                if let start = marqueeStart, let current = marqueeCurrent {
                    let mods = NSEvent.modifierFlags.intersection([.shift, .option])
                    if mods == [.shift] {
                        selectNodesInRect(from: start, to: current)
                    } else if mods == [.option] {
                        groupNodesInRect(from: start, to: current)
                    }
                    marqueeStart = nil
                    marqueeCurrent = nil
                }
                dragPanStart = nil
            }
    }

    /// AJ-12：Shift 框选多选——把中心落在选取矩形内的节点设为选中（替换当前选择）。
    /// 折叠分组内的隐形节点排除（不可见即不可被框选，防选中后 Delete 删掉看不见的节点）。
    private func selectNodesInRect(from start: Point, to end: Point) {
        let minX = min(start.x, end.x), maxX = max(start.x, end.x)
        let minY = min(start.y, end.y), maxY = max(start.y, end.y)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        var ids = CanvasStore.nodes(in: rect, of: store.graph)
        ids.subtract(store.collapsedHiddenNodeIDs())
        store.selectNodes(ids)
    }

    // MARK: 组层（AJ-21：ComfyUI 组，渲染在节点之下）

    private var groupsLayer: some View {
        ForEach(store.groups) { group in
            CanvasGroupView(group: group, store: store)
                .position(x: group.center.x, y: group.center.y)
        }
    }

    /// Option 框选建组：把中心落在选取矩形内的节点建为一个组。
    private func groupNodesInRect(from start: Point, to end: Point) {
        let minX = min(start.x, end.x), maxX = max(start.x, end.x)
        let minY = min(start.y, end.y), maxY = max(start.y, end.y)
        let ids = store.graph.nodes.compactMap { node -> UUID? in
            let h = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
            // 节点矩形与选取矩形相交（含中心判定，更宽松）
            let nodeMinX = node.position.x - NodeMetrics.nodeWidth / 2
            let nodeMaxX = node.position.x + NodeMetrics.nodeWidth / 2
            let nodeMinY = node.position.y - h / 2
            let nodeMaxY = node.position.y + h / 2
            let intersects = nodeMinX <= maxX && nodeMaxX >= minX
                && nodeMinY <= maxY && nodeMaxY >= minY
            return intersects ? node.id : nil
        }
        guard !ids.isEmpty else { return }
        // 折叠分组内的隐形节点不可建组（与框选多选同一过滤规则）
        let visible = ids.filter { !store.collapsedHiddenNodeIDs().contains($0) }
        guard !visible.isEmpty else { return }
        store.createGroup(nodeIDs: Set(visible))
    }

    /// 框选矩形（世界坐标，虚线描边），随 Option 拖拽实时显示
    @ViewBuilder
    private var marqueeLayer: some View {
        if let start = marqueeStart, let current = marqueeCurrent {
            let minX = min(start.x, current.x), maxX = max(start.x, current.x)
            let minY = min(start.y, current.y), maxY = max(start.y, current.y)
            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .overlay(Rectangle().stroke(Color.accentColor,
                                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: maxX - minX, height: maxY - minY)
                .position(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: 连线层

    private var edgesLayer: some View {
        // 折叠分组内的成员节点不可见——其连线一并隐藏（任一端的节点被折叠隐藏即跳过），
        // 避免悬空连线漂浮在画布上（nodesLayer 已隐藏成员，edgesLayer 必须同步过滤）。
        let hidden = store.collapsedHiddenNodeIDs()
        return ForEach(store.graph.edges.filter {
            !hidden.contains($0.fromNode) && !hidden.contains($0.toNode)
        }) { edge in
            EdgeCurve(edge: edge, store: store)
        }
    }

    // MARK: 节点层（世界坐标 position，缩放由渲染层统一承担）
    // AJ-21：折叠组内的成员节点隐藏（仅剩组标题栏可见）

    private var nodesLayer: some View {
        let collapsedNodeIDs = Set(
            store.groups.filter { $0.isCollapsed }.flatMap { $0.nodeIDs }
        )
        return ForEach(store.graph.nodes) { node in
            if !collapsedNodeIDs.contains(node.id) {
                NodeView(node: node, store: store,
                         mutationCoordinator: mutationCoordinator,
                         isSelected: store.selectedNodeIDs.contains(node.id))
                    .position(x: node.position.x, y: node.position.y)
                    .gesture(nodeDragGesture(for: node))
            }
        }
    }

    // MARK: 拖拽中的临时连线（世界坐标）

    @ViewBuilder
    private var pendingEdgeLayer: some View {
        if let pending = store.pendingEdge,
           let fromNode = store.graph.node(id: pending.fromNode),
           let fromPort = fromNode.outputs.first(where: { $0.id == pending.fromPort })
               ?? fromNode.inputs.first(where: { $0.id == pending.fromPort }) {
            let from = store.portAnchor(for: fromNode, port: fromPort)
            // E17：方向感知——控制点方向由目标几何位置自动决定（左拖/反向边自动向左），
            // 比旧端口方向启发式（input→-1/output→+1）更稳：拖向哪侧就向哪侧凸。
            let dir = EdgeGeometry.autoDirection(from: from, to: pending.end)
            // N2：控制点与端点同属世界坐标（EdgeGeometry 纯函数），渲染层统一缩放——
            // 不再逐点乘 zoom，缩放后拖线从端口正确发出
            let (c1, c2) = EdgeGeometry.controlPoints(from: from, to: pending.end, direction: dir)
            // C2-1：悬停非法目标（类型不匹配）时临时线变红提示（C3-2：统一走 danger token）
            let pendingColor: Color = (store.edgeTarget != nil && !store.edgeTargetValid)
                ? (theme?.statusDanger ?? Color(nsColor: .systemRed))
                : (theme?.accentColor ?? Color(nsColor: .systemBlue))
            Path { p in
                p.move(to: CGPoint(x: from.x, y: from.y))
                p.addCurve(to: CGPoint(x: pending.end.x, y: pending.end.y),
                           control1: CGPoint(x: c1.x, y: c1.y),
                           control2: CGPoint(x: c2.x, y: c2.y))
            }
            .stroke(pendingColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
        }
    }

    // MARK: 空画布提示（视口坐标，不随缩放）

    @ViewBuilder
    private var emptyHint: some View {
        if store.graph.nodes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("在右侧聊天框输入「建节点 llm」等指令，或点工具栏添加节点")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 缩放指示（比例尺 + 百分比；点击复位 100%）

    /// 比例尺：世界 200pt 基准 → 按 zoom 换算屏幕长度（放大线段变长，缩放有感知）。
    /// 世界刻度取 1/2/5×10ⁿ 规整步长，屏幕长度夹在 ~40-100px 之间。
    private var scaleBar: some View {
        let target: CGFloat = 64 // 屏幕目标长度（px）
        let raw = target / max(viewport.zoom, 0.0001)
        let mag = pow(10, floor(log10(Double(raw))))
        let norm = raw / mag
        let worldStep = (norm < 1.5 ? 1.0 : norm < 3.5 ? 2.0 : norm < 7.5 ? 5.0 : 10.0) * mag
        let screenLen = worldStep * viewport.zoom
        let label = worldStep >= 1000
            ? String(format: "%.0fk pt", worldStep / 1000)
            : "\(Int(worldStep)) pt"
        return VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .frame(width: max(12, screenLen), height: 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.9))
        )
    }

    private var zoomBadge: some View {
        VStack(alignment: .trailing, spacing: 5) {
            scaleBar
            Text("\u{1F50D} \(Int(viewport.zoom * 100))%")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.92)))
                .overlay(Capsule().stroke(theme?.aj38.accent.swiftUIColor ?? Color.accentColor.opacity(0.4), lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewport = ViewportTransform()
                    }
                }
                .help("点击复位 100%")
                .accessibilityElement()
                .accessibilityLabel("画布缩放，当前 \(Int(viewport.zoom * 100))%")
                .accessibilityHint("点击或执行操作恢复到 100%")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewport = ViewportTransform()
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(12)
    }

    // MARK: 节点拖拽（世界坐标：translation 在缩放层内即世界位移，不再 /zoom 换算）

    private func nodeDragGesture(for node: CanvasNode) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartPositions.isEmpty {
                    // AJ-12 多选拖拽整组：拖动的是多选集合中的任一节点 → 快照全部选中节点
                    // 起始位置，整组同步平移；单选（或长按非选中节点）→ 只移动该节点。
                    let selected = store.selectedNodeIDs
                    let ids = selected.contains(node.id) && selected.count > 1
                        ? selected
                        : [node.id]
                    var starts: [UUID: Point] = [:]
                    for id in ids {
                        if let pos = store.graph.node(id: id)?.position {
                            starts[id] = pos
                        }
                    }
                    dragStartPositions = starts
                }
                guard !dragStartPositions.isEmpty else { return }
                let delta = Point(x: value.translation.width, y: value.translation.height)
                for (id, start) in dragStartPositions {
                    store.moveNode(
                        id: id,
                        to: Point(x: start.x + delta.x, y: start.y + delta.y)
                    )
                }
            }
            .onEnded { _ in
                dragStartPositions = [:]
            }
    }
}

// MARK: - 节点视图

struct NodeView: View {
    let node: CanvasNode
    let store: CanvasStore
    let mutationCoordinator: CanvasMutationCoordinator?
    let isSelected: Bool

    @Environment(\.themeTokens) private var theme

    /// F12-① 标题内联重命名（状态由 store.renamingNodeID 驱动，双击/右键共用一条路径）
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    /// 端口 hover 高亮：当前悬停的端口 id（提示可连线；拖动命中区扩大后行内任意位置可拖）
    @State private var hoveredPortID: UUID?

    private var width: Double { NodeMetrics.nodeWidth }

    // MARK: P2 分镜锚点（标记 + 拖动；数据契约 params["anchor"] = "x,y" 归一化 0...1）

    /// 节点锚点（nil = 未设置；锚点圆点仅在已设置时显示）
    private var anchor: StoryboardAnchor? { store.anchor(of: node.id) }

    /// 锚点可视范围 = 内容区骨架（header 下方到最末端口行底，与 portAnchor 同一几何源）。
    /// 归一化 y 映射到 [headerHeight, headerHeight + maxPorts×rowHeight]，不占卡片布局。
    private var anchorMaxPorts: Int { max(node.inputs.count, node.outputs.count) }

    /// 锚点圆点 local 坐标（overlay 容器原点 = 卡片左上）
    private var anchorPoint: CGPoint? {
        guard let anchor else { return nil }
        let contentH = NodeMetrics.headerHeight + Double(max(anchorMaxPorts, 1)) * NodeMetrics.rowHeight
        return CGPoint(x: anchor.x * width, y: NodeMetrics.headerHeight + anchor.y * (contentH - NodeMetrics.headerHeight))
    }

    /// F12-② 卡片内联文本编辑（状态由 store.editingContentNodeID 驱动；失焦提交 / ESC 取消）
    @State private var inlineDraft = ""
    @FocusState private var inlineEditFocused: Bool
    /// L2：ESC 取消标志——onExitCommand 先置位再退编辑态，失焦回调据此跳过提交
    /// （未置位时失焦一律提交，含点其它文本节点导致本节点编辑态被顶掉的情况）
    @State private var cancelInlineEdit = false
    /// P2 分镜锚点拖动：拖动起点（首帧捕获；nil = 非拖动中）。结束后 setAnchor 提交（undo+落盘）
    @State private var dragAnchorOrigin: StoryboardAnchor?

    /// 节点状态语义色（C3-2：QC 通过/失败、执行中、缓存等统一走 token；
    /// 未注入 provider 时回退原有系统色）。
    private var statusColor: Color {
        theme?.nodeStatusColor(node.status) ?? node.status.color
    }

    /// B1：是否为审核节点（reviewGate）
    private var isReviewGate: Bool {
        node.type == ManjuNodeType.reviewGate.rawValue
    }

    /// B1：审核三态（未设置 / 未知值 → 待审）
    private var reviewStatus: ReviewStatus {
        ReviewStatus.fromParams(node.backendConfig?.params)
    }

    /// B1：卡片主色（审核节点 → 三态色；其余节点 → 执行状态色）
    private var cardAccent: Color {
        isReviewGate ? reviewStatus.color : statusColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            portsRow
        }
        // U-1：卡片定高 nodeHeight（与 portAnchor 同一几何源）；Divider 移入 header 底缘
        // overlay 不占布局高度——旧实现 Divider 参与 VStack 布局，卡片实际高度比
        // nodeHeight 多 ~1px 且不受控，端口锚点与视觉圆点错位（截图实测连线歪斜根因之一）。
        .frame(width: width, height: cardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.96))
                .shadow(color: .black.opacity(isSelected ? 0.45 : 0.25),
                        radius: isSelected ? 10 : 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isSelected ? 2.5 : 1.5)
        )
        // A1 左键交互（08-06 用户定案：单击 = 纯选中，不再触发编辑/上传/预览——
        // 编辑、上传只从 contentPanelTray 明确位置（文本面板点击=内联编辑 / 图片面板
        // 点击=上传 / 视频面板点击=导入）、双击内容编辑面板、右键菜单进入）；
        // Shift+单击 = 多选（不触发操作）；双击 = 内容编辑面板（保留）
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    // P2 入口1：分镜节点双击 → 打开分镜表工作台（设计 §5.1「批量展开后
                    // 双击分镜节点 → 表格视图」）；其余节点维持原双击行为（内容编辑面板）。
                    if CanvasStore.shouldOpenWorkbench(nodeType: node.type) {
                        store.openStoryboardWorkbench(for: node.id)
                    } else {
                        store.presentContentEditor(for: node.id)
                    }
                }
                .exclusively(before: TapGesture().onEnded {
                    if NSEvent.modifierFlags.contains(.shift) {
                        store.toggleSelectNode(id: node.id)
                    } else {
                        store.selectNode(id: node.id)
                    }
                })
        )
        // F12：下挂内容面板（文本摘要/内联编辑 · 图片上传/缩略图 · 视频播放入口）——
        // overlay 不参与布局 → 卡片中心/端口锚点几何不变（E17/N2 既有测试保持）
        .overlay(alignment: .top) { contentPanelTray }
        // B1：审核节点选中时，卡片下方悬挂 放行/打回 操作区（同 overlay 语义，不改卡片布局）
        .overlay(alignment: .top) { reviewActionTray }
        // P2 分镜锚点：内容区锚点圆点标记（青 #78BFC8 + 白描边），可拖动（实时写回 + 结束提交）。
        // 与 contentPanelTray 同款 overlay 语义——不参与布局，卡片几何/端口锚点不变（E17/N2 保持）
        .overlay(alignment: .topLeading) { anchorMarker }
        // F12：节点右键菜单（①重命名 ②编辑内容 ③上传图片 ④预览结果 ⑤复制/粘贴 + 删除）
        // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(nodeMenuItems(), at: windowPoint)
        })
        .onChange(of: store.renamingNodeID) { _, newValue in
            if newValue == node.id {
                renameDraft = node.title
                Task { @MainActor in renameFocused = true }
            }
        }
        .help("单击：选中 · 双击：编辑内容 · 标题双击：重命名 · 右键：更多操作")
    }

    /// P2 分镜锚点圆点标记：仅已设置锚点显示。拖动 = 实时 setAnchorLive（零卡顿跟手）
    /// + 结束 setAnchor 提交（pushUndoState + 落盘 + 状态提示）。归一化坐标换算经
    /// anchorPoint（内容区骨架映射，与 portAnchor 同源），clamped() 防御越界。
    @ViewBuilder
    private var anchorMarker: some View {
        if anchor != nil, let p = anchorPoint {
            Circle()
                .fill(Color(red: 0.47, green: 0.75, blue: 0.78)) // 状态青 #78BFC8
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .position(x: p.x, y: p.y)
                .contentShape(Circle().inset(by: -6))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragAnchorOrigin == nil { dragAnchorOrigin = anchor }
                            guard let origin = dragAnchorOrigin else { return }
                            let contentH = NodeMetrics.headerHeight + Double(max(anchorMaxPorts, 1)) * NodeMetrics.rowHeight
                            let nx = origin.x + value.translation.width / width
                            let ny = origin.y + value.translation.height / (contentH - NodeMetrics.headerHeight)
                            store.setAnchorLive(StoryboardAnchor(x: nx, y: ny).clamped(), for: node.id)
                        }
                        .onEnded { _ in
                            if let current = store.anchor(of: node.id) {
                                store.setAnchor(current, for: node.id)
                            }
                            dragAnchorOrigin = nil
                        }
                )
                .help("拖动调整分镜锚点（镜头构图参考点）")
        }
    }

    /// B1：审核状态徽标（待审/通过/打回；三态色胶囊小字）
    private var reviewBadge: some View {
        let status = reviewStatus
        return Text(status.label)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(status.color.opacity(0.18)))
            .foregroundStyle(status.color)
            .help("审核状态：" + status.label + "（params[review.status]）")
    }

    private var borderColor: Color {
        if isSelected { return statusColor }
        return theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(cardAccent)
                .frame(width: 8, height: 8)
            // F12-① 标题：双击进入内联重命名 TextField；回车提交 / ESC 取消 / 失焦提交
            if store.renamingNodeID == node.id {
                TextField("节点名称", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { store.endRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && store.renamingNodeID == node.id { commitRename() }
                    }
            } else {
                Text(node.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { store.beginRename(id: node.id) }
                    .help("双击重命名节点")
            }
            Spacer(minLength: 4)
            // E15：内容编辑快捷按钮（双击节点同样可打开）
            Button {
                store.presentContentEditor(for: node.id)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme?.aj38.textSecondary.swiftUIColor ?? Color(nsColor: .secondaryLabelColor))
            .help("编辑节点内容（双击节点也可）")
            .accessibilityLabel("编辑节点内容")
            .accessibilityHint("打开节点内容编辑器")
            // 08-06 用户反馈「点生图和生视频节点就能运行」：生成类节点 header 常驻
            // 「▶ 运行」胶囊按钮（视觉突出），点击 = store.runGraph(from: [node.id])
            // 只跑此节点及其下游（P0 局部重跑），与右键菜单「重跑此节点及下游」同一语义。
            if node.type == ManjuNodeType.imageGen.rawValue || node.type == ManjuNodeType.videoGen.rawValue {
                Button {
                    mutationCoordinator?.dispatch(.runGraph(nodeIDs: [node.id]))
                } label: {
                    Label("运行", systemImage: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.18))
                        )
                        .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("运行此节点及其下游（不重跑上游）")
                .accessibilityLabel("运行节点")
                .accessibilityHint("运行此节点及其下游，不重跑上游")
            }
            // B1：审核节点显示三态徽标（待审/通过/打回），替代执行状态小字
            if isReviewGate {
                reviewBadge
            } else {
                Text(node.status.label)
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NodeMetrics.headerHeight)
        .background(cardAccent.opacity(0.10))
        // U-1：分隔线改 header 底缘 overlay（不占布局高度），卡片定高与 portAnchor 几何严格一致
        .overlay(alignment: .bottom) {
            Divider().overlay(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor))
        }
    }

    /// F12-① 提交重命名（回车 / 失焦；空串回退原标题由 store 兜底）
    private func commitRename() {
        store.renameNode(id: node.id, title: renameDraft)
        store.endRename()
    }

    // MARK: F12 节点右键菜单（ComfyUI 节点右键语义）

    private func nodeMenuItems() -> [FloatingMenuItem] {
        var items: [FloatingMenuItem] = [
            FloatingMenuItem(kind: .button(title: "重命名", icon: "pencil", role: nil, help: nil) { store.beginRename(id: node.id) }),
            FloatingMenuItem(kind: .button(title: "编辑内容", icon: "text.alignleft", role: nil, help: nil) { store.presentContentEditor(for: node.id) }),
        ]
        if CanvasStore.contentKind(of: node.type) == .image {
            items.append(FloatingMenuItem(kind: .button(title: "上传图片…", icon: "photo.badge.plus", role: nil, help: nil) { pickImageFile() }))
        }
        // 08-06：视频节点右键同样提供导入入口（单击不再弹导入，B2 导入能力保留在显式菜单）
        if CanvasStore.contentKind(of: node.type) == .video {
            items.append(FloatingMenuItem(kind: .button(title: "上传视频…", icon: "video.badge.plus", role: nil, help: nil) { pickMediaFile() }))
        }
        if store.resultMedia(of: node.id) != nil {
            items.append(FloatingMenuItem(kind: .button(title: "预览结果", icon: "eye", role: nil, help: nil) { store.presentPreview(for: node.id) }))
        }
        // P2 分镜锚点入口：无锚点 → 「设置锚点」（默认画面中心 0.5,0.5，可拖动微调）；
        // 有锚点 → 「清除锚点」。与画布圆点标记同一数据契约（params["anchor"]）。
        if anchor == nil {
            items.append(FloatingMenuItem(kind: .button(title: "设置锚点", icon: "scope", role: nil, help: "在镜头画面内标记构图参考点（拖动圆点可微调）") { store.setAnchor(StoryboardAnchor(x: 0.5, y: 0.5), for: node.id) }))
        } else {
            items.append(FloatingMenuItem(kind: .button(title: "清除锚点", icon: "scope", role: nil, help: nil) { store.setAnchor(nil, for: node.id) }))
        }
        // B7：生图结果「加载到画布」——新建资产引用节点（assetRef）引用该图片，
        // 节点卡片显示缩略图，可在画布上继续导入替换/连线下游（生成图片画布节点化）。
        if let media = store.resultMedia(of: node.id), media.kind == "image" {
            let offset = Point(x: node.position.x + 40, y: node.position.y + 60)
            items.append(FloatingMenuItem(kind: .button(title: "加载到画布", icon: "plus.rectangle.on.rectangle", role: nil, help: "把该图片生成为画布上的资产引用节点") {
                mutationCoordinator?.dispatch(
                    .addImageAsset(path: media.path, name: nil, position: offset)
                )
            }))
        }
        // 线G：生视频结果「加载到画布」——与生图结果同一入口（FloatingMenuItem 列表即右键菜单，
        // 右键菜单天然对称）：新建 assetRef 节点挂载该视频（assetKind=.video），
        // 节点卡片显示视频播放入口，可在画布上继续导入替换/连线下游。
        if let media = store.resultMedia(of: node.id), media.kind == "video" {
            let offset = Point(x: node.position.x + 40, y: node.position.y + 60)
            items.append(FloatingMenuItem(kind: .button(title: "加载到画布", icon: "plus.rectangle.on.rectangle", role: nil, help: "把该视频生成为画布上的资产引用节点") {
                mutationCoordinator?.dispatch(
                    .addVideoAsset(path: media.path, name: nil, position: offset)
                )
            }))
        }
        items.append(FloatingMenuItem(kind: .divider))
        // P0 局部重跑（画布逻辑补强）：只重跑此节点及其下游，上游复用上次结果——
        // 漫剧迭代制作语义：改提示词/参数后不必整图重跑，不重复烧上游 token。
        items.append(FloatingMenuItem(kind: .button(title: "重跑此节点及下游", icon: "arrow.triangle.2.circlepath", role: nil, help: nil) {
            mutationCoordinator?.dispatch(.runGraph(nodeIDs: [node.id]))
        }))
        // P1 分镜批量展开：一键把分镜节点内容切成 N 个分镜节点（一集几十镜）
        // P2 入口3：分镜节点右键菜单「打开分镜表工作台」（设计 §5.1：与批量展开并列）
        if node.type == ManjuNodeType.storyboard.rawValue {
            items.append(FloatingMenuItem(kind: .button(title: "批量展开分镜", icon: "rectangle.split.3x1", role: nil, help: "按镜号行/空行把分镜内容切成多个分镜节点") {
                mutationCoordinator?.dispatch(.expandStoryboard(id: node.id))
            }))
            items.append(FloatingMenuItem(kind: .button(title: "打开分镜表工作台", icon: "rectangle.split.3x1", role: nil, help: "按镜头汇总整部剧，查看/组织每镜详情") { store.openStoryboardWorkbench(for: node.id) }))
        }
        // B1 审核节点：手动放行/打回（写 params["review.status"] = PASS/REJECT）
        if node.type == ManjuNodeType.reviewGate.rawValue {
            items.append(FloatingMenuItem(kind: .button(title: "放行（通过）", icon: "checkmark.circle", role: nil, help: "审核通过：写入 PASS") { store.setReviewStatus(nodeID: node.id, pass: true) }))
            items.append(FloatingMenuItem(kind: .button(title: "打回（拒绝）", icon: "xmark.circle", role: nil, help: "审核拒绝：写入 REJECT") { store.setReviewStatus(nodeID: node.id, pass: false) }))
        }
        items.append(FloatingMenuItem(kind: .divider))
        items.append(FloatingMenuItem(kind: .button(title: "复制", icon: "doc.on.doc", role: nil, help: nil) { store.copyNode(id: node.id) }))
        items.append(FloatingMenuItem(kind: .button(title: "粘贴", icon: "doc.on.clipboard", role: nil, help: nil) { store.pasteNode(near: node.id) }))
        items.append(FloatingMenuItem(kind: .divider))
        items.append(FloatingMenuItem(kind: .button(title: "删除", icon: "trash", role: .destructive, help: nil) {
            // AJ-12 批量删除：右键多选集合中的任一节点 → 删除整个选中集合；否则删单个。
            if store.selectedNodeIDs.contains(node.id) && store.selectedNodeIDs.count > 1 {
                mutationCoordinator?.dispatch(
                    .removeNodes(ids: Array(store.selectedNodeIDs))
                )
            } else {
                mutationCoordinator?.dispatch(.removeNode(id: node.id))
            }
        }))
        return items
    }

    // MARK: F12 下挂内容面板（卡片下方悬挂，overlay 不改卡片布局）

    /// 卡片本体高度（与 NodeMetrics.nodeHeight 同口径）
    private var cardHeight: Double {
        NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
    }

    @ViewBuilder
    private var contentPanelTray: some View {
        if let kind = CanvasStore.contentKind(of: node.type) {
            Group {
                switch kind {
                case .text: textContentPanel
                case .image: imageContentPanel
                case .video: videoContentPanel
                }
            }
            .frame(width: width - 12)
            .offset(y: cardHeight + 6)
        }
    }

    /// B1：审核节点操作区——选中时在卡片下方悬挂「放行」「打回」按钮，
    /// 点击调用 store.setReviewStatus(nodeID:pass:)（放行→true / 打回→false），
    /// 写 params["review.status"] = PASS/REJECT，@Observable 驱动卡片三态即时刷新。
    /// overlay 悬挂不参与卡片布局（与 contentPanelTray 同语义）。
    @ViewBuilder
    private var reviewActionTray: some View {
        if isReviewGate && isSelected {
            HStack(spacing: 6) {
                reviewActionButton(title: "放行", pass: true)
                reviewActionButton(title: "打回", pass: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.96))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            )
            .frame(width: width - 12)
            .offset(y: cardHeight + 6)
        }
    }

    /// B1：单个审核操作按钮（放行=青 / 打回=红 胶囊）
    private func reviewActionButton(title: String, pass: Bool) -> some View {
        let status = pass ? ReviewStatus.pass : ReviewStatus.reject
        return Button {
            store.setReviewStatus(nodeID: node.id, pass: pass)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(status.color.opacity(0.16)))
                .foregroundStyle(status.color)
        }
        .buttonStyle(.plain)
        .help(pass ? "放行：审核通过（写入 PASS）" : "打回：审核拒绝（写入 REJECT）")
    }

    /// F12-② 文本节点面板：显示摘要/截断；点击进入内联编辑（输入/粘贴），
    /// 失焦提交写回 params["content"]；「全文」按钮打开完整编辑面板
    /// A3：面板高度可拖拽拉高（store.textPanelHeight(for:) 覆盖默认 56）
    @ViewBuilder
    private var textContentPanel: some View {
        let panelHeight = store.textPanelHeight(for: node.id)
        if store.editingContentNodeID == node.id {
            TextEditor(text: $inlineDraft)
                .font(.system(size: 10))
                .scrollContentBackground(.hidden)
                .focused($inlineEditFocused)
                .frame(height: panelHeight)
                .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme?.aj38.accent.swiftUIColor ?? Color.accentColor, lineWidth: 1))
                .onSubmit { commitInlineContent() }
                .onExitCommand {
                    // L2：ESC 取消——先置位取消标志再退编辑态，失焦回调据此跳过提交
                    cancelInlineEdit = true
                    store.endInlineContentEdit()
                }
                .onChange(of: inlineEditFocused) { _, focused in
                    // L2：失焦一律提交（含点其它文本节点把本节点编辑态顶掉的场景），
                    // 仅 ESC 取消路径（cancelInlineEdit）跳过
                    if !focused && !cancelInlineEdit { commitInlineContent() }
                }
                .onAppear {
                    inlineDraft = store.content(of: node.id)
                    cancelInlineEdit = false
                    // L2：延迟一帧聚焦（等视图稳定；右侧面板已互斥关闭不再抢焦点），
                    // 聚焦前确认仍处本节点编辑态，避免对已退出的 TextEditor 无效聚焦
                    Task { @MainActor in
                        guard store.editingContentNodeID == node.id else { return }
                        inlineEditFocused = true
                    }
                }
        } else {
            let summary = CanvasStore.contentSummary(store.content(of: node.id))
            HStack(alignment: .top, spacing: 4) {
                Text(summary.isEmpty ? "点击输入 / 粘贴文本…" : summary)
                    .font(.system(size: 10))
                    .foregroundStyle(summary.isEmpty ? .tertiary : .secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    store.presentContentEditor(for: node.id)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("打开完整内容编辑面板")
            }
            .padding(6)
            .frame(height: panelHeight, alignment: .top)
            .background(panelBackground)
            .contentShape(Rectangle())
            .onTapGesture { store.beginInlineContentEdit(nodeID: node.id) }
            // A3：右下角拖拽手柄拉高面板（方便长文本阅读）
            .overlay(alignment: .bottomTrailing) { resizeHint }
            .onChange(of: store.editingContentNodeID) { _, newValue in
                if newValue == node.id {
                    inlineDraft = store.content(of: node.id)
                    Task { @MainActor in inlineEditFocused = true }
                }
            }
        }
    }

    /// A3：文本面板拉高手柄（拖右下角三角向上拉高面板）
    private var resizeHint: some View {
        Image(systemName: "arrow.up.and.down")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .padding(3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        store.setTextPanelHeight(NodeMetrics.textPanelHeight + value.translation.height, for: node.id)
                    }
            )
            .help("向上拖拽拉高文本面板（方便阅读）")
    }

    private func commitInlineContent() {
        let wasEditing = store.editingContentNodeID == node.id
        mutationCoordinator?.dispatch(
            .updateNodeContent(content: inlineDraft, id: node.id)
        )
        // L2：仅当本节点仍是当前编辑态才退出编辑态——点其它文本节点时本节点失焦提交，
        // 但 editingContentNodeID 已指向新节点，不能把新节点的编辑态误关掉。
        if wasEditing { store.endInlineContentEdit() }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor), lineWidth: 1))
    }

    /// F12-③ 图片节点面板：有结果 → 缩略图（F12-④ 点击预览大图）；
    /// 无结果 → 虚线占位「点击选择 / 拖入图片」，NSOpenPanel 或 onDrop 直接上传
    @ViewBuilder
    private var imageContentPanel: some View {
        if let media = store.resultMedia(of: node.id), media.kind == "image",
           let nsImage = store.cachedImage(path: media.path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: NodeMetrics.imagePanelHeight)
                .background(Color.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.presentPreview(for: node.id) }
                .help("点击预览大图")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("预览图片")
                .accessibilityHint("打开图片大图预览")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { store.presentPreview(for: node.id) }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                Text("点击选择 / 拖入图片")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NodeMetrics.imagePanelHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor))
            )
            .contentShape(Rectangle())
            .onTapGesture { pickImageFile() }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return store.importImage(fileURL: url, for: node.id)
            }
            .help("点击选择图片文件，或直接拖入图片")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("导入图片")
            .accessibilityHint("选择图片文件；也可以拖入图片")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pickImageFile() }
        }
    }

    /// F12-④ 视频节点面板：有结果 → 播放入口（点击弹预览播放器）；无结果不弹
    @ViewBuilder
    private var videoContentPanel: some View {
        if let media = store.resultMedia(of: node.id), media.kind == "video" {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text(URL(fileURLWithPath: media.path).lastPathComponent)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: NodeMetrics.videoPanelHeight)
            .background(panelBackground)
            .contentShape(Rectangle())
            .onTapGesture { store.presentPreview(for: node.id) }
            .help("点击播放视频")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("播放视频")
            .accessibilityHint("打开视频预览播放器")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.presentPreview(for: node.id) }
        } else {
            // 08-06：单击节点不再弹导入（单击=纯选中），视频导入入口收敛到这里——
            // 视频面板空态本身即「导入位置」：点击选择 / 拖入视频（与图片面板同语义）。
            VStack(spacing: 4) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                Text("点击选择 / 拖入视频")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NodeMetrics.videoPanelHeight)
            .background(panelBackground)
            .contentShape(Rectangle())
            .onTapGesture { pickMediaFile() }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return store.importVideo(fileURL: url, for: node.id)
            }
            .help("点击选择视频文件，或直接拖入视频")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("导入视频")
            .accessibilityHint("选择视频文件；也可以拖入视频")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pickMediaFile() }
        }
    }

    /// 08-06 用户定案：单击 = 纯选中，此函数（单击自动进入编辑/上传/预览）已删除——
    /// 编辑/上传入口收敛到 contentPanelTray 明确位置（文本面板点击 / 图片面板点击 /
    /// 视频面板点击）、双击内容编辑面板、右键菜单。
    ///
    /// F12-③ NSOpenPanel 静默选择图片文件（选中即写入节点，无模态打断）
    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.importImage(fileURL: url, for: node.id)
        }
    }

    /// B2：NSOpenPanel 静默选择视频文件（视频节点导入用；选中即写入节点，无模态打断）
    private func pickMediaFile() {
        let panel = NSOpenPanel()
        panel.title = "选择视频"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            _ = store.importVideo(fileURL: url, for: node.id)
        }
    }

    // MARK: 端口区

    private var portsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(node.inputs) { port in
                    portRow(port: port, leadingDot: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(node.outputs) { port in
                    portRow(port: port, leadingDot: false)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, NodeMetrics.bottomPadding)
    }

    private func portRow(port: CanvasCore.Port, leadingDot: Bool) -> some View {
        // E17：拖拽连线中的吸附目标端口高亮；C2-1：合法绿 / 非法红（类型校验）
        let isEdgeTarget = store.edgeTarget?.nodeID == node.id && store.edgeTarget?.portID == port.id
        let targetValid = store.edgeTargetValid
        let isHovered = hoveredPortID == port.id
        return HStack(spacing: 6) {
            if leadingDot { dot(port, isEdgeTarget: isEdgeTarget, targetValid: targetValid, isHovered: isHovered) }
            Text(port.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !leadingDot { dot(port, isEdgeTarget: isEdgeTarget, targetValid: targetValid, isHovered: isHovered) }
        }
        // 命中扩大（08-06 用户反馈）：端口行整行可拖出连线——行宽撑满所在列
        // （输入列左对齐 / 输出列右对齐），contentShape 覆盖整行矩形（行高 26pt ≥ 16x16 目标），
        // 不再要求精确点到 9pt 小圆点。视觉布局不变：内容仍贴边，仅命中/高亮区域变宽。
        .frame(maxWidth: .infinity, alignment: leadingDot ? .leading : .trailing)
        .frame(height: NodeMetrics.rowHeight)
        .contentShape(Rectangle())
        .background(isHovered ? Color.accentColor.opacity(0.07) : Color.clear)
        .onHover { hovering in
            if hovering {
                hoveredPortID = port.id
            } else if hoveredPortID == port.id {
                hoveredPortID = nil
            }
        }
        .gesture(connectDragGesture(for: port))
        // C2-1：点已连口断开（LiteGraph click_do_break_link_to；未连接口 no-op）
        .simultaneousGesture(
            TapGesture().onEnded {
                store.disconnectPort(nodeID: node.id, portID: port.id)
            }
        )
        .help("按住拖动连线 · 单击断开已有连线")
    }

    private func dot(_ port: CanvasCore.Port, isEdgeTarget: Bool = false, targetValid: Bool = true,
                     isHovered: Bool = false) -> some View {
        // C2-1：吸附目标高亮环——合法目标绿色（LiteGraph input_on #7F7）、非法红色（类型不匹配）
        // C3-2：统一走 success / danger token。
        // 命中扩大（08-06）：视觉圆点仍 9pt（不占额外布局、不动端口锚点几何），
        // 命中由 portRow 整行 contentShape 承担（≥16x16）；hover 时圆点放大 + 光环显现提示可连线。
        let ringColor: Color = isEdgeTarget
            ? (targetValid
                ? (theme?.statusSuccess ?? Color(nsColor: .systemGreen))
                : (theme?.statusDanger ?? Color(nsColor: .systemRed)))
            : portColor(port)
        let dotSize: CGFloat = isHovered ? 12 : 9
        let showRing = isEdgeTarget || isHovered
        let ringOpacity: Double = isEdgeTarget ? 1 : (isHovered ? 0.8 : 0)
        return Circle()
            .fill(portColor(port))
            .frame(width: dotSize, height: dotSize)
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.5))
            .overlay(
                Circle()
                    .stroke(ringColor.opacity(ringOpacity), lineWidth: 3)
                    .frame(width: 20, height: 20)
            )
            .shadow(color: ringColor.opacity(showRing ? 0.9 : 0),
                    radius: showRing ? 6 : 0)
            .animation(.easeOut(duration: 0.12), value: isEdgeTarget)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func portColor(_ port: CanvasCore.Port) -> Color {
        switch port.dataType {
        case "string": return Color(nsColor: .systemOrange)
        case "image": return Color(nsColor: .systemPurple)
        case "video": return Color(nsColor: .systemPink)
        default: return Color(nsColor: .systemTeal)
        }
    }

    // MARK: 端口拖拽 → 连线（世界坐标：translation 在缩放层内即世界位移，不再 /zoom）

    private func connectDragGesture(for port: CanvasCore.Port) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let anchor = store.portAnchor(for: node, port: port)
                // E17：translation 从拖拽起点（端口附近）起算 → 线尾 = 锚点 + 鼠标位移，
                // 精确跟随鼠标；N2：缩放层内 translation 即世界坐标位移。
                let point = Point(x: anchor.x + value.translation.width,
                                  y: anchor.y + value.translation.height)
                if store.pendingEdge == nil {
                    store.beginEdge(from: node.id, portID: port.id, at: point)
                } else {
                    store.updateEdgeEnd(point)
                }
            }
            .onEnded { value in
                let anchor = store.portAnchor(for: node, port: port)
                let point = Point(x: anchor.x + value.translation.width,
                                  y: anchor.y + value.translation.height)
                store.endEdge(at: point)
            }
    }
}

// MARK: - 贝塞尔连线

struct EdgeCurve: View {
    let edge: CanvasCore.Edge
    let store: CanvasStore

    @Environment(\.themeTokens) private var theme

    var body: some View {
        // E17：坐标统一走 store.edgeEndpoints（= portAnchor 中心坐标语义），渲染与测试一致
        if let endpoints = store.edgeEndpoints(edge),
           let fromNode = store.graph.node(id: edge.fromNode) {
            let from = endpoints.from
            let to = endpoints.to
            // N2：与拖线临时线共用 EdgeGeometry（控制点世界坐标），渲染层统一缩放——
            // 不再逐点乘 zoom，缩放后曲线不漂移
            // 第二层病根（08-04）：方向不再硬编码 direction: 1.0——反向边（终节点在源左侧）
            // 与长距离边曾画大回环；现按目标相对源的几何位置自动定方向 + 控制偏移封顶。
            let dir = EdgeGeometry.autoDirection(from: from, to: to)
            let (c1, c2) = EdgeGeometry.controlPoints(from: from, to: to, direction: dir)

            Path { p in
                p.move(to: CGPoint(x: from.x, y: from.y))
                p.addCurve(
                    to: CGPoint(x: to.x, y: to.y),
                    control1: CGPoint(x: c1.x, y: c1.y),
                    control2: CGPoint(x: c2.x, y: c2.y)
                )
            }
            .stroke((theme?.nodeStatusColor(fromNode.status) ?? fromNode.status.color).opacity(0.9),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .contentShape(Path().strokedPath(StrokeStyle(lineWidth: 8)))
            // C2-1：双击连线删除（LiteGraph visible_links 中点命中语义）
            .gesture(
                TapGesture(count: 2).onEnded {
                    store.removeEdge(id: edge.id)
                }
            )
        }
    }
}

// MARK: - 连线几何（U1：纯函数，可单测；N2：世界坐标，与渲染层缩放解耦）

/// 贝塞尔连线控制点计算：控制点与端点同属世界坐标（不随 zoom 变），渲染层统一缩放。
/// 方向感知：控制点方向由「目标相对源」的几何位置自动决定（反向边/左拖自动向左），
/// 并限制长距离边的控制偏移，避免大回环。
enum EdgeGeometry {
    /// 水平控制偏移（世界坐标）上限：两端水平距离的一半，但封顶 150 世界单位——
    /// 长距离/反向边不再无限放大控制点（防大回环），至少 50（防近距线过弯）。
    static let maxControlOffset = 150.0

    /// 水平控制偏移（世界坐标）：两端水平距离的一半，夹在 [50, 150] 之间。
    static func controlOffset(from: Point, to: Point) -> Double {
        min(max(abs(to.x - from.x) * 0.5, 50.0), maxControlOffset)
    }

    /// 自动方向：目标在源左侧（反向边 / 向左拖线）为 -1，否则 +1。
    /// 替代旧硬编码 direction: 1.0 —— 旧逻辑反向边、长距离边画大回环。
    static func autoDirection(from: Point, to: Point) -> Double {
        to.x >= from.x ? 1.0 : -1.0
    }

    /// 由两端点 + 方向（+1 输出→输入 / -1 反向）生成贝塞尔控制点（世界坐标）
    static func controlPoints(from: Point, to: Point, direction: Double)
        -> (control1: Point, control2: Point) {
        let dx = controlOffset(from: from, to: to)
        return (
            Point(x: from.x + dx * direction, y: from.y),
            Point(x: to.x - dx * direction, y: to.y)
        )
    }
}

// MARK: - 画布组视图（AJ-21：ComfyUI 组）

/// 画布组矩形：半透明背景 + 标题栏（含折叠按钮/重命名/节点数），可整组拖动。
/// 折叠时仅显示标题栏；成员节点由 nodesLayer 隐藏。
struct CanvasGroupView: View {
    let group: CanvasGroup
    let store: CanvasStore

    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(group.color)
            VStack(alignment: .leading, spacing: 0) {
                titleBar
                Spacer(minLength: 0)
            }
        }
        .frame(width: group.size.width, height: group.displayHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)).opacity(0.6), lineWidth: 1)
        )
        .contentShape(Rectangle())
        // B4：单击组体 → 选中组（显示四角缩放手柄；拖动组体仍为整组平移）
        .onTapGesture { store.selectGroup(id: group.id) }
        // 拖动标题栏 → 整组平移（成员节点同步，连线锚定节点自动跟随）
        .gesture(groupDragGesture)
        // B4：选中且未折叠时显示四角缩放手柄（ComfyUI 风格）
        .overlay {
            if store.selectedGroupID == group.id && !group.isCollapsed {
                resizeHandles
            }
        }
        // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(groupMenuItems(), at: windowPoint)
        })
        .onChange(of: store.renamingGroupID) { _, newValue in
            if newValue == group.id {
                renameDraft = group.title
                Task { @MainActor in renameFocused = true }
            }
        }
        .help("单击选中组（拖角缩放）· 拖动标题栏移动整组 · 右键更多操作")
    }

    // MARK: 标题栏

    private var titleBar: some View {
        HStack(spacing: 6) {
            Button {
                store.toggleGroupCollapsed(id: group.id)
            } label: {
                Image(systemName: group.isCollapsed
                      ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme?.aj38.textSecondary.swiftUIColor ?? Color(nsColor: .secondaryLabelColor))
            .help(group.isCollapsed ? "展开分组" : "折叠分组")
            .accessibilityLabel(group.isCollapsed ? "展开分组" : "折叠分组")
            .accessibilityHint("切换分组内容显示状态")

            if store.renamingGroupID == group.id {
                TextField("分组名称", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { store.endGroupRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && store.renamingGroupID == group.id { commitRename() }
                    }
            } else {
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { store.beginGroupRename(id: group.id) }
                    .help("双击重命名分组")
            }
            Spacer(minLength: 4)
            Text("\(group.nodeIDs.count) 节点")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: CanvasGroup.titleBarHeight)
        .background((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.55))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0,
                                                  bottomTrailingRadius: 0, topTrailingRadius: 10))
    }

    private func commitRename() {
        store.renameGroup(id: group.id, title: renameDraft)
        store.endGroupRename()
    }

    // MARK: 整组拖动

    private var groupDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // translation 为相对拖拽起点的累计位移（缩放层内即世界位移）
                store.moveGroup(id: group.id,
                                by: Point(x: value.translation.width,
                                          y: value.translation.height))
            }
    }

    // MARK: B4 缩放手柄（ComfyUI 风格：选中组后四角拖拽缩放，成员节点按比例跟随）

    /// 手柄边长（世界坐标）
    private static let handleSize = 14.0
    /// 组最小尺寸（世界坐标，防止缩到负尺寸/标题栏以下）
    private static let minGroupSize = CGSize(width: 80, height: 60)

    private enum ResizeCorner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// 拖拽起点快照（translation 是累计位移，必须用「手势开始时的组矩形」计算，否则每帧叠加漂移）
    @State private var resizeStartOrigin: Point?
    @State private var resizeStartSize: CGSize?

    private var resizeHandles: some View {
        ZStack {
            handle(at: .topLeft).position(x: 0, y: 0)
            handle(at: .topRight).position(x: group.size.width, y: 0)
            handle(at: .bottomLeft).position(x: 0, y: group.displayHeight)
            handle(at: .bottomRight).position(x: group.size.width, y: group.displayHeight)
        }
    }

    private func handle(at corner: ResizeCorner) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
            .frame(width: Self.handleSize, height: Self.handleSize)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .contentShape(Rectangle())
            .gesture(resizeGesture(for: corner))
            .help("拖拽缩放分组")
    }

    private func resizeGesture(for corner: ResizeCorner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartOrigin == nil {
                    resizeStartOrigin = group.origin
                    resizeStartSize = group.size
                }
                guard let startOrigin = resizeStartOrigin, let startSize = resizeStartSize else { return }
                let t = value.translation
                var newOrigin = startOrigin
                var newSize = startSize
                switch corner {
                case .bottomRight:
                    newSize = CGSize(width: startSize.width + t.width,
                                     height: startSize.height + t.height)
                case .topLeft:
                    newOrigin = Point(x: startOrigin.x + t.width, y: startOrigin.y + t.height)
                    newSize = CGSize(width: startSize.width - t.width,
                                     height: startSize.height - t.height)
                case .topRight:
                    newOrigin = Point(x: startOrigin.x, y: startOrigin.y + t.height)
                    newSize = CGSize(width: startSize.width + t.width,
                                     height: startSize.height - t.height)
                case .bottomLeft:
                    newOrigin = Point(x: startOrigin.x + t.width, y: startOrigin.y)
                    newSize = CGSize(width: startSize.width - t.width,
                                     height: startSize.height + t.height)
                }
                // 最小尺寸钳制：缩小时反向修正 origin，保证「被拖角」继续跟随鼠标
                let minW = Self.minGroupSize.width, minH = Self.minGroupSize.height
                if newSize.width < minW {
                    if corner == .topLeft || corner == .bottomLeft {
                        newOrigin.x = startOrigin.x + startSize.width - minW
                    }
                    newSize.width = minW
                }
                if newSize.height < minH {
                    if corner == .topLeft || corner == .topRight {
                        newOrigin.y = startOrigin.y + startSize.height - minH
                    }
                    newSize.height = minH
                }
                store.resizeGroup(id: group.id, newOrigin: newOrigin, newSize: newSize)
            }
            .onEnded { _ in
                resizeStartOrigin = nil
                resizeStartSize = nil
            }
    }

    // MARK: 右键菜单

    private func groupMenuItems() -> [FloatingMenuItem] {
        [
            FloatingMenuItem(kind: .button(title: "重命名", icon: "pencil", role: nil, help: nil) { store.beginGroupRename(id: group.id) }),
            FloatingMenuItem(kind: .button(title: group.isCollapsed ? "展开" : "折叠", icon: group.isCollapsed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", role: nil, help: nil) { store.toggleGroupCollapsed(id: group.id) }),
            FloatingMenuItem(kind: .divider),
            // B10：组自定义颜色（10 色预设，当前色打勾）
            FloatingMenuItem(kind: .submenu(title: "颜色", icon: "paintpalette", items: groupColorItems())),
            FloatingMenuItem(kind: .divider),
            FloatingMenuItem(kind: .button(title: "删除分组", icon: "trash", role: .destructive, help: nil) { store.deleteGroup(id: group.id) }),
        ]
    }

    private func groupColorItems() -> [FloatingMenuItem] {
        CanvasGroup.groupColors.map { preset in
            let isCurrent = group.color == preset.color
            return FloatingMenuItem(kind: .button(
                title: preset.name,
                icon: isCurrent ? "checkmark" : nil,
                role: nil,
                help: "将分组颜色设为「\(preset.name)」"
            ) {
                store.changeGroupColor(id: group.id, color: preset.color)
            })
        }
    }
}

// MARK: - 滚轮事件捕获（Cmd+滚轮缩放 / 滚轮平移）

/// 透明 NSView 覆层 + 本地事件监听，拦截画布区域内的滚轮事件。
/// 不参与 hit-testing（allowsHitTesting(false)），不影响节点/端口手势。
struct WheelEventCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void
    var onZoom: (CGFloat, Bool, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, onScroll: onScroll, onZoom: onZoom)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(onScroll: onScroll, onZoom: onZoom)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private weak var view: NSView?
        private var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        private var onZoom: ((CGFloat, Bool, CGPoint) -> Void)?

        /// 滚轮事件的 Sendable 载荷（NSEvent 非 Sendable，跨隔离域只传数值）
        private struct WheelPayload: Sendable {
            let x: Double
            let y: Double
            let dx: Double
            let dy: Double
            let precise: Bool
            let cmd: Bool
        }

        func install(view: NSView,
                     onScroll: @escaping (CGFloat, CGFloat, Bool) -> Void,
                     onZoom: @escaping (CGFloat, Bool, CGPoint) -> Void) {
            self.view = view
            self.onScroll = onScroll
            self.onZoom = onZoom
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                // 只拦截本画布视图内的滚轮；其他视图（侧栏/面板）的事件放行
                guard let view = self.view, view.window != nil, event.window === view.window else {
                    return event
                }
                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local) else { return event }
                let payload = WheelPayload(
                    x: event.locationInWindow.x,
                    y: event.locationInWindow.y,
                    dx: event.scrollingDeltaX,
                    dy: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas,
                    cmd: event.modifierFlags.contains(.command)
                )
                Task { @MainActor in
                    self.route(payload)
                }
                return nil
            }
        }

        func update(onScroll: @escaping (CGFloat, CGFloat, Bool) -> Void,
                    onZoom: @escaping (CGFloat, Bool, CGPoint) -> Void) {
            self.onScroll = onScroll
            self.onZoom = onZoom
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func route(_ payload: WheelPayload) {
            guard let view, view.window != nil else { return }
            let local = view.convert(CGPoint(x: payload.x, y: payload.y), from: nil)
            guard view.bounds.contains(local) else { return }
            if payload.cmd {
                onZoom?(payload.dy, payload.precise, local)
            } else {
                onScroll?(payload.dx, payload.dy, payload.precise)
            }
        }
    }
}

// MARK: - 键盘快捷键捕获（C5：⌘C 复制 / ⌘V 粘贴 / ⌘D 删除 / ⌘Z 撤销）
//
// 本地 keyDown 监听（同 WheelEventCatcher 模式）：仅当画布窗口为 key、焦点不在文本输入
// （TextField/TextEditor 的 field editor 是 NSTextView，此时放行给系统文本编辑）、
// 画布有选中节点（无选中时 Delete/⌘C/⌘D 不吞事件）、且修饰键为「纯 ⌘」时拦截
// ⌘C/⌘V/⌘D/⌘Z——不抢聊天框/搜索面板/内容编辑器里的文本复制粘贴。
// AJ-64/65：判定逻辑收敛到 CanvasKeyboardCatcher.shouldHandle 纯函数（可单测）。

struct CanvasKeyboardCatcher: NSViewRepresentable {
    /// AJ-64/65：画布当前是否有选中节点。无选中时 Delete/⌘D/⌘C 不拦截（事件放行给系统）。
    var hasSelection: Bool
    var onCopy: () -> Void
    /// 粘贴回调：参数为画布本地坐标；鼠标不在画布上（工具栏/侧栏/窗口外）时传 nil，
    /// 由 CanvasView 改用视口中心作落点，避免把节点贴到画布外。
    var onPaste: (CGPoint?) -> Void
    var onDelete: () -> Void
    var onUndo: () -> Void
    var onSelectAll: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, hasSelection: hasSelection,
                                    onCopy: onCopy, onPaste: onPaste,
                                    onDelete: onDelete, onUndo: onUndo,
                                    onSelectAll: onSelectAll, onEscape: onEscape)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(hasSelection: hasSelection,
                                   onCopy: onCopy, onPaste: onPaste,
                                   onDelete: onDelete, onUndo: onUndo,
                                   onSelectAll: onSelectAll, onEscape: onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - AJ-64/65 键盘事件纯逻辑判定（可单测，无 NSEvent 依赖）

    /// 画布应响应的键盘动作；nil = 放行（不吞事件，交给系统/文本编辑）。
    enum CanvasKeyAction: Equatable {
        case escape
        case delete
        case copy
        case paste
        case undo
        case selectAll
    }

    /// 简化修饰键状态（自 NSEvent.modifierFlags 提取为纯值类型，便于单测构造）。
    struct CanvasKeyModifiers: Equatable {
        var command: Bool = false
        var shift: Bool = false
        var option: Bool = false
        var control: Bool = false

        static func from(_ flags: NSEvent.ModifierFlags) -> CanvasKeyModifiers {
            CanvasKeyModifiers(
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.option),
                control: flags.contains(.control)
            )
        }

        /// 恰好为「纯 ⌘」：仅 command，无其他修饰
        var isPureCommand: Bool { command && !shift && !option && !control }
        /// 完全无修饰键（裸键）
        var isEmpty: Bool { !command && !shift && !option && !control }
    }

    /// 键盘删除键判定：裸 Delete/Backspace（keyCode 51）与 fn-Delete（keyCode 117）。
    static func isDeleteKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 51 || keyCode == 117
    }

    /// 键盘诊断日志（debug 级，仅命中/放行时记录，正常文本输入零记录）。
    private static let keyboardLog = Logger(subsystem: "com.miniscanvas.keyboard", category: "catcher")

    /// 画布热键判定（诊断用）：Delete/⌘C/⌘V/⌘D/⌘Z/⌘A/Esc ——「画布可能消费但被放行」时记录，
    /// 用于区分事件未到达 monitor 与判定放行两种失效路径。
    static func isCanvasHotKey(keyCode: UInt16, characters: String?, modifiers: CanvasKeyModifiers) -> Bool {
        if isDeleteKeyCode(keyCode) { return true }
        if keyCode == 53 { return true } // Esc
        if modifiers.command, let ch = characters?.lowercased(), ["c", "v", "d", "z", "a"].contains(ch) {
            return true
        }
        return false
    }

    /// AJ-64/65 焦点守卫判定（纯函数，可单测）：
    /// - 焦点在文本输入框（isTextEditing）→ 一律放行：Delete/⌘C/⌘V 交还系统文本编辑，画布不吞。
    /// - 无选中节点（hasSelection == false）→ Delete/⌘D/⌘C 放行（不吞、无效）。
    /// - 裸 Delete / fn-Delete：无修饰或仅 ⌘ 时删除选中；含 ⌥/⌃/⇧（删词/删行/扩展选择）放行。
    /// - 纯 ⌘ + c/v/d/z/a → 复制/粘贴/删除/撤销/全选。
    static func shouldHandle(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: CanvasKeyModifiers,
        hasSelection: Bool,
        isTextEditing: Bool
    ) -> CanvasKeyAction? {
        // 焦点守卫：文本输入框 firstResponder → 画布不拦截任何键
        if isTextEditing { return nil }
        // Esc（keyCode 53）：无修饰键 → 取消选择
        if keyCode == 53 && modifiers.isEmpty { return .escape }
        // 裸 Delete / Backspace（51）与 fn-Delete（117）：无修饰或仅 ⌘；
        // 含 ⌥/⌃/⇧（删词/删行/扩展选择等系统语义）放行；无选中不吞（放行系统默认行为）
        if isDeleteKeyCode(keyCode) {
            guard modifiers.isEmpty || modifiers.isPureCommand else { return nil }
            return hasSelection ? .delete : nil
        }
        // 纯 ⌘ 组合键
        guard modifiers.isPureCommand else { return nil }
        switch charactersIgnoringModifiers?.lowercased() {
        case "c": return hasSelection ? .copy : nil
        case "v": return .paste
        case "d": return hasSelection ? .delete : nil
        case "z": return .undo
        case "a": return .selectAll
        default: return nil
        }
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private weak var view: NSView?
        private var hasSelection: Bool = false
        private var onCopy: (() -> Void)?
        private var onPaste: ((CGPoint?) -> Void)?
        private var onDelete: (() -> Void)?
        private var onUndo: (() -> Void)?
        private var onSelectAll: (() -> Void)?
        private var onEscape: (() -> Void)?

        func install(view: NSView,
                     hasSelection: Bool,
                     onCopy: @escaping () -> Void,
                     onPaste: @escaping (CGPoint?) -> Void,
                     onDelete: @escaping () -> Void,
                     onUndo: @escaping () -> Void,
                     onSelectAll: @escaping () -> Void,
                     onEscape: @escaping () -> Void) {
            self.view = view
            self.hasSelection = hasSelection
            self.onCopy = onCopy
            self.onPaste = onPaste
            self.onDelete = onDelete
            self.onUndo = onUndo
            self.onSelectAll = onSelectAll
            self.onEscape = onEscape
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let view = self.view, view.window != nil, event.window === view.window else {
                    return event
                }
                // AJ-64/65：判定逻辑收敛到纯函数 shouldHandle——
                // 文本输入焦点（field editor 为 NSText）一律放行（Delete 不误删节点、
                // ⌘C/⌘V 走系统文本复制粘贴）；无选中节点时 Delete/⌘C/⌘D 不吞事件。
                let isTextEditing = view.window?.firstResponder is NSText
                let action = CanvasKeyboardCatcher.shouldHandle(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifiers: CanvasKeyboardCatcher.CanvasKeyModifiers.from(event.modifierFlags),
                    hasSelection: self.hasSelection,
                    isTextEditing: isTextEditing
                )
                // 键盘诊断（debug 级，仅画布窗口 keyDown）：画布动作命中 → 记录 action；
                // 画布热键（Delete/⌘C/⌘V/⌘D/⌘Z/⌘A/Esc）被放行 → 记录 RELEASED + 上下文。
                // 复测「⌘C/⌘V/Delete 无反应」时 log show 即可区分：
                // 无记录 = 事件未到达 monitor（窗口/焦点层问题）；RELEASED = 判定放行（选中态/焦点问题）。
                if action != nil {
                    CanvasKeyboardCatcher.keyboardLog.debug(
                        "canvas action=\(String(describing: action), privacy: .public) hasSelection=\(self.hasSelection) isTextEditing=\(isTextEditing) keyCode=\(event.keyCode)")
                } else if CanvasKeyboardCatcher.isCanvasHotKey(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers,
                    modifiers: CanvasKeyboardCatcher.CanvasKeyModifiers.from(event.modifierFlags)
                ) {
                    CanvasKeyboardCatcher.keyboardLog.debug(
                        "canvas hotkey RELEASED keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "nil", privacy: .public) hasSelection=\(self.hasSelection) isTextEditing=\(isTextEditing)")
                }
                guard let action else { return event }
                switch action {
                case .escape:
                    Task { @MainActor in self.onEscape?() }
                case .delete:
                    Task { @MainActor in self.onDelete?() }
                case .copy:
                    Task { @MainActor in self.onCopy?() }
                case .paste:
                    // 粘贴落点：鼠标在画布上 → 传画布本地坐标；鼠标在画布外
                    // （工具栏/侧栏/窗口外，convert 后出 bounds）→ 传 nil，由 CanvasView
                    // 改用视口中心，避免把节点贴到画布外导致"粘贴后看不到"。
                    let windowPoint = view.window?.convertPoint(fromScreen: NSEvent.mouseLocation)
                    let local = windowPoint.map { view.convert($0, from: nil) }
                    let inCanvas = local.map { view.bounds.contains($0) } ?? false
                    Task { @MainActor in self.onPaste?(inCanvas ? local : nil) }
                case .undo:
                    Task { @MainActor in self.onUndo?() }
                case .selectAll:
                    Task { @MainActor in self.onSelectAll?() }
                }
                return nil
            }
        }

        func update(hasSelection: Bool,
                    onCopy: @escaping () -> Void,
                    onPaste: @escaping (CGPoint?) -> Void,
                    onDelete: @escaping () -> Void,
                    onUndo: @escaping () -> Void,
                    onSelectAll: @escaping () -> Void,
                    onEscape: @escaping () -> Void) {
            self.hasSelection = hasSelection
            self.onCopy = onCopy
            self.onPaste = onPaste
            self.onDelete = onDelete
            self.onUndo = onUndo
            self.onSelectAll = onSelectAll
            self.onEscape = onEscape
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - F12-⑥ 右键「添加节点」菜单（NodeTypeRegistry.specs 分组，在右键位置创建）

/// 右键菜单分组图标（半透明浮动菜单 submenu 用）
private func groupIcon(for group: NodePaletteGroup) -> String {
    switch group {
    case .basic: return "square.grid.2x2"
    case .manjuFlow: return "flowchart"
    case .manjuTools: return "wrench.and.screwdriver"
    }
}

// MARK: - F12-④ 节点结果媒体预览（图片大图 / 视频播放器）

/// 预览 sheet：图片 → 原图自适应大图；视频 → AVPlayer 播放。
/// 结果媒体读取与缩略图同源（store.resultMedia），无结果时显示占位提示。
struct NodeMediaPreviewView: View {
    let nodeID: UUID
    let store: CanvasStore

    // B8：图片预览缩放状态（滚轮/捏合缩放 + 拖拽平移，双击还原）
    @State private var previewZoom: CGFloat = 1.0
    @State private var previewPan: CGSize = .zero
    @State private var lastPreviewZoom: CGFloat = 1.0
    @State private var previewPanStart: CGSize = .zero

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            if let media = store.resultMedia(of: nodeID) {
                if media.kind == "video" {
                    // AVPlayerContainerView：规避 SwiftUI VideoPlayer 在 macOS 26.5.2 的
                    // _AVKit_SwiftUI 泛型元数据初始化崩溃（getSuperclassMetadata → abort）。
                    AVPlayerContainerView(url: mediaURL(media.path))
                        .frame(minWidth: 560, minHeight: 380)
                } else if let nsImage = store.cachedImage(path: media.path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(previewZoom)
                        .offset(previewPan)
                        .frame(maxWidth: 760, maxHeight: 560)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    previewZoom = min(max(lastPreviewZoom * value, 1.0), 8.0)
                                }
                                .onEnded { _ in
                                    lastPreviewZoom = previewZoom
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    previewPan = CGSize(
                                        width: previewPanStart.width + value.translation.width,
                                        height: previewPanStart.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    previewPanStart = previewPan
                                }
                        )
                        .onTapGesture(count: 2) {
                            previewZoom = 1.0
                            lastPreviewZoom = 1.0
                            previewPan = .zero
                            previewPanStart = .zero
                        }
                        .help("捏合缩放 · 拖拽平移 · 双击还原")
                } else {
                    placeholder("图片文件无法读取")
                }
            } else {
                placeholder("该节点暂无结果媒体")
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 460)
    }

    /// 结果路径可能是本地路径或 URL（视频执行结果为 URL 字符串）
    private func mediaURL(_ path: String) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.inset.filled.and.person.standing")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.graph.node(id: nodeID)?.title ?? "节点")
                    .font(.system(size: 14, weight: .semibold))
                Text("结果预览")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("关闭") { store.closePreview() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
