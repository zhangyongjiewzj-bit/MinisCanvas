import Testing
@testable import CanvasCore

// MARK: - ManjuPipeline 测试

struct ManjuPipelineTests {

    private func node(of type: ManjuNodeType, in graph: NodeGraph) -> CanvasNode? {
        graph.nodes.first { $0.type == type.rawValue }
    }

    // MARK: - standardPipeline：节点数 / 边数 / 无环

    @Test func standardPipelineNodeEdgeCountAndAcyclic() throws {
        let graph = ManjuPipeline.standardPipeline()

        #expect(graph.nodes.count == 9, "标准流水线应为 9 个节点")
        #expect(graph.edges.count == 9, "标准流水线应为 9 条连线")

        let order = try DAGScheduler.topologicalSort(in: graph)
        #expect(order.count == 9, "流水线应为无环 DAG，可完整拓扑排序")
    }

    // MARK: - standardPipeline：中文标题

    @Test func standardPipelineChineseTitles() {
        let graph = ManjuPipeline.standardPipeline()

        let expected: [(ManjuNodeType, String)] = [
            (.novelImport, "小说导入"),
            (.plotOutline, "剧情拆解"),
            (.script, "脚本生成"),
            (.storyboard, "分镜生成"),
            (.imagePrompt, "图片提示词"),
            (.videoPrompt, "视频提示词"),
            (.imageGen, "生图"),
            (.videoGen, "生视频"),
            (.qcCheck, "QC检查"),
        ]
        for (type, title) in expected {
            #expect(node(of: type, in: graph)?.title == title,
                    "\(type.rawValue) 节点标题应为「\(title)」")
        }
    }

    // MARK: - standardPipeline：默认模型配置

    @Test func standardPipelineDefaultModelConfigs() {
        let graph = ManjuPipeline.standardPipeline()

        // LLM 节点（7 个）：bailian / qwen3.8-max-preview
        let llmTypes: [ManjuNodeType] = [
            .novelImport, .plotOutline, .script, .storyboard,
            .imagePrompt, .videoPrompt, .qcCheck,
        ]
        for type in llmTypes {
            let config = node(of: type, in: graph)?.backendConfig
            #expect(config?.providerID == "bailian", "\(type.rawValue) 应走 bailian")
            #expect(config?.modelID == "qwen3.8-max-preview", "\(type.rawValue) 应使用 qwen3.8-max-preview")
        }

        // 生图：gimage2
        let imageGen = node(of: .imageGen, in: graph)?.backendConfig
        #expect(imageGen?.providerID == "gimage2")
        #expect(imageGen?.modelID == "gimage2")

        // 生视频：kling
        let videoGen = node(of: .videoGen, in: graph)?.backendConfig
        #expect(videoGen?.providerID == "kling")
        #expect(videoGen?.modelID == "kling")
    }

    // MARK: - 分镜占位生成

    @Test func storyboardNodesThreeParagraphsMakeThreeNodes() {
        let nodes = ManjuPipeline.storyboardNodes(script: "第一段\n\n第二段\n\n第三段")

        #expect(nodes.count == 3, "3 段脚本应生成 3 个分镜节点")
        #expect(nodes.map(\.title) == ["分镜1", "分镜2", "分镜3"], "标题应按「分镜1..N」编号")
        for node in nodes {
            #expect(node.type == ManjuNodeType.storyboard.rawValue)
            #expect(node.backendConfig?.providerID == "bailian", "分镜节点应带默认 LLM 配置")
        }
    }

    @Test func storyboardNodesEmptyScriptMakesOnePlaceholder() {
        let nodes = ManjuPipeline.storyboardNodes(script: "")
        #expect(nodes.count == 1, "空脚本文本也应保留 1 个占位分镜节点")
        #expect(nodes.first?.title == "分镜1")
    }

    @Test func storyboardCountCappedAtTwentyFour() {
        let longScript = (1...30).map { "段落\($0)" }.joined(separator: "\n\n")
        #expect(ManjuPipeline.storyboardCount(from: longScript) == 24, "分镜数上限应为 24")
    }
}
