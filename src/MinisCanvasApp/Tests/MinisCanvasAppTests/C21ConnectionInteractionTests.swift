import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - C2-1 连线交互升级（学 ComfyUI LiteGraph）：
// 类型校验 isValidConnection + 合法目标高亮（绿/红）+ 落线拦截 + 点已连口断开 + 双击删线 + 拖动改接

@Suite("C2-1 连线交互升级")
@MainActor
struct C21ConnectionInteractionTests {

    // MARK: - 测试脚手架

    /// 输出节点 A(300,300) + 输入节点 B(600,300)，可指定端口类型
    private func makePair(
        outType: String = "string", inType: String = "string"
    ) -> (store: CanvasStore, outNode: CanvasNode, inNode: CanvasNode,
          outPort: CanvasCore.Port, inPort: CanvasCore.Port) {
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: outType)
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: inType)
        let outNode = CanvasNode(type: "test", title: "A", position: Point(x: 300, y: 300),
                                 inputs: [], outputs: [outPort])
        let inNode = CanvasNode(type: "test", title: "B", position: Point(x: 600, y: 300),
                                inputs: [inPort], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [outNode, inNode], edges: []))
        return (store, outNode, inNode, outPort, inPort)
    }

    // MARK: - 类型校验 isValidConnection（LiteGraph 语义）

    @Test func sameTypeIsValid() {
        #expect(CanvasStore.isValidConnection("string", "string"))
        #expect(CanvasStore.isValidConnection("image", "image"))
        #expect(CanvasStore.isValidConnection("video", "video"))
    }

    @Test func differentTypesInvalid() {
        #expect(!CanvasStore.isValidConnection("string", "image"))
        #expect(!CanvasStore.isValidConnection("image", "video"))
        #expect(!CanvasStore.isValidConnection("string", "video"))
    }

    @Test func wildcardMatchesAnything() {
        #expect(CanvasStore.isValidConnection("*", "string"))
        #expect(CanvasStore.isValidConnection("image", "*"))
        #expect(CanvasStore.isValidConnection("*", "*"))
    }

    @Test func emptyTypeIsWildcard() {
        #expect(CanvasStore.isValidConnection("", "string"))
        #expect(CanvasStore.isValidConnection("image", ""))
    }

    @Test func commaMultiTypeAnyMatch() {
        #expect(CanvasStore.isValidConnection("string,image", "image"))
        #expect(CanvasStore.isValidConnection("string,image", "string"))
        #expect(!CanvasStore.isValidConnection("string,image", "video"))
        #expect(CanvasStore.isValidConnection("string", "image,string"))
        // 列表内通配
        #expect(CanvasStore.isValidConnection("string,*", "video"))
    }

    @Test func caseInsensitive() {
        #expect(CanvasStore.isValidConnection("String", "string"))
        #expect(CanvasStore.isValidConnection("IMAGE", "image"))
    }

    // MARK: - 拖线中合法目标高亮（edgeTarget + edgeTargetValid）

    @Test func dragMatchingTypesHighlightsValidTarget() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.updateEdgeEnd(store.portAnchor(for: inNode, port: inPort))
        // 同类型：吸附目标存在且合法 → 绿色高亮
        #expect(store.edgeTarget?.portID == inPort.id)
        #expect(store.edgeTargetValid)
    }

    @Test func dragMismatchedTypesHighlightsInvalidTarget() {
        // image → string：目标仍被吸附（以便红色提示），但合法性为 false
        let (store, outNode, inNode, outPort, inPort) = makePair(outType: "image", inType: "string")
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.updateEdgeEnd(store.portAnchor(for: inNode, port: inPort))
        #expect(store.edgeTarget?.portID == inPort.id)
        #expect(!store.edgeTargetValid)
    }

    @Test func noTargetResetsValidity() {
        let (store, outNode, _, outPort, _) = makePair()
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.updateEdgeEnd(Point(x: 100, y: 100))
        #expect(store.edgeTarget == nil)
        #expect(store.edgeTargetValid)
    }

    // MARK: - 落线前强制校验（非法拒绝）

    @Test func endEdgeWithMismatchedTypeRejected() {
        let (store, outNode, inNode, outPort, inPort) = makePair(outType: "image", inType: "string")
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.endEdge(at: store.portAnchor(for: inNode, port: inPort))
        // 非法类型：不建线、拖拽态清空、提示类型不匹配
        #expect(store.graph.edges.isEmpty)
        #expect(store.pendingEdge == nil)
        #expect(store.edgeTarget == nil)
        #expect(store.statusMessage?.contains("类型不匹配") == true)
    }

    @Test func endEdgeWithMatchingTypeConnects() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.endEdge(at: store.portAnchor(for: inNode, port: inPort))
        #expect(store.graph.edges.count == 1)
    }

    @Test func connectRejectsMismatchedTypesDirectly() {
        let (store, outNode, inNode, outPort, inPort) = makePair(outType: "video", inType: "string")
        let ok = store.connect(fromNode: outNode.id, fromPort: outPort.id,
                               toNode: inNode.id, toPort: inPort.id)
        #expect(!ok)
        #expect(store.graph.edges.isEmpty)
    }

    // MARK: - 点已连口断开

    @Test func clickConnectedOutputPortDisconnects() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        store.connect(fromNode: outNode.id, fromPort: outPort.id,
                      toNode: inNode.id, toPort: inPort.id)
        #expect(store.graph.edges.count == 1)
        let removed = store.disconnectPort(nodeID: outNode.id, portID: outPort.id)
        #expect(removed)
        #expect(store.graph.edges.isEmpty)
    }

    @Test func clickConnectedInputPortDisconnects() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        store.connect(fromNode: outNode.id, fromPort: outPort.id,
                      toNode: inNode.id, toPort: inPort.id)
        let removed = store.disconnectPort(nodeID: inNode.id, portID: inPort.id)
        #expect(removed)
        #expect(store.graph.edges.isEmpty)
    }

    @Test func clickUnconnectedPortIsNoop() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        #expect(!store.disconnectPort(nodeID: outNode.id, portID: outPort.id))
        #expect(!store.disconnectPort(nodeID: inNode.id, portID: inPort.id))
        #expect(store.graph.edges.isEmpty)
    }

    // MARK: - 双击连线删除

    @Test func removeEdgeDeletesEdge() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        store.connect(fromNode: outNode.id, fromPort: outPort.id,
                      toNode: inNode.id, toPort: inPort.id)
        let edge = store.graph.edges[0]
        store.removeEdge(id: edge.id)
        #expect(store.graph.edges.isEmpty)
    }

    // MARK: - 拖动改接（输入口单连线 / 输出口多连线）

    @Test func reconnectToOccupiedInputReplacesOldEdge() {
        // A1 → X 已连；再从 A2 拖到 X：旧线被替换，只剩 A2 → X
        let out1 = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let out2 = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let a1 = CanvasNode(type: "t", title: "A1", position: Point(x: 300, y: 300),
                            inputs: [], outputs: [out1])
        let a2 = CanvasNode(type: "t", title: "A2", position: Point(x: 300, y: 500),
                            inputs: [], outputs: [out2])
        let x = CanvasNode(type: "t", title: "X", position: Point(x: 600, y: 400),
                           inputs: [inPort], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [a1, a2, x], edges: []))
        #expect(store.connect(fromNode: a1.id, fromPort: out1.id,
                              toNode: x.id, toPort: inPort.id))
        #expect(store.graph.edges.count == 1)
        // 拖动改接：A2 → X 覆盖 A1 → X（输入口单连线语义）
        #expect(store.connect(fromNode: a2.id, fromPort: out2.id,
                              toNode: x.id, toPort: inPort.id))
        #expect(store.graph.edges.count == 1)
        let edge = store.graph.edges[0]
        #expect(edge.fromNode == a2.id && edge.fromPort == out2.id)
        #expect(edge.toNode == x.id && edge.toPort == inPort.id)
    }

    @Test func outputFanOutKeepsOldEdges() {
        // 同一输出口可接多个输入口（ComfyUI 输出扇出语义，不改接）
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let in1 = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let in2 = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let a = CanvasNode(type: "t", title: "A", position: Point(x: 300, y: 300),
                           inputs: [], outputs: [outPort])
        let b1 = CanvasNode(type: "t", title: "B1", position: Point(x: 600, y: 200),
                            inputs: [in1], outputs: [])
        let b2 = CanvasNode(type: "t", title: "B2", position: Point(x: 600, y: 500),
                            inputs: [in2], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [a, b1, b2], edges: []))
        #expect(store.connect(fromNode: a.id, fromPort: outPort.id,
                              toNode: b1.id, toPort: in1.id))
        #expect(store.connect(fromNode: a.id, fromPort: outPort.id,
                              toNode: b2.id, toPort: in2.id))
        #expect(store.graph.edges.count == 2)
    }

    @Test func identicalEdgeIsNotDuplicated() {
        let (store, outNode, inNode, outPort, inPort) = makePair()
        #expect(store.connect(fromNode: outNode.id, fromPort: outPort.id,
                              toNode: inNode.id, toPort: inPort.id))
        #expect(!store.connect(fromNode: outNode.id, fromPort: outPort.id,
                               toNode: inNode.id, toPort: inPort.id))
        #expect(store.graph.edges.count == 1)
    }
}
