import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-19/20 参考图上限 + 动态端口（按节点类型，参照 ComfyUI）
//
// 覆盖 4 项：
// 1. 参考图数量上限按节点类型（imageGen 4 / videoGen 1 / 其余 0）
// 2. 动态端口：参考图数量变化 → 端口动态加（image1/image2/…，上限内）
// 3. 动态端口：数量减少 → 端口动态减（保留基础 image 图生图入口）
// 4. 移除动态端口时断开其连线；不支持/已达上限/未知节点均拒绝
//
// 注：测试显式构造节点端口（不依赖 NodeTypeRegistry 的 imageGen 规格，避免与其他任务
// 并行改动该规格冲突），据此验证 addReferenceImage/removeReferenceImage 的纯行为。

@Suite("AJ-19/20 参考图上限与动态端口")
@MainActor
struct AJ19ReferenceImagePortTests {

    /// 构造一个 U-2 对齐的 imageGen 节点（prompt + image 基础输入端口）并加入 store 图。
    private func makeImageGenNode(in store: CanvasStore) -> CanvasNode {
        let node = CanvasNode(
            type: ManjuNodeType.imageGen.rawValue, title: "生图",
            inputs: [
                Port(name: "prompt", direction: .input, dataType: "string"),
                Port(name: "image", direction: .input, dataType: "image"),
            ],
            outputs: [Port(name: "image", direction: .output, dataType: "image")]
        )
        store.graph.addNode(node)
        return node
    }

    // MARK: - 1) 参考图上限按节点类型

    @Test func referenceLimitPerNodeType() {
        #expect(ManjuNodeType.imageGen.maxReferenceImages == 4, "生图最多 4 张参考图")
        #expect(ManjuNodeType.videoGen.maxReferenceImages == 1, "生视频仅 I2V 首帧 1 张")
        #expect(ManjuNodeType.qcCheck.maxReferenceImages == 0, "非生成类节点不支持参考图")
        #expect(ManjuNodeType.imageGen.supportsReferenceImages)
        #expect(!ManjuNodeType.qcCheck.supportsReferenceImages)
    }

    @Test func nodeTypeSpecExposesReferenceLimit() {
        #expect(NodeTypeRegistry.spec(for: ManjuNodeType.imageGen.rawValue)?.maxReferenceImages == 4)
        #expect(NodeTypeRegistry.spec(for: ManjuNodeType.videoGen.rawValue)?.maxReferenceImages == 1)
        #expect(NodeTypeRegistry.spec(for: "llm")?.maxReferenceImages == 0, "基础 LLM 节点不支持参考图")
        #expect(NodeTypeRegistry.spec(for: ManjuNodeType.imageGen.rawValue)?.supportsReferenceImages == true)
    }

    // MARK: - 2) 动态端口：数量增加 → 端口动态加（上限内）

    @Test func addReferenceImageUpToLimit() {
        let store = CanvasStore()
        let node = makeImageGenNode(in: store)
        // 基础端口：prompt + image（image 即第 1 张参考图）
        #expect(store.graph.node(id: node.id)?.inputs.map(\.name) == ["prompt", "image"])

        // 依次加到上限 4 张：image1 / image2 / image3
        #expect(store.addReferenceImage(nodeID: node.id))
        #expect(store.addReferenceImage(nodeID: node.id))
        #expect(store.addReferenceImage(nodeID: node.id))
        let names = store.graph.node(id: node.id)?.inputs.map(\.name) ?? []
        #expect(names == ["prompt", "image", "image1", "image2", "image3"],
                "基础 image + 3 张动态参考图 = 4 张上限")
    }

    @Test func addReferenceImageBeyondLimitRejected() {
        let store = CanvasStore()
        let node = makeImageGenNode(in: store)
        // 基础 image + image1 + image2 + image3 = 4 张，已满
        _ = store.addReferenceImage(nodeID: node.id)
        _ = store.addReferenceImage(nodeID: node.id)
        _ = store.addReferenceImage(nodeID: node.id)
        // 第 5 张拒绝
        #expect(!store.addReferenceImage(nodeID: node.id))
        #expect(store.graph.node(id: node.id)?.inputs.filter { $0.dataType == "image" }.count == 4,
                "参考图端口数不得超过上限")
    }

    @Test func videoGenSingleReferenceStopsAtOne() {
        let store = CanvasStore()
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue, title: "生视频",
            inputs: [
                Port(name: "prompt", direction: .input, dataType: "string"),
                Port(name: "image", direction: .input, dataType: "image"),
            ],
            outputs: [Port(name: "video", direction: .output, dataType: "video")]
        )
        store.graph.addNode(node)
        // 基础 image 已是第 1 张，上限 1 → 不允许再动态加
        #expect(!store.addReferenceImage(nodeID: node.id))
        #expect(store.graph.node(id: node.id)?.inputs.filter { $0.dataType == "image" }.count == 1)
    }

    @Test func unsupportedTypeAndUnknownNodeRejected() {
        let store = CanvasStore()
        let llm = try! #require(store.addNode(ofType: "llm"))
        #expect(!store.addReferenceImage(nodeID: llm.id), "LLM 节点不支持参考图")
        #expect(!store.addReferenceImage(nodeID: UUID()), "未知节点返回 false")
    }

    // MARK: - 3) 动态端口：数量减少 → 端口动态减（保留基础 image）

    @Test func removeReferenceImageKeepsBaseImage() {
        let store = CanvasStore()
        let node = makeImageGenNode(in: store)
        _ = store.addReferenceImage(nodeID: node.id) // image1
        _ = store.addReferenceImage(nodeID: node.id) // image2

        #expect(store.removeReferenceImage(nodeID: node.id))
        let names = store.graph.node(id: node.id)?.inputs.map(\.name) ?? []
        #expect(names == ["prompt", "image", "image1"], "先移除 image2")

        #expect(store.removeReferenceImage(nodeID: node.id))
        #expect(store.graph.node(id: node.id)?.inputs.map(\.name) == ["prompt", "image"],
                "只保留基础 image，不再有多余动态参考图")

        // 只剩基础 image → 无可移除的动态端口
        #expect(!store.removeReferenceImage(nodeID: node.id))
    }

    // MARK: - 4) 移除动态端口时断开其连线

    @Test func removeReferenceImageDisconnectsItsEdge() {
        let store = CanvasStore()
        let upstream = makeImageGenNode(in: store)
        let target = makeImageGenNode(in: store)
        #expect(upstream.id != target.id)

        #expect(store.addReferenceImage(nodeID: target.id), "addReferenceImage 应成功") // image1
        #expect(store.graph.node(id: target.id)?.inputs.map(\.name) == ["prompt", "image", "image1"])
        let extra = try! #require(store.graph.node(id: target.id)?.inputs.first(where: { $0.name == "image1" }))

        let connected = store.connect(
            fromNode: upstream.id, fromPort: try! #require(upstream.outputs.first).id,
            toNode: target.id, toPort: extra.id
        )
        #expect(connected)
        #expect(store.graph.edges.contains { $0.toPort == extra.id })

        #expect(store.removeReferenceImage(nodeID: target.id))
        #expect(!store.graph.edges.contains { $0.toPort == extra.id }, "移除端口须同时断开其连线")
        #expect(store.graph.node(id: target.id)?.inputs.map(\.name) == ["prompt", "image"])
    }
}