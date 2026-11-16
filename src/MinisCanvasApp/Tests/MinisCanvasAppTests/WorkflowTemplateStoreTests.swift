import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-37 工作流模板库测试
//
// 覆盖：模板自检（类型在注册表 / 端口匹配）、模板 → 节点图构建（节点 + 连线）、
// 应用到当前画布（追加节点 / 连线 / 空画布复用 / 已有内容右移不覆盖）、
// BridgeStore 聊天回执 + 不自动执行（静态骨架语义）。

@Suite("AJ-37 工作流模板库")
@MainActor
struct WorkflowTemplateStoreTests {

    private func makeBridge() -> BridgeStore {
        BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
    }

    // MARK: 模板库完整性

    @Test func presetsAreValidAndComplete() {
        // 四个内置模板全部通过自检
        for template in WorkflowTemplateStore.presets {
            #expect(WorkflowTemplateStore.validate(template).isEmpty,
                    "模板「\(template.name)」自检未通过：\(WorkflowTemplateStore.validate(template))")
        }
        // 覆盖要求的四类常用组合
        let ids = Set(WorkflowTemplateStore.presets.map(\.id))
        #expect(ids.contains("text-llm"))      // 文本→LLM
        #expect(ids.contains("text-to-image")) // 文生图
        #expect(ids.contains("text-to-video")) // 文生视频
        #expect(ids.contains("image-to-video")) // 图生视频
    }

    @Test func templateLookupById() {
        #expect(WorkflowTemplateStore.template(id: "text-to-image") != nil)
        #expect(WorkflowTemplateStore.template(id: "no-such-template") == nil)
    }

    // MARK: 模板 → 节点图构建（节点 + 连线）

    @Test func buildGraphCreatesNodesAndEdges() throws {
        let graph = WorkflowTemplateStore.buildGraph(for: .textToImage)
        #expect(graph.nodes.count == 3) // text / llm / imageGen
        #expect(graph.edges.count == 2) // text→llm, llm→imageGen
        let types = Set(graph.nodes.map(\.type))
        #expect(types.contains("text"))
        #expect(types.contains("llm"))
        #expect(types.contains(ManjuNodeType.imageGen.rawValue))
        // 无环：可分层
        let layers = try DAGScheduler.layers(in: graph)
        #expect(layers.count >= 1)
    }

    @Test func buildGraphI2VConnectsImageAndPrompt() {
        let graph = WorkflowTemplateStore.buildGraph(for: .imageToVideo)
        #expect(graph.nodes.count == 4)
        #expect(graph.edges.count == 4) // text→llm, llm→imageGen, imageGen→videoGen, llm→videoGen
        // 首节点入度 0（无前驱），末节点视频入度 2（image + prompt）
        let videoNode = graph.nodes.first { $0.type == ManjuNodeType.videoGen.rawValue }!
        let incoming = graph.edges.filter { $0.toNode == videoNode.id }
        #expect(incoming.count == 2)
    }

    @Test func buildGraphLayoutsHorizontally() {
        let graph = WorkflowTemplateStore.buildGraph(for: .textToLLM)
        let xs = graph.nodes.map(\.position.x)
        #expect(xs[1] > xs[0]) // 右节点 x 更大
        #expect(graph.nodes.allSatisfy { $0.position != .zero })
    }

    // MARK: 应用到当前画布

    @Test func applyTemplateToEmptyCanvas() {
        let bridge = makeBridge()
        // AJ-74：llm 节点下线——textToLLM 模板应用时过滤 llm 节点及关联连线，仅剩 text
        let result = bridge.canvas.applyTemplate(.textToLLM)
        #expect(result.nodes.count == 1)
        #expect(result.edges.count == 0)
        #expect(bridge.canvas.graph.nodes.count == 1)
        #expect(bridge.canvas.graph.edges.count == 0)
        // 自动选中首节点
        let first = bridge.canvas.graph.nodes[0]
        #expect(bridge.canvas.selectedNodeID == first.id)
    }

    @Test func applyTemplateAppendsToExistingCanvas() {
        let bridge = makeBridge()
        bridge.canvas.addNode(ofType: "text")
        let existingX = bridge.canvas.graph.nodes[0].position.x
        // AJ-74：textToImage（text→llm→imageGen）过滤 llm 后剩 text+imageGen，2 节点 0 边
        let result = bridge.canvas.applyTemplate(.textToImage)
        #expect(bridge.canvas.graph.nodes.count == 1 + 2) // 已有 1 + 模板过滤后 2
        #expect(result.edges.count == 0)
        // 模板整体右移，不覆盖已有节点
        for node in bridge.canvas.graph.nodes where node.type != "text" {
            #expect(node.position.x > existingX)
        }
    }

    @Test func applyTemplateDoesNotAutoRun() {
        let bridge = makeBridge()
        bridge.canvas.applyTemplate(.textToImage)
        // 静态骨架：应用后未进入执行状态
        #expect(bridge.canvas.isRunning == false)
        #expect(bridge.canvas.executionProgress == nil)
        // 所有节点状态均为初始（未执行）
        #expect(bridge.canvas.graph.nodes.allSatisfy { $0.status == .pending })
    }

    // MARK: BridgeStore 共用入口（工具栏「模板」菜单同一路径）

    @Test func bridgeEntryAppliesTemplateAndWritesReceipt() {
        let bridge = makeBridge()
        // AJ-74：textToVideo（text→llm→videoGen）过滤 llm 后剩 text+videoGen，2 节点 0 边
        bridge.applyTemplate(.textToVideo)
        #expect(bridge.canvas.graph.nodes.count == 2)
        #expect(bridge.canvas.graph.edges.count == 0)
        #expect(bridge.chat.messages.contains {
            $0.content.contains("已应用模板「文生视频」") && $0.content.contains("2 节点 · 0 连线")
        })
    }
}
