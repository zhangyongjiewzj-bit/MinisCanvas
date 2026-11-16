import SwiftUI
import AppKit
import CanvasCore

// MARK: - 无限画布（A2-v05 transform 模式）

/// 画布主体：pan(平移) + scaleEffect(缩放) 变换模式，替代 ScrollView 布局缩放。
/// - 缩放：Cmd+滚轮（光标锚点）+ 触控板捏合，范围 0.2x~3.0x，平滑动画
/// - 平移：拖拽空白 / 双指滚轮，边界松（±60% 画布尺寸）
/// - 框选：Shift+拖拽空白多选
/// - 性能：节点/连线按可见区裁剪（只渲染视口内），缩放只改变换不重排布局
struct CanvasView: View {
    let store: CanvasStore

    /// 逻辑画布尺寸（无限画布 ≈ 足够大的固定画布）
    private let canvasWidth = 4000.0
    private let canvasHeight = 4000.0

    /// 缩放范围
    private let minZoom = 0.2
    private let maxZoom = 3.0

    @State private var zoom: Double = 1.0
    @State private var lastZoom: Double = 1.0
    /// 视口内平移偏移（屏幕坐标）
    @State private var pan: CGPoint = .zero
    /// 拖拽平移起点
    @State private var dragPanStart: CGPoint?
    /// Shift 框选中
    @State private var boxSelecting = false
    /// 框选矩形（逻辑坐标）
    @State private var selectionRect: CGRect?
    /// 悬停端口（连线/端口高亮）
    @State private var hoveredPort: PortRef?
    /// 节点拖拽起点
    @State private var dragStart: Point?
    /// 视口尺寸（用于光标锚点缩放与可见区裁剪）
    @State private var viewportSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CanvasTheme.background
                    .ignoresSafeArea()

                worldLayer
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(x: pan.x, y: pan.y)

                if let rect = selectionRect {
                    selectionOverlay(rect)
                }
                emptyHint
                zoomBadge
            }
            .contentShape(Rectangle())
            .onTapGesture { store.deselectAll() }
            .onTapGesture(count: 2) { restoreView() }
            .gesture(backgroundDragGesture)
            .gesture(magnificationGesture)
            .onAppear { viewportSize = geo.size }
            .onChange(of: geo.size) { _, newSize in viewportSize = newSize }
            .onChange(of: store.fitRequestID) { _, _ in
                fitToContent()
            }
            .overlay(
                WheelEventCatcher(
                    onScroll: { dx, dy, precise in handleWheelScroll(dx: dx, dy: dy, precise: precise) },
                    onZoom: { dy, precise, anchor in handleWheelZoom(dy: dy, precise: precise, anchor: anchor) }
                )
                .allowsHitTesting(false)
            )
        }
        .clipped()
    }

    // MARK: 世界层（逻辑坐标，整体变换）

    private var worldLayer: some View {
        ZStack {
            gridLayer
            edgesLayer
            nodesLayer
            pendingEdgeLayer
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    // MARK: 缩放

    private func clampZoom(_ z: Double) -> Double {
        min(max(z, minZoom), maxZoom)
    }

    /// 应用缩放：可选光标锚点（保持锚点下逻辑点不动），可选平滑动画
    private func applyZoom(_ newZoom: Double, anchor: CGPoint? = nil, animated: Bool = true) {
        let clamped = clampZoom(newZoom)
        guard abs(clamped - zoom) > 0.0001 else { return }
        let update = {
            if let anchor, zoom > 0.0001 {
                let logical = CGPoint(x: (anchor.x - pan.x) / zoom, y: (anchor.y - pan.y) / zoom)
                pan = clampPan(CGPoint(x: anchor.x - logical.x * clamped,
                                       y: anchor.y - logical.y * clamped))
            }
            zoom = clamped
        }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { update() }
        } else {
            update()
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let anchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                applyZoom(lastZoom * value, anchor: anchor, animated: false)
            }
            .onEnded { _ in
                lastZoom = zoom
            }
    }

    /// Cmd+滚轮缩放（dy>0 向上滚动 → 放大）
    private func handleWheelZoom(dy: CGFloat, precise: Bool, anchor: CGPoint) {
        guard dy != 0 else { return }
        let normalized = precise ? dy : dy * 10
        let factor = pow(1.01, normalized)
        applyZoom(zoom * factor, anchor: anchor, animated: true)
    }

    /// 滚轮平移（双指滚动自带系统惯性；拖拽平移惯性成本高，暂不实现）
    private func handleWheelScroll(dx: CGFloat, dy: CGFloat, precise: Bool) {
        let factor = precise ? 1.0 : 12.0
        pan = clampPan(CGPoint(x: pan.x + dx * factor, y: pan.y + dy * factor))
    }

    /// 边界松：允许平移到画布 ±60% 范围
    private func clampPan(_ p: CGPoint) -> CGPoint {
        let limitX = canvasWidth * zoom * 0.6
        let limitY = canvasHeight * zoom * 0.6
        return CGPoint(x: min(max(p.x, -limitX), limitX),
                       y: min(max(p.y, -limitY), limitY))
    }

    /// 双击空白恢复视图：有内容 → 居中缩放到全图；空画布 → 复位 100% 原点。
    /// 缩放边界已由 clampZoom（0.2x~3.0x）兜底，双击是手动回到可读视图的快捷方式。
    private func restoreView() {
        if !store.graph.nodes.isEmpty {
            fitToContent()
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                zoom = 1.0
                pan = .zero
            }
        }
    }

    // MARK: 自动缩放全图（M1h：模板生成后 fit bounds）

    /// 计算全部节点包围盒，按视口比例缩放并居中（含节点高度，留 15% 边距）。
    /// 空画布 / 视口未就绪时跳过；缩放范围仍受 minZoom/maxZoom 约束。
    private func fitToContent() {
        let nodes = store.graph.nodes
        guard !nodes.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for node in nodes {
            let height = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + NodeMetrics.nodeWidth)
            maxY = max(maxY, node.position.y + height)
        }
        let boundsWidth = max(maxX - minX, 240)
        let boundsHeight = max(maxY - minY, 140)
        let targetZoom = clampZoom(
            min(viewportSize.width / boundsWidth, viewportSize.height / boundsHeight) * 0.85
        )
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        withAnimation(.easeOut(duration: 0.25)) {
            zoom = targetZoom
            // 屏幕坐标 = 逻辑坐标 × zoom + pan → pan 使包围盒中心对齐视口中心
            pan = clampPan(CGPoint(x: viewportSize.width / 2 - centerX * targetZoom,
                                   y: viewportSize.height / 2 - centerY * targetZoom))
        }
    }

    // MARK: 背景手势（空白拖拽平移 / Shift 框选）

    private var backgroundDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if selectionRect == nil && dragPanStart == nil {
                    boxSelecting = NSEvent.modifierFlags.contains(.shift)
                    if !boxSelecting { dragPanStart = pan }
                }
                if boxSelecting {
                    let start = CGPoint(x: (value.startLocation.x - pan.x) / zoom,
                                        y: (value.startLocation.y - pan.y) / zoom)
                    let cur = CGPoint(x: (value.location.x - pan.x) / zoom,
                                      y: (value.location.y - pan.y) / zoom)
                    selectionRect = CGRect(x: min(start.x, cur.x), y: min(start.y, cur.y),
                                           width: abs(cur.x - start.x), height: abs(cur.y - start.y))
                } else if let start = dragPanStart {
                    pan = clampPan(CGPoint(x: start.x + value.translation.width,
                                           y: start.y + value.translation.height))
                }
            }
            .onEnded { _ in
                if boxSelecting, let rect = selectionRect {
                    store.selectNodes(in: rect, additive: NSEvent.modifierFlags.contains(.shift))
                }
                selectionRect = nil
                boxSelecting = false
                dragPanStart = nil
            }
    }

    private func selectionOverlay(_ rect: CGRect) -> some View {
        let viewRect = CGRect(x: rect.minX * zoom + pan.x, y: rect.minY * zoom + pan.y,
                              width: rect.width * zoom, height: rect.height * zoom)
        return Rectangle()
            .fill(CanvasTheme.accent.opacity(0.12))
            .overlay(Rectangle().stroke(CanvasTheme.accent, lineWidth: 1))
            .frame(width: viewRect.width, height: viewRect.height)
            .position(x: viewRect.midX, y: viewRect.midY)
    }

    // MARK: 可见区裁剪（50+ 节点性能）

    /// 视口对应的逻辑坐标矩形（外扩 200 逻辑像素缓冲，避免边缘闪烁）
    private var visibleLogicalRect: CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        }
        return CGRect(x: -pan.x / zoom, y: -pan.y / zoom,
                      width: viewportSize.width / zoom, height: viewportSize.height / zoom)
            .insetBy(dx: -200, dy: -200)
    }

    private var visibleNodes: [CanvasNode] {
        let rect = visibleLogicalRect
        return store.graph.nodes.filter { node in
            let frame = CGRect(x: node.position.x, y: node.position.y,
                               width: NodeMetrics.nodeWidth,
                               height: NodeMetrics.nodeHeight(inputs: node.inputs.count,
                                                              outputs: node.outputs.count))
            return frame.intersects(rect)
        }
    }

    private var visibleEdges: [CanvasCore.Edge] {
        let visibleIDs = Set(visibleNodes.map(\.id))
        return store.graph.edges.filter {
            visibleIDs.contains($0.fromNode) || visibleIDs.contains($0.toNode)
        }
    }

    // MARK: 网格背景

    private var gridLayer: some View {
        Canvas { context, size in
            let minor = 48.0
            let major = 240.0
            var minorPath = Path()
            var x = 0.0
            while x <= size.width {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += minor
            }
            var y = 0.0
            while y <= size.height {
                minorPath.move(to: CGPoint(x: 0, y: y))
                minorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += minor
            }
            context.stroke(minorPath, with: .color(CanvasTheme.gridMinor), lineWidth: 1)

            var majorPath = Path()
            x = 0.0
            while x <= size.width {
                majorPath.move(to: CGPoint(x: x, y: 0))
                majorPath.addLine(to: CGPoint(x: x, y: size.height))
                x += major
            }
            y = 0.0
            while y <= size.height {
                majorPath.move(to: CGPoint(x: 0, y: y))
                majorPath.addLine(to: CGPoint(x: size.width, y: y))
                y += major
            }
            context.stroke(majorPath, with: .color(CanvasTheme.gridMajor), lineWidth: 1)
        }
    }

    // MARK: 连线层（贝塞尔 + 选中/悬停高亮）

    private var edgesLayer: some View {
        // 性能：一次性建 [UUID: CanvasNode] 查找字典，避免每条边两次 O(N) 的 node(id:) 线性扫描
        let nodesByID = Dictionary(uniqueKeysWithValues: store.graph.nodes.map { ($0.id, $0) })
        return ForEach(visibleEdges) { edge in
            EdgeCurve(edge: edge, nodesByID: nodesByID, store: store, isHighlighted: isEdgeHighlighted(edge))
        }
    }

    private func isEdgeHighlighted(_ edge: CanvasCore.Edge) -> Bool {
        if !store.selectedNodeIDs.isEmpty {
            if store.selectedNodeIDs.contains(edge.fromNode) || store.selectedNodeIDs.contains(edge.toNode) {
                return true
            }
        }
        if let hovered = hoveredPort {
            return edge.fromPort == hovered.portID || edge.toPort == hovered.portID
        }
        return false
    }

    // MARK: 节点层

    private var nodesLayer: some View {
        ForEach(visibleNodes) { node in
            NodeView(node: node, store: store,
                     isSelected: store.selectedNodeIDs.contains(node.id),
                     hoveredPort: hoveredPort,
                     setHoveredPort: { hoveredPort = $0 })
                .position(x: node.position.x, y: node.position.y)
                .gesture(nodeDragGesture(for: node))
        }
    }

    // MARK: 拖拽中的临时连线

    @ViewBuilder
    private var pendingEdgeLayer: some View {
        if let pending = store.pendingEdge,
           let fromNode = store.graph.node(id: pending.fromNode),
           let fromPort = fromNode.outputs.first(where: { $0.id == pending.fromPort }) {
            let from = store.portAnchor(for: fromNode, port: fromPort)
            Path { p in
                p.move(to: CGPoint(x: from.x, y: from.y))
                p.addCurve(to: CGPoint(x: pending.end.x, y: pending.end.y),
                           control1: CGPoint(x: from.x + 60, y: from.y),
                           control2: CGPoint(x: pending.end.x - 60, y: pending.end.y))
            }
            .stroke(CanvasTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
        }
    }

    // MARK: 空画布提示

    @ViewBuilder
    private var emptyHint: some View {
        if store.graph.nodes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 40))
                    .foregroundStyle(CanvasTheme.textSecondary.opacity(0.5))
                Text("从左侧面板添加节点，开始搭建工作流")
                    .font(.system(size: 14))
                    .foregroundStyle(CanvasTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 缩放指示（点击复位 100%）

    private var zoomBadge: some View {
        Text("\(Int(zoom * 100))%")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CanvasTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(CanvasTheme.nodeBackground.opacity(0.9)))
            .overlay(Capsule().stroke(CanvasTheme.nodeBorder, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = 1.0
                    pan = .zero
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(12)
    }

    // MARK: 节点拖拽（变换模式下 translation 即逻辑坐标）

    private func nodeDragGesture(for node: CanvasNode) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = store.graph.node(id: node.id)?.position
                }
                guard let start = dragStart else { return }
                store.moveNode(
                    id: node.id,
                    to: Point(x: start.x + value.translation.width,
                              y: start.y + value.translation.height)
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}

// MARK: - 端口引用（悬停高亮用）

struct PortRef: Equatable {
    let nodeID: UUID
    let portID: UUID
}

// MARK: - 节点视图（A2-v05：深色卡片 + 状态色条 + 端口悬停）

struct NodeView: View {
    let node: CanvasNode
    let store: CanvasStore
    let isSelected: Bool
    let hoveredPort: PortRef?
    let setHoveredPort: (PortRef?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CanvasTheme.nodeBorder)
            portsRow
            resultThumbnail
        }
        .frame(width: NodeMetrics.nodeWidth)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(CanvasTheme.nodeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .overlay(alignment: .leading) {
            statusStrip
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(isSelected ? 0.5 : 0.3),
                radius: isSelected ? 10 : 6, y: 2)
        .onTapGesture { store.presentModelPanel(for: node.id) }
        .onTapGesture(count: 2) { store.presentModelPanel(for: node.id) }
        .contextMenu {
            // M1f 任务单模式：生图/生视频节点右键一键复制任务单提示词
            if let ticket = store.jobTicket(for: node.id) {
                Button {
                    store.copyPrompt(ticket)
                } label: {
                    Label("复制任务单提示词（\(ticket.slotCount) 槽）", systemImage: "doc.on.doc")
                }
                Divider()
            }
            Button {
                store.runToNode(node.id)
            } label: {
                Label("执行到此处", systemImage: "arrow.down.to.line")
            }
            .disabled(store.isRunning)
            Button {
                store.resetNodeStatus(node.id)
            } label: {
                Label("重置状态", systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button(role: .destructive) {
                store.removeNode(id: node.id)
            } label: {
                Label("删除节点", systemImage: "trash")
            }
        }
    }

    /// 左边缘状态色条（pending 半透明，运行/成功/失败高亮）
    private var statusStrip: some View {
        Rectangle()
            .fill(node.status.color)
            .frame(width: 4)
            .opacity(node.status == .pending ? 0.5 : 1)
    }

    // MARK: 模型徽标（右上角，未配置显示"默认"）

    private var modelBadge: some View {
        let text: String
        if let config = node.backendConfig, !config.modelID.isEmpty {
            text = config.badgeShortName
        } else {
            text = "默认"
        }
        return Text(text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .systemYellow).opacity(0.16)))
            .foregroundStyle(Color(nsColor: .systemYellow))
    }

    // MARK: 失败错误角标（失败节点显示 ⚠️，悬停可见错误信息）

    @ViewBuilder
    private var errorBadge: some View {
        if let error = store.nodeErrors[node.id] {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color(nsColor: .systemRed))
                .help(error)
        }
    }

    /// 边框色：失败节点恒红（高亮）；选中时用状态色；否则主题边框灰
    private var borderColor: Color {
        if node.status == .failed { return Color(nsColor: .systemRed) }
        if isSelected { return node.status.color }
        return CanvasTheme.nodeBorder
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(node.status.color)
                .frame(width: 8, height: 8)
            Text(node.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CanvasTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            modelBadge
            errorBadge
            Text(node.status.label)
                .font(.system(size: 9))
                .foregroundStyle(node.status.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: NodeMetrics.headerHeight)
        .background(CanvasTheme.headerBackground)
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

    // MARK: 导入结果缩略图（M1f：任务单模式结果回填显示）

    /// 节点底部显示导入的结果：图片 → 缩略图，视频 → 胶片图标 + 文件名。
    @ViewBuilder
    private var resultThumbnail: some View {
        if let path = node.backendConfig?.params["result.path"],
           let kind = node.backendConfig?.params["result.kind"] {
            HStack(spacing: 6) {
                if kind == "image", let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: kind == "video" ? "film.fill" : "photo.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(CanvasTheme.nodeBorder.opacity(0.5))
                        )
                }
                Text(node.backendConfig?.params["result.name"]
                     ?? (path as NSString).lastPathComponent)
                    .font(.system(size: 9))
                    .foregroundStyle(CanvasTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .help(path)
        }
    }

    @ViewBuilder
    private func portRow(port: CanvasCore.Port, leadingDot: Bool) -> some View {
        let row = HStack(spacing: 6) {
            if leadingDot { dot(port) }
            Text(port.name)
                .font(.system(size: 11))
                .foregroundStyle(CanvasTheme.textSecondary)
                .lineLimit(1)
            if !leadingDot { dot(port) }
        }
        .frame(height: NodeMetrics.rowHeight)
        .contentShape(Rectangle())
        // 只允许从输出端口拖出连线（输入端口是连线落点，不发起拖线）
        if port.direction == .output {
            row.gesture(connectDragGesture(for: port))
        } else {
            row
        }
    }

    /// 端口圆点（悬停放大 + 光环，作为连线高亮锚点）
    private func dot(_ port: CanvasCore.Port) -> some View {
        let isHovered = hoveredPort == PortRef(nodeID: node.id, portID: port.id)
        return Circle()
            .fill(portColor(port))
            .frame(width: isHovered ? 12 : 9, height: isHovered ? 12 : 9)
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: portColor(port).opacity(isHovered ? 0.8 : 0), radius: isHovered ? 5 : 0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                setHoveredPort(hovering ? PortRef(nodeID: node.id, portID: port.id) : nil)
            }
    }

    private func portColor(_ port: CanvasCore.Port) -> Color {
        switch port.dataType {
        case "string": return Color(nsColor: .systemOrange)
        case "image": return Color(nsColor: .systemPurple)
        case "video": return Color(nsColor: .systemPink)
        default: return Color(nsColor: .systemTeal)
        }
    }

    // MARK: 端口拖拽 → 连线（变换模式下 location 即逻辑坐标）

    private func connectDragGesture(for port: CanvasCore.Port) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let anchor = store.portAnchor(for: node, port: port)
                let point = Point(x: anchor.x + value.location.x,
                                  y: anchor.y + value.location.y)
                if store.pendingEdge == nil {
                    store.beginEdge(from: node.id, portID: port.id, at: point)
                } else {
                    store.updateEdgeEnd(point)
                }
            }
            .onEnded { value in
                let anchor = store.portAnchor(for: node, port: port)
                let point = Point(x: anchor.x + value.location.x,
                                  y: anchor.y + value.location.y)
                store.endEdge(at: point)
            }
    }
}

// MARK: - 贝塞尔连线（选中/悬停高亮）

struct EdgeCurve: View {
    let edge: CanvasCore.Edge
    /// 节点查找字典（CanvasView 每帧建一次，避免每条边两次 O(N) 查找）
    let nodesByID: [UUID: CanvasNode]
    let store: CanvasStore
    let isHighlighted: Bool

    /// 贝塞尔路径缓存：key = 边 id，值记录起终点；节点移动后起终点变化自动失效重算。
    /// 拖节点时只有相邻边重算路径，其余边直接命中缓存（50+ 节点场景省掉每帧全量 Path 重建）。
    nonisolated(unsafe) private static var pathCache: [UUID: (from: Point, to: Point, path: Path)] = [:]
    private static let pathCacheLimit = 2000

    var body: some View {
        if let fromNode = nodesByID[edge.fromNode],
           let toNode = nodesByID[edge.toNode],
           let fromPort = fromNode.outputs.first(where: { $0.id == edge.fromPort }),
           let toPort = toNode.inputs.first(where: { $0.id == edge.toPort }) {
            let from = store.portAnchor(for: fromNode, port: fromPort)
            let to = store.portAnchor(for: toNode, port: toPort)
            let path = Self.cachedPath(for: edge, from: from, to: to)
            let color = strokeColor(fromNode)

            let stroked = path.stroke(
                color,
                style: StrokeStyle(lineWidth: isHighlighted ? 3 : 1.5, lineCap: .round)
            )
            // 高亮时才加阴影（阴影走 GPU 离屏渲染，常态下省掉）
            if isHighlighted {
                stroked
                    .shadow(color: color.opacity(0.7), radius: 4)
                    .contentShape(path.strokedPath(StrokeStyle(lineWidth: 12)))
                    .onTapGesture {
                        store.removeEdge(id: edge.id)
                    }
            } else {
                stroked
                    .contentShape(path.strokedPath(StrokeStyle(lineWidth: 12)))
                    .onTapGesture {
                        store.removeEdge(id: edge.id)
                    }
            }
        }
    }

    /// 缓存查询 + 重建：起终点不变直接复用 Path
    private static func cachedPath(for edge: CanvasCore.Edge, from: Point, to: Point) -> Path {
        if let hit = pathCache[edge.id], hit.from == from, hit.to == to {
            return hit.path
        }
        let dx = max(abs(to.x - from.x) * 0.5, 50.0)
        let path = Path { p in
            p.move(to: CGPoint(x: from.x, y: from.y))
            p.addCurve(
                to: CGPoint(x: to.x, y: to.y),
                control1: CGPoint(x: from.x + dx, y: from.y),
                control2: CGPoint(x: to.x - dx, y: to.y)
            )
        }
        if pathCache.count >= pathCacheLimit { pathCache.removeAll(keepingCapacity: true) }
        pathCache[edge.id] = (from, to, path)
        return path
    }

    /// 连线色：高亮用状态色；运行/成功/失败节点用状态色；默认主题灰
    private func strokeColor(_ fromNode: CanvasNode) -> Color {
        if isHighlighted { return fromNode.status.color }
        switch fromNode.status {
        case .succeeded, .running, .failed:
            return fromNode.status.color.opacity(0.85)
        default:
            return CanvasTheme.edge
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

// MARK: - 深色主题（背景 #14181C）

enum CanvasTheme {
    /// 画布背景 #14181C
    static let background = Color(red: 20.0 / 255.0, green: 24.0 / 255.0, blue: 28.0 / 255.0)
    /// 节点卡片底色（略亮于背景）
    static let nodeBackground = Color(red: 31.0 / 255.0, green: 36.0 / 255.0, blue: 43.0 / 255.0)
    /// 卡片边框
    static let nodeBorder = Color(red: 52.0 / 255.0, green: 60.0 / 255.0, blue: 70.0 / 255.0)
    /// 标题栏底色（半透明白叠加深色卡片）
    static let headerBackground = Color(white: 1, opacity: 0.04)
    /// 主文字
    static let textPrimary = Color(white: 0.93)
    /// 次要文字
    static let textSecondary = Color(white: 0.62)
    /// 网格（细）
    static let gridMinor = Color(white: 1, opacity: 0.045)
    /// 网格（粗）
    static let gridMajor = Color(white: 1, opacity: 0.08)
    /// 默认连线色
    static let edge = Color(red: 0.42, green: 0.47, blue: 0.55)
    /// 强调色（框选/拖拽连线）
    static let accent = Color(red: 0.30, green: 0.63, blue: 1.0)
}
