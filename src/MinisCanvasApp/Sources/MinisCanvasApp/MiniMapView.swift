import SwiftUI
import AppKit
import CanvasCore

// MARK: - 画布 minimap（AJ-16：右下角小地图，参照 ComfyUI minimap）
// 纯几何逻辑（可单测）+ 视图渲染 + 视口跳转 + 开关。

/// minimap 几何（纯值类型，可单测）：内容包围盒 → 小地图缩放/偏移 → 视口矩形映射。
/// 世界坐标 ↔ 小地图坐标双向换算；点击跳转视口为静态纯函数，便于单元测试。
struct MiniMapGeometry: Equatable {
    /// 小地图画布尺寸（点）
    let mapSize: CGSize
    /// 内容包围盒（世界坐标，含全部节点；空画布为 nil）
    let contentBounds: CGRect?

    /// 内容 → 小地图缩放（保持纵横比 fit；无内容回退 1 防 NaN）
    var scale: CGFloat {
        guard let b = contentBounds, b.width > 0, b.height > 0 else { return 1 }
        return min(mapSize.width / b.width, mapSize.height / b.height)
    }

    /// 内容缩放后尺寸
    var scaledContentSize: CGSize {
        guard let b = contentBounds else { return .zero }
        return CGSize(width: b.width * scale, height: b.height * scale)
    }

    /// 内容左上角在小地图中的坐标（居中放置）
    var contentOriginInMap: CGPoint {
        CGPoint(x: (mapSize.width - scaledContentSize.width) / 2,
                y: (mapSize.height - scaledContentSize.height) / 2)
    }

    /// 是否有可绘制内容
    var hasContent: Bool { contentBounds != nil }

    /// 世界坐标 → 小地图坐标
    func worldToMap(_ world: Point) -> CGPoint {
        guard let b = contentBounds else { return .zero }
        return CGPoint(x: contentOriginInMap.x + (world.x - b.origin.x) * scale,
                       y: contentOriginInMap.y + (world.y - b.origin.y) * scale)
    }

    /// 小地图坐标 → 世界坐标（无内容返回 nil）
    func mapToWorld(_ map: CGPoint) -> Point? {
        guard let b = contentBounds, scale > 0.0001 else { return nil }
        return Point(x: (map.x - contentOriginInMap.x) / scale + b.origin.x,
                     y: (map.y - contentOriginInMap.y) / scale + b.origin.y)
    }

    /// 视口矩形（世界坐标）→ 小地图矩形
    func rect(of worldRect: CGRect) -> CGRect {
        let tl = worldToMap(Point(x: worldRect.minX, y: worldRect.minY))
        let br = worldToMap(Point(x: worldRect.maxX, y: worldRect.maxY))
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    // MARK: 静态：视口世界矩形 / 内容包围盒 / 点击跳转（纯函数，可单测）

    /// 视口（世界坐标）当前可见区：由 viewport(zoom/pan) + 屏幕尺寸反推。
    static func viewportWorldRect(viewport: ViewportTransform, viewportSize: CGSize) -> CGRect {
        let tl = viewport.world(CGPoint(x: 0, y: 0))
        let br = viewport.world(CGPoint(x: viewportSize.width, y: viewportSize.height))
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    /// 内容包围盒（世界坐标，含节点高度）：空画布返回 nil。
    static func contentBounds(of nodes: [CanvasNode]) -> CGRect? {
        guard !nodes.isEmpty else { return nil }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for node in nodes {
            let h = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + NodeMetrics.nodeWidth)
            maxY = max(maxY, node.position.y + h)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 点击小地图 → 跳转视口：把点击的世界坐标居中到主视口中心（保持当前 zoom，夹边界）。
    static func jumpViewport(
        tapInMap: CGPoint,
        mapSize: CGSize,
        contentBounds: CGRect?,
        viewportSize: CGSize,
        viewport: ViewportTransform,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> ViewportTransform? {
        let geo = MiniMapGeometry(mapSize: mapSize, contentBounds: contentBounds)
        guard let worldCenter = geo.mapToWorld(tapInMap) else { return nil }
        let targetPan = CGPoint(
            x: viewportSize.width / 2 - worldCenter.x * viewport.zoom,
            y: viewportSize.height / 2 - worldCenter.y * viewport.zoom)
        return viewport.clampedPan(canvasWidth: canvasWidth, canvasHeight: canvasHeight, at: targetPan)
    }
}

/// 小地图视图：右下角浮层，渲染全部节点缩略 + 当前视口矩形；点击/拖动跳转视口。
/// 参照 ComfyUI 右下角 minimap：小画布显示全图 + 视口框 + 点按跳转。
struct MiniMapView: View {
    let store: CanvasStore
    @Binding var viewport: ViewportTransform
    let viewportSize: CGSize
    let canvasWidth: Double
    let canvasHeight: Double
    /// 关闭回调（隐藏 minimap；⌘M 重新打开）
    var onClose: () -> Void

    @Environment(\.themeTokens) private var theme
    /// 放大 + 醒目：用户反馈「小地图确实没有」——加大到 220×170，accent 边框
    private let mapSize = CGSize(width: 220, height: 170)

    private var bounds: CGRect? { MiniMapGeometry.contentBounds(of: store.graph.nodes) }
    private var geo: MiniMapGeometry { MiniMapGeometry(mapSize: mapSize, contentBounds: bounds) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            header
            mapCanvas
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.92))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("迷你地图")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭迷你地图")
            .accessibilityIdentifier("canvas.minimap.close")
            .foregroundStyle(.tertiary)
            .help("关闭迷你地图（⌘M 重新打开）")
        }
    }

    /// 缩略画布：节点 + 视口矩形；点击/拖动跳转视口。
    private var mapCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor)).opacity(0.6))
            if bounds != nil {
                ForEach(store.graph.nodes) { node in
                    let h = NodeMetrics.nodeHeight(inputs: node.inputs.count, outputs: node.outputs.count)
                    let w = NodeMetrics.nodeWidth * geo.scale
                    let ht = h * geo.scale
                    let tl = geo.worldToMap(Point(x: node.position.x, y: node.position.y))
                    Rectangle()
                        .fill((theme?.aj38.accent.swiftUIColor ?? Color(nsColor: .controlAccentColor)).opacity(0.7))
                        .frame(width: max(2, w), height: max(2, ht))
                        .position(x: tl.x + w / 2, y: tl.y + ht / 2)
                }
                let vpRect = geo.rect(of: MiniMapGeometry.viewportWorldRect(
                    viewport: viewport, viewportSize: viewportSize))
                Rectangle()
                    .stroke(theme?.aj38.accent.swiftUIColor ?? Color.accentColor, lineWidth: 1.5)
                    .frame(width: vpRect.width, height: vpRect.height)
                    .position(x: vpRect.midX, y: vpRect.midY)
                    .allowsHitTesting(false)
            } else {
                Text("空画布")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: mapSize.width, height: mapSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in applyJump(at: value.location) }
        )
        .help("点击 / 拖动跳转视口")
    }

    private func applyJump(at point: CGPoint) {
        guard let next = MiniMapGeometry.jumpViewport(
            tapInMap: point, mapSize: mapSize, contentBounds: bounds,
            viewportSize: viewportSize, viewport: viewport,
            canvasWidth: canvasWidth, canvasHeight: canvasHeight) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            viewport = next
        }
    }
}