import Testing
@testable import CanvasCore

// MARK: - GraphLayout 测试

struct GraphLayoutTests {

    private func makeNode(_ title: String) -> CanvasNode {
        CanvasNode(type: "llm", title: title)
    }

    private func makeEdge(_ from: CanvasNode, _ to: CanvasNode) -> Edge {
        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        return Edge(fromNode: from.id, fromPort: pOut.id, toNode: to.id, toPort: pIn.id)
    }

    private func makeGraph(nodes: [CanvasNode], edges: [Edge] = []) -> NodeGraph {
        var g = NodeGraph()
        nodes.forEach { g.addNode($0) }
        edges.forEach { g.addEdge($0) }
        return g
    }

    // MARK: - 分层：x 按层递增 / 同层 y 间距

    @Test func layeredXIncreasesAndYSameWithinLayer() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])

        let layout = try GraphLayout().layeredLayout(graph: graph)

        // 默认 layerSpacing=200：层 0/1/2 的 x 分别为 0/200/400
        #expect(layout[a.id]?.x == 0)
        #expect(layout[b.id]?.x == 200)
        #expect(layout[c.id]?.x == 400)
        #expect(layout[a.id]?.y == 0 && layout[b.id]?.y == 0 && layout[c.id]?.y == 0,
                "每层单节点时 y 应相同")
    }

    @Test func sameLayerVerticalSpacing() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [a, b, c]) // 无依赖 → 同一层

        let layout = try GraphLayout().layeredLayout(graph: graph)

        // 默认 nodeSpacing=80：同层 y 依次 0/80/160，x 相同
        #expect(layout[a.id]?.x == layout[b.id]?.x)
        #expect(layout[a.id]?.y == 0)
        #expect(layout[b.id]?.y == 80)
        #expect(layout[c.id]?.y == 160)
    }

    // MARK: - 手动位置保留

    @Test func manualPositionPreserved() throws {
        let a = makeNode("A")
        let b = makeNode("B")
        var c = makeNode("C")
        c.position = Point(x: 999, y: 888)
        let graph = makeGraph(nodes: [a, b, c], edges: [makeEdge(a, b), makeEdge(b, c)])

        let layout = try GraphLayout().layeredLayout(graph: graph)

        #expect(layout[c.id] == Point(x: 999, y: 888), "手动定位节点应原样保留坐标")
        #expect(layout[a.id] != nil && layout[b.id] != nil, "其余节点仍应获得布局坐标")
    }

    // MARK: - 同层分列避让

    @Test func columnSplittingBeyondMaxNodesPerColumn() throws {
        let nodes = (0..<10).map { makeNode("N\($0)") }
        let graph = makeGraph(nodes: nodes)

        let layout = try GraphLayout().layeredLayout(graph: graph)

        // 默认 maxNodesPerColumn=8：前 8 个在第 0 列，后 2 个在第 1 列（x 偏移 columnSpacing=120）
        #expect(layout[nodes[0].id]?.x == 0)
        #expect(layout[nodes[7].id]?.x == 0)
        #expect(layout[nodes[8].id]?.x == 120, "超过每列上限应自动分列")
        #expect(layout[nodes[9].id]?.x == 120)
        #expect(layout[nodes[8].id]?.y == 0, "新列应从顶部重新排")
        #expect(layout[nodes[9].id]?.y == 80)
    }

    @Test func autoNodesAvoidManualPositionsInSameLayer() throws {
        let manual = makeNode("M")
        var manualNode = manual
        manualNode.position = Point(x: 0, y: 50) // 非 zero，视为手动定位
        let b = makeNode("B")
        let c = makeNode("C")
        let graph = makeGraph(nodes: [manualNode, b, c]) // 全部同层

        let layout = try GraphLayout().layeredLayout(graph: graph)

        #expect(layout[manualNode.id] == Point(x: 0, y: 50), "手动节点保持不动")
        // 自动节点必须与手动节点 y 保持至少 nodeSpacing(80) 距离
        for nodeID in [b.id, c.id] {
            let y = layout[nodeID]?.y ?? 0
            #expect(abs(y - 50) >= 80, "自动节点应避让手动节点，避免重叠")
        }
    }

    // MARK: - 空图

    @Test func emptyGraphReturnsEmptyLayout() throws {
        let layout = try GraphLayout().layeredLayout(graph: NodeGraph())
        #expect(layout.isEmpty, "空图布局应为空字典")
    }
}
