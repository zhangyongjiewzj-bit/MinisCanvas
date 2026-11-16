import Foundation

// MARK: - Point 便捷扩展

extension Point {
    /// 原点（未设置位置时 CanvasNode.position 的默认值）
    public static let zero = Point(x: 0, y: 0)
}

// MARK: - 分层布局

/// 节点图自动布局：基于 `DAGScheduler.layers` 的分层布局算法。
///
/// 约定：
/// - 层号 0 在最左，层间横向排列：`x = origin.x + 层号 × layerSpacing`；
/// - 同层节点纵向排列：`y = origin.y + 序号 × nodeSpacing`；
/// - 同层节点过多时自动分列（column），列间以 `columnSpacing` 横向错开，避免重叠；
/// - 已手动设置位置的节点（`position != .zero`）保持不动，仅参与避让，不被重新计算。
///
/// 纯 Foundation 实现，不依赖 SwiftUI / AppKit / CoreGraphics。
public struct GraphLayout: Sendable {

    /// 同层节点纵向间距
    public var nodeSpacing: Double
    /// 相邻层横向间距
    public var layerSpacing: Double
    /// 同层分列时列与列之间的横向间距
    public var columnSpacing: Double
    /// 每列最多容纳的节点数，超过则自动分列
    public var maxNodesPerColumn: Int
    /// 布局起点（左上角）
    public var origin: Point

    public init(
        nodeSpacing: Double = 80,
        layerSpacing: Double = 200,
        columnSpacing: Double = 120,
        maxNodesPerColumn: Int = 8,
        origin: Point = .zero
    ) {
        self.nodeSpacing = nodeSpacing
        self.layerSpacing = layerSpacing
        self.columnSpacing = columnSpacing
        self.maxNodesPerColumn = max(1, maxNodesPerColumn)
        self.origin = origin
    }

    /// 使用默认参数直接对图进行分层布局。
    public static func layeredLayout(graph: NodeGraph) throws -> [UUID: Point] {
        try GraphLayout().layeredLayout(graph: graph)
    }

    /// 计算整张图的布局，返回「节点 id → 画布坐标」字典。
    ///
    /// - 返回字典包含图中**所有**节点：已手动定位的节点原样保留其坐标，
    ///   其余节点按分层算法计算；
    /// - 图中有环或边引用不存在的节点时抛出 `DAGSchedulerError`。
    public func layeredLayout(graph: NodeGraph) throws -> [UUID: Point] {
        let layers = try DAGScheduler.layers(in: graph)
        var result: [UUID: Point] = [:]

        for (layerIndex, layer) in layers.enumerated() {
            // 该层已手动定位的节点：保留原坐标，并作为避让对象
            var manual: [(id: UUID, position: Point)] = []
            var auto: [UUID] = []
            for nodeID in layer {
                guard let node = graph.node(id: nodeID) else { continue }
                if node.position == .zero {
                    auto.append(nodeID)
                } else {
                    manual.append((nodeID, node.position))
                    result[nodeID] = node.position
                }
            }

            // 自动节点纵向排列，必要时分列
            var column = 0
            var yCursor = origin.y
            var countInColumn = 0

            for nodeID in auto {
                var y = yCursor
                // 简单避让：与同层手动节点靠得太近时下移，避免重叠
                while manual.contains(where: { abs($0.position.y - y) < nodeSpacing }) {
                    y += nodeSpacing
                }
                let x = origin.x
                    + Double(layerIndex) * layerSpacing
                    + Double(column) * columnSpacing
                result[nodeID] = Point(x: x, y: y)

                yCursor = y + nodeSpacing
                countInColumn += 1
                if countInColumn >= maxNodesPerColumn {
                    column += 1
                    countInColumn = 0
                    yCursor = origin.y
                }
            }
        }

        return result
    }
}
