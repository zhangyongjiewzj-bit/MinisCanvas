import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - E17 画布连线修复：portAnchor 中心坐标语义 + 端口拖线创建连线（参考 ComfyUI LiteGraph 吸附/高亮）

@Suite("E17 画布连线修复")
@MainActor
struct E17EdgeTests {

    /// 输出口节点 A(300,300) + 输入口节点 B(600,300)
    private func makePair() -> (
        store: CanvasStore, outNode: CanvasNode, inNode: CanvasNode,
        outPort: CanvasCore.Port, inPort: CanvasCore.Port
    ) {
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let outNode = CanvasNode(type: "test", title: "A", position: Point(x: 300, y: 300),
                                 inputs: [], outputs: [outPort])
        let inNode = CanvasNode(type: "test", title: "B", position: Point(x: 600, y: 300),
                                inputs: [inPort], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [outNode, inNode], edges: []))
        return (store, outNode, inNode, outPort, inPort)
    }

    // MARK: - 锚点中心坐标语义（修偏左）

    @Test func outputAnchorIsRightEdgeCenterSemantics() {
        let (store, outNode, _, outPort, _) = makePair()
        let anchor = store.portAnchor(for: outNode, port: outPort)
        // node.position 是中心坐标：输出锚点 = center + width/2（右边缘）
        #expect(anchor.x == outNode.position.x + NodeMetrics.nodeWidth / 2)
        // U-1：Y 也是中心语义 = position.y + localY − nodeHeight/2
        // （旧断言锚定左上角语义，与渲染层错位 nodeHeight/2，已随实现修正）
        let nodeH = NodeMetrics.nodeHeight(inputs: 0, outputs: 1)
        let expectY = outNode.position.y + (NodeMetrics.headerHeight + NodeMetrics.rowHeight / 2) - nodeH / 2
        #expect(anchor.y == expectY)
    }

    @Test func inputAnchorIsLeftEdgeCenterSemantics() {
        let (store, _, inNode, _, inPort) = makePair()
        let anchor = store.portAnchor(for: inNode, port: inPort)
        // 输入锚点 = center - width/2（左边缘）
        #expect(anchor.x == inNode.position.x - NodeMetrics.nodeWidth / 2)
    }

    @Test func anchorsStraddleNodeCenter() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        let out = store.portAnchor(for: outNode, port: outPort)
        let inn = store.portAnchor(for: inNode, port: inPort)
        // 输出锚点在自身中心右侧 width/2，输入锚点在自身中心左侧 width/2（中心对称）
        #expect(out.x - outNode.position.x == NodeMetrics.nodeWidth / 2)
        #expect(inn.x - inNode.position.x == -NodeMetrics.nodeWidth / 2)
        // 两锚点横坐标的中点是两节点中心的中点（连线横穿节点中心）
        let anchorMidX = (out.x + inn.x) / 2
        let nodeMidX = (outNode.position.x + inNode.position.x) / 2
        #expect(anchorMidX == nodeMidX)
        #expect(out.y == inn.y)
    }

    @Test func multiplePortRowsOffsetY() {
        let p1 = CanvasCore.Port(name: "a", direction: .input, dataType: "string")
        let p2 = CanvasCore.Port(name: "b", direction: .input, dataType: "string")
        let node = CanvasNode(type: "t", title: "N", position: Point(x: 0, y: 0),
                              inputs: [p1, p2], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [node], edges: []))
        let a1 = store.portAnchor(for: node, port: p1)
        let a2 = store.portAnchor(for: node, port: p2)
        #expect(a2.y - a1.y == NodeMetrics.rowHeight)
        // 中心语义：position(0,0) 的输入锚点 x 为 -width/2（旧实现会算成 0 = 偏右）
        #expect(a1.x == -NodeMetrics.nodeWidth / 2)
    }

    // MARK: - 端口拖线创建连线（LiteGraph 吸附语义）

    @Test func dragFromOutputToInputCreatesEdgeAndHighlights() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        let start = store.portAnchor(for: outNode, port: outPort)
        let target = store.portAnchor(for: inNode, port: inPort)
        store.beginEdge(from: outNode.id, portID: outPort.id, at: start)
        store.updateEdgeEnd(target)
        // 拖拽中：临时线终点 = 鼠标位置，且实时吸附目标被高亮
        #expect(store.pendingEdge?.end == target)
        #expect(store.edgeTarget?.nodeID == inNode.id)
        #expect(store.edgeTarget?.portID == inPort.id)
        // 松手：创建 output → input 连线，拖拽态清空
        store.endEdge(at: target)
        #expect(store.graph.edges.count == 1)
        let edge = store.graph.edges[0]
        #expect(edge.fromNode == outNode.id && edge.fromPort == outPort.id)
        #expect(edge.toNode == inNode.id && edge.toPort == inPort.id)
        #expect(store.pendingEdge == nil)
        #expect(store.edgeTarget == nil)
    }

    @Test func dropWithinToleranceConnects() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        let start = store.portAnchor(for: outNode, port: outPort)
        let target = store.portAnchor(for: inNode, port: inPort)
        store.beginEdge(from: outNode.id, portID: outPort.id, at: start)
        // 阈值 22 内（20px）松手 → 吸附创建
        store.endEdge(at: Point(x: target.x + 20, y: target.y))
        #expect(store.graph.edges.count == 1)
        #expect(store.graph.edges[0].toPort == inPort.id)
    }

    @Test func dropOutsideToleranceDoesNotConnect() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        let start = store.portAnchor(for: outNode, port: outPort)
        let target = store.portAnchor(for: inNode, port: inPort)
        store.beginEdge(from: outNode.id, portID: outPort.id, at: start)
        // 阈值 22 外（25px）松手 → 不创建
        store.endEdge(at: Point(x: target.x + 25, y: target.y))
        #expect(store.graph.edges.isEmpty)
    }

    @Test func dragFromInputToOutputCreatesNormalizedEdge() {
        // LiteGraph：从输入口反向拖到输出口同样成链，方向规范化为 output → input
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let a = CanvasNode(type: "t", title: "A", position: Point(x: 300, y: 300),
                           inputs: [inPort], outputs: [])
        let b = CanvasNode(type: "t", title: "B", position: Point(x: 600, y: 300),
                           inputs: [], outputs: [outPort])
        let store = CanvasStore(graph: NodeGraph(nodes: [a, b], edges: []))
        let start = store.portAnchor(for: a, port: inPort)
        let target = store.portAnchor(for: b, port: outPort)
        store.beginEdge(from: a.id, portID: inPort.id, at: start)
        store.updateEdgeEnd(target)
        #expect(store.edgeTarget?.portID == outPort.id)
        store.endEdge(at: target)
        #expect(store.graph.edges.count == 1)
        let edge = store.graph.edges[0]
        #expect(edge.fromNode == b.id && edge.fromPort == outPort.id)
        #expect(edge.toNode == a.id && edge.toPort == inPort.id)
    }

    @Test func sourceNodeOwnPortsAreExcluded() {
        // 自身输入口不算吸附目标（避免自连）
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let node = CanvasNode(type: "t", title: "A", position: Point(x: 300, y: 300),
                              inputs: [inPort], outputs: [outPort])
        let store = CanvasStore(graph: NodeGraph(nodes: [node], edges: []))
        let start = store.portAnchor(for: node, port: outPort)
        let ownInput = store.portAnchor(for: node, port: inPort)
        store.beginEdge(from: node.id, portID: outPort.id, at: start)
        store.updateEdgeEnd(ownInput)
        #expect(store.edgeTarget == nil)
        store.endEdge(at: ownInput)
        #expect(store.graph.edges.isEmpty)
    }

    @Test func deselectAllClearsPendingEdgeAndTarget() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        let start = store.portAnchor(for: outNode, port: outPort)
        let target = store.portAnchor(for: inNode, port: inPort)
        store.beginEdge(from: outNode.id, portID: outPort.id, at: start)
        store.updateEdgeEnd(target)
        #expect(store.pendingEdge != nil)
        #expect(store.edgeTarget != nil)
        store.deselectAll()
        #expect(store.pendingEdge == nil)
        #expect(store.edgeTarget == nil)
    }

    // MARK: - EdgeCurve 坐标一致性

    @Test func edgeEndpointsMatchPortAnchors() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        store.connect(fromNode: outNode.id, fromPort: outPort.id,
                      toNode: inNode.id, toPort: inPort.id)
        let edge = store.graph.edges[0]
        let endpoints = store.edgeEndpoints(edge)
        let expectedFrom = store.portAnchor(for: outNode, port: outPort)
        let expectedTo = store.portAnchor(for: inNode, port: inPort)
        // EdgeCurve 渲染坐标 = portAnchor 中心坐标（同一语义，不偏）
        #expect(endpoints?.from == expectedFrom)
        #expect(endpoints?.to == expectedTo)
        #expect(expectedFrom.x == outNode.position.x + NodeMetrics.nodeWidth / 2)
        #expect(expectedTo.x == inNode.position.x - NodeMetrics.nodeWidth / 2)
    }
}
