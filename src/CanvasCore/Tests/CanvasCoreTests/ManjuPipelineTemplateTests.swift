import XCTest
@testable import CanvasCore

// MARK: - M1b：漫剧流水线模板 + 资产锁定注入

final class ManjuPipelineTemplateTests: XCTestCase {

    func testPipelineSkeletonNodesAndEdges() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)

        // 12 类节点各 1 个
        XCTAssertEqual(graph.nodes.count, 12)
        for type in ManjuNodeType.allCases {
            XCTAssertTrue(
                graph.nodes.contains { $0.type == type.rawValue },
                "缺少节点类型 \(type.rawValue)"
            )
        }
        // 16 条连线（含 videoGen.video → qcCheck.video 审视频接线）
        XCTAssertEqual(graph.edges.count, 16)
        // 所有边的端口引用有效
        for edge in graph.edges {
            let from = try XCTUnwrap(graph.node(id: edge.fromNode))
            let to = try XCTUnwrap(graph.node(id: edge.toNode))
            XCTAssertTrue(from.outputs.contains { $0.id == edge.fromPort }, "出边端口无效")
            XCTAssertTrue(to.inputs.contains { $0.id == edge.toPort }, "入边端口无效")
        }
    }

    func testPipelineIsDAGWithExpectedLayers() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        // 无环 + 可拓扑排序（DAG 校验）
        let order = try DAGScheduler.topologicalSort(in: graph)
        XCTAssertEqual(order.count, 12) // 12 节点（reviewGate 加入后）
    }

    func testMainChainWiring() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        func nodeID(_ type: ManjuNodeType) throws -> UUID {
            try XCTUnwrap(graph.nodes.first { $0.type == type.rawValue }.map(\.id))
        }
        // 主链：小说 → 剧情 → 脚本 → 分镜 → 提示词 → 生图 → 生视频 → 质检
        let chain: [ManjuNodeType] = [.novelImport, .plotOutline, .script, .storyboard]
        for (a, b) in zip(chain, chain.dropFirst()) {
            XCTAssertFalse(graph.edges(from: try nodeID(a), to: try nodeID(b)).isEmpty,
                           "主链断：\(a) → \(b)")
        }
        XCTAssertFalse(graph.edges(from: try nodeID(.storyboard), to: try nodeID(.imagePrompt)).isEmpty)
        XCTAssertFalse(graph.edges(from: try nodeID(.storyboard), to: try nodeID(.videoPrompt)).isEmpty)
        XCTAssertFalse(graph.edges(from: try nodeID(.imagePrompt), to: try nodeID(.imageGen)).isEmpty)
        XCTAssertFalse(graph.edges(from: try nodeID(.videoPrompt), to: try nodeID(.videoGen)).isEmpty)
        XCTAssertFalse(graph.edges(from: try nodeID(.imageGen), to: try nodeID(.videoGen)).isEmpty)
        XCTAssertFalse(graph.edges(from: try nodeID(.videoGen), to: try nodeID(.qcCheck)).isEmpty)
        // 首尾帧：生图 image 喂视频生成
        XCTAssertFalse(graph.edges(from: try nodeID(.imageGen), to: try nodeID(.videoGen)).isEmpty)
    }

    func testAssetInjectionIntoPromptSlots() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)

        let imagePrompt = try XCTUnwrap(graph.nodes.first { $0.type == ManjuNodeType.imagePrompt.rawValue })
        let videoPrompt = try XCTUnwrap(graph.nodes.first { $0.type == ManjuNodeType.videoPrompt.rawValue })
        let script = try XCTUnwrap(graph.nodes.first { $0.type == ManjuNodeType.script.rawValue })

        let ip = try XCTUnwrap(imagePrompt.backendConfig).params
        let vp = try XCTUnwrap(videoPrompt.backendConfig).params

        // 图片 8 槽注入：REFERENCE（角色卡）/ STRUCTURE（服装）/ LAYOUT（场景）/ COLOR（色板）
        XCTAssertTrue(ip["slot.REFERENCE"]?.contains("魏衔") == true)
        XCTAssertTrue(ip["slot.REFERENCE"]?.contains("只继承") == true)
        XCTAssertTrue(ip["slot.STRUCTURE"]?.contains("玄色道袍") == true)
        XCTAssertTrue(ip["slot.LAYOUT"]?.contains("青崖观") == true)
        XCTAssertTrue(ip["slot.COLOR"]?.contains("#1F2A33") == true)

        // 视频 9 槽注入：REFERENCE MAP / STYLE LOCK / COLOR
        XCTAssertTrue(vp["slot.REFERENCE MAP"]?.contains("魏衔") == true)
        XCTAssertTrue(vp["slot.STYLE LOCK"]?.contains("weixian-lock") == true)
        XCTAssertTrue(vp["slot.COLOR"]?.contains("色板 v1") == true)

        // 锁定标记 + 系统提示词均就位
        XCTAssertEqual(ip[ManjuAssetInjection.lockedFlagKey], "1")
        XCTAssertEqual(vp[ManjuAssetInjection.lockedFlagKey], "1")
        XCTAssertNotNil(ip[ManjuPipelineTemplate.systemPromptKey])
        XCTAssertNotNil(vp[ManjuPipelineTemplate.systemPromptKey])

        // 非提示词节点不注入槽位锁定
        XCTAssertNil(script.backendConfig?.params["slot.REFERENCE"])
        XCTAssertNotEqual(script.backendConfig?.params[ManjuAssetInjection.lockedFlagKey], "1")

        // 资产引用节点携带摘要
        let assetRef = try XCTUnwrap(graph.nodes.first { $0.type == ManjuNodeType.assetRef.rawValue })
        XCTAssertTrue(assetRef.backendConfig?.params[ManjuAssetInjection.assetRefSummaryKey]?.contains("魏衔") == true)
    }

    func testEmptyAssetsMeansNoInjection() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: ManjuAssetLibrary())
        let imagePrompt = try XCTUnwrap(graph.nodes.first { $0.type == ManjuNodeType.imagePrompt.rawValue })
        XCTAssertNil(imagePrompt.backendConfig?.params[ManjuAssetInjection.lockedFlagKey])
        XCTAssertNotNil(imagePrompt.backendConfig?.params[ManjuPipelineTemplate.systemPromptKey])
    }

    func testApplyLockedAssetsReinjection() throws {
        var graph = ManjuPipelineTemplate.makeManjuPipeline(assets: ManjuAssetLibrary())
        // 后置注入：资产更新后统一重注入
        var assets = ManjuAssetLibrary.demo
        assets.characters[0].name = "李长生"
        graph = ManjuAssetInjection.applyLockedAssets(assets, to: graph)
        let imagePrompt = try XCTUnwrap(graph.nodes.first { $0.type == ManjuNodeType.imagePrompt.rawValue })
        XCTAssertTrue(imagePrompt.backendConfig?.params["slot.REFERENCE"]?.contains("李长生") == true)
        XCTAssertEqual(imagePrompt.backendConfig?.params[ManjuAssetInjection.lockedFlagKey], "1")
    }

    func testAutoLayoutPositionsAssigned() {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        // 全部节点已获得非零坐标（模板内未手动定位）
        for node in graph.nodes {
            XCTAssertNotEqual(node.position, .zero, "节点 \(node.type) 未布局")
        }
        // 小说导入应在最左层
        let novel = graph.nodes.first { $0.type == ManjuNodeType.novelImport.rawValue }!
        let qc = graph.nodes.first { $0.type == ManjuNodeType.qcCheck.rawValue }!
        XCTAssertLessThan(novel.position.x, qc.position.x)
    }
}
