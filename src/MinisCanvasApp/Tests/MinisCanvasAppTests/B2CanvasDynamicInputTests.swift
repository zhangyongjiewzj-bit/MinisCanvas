import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - B2 动态多输入端口 · 画布连线挂接
//
// 覆盖：connect 成功占用最后一个空槽 → 自动长出下一个；断开/删边 → 尾部空槽回收；
// 改接同一端口不涨端口数（输入口单连线语义）。
//
// 注：测试显式构造节点端口（不依赖 NodeTypeRegistry 规格，避免与其他任务并行改动冲突）。

@Suite("B2 动态多输入端口 · 画布挂接")
@MainActor
struct B2CanvasDynamicInputTests {

    /// qcCheck 节点（image + text 基础端口，对齐动态配置 dataType=image）
    private func makeQCNode(in store: CanvasStore) -> CanvasNode {
        let node = CanvasNode(
            type: ManjuNodeType.qcCheck.rawValue, title: "QC",
            inputs: [
                Port(name: "image", direction: .input, dataType: "image"),
                Port(name: "text", direction: .input, dataType: "string"),
            ],
            outputs: [Port(name: "report", direction: .output, dataType: "string")]
        )
        store.graph.addNode(node)
        return node
    }

    /// image 输出源节点（模拟上游生图节点）
    private func makeImageSource(in store: CanvasStore) -> CanvasNode {
        let node = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue, title: "生图",
            inputs: [Port(name: "prompt", direction: .input, dataType: "string")],
            outputs: [Port(name: "image", direction: .output, dataType: "image")]
        )
        store.graph.addNode(node)
        return node
    }

    @Test func connectToLastSlotGrowsNextPort() {
        let store = CanvasStore()
        let qc = makeQCNode(in: store)
        let src = makeImageSource(in: store)
        let imagePort = qc.inputs.first { $0.name == "image" }!
        let ok = store.connect(
            fromNode: src.id, fromPort: src.outputs[0].id,
            toNode: qc.id, toPort: imagePort.id
        )
        #expect(ok)
        #expect(store.graph.node(id: qc.id)?.inputs.map(\.name) == ["image", "text", "image1"],
                "占用最后一个 image 空槽 → 自动长出 image1")
    }

    @Test func reconnectSamePortDoesNotGrow() {
        let store = CanvasStore()
        let qc = makeQCNode(in: store)
        let src1 = makeImageSource(in: store)
        let src2 = makeImageSource(in: store)
        let imagePort = qc.inputs.first { $0.name == "image" }!
        #expect(store.connect(
            fromNode: src1.id, fromPort: src1.outputs[0].id,
            toNode: qc.id, toPort: imagePort.id
        ))
        // 改接同一输入口（输入口单连线语义：先移除旧线再接新线）→ 端口数不涨
        #expect(store.connect(
            fromNode: src2.id, fromPort: src2.outputs[0].id,
            toNode: qc.id, toPort: imagePort.id
        ))
        #expect(store.graph.node(id: qc.id)?.inputs.map(\.name) == ["image", "text", "image1"])
    }

    @Test func disconnectRecyclesTrailingSlot() {
        let store = CanvasStore()
        let qc = makeQCNode(in: store)
        let src1 = makeImageSource(in: store)
        let src2 = makeImageSource(in: store)
        let imagePort = qc.inputs.first { $0.name == "image" }!
        #expect(store.connect(
            fromNode: src1.id, fromPort: src1.outputs[0].id,
            toNode: qc.id, toPort: imagePort.id
        ))
        let image1Port = store.graph.node(id: qc.id)!.inputs.first { $0.name == "image1" }!
        #expect(store.connect(
            fromNode: src2.id, fromPort: src2.outputs[0].id,
            toNode: qc.id, toPort: image1Port.id
        ))
        #expect(store.graph.node(id: qc.id)?.inputs.map(\.name) == ["image", "text", "image1", "image2"])

        // 断开 image（基础端口）→ 仅回收尾部空槽 image2；image1 仍有入边 → 保留
        #expect(store.disconnectPort(nodeID: qc.id, portID: imagePort.id))
        #expect(store.graph.node(id: qc.id)?.inputs.map(\.name) == ["image", "text", "image1"])

        // 断开 image1（无入边后与尾部空槽同语义）→ 回收，回到基础端口
        #expect(store.disconnectPort(nodeID: qc.id, portID: image1Port.id))
        #expect(store.graph.node(id: qc.id)?.inputs.map(\.name) == ["image", "text"])
    }

    @Test func removeEdgeRecyclesTrailingSlot() {
        let store = CanvasStore()
        let qc = makeQCNode(in: store)
        let src = makeImageSource(in: store)
        let imagePort = qc.inputs.first { $0.name == "image" }!
        #expect(store.connect(
            fromNode: src.id, fromPort: src.outputs[0].id,
            toNode: qc.id, toPort: imagePort.id
        ))
        #expect(store.graph.node(id: qc.id)?.inputs.count == 3, "connect 后应长出 image1")

        let edge = store.graph.edges.first { $0.toNode == qc.id && $0.toPort == imagePort.id }!
        store.removeEdge(id: edge.id)
        #expect(store.graph.node(id: qc.id)?.inputs.map(\.name) == ["image", "text"],
                "双击删边 → image1 无入边 → 回收")
    }
}
