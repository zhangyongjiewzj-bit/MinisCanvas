import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - P2-1 一键漫剧流水线入口测试
//
// 覆盖：工具栏按钮 / 对话指令 / DeepLink 三入口 → 完整 11 节点流水线图
// （主链 9 节点 + 资产引用/Blender 预演 2 节点，14 连线，无环，已布局），
// 以及旧 4 节点链被完整图替代的回归断言。

@Suite("P2-1 一键漫剧流水线入口")
@MainActor
struct P2PipelineEntryTests {

    private func makeBridge() -> BridgeStore {
        BridgeStore(allowsLegacyCanvasCommandExecutionForTests: true)
    }

    // MARK: 模板图完整性（节点数 / 连线数 / 无环 / 布局应用）

    @Test func templateProducesCompleteLayout() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        #expect(graph.nodes.count == 12)
        #expect(graph.edges.count == 16)
        // 11 类节点全部在场
        let types = Set(graph.nodes.map(\.type))
        for type in ManjuNodeType.allCases {
            #expect(types.contains(type.rawValue), "模板缺少节点类型 \(type.rawValue)")
        }
        // 无环：DAGScheduler.layers 可分层（有环抛错），且层数 ≥ 5（主链深度）
        let layers = try DAGScheduler.layers(in: graph)
        #expect(layers.count >= 5)
        // 布局应用：模板自带 GraphLayout 分层布局，所有节点位置已计算（非原点）
        for node in graph.nodes {
            #expect(node.position != .zero, "\(node.title) 未被布局")
        }
        // 层间横向递增：最右节点 x 显著大于最左节点
        let xs = graph.nodes.map(\.position.x)
        #expect(xs.max()! > xs.min()! + 500)
    }

    // MARK: BridgeStore 共用入口（工具栏按钮同一路径）

    @Test func bridgeEntryGeneratesPipelineAndReceipt() {
        let bridge = makeBridge()
        bridge.createManjuPipeline()
        #expect(bridge.canvas.graph.nodes.count == 12)
        #expect(bridge.canvas.graph.edges.count == 16)
        // 聊天回执：节点数 + 主链摘要（F4：断言对齐 ManjuNodeType.displayName ——
        // 「剧情大纲/质检」是当前产品设计的节点显示名，回执取自模板节点标题）
        #expect(bridge.chat.messages.contains { $0.content.contains("已生成漫剧流水线（12 节点 · 16 连线）") })
        #expect(bridge.chat.messages.contains { $0.content.contains("小说导入 → 剧情大纲 → 剧本") })
        #expect(bridge.chat.messages.contains { $0.content.contains("→ 质检") })
        // 生成后自动选中小说导入节点（引导开始）
        let novel = bridge.canvas.graph.nodes.first { $0.type == ManjuNodeType.novelImport.rawValue }
        #expect(novel != nil && bridge.canvas.selectedNodeID == novel?.id)
        // 资产引用节点存在（资产锁定进流程，铁律 2/6）
        #expect(bridge.canvas.graph.nodes.contains { $0.type == ManjuNodeType.assetRef.rawValue })
    }

    @Test func bridgeEntryAppendsToExistingCanvas() {
        let bridge = makeBridge()
        bridge.canvas.addNode(ofType: "text")
        let existingX = bridge.canvas.graph.nodes[0].position.x
        bridge.createManjuPipeline()
        #expect(bridge.canvas.graph.nodes.count == 13) // 已有 1 + 模板 12
        // 流水线整体右移，不覆盖已有节点
        for node in bridge.canvas.graph.nodes where node.type != "text" {
            #expect(node.position.x > existingX)
        }
    }

    // MARK: 对话指令触发（BridgeStore 解析器）

    @Test func chatCommandTriggersPipeline() async {
        for command in ["一键流水线", "生成流水线", "漫剧流程", "建漫剧流水线"] {
            let bridge = makeBridge()
            bridge.chat.draftText = command
            bridge.chat.sendDraft()
            await awaitLegacyCanvasCommandCompletion(bridge)
            #expect(bridge.canvas.graph.nodes.count == 12, "指令「\(command)」未触发完整流水线")
            #expect(bridge.chat.messages.contains {
                $0.role == .assistant && $0.content.contains("已生成漫剧流水线")
            })
        }
    }

    @Test func commandParserRecognizesPipelineTriggers() {
        for command in ["一键流水线", "生成流水线", "漫剧流程", "漫剧流水线"] {
            guard case .createPipeline? = CommandParser.parse(command) else {
                Issue.record("指令「\(command)」未解析为 createPipeline")
                continue
            }
        }
        // 既有指令不被误伤
        #expect(CommandParser.parse("建节点 llm") != nil)
        switch CommandParser.parse("执行") {
        case .run: break
        default: Issue.record("「执行」未解析为 run")
        }
        switch CommandParser.parse("布局") {
        case .layout: break
        default: Issue.record("「布局」未解析为 layout")
        }
    }

    // MARK: DeepLink createPipeline（替代旧 4 节点链）

    @Test func deepLinkCreatePipelineBuildsFullGraph() {
        let bridge = makeBridge()
        bridge.deepLinkHandler.handle(.createPipeline)
        #expect(bridge.canvas.graph.nodes.count == 12)
        #expect(bridge.canvas.graph.edges.count == 16)
        let types = Set(bridge.canvas.graph.nodes.map(\.type))
        #expect(types.contains(ManjuNodeType.novelImport.rawValue))
        #expect(types.contains(ManjuNodeType.qcCheck.rawValue))
        #expect(types.contains(ManjuNodeType.assetRef.rawValue))
        // 旧 4 节点链（text/llm/image/video）不再出现
        #expect(!types.contains("text"))
        #expect(!types.contains("llm"))
        #expect(!types.contains("image"))
        #expect(!types.contains("video"))
    }
}
