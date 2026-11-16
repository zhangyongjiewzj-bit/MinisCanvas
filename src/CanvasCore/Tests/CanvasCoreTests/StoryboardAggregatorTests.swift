import Testing
import Foundation
@testable import CanvasCore

// MARK: - P2 分镜表工作台：聚合逻辑测试
//
// 设计文档：issues/p2_storyboard_design_20260805.md §4.3 边界情况表 + §8 测试计划
// 覆盖：空图/无锚点、未展开切分、已展开 y 排序、混合形态、手动连线升级、
//       字段填充（imageRefs 去重保序 / reviewStatus 三态 / videoRefs 兜底 outputs）、
//       环防御、共享 assetRef、防串镜剪枝、prompt 优先级、review.reason 只读。

private func sbNode(
    _ type: ManjuNodeType,
    title: String = "",
    x: Double = 0,
    y: Double = 0,
    params: [String: String]? = nil
) -> CanvasNode {
    CanvasNode(
        type: type.rawValue,
        title: title.isEmpty ? type.displayName : title,
        position: Point(x: x, y: y),
        backendConfig: params.map { NodeBackendConfig(params: $0) }
    )
}

private func sbEdge(_ from: CanvasNode, _ to: CanvasNode) -> Edge {
    Edge(fromNode: from.id, fromPort: UUID(), toNode: to.id, toPort: UUID())
}

@Suite struct StoryboardAggregatorTests {

    @Test("空图 → 空表（rows 为空、sourceNodeID 为 nil、默认标题）")
    func emptyGraphYieldsEmptyTable() {
        let table = StoryboardAggregator.aggregate(graph: NodeGraph())
        #expect(table.rows.isEmpty)
        #expect(table.title == "分镜表")
        #expect(table.sourceNodeID == nil)
    }

    @Test("无 storyboard 节点（只有生图节点）→ 空表")
    func noStoryboardNodesYieldsEmptyTable() {
        let g = NodeGraph(nodes: [sbNode(.imageGen, title: "生图1")], edges: [])
        #expect(StoryboardAggregator.aggregate(graph: g).rows.isEmpty)
    }

    @Test("未展开：单分镜多镜文本 → split 切段每段一行，与切分器完全一致")
    func unexpandedSingleStoryboardSplitsIntoRows() {
        let content = """
        第1镜：魏衔踏雾而来，长袍翻卷。
        第2镜：大殿内，香炉青烟。
        第3镜：神像暗部，朱砂一点。
        """
        let anchor = sbNode(.storyboard, title: "分镜", params: ["content": content])
        let g = NodeGraph(nodes: [anchor], edges: [])
        let table = StoryboardAggregator.aggregate(graph: g)
        let segments = ManjuStoryboardSplitter.split(script: content)
        #expect(segments.count == 3)
        #expect(table.rows.count == segments.count)
        #expect(table.sourceNodeID == anchor.id)
        for (i, row) in table.rows.enumerated() {
            #expect(row.sceneIndex == i + 1)
            #expect(row.prompt == segments[i])
            #expect(row.nodeIDs == [anchor.id])
            #expect(row.reviewStatus == .pending)
            #expect(row.imageRefs.isEmpty)
            #expect(row.videoRefs.isEmpty)
        }
    }

    @Test("单分镜节点但内容为空/单段 → 视为已展开单行（不切分、sourceNodeID 为 nil）")
    func singleNodeWithEmptyContentIsExpandedRow() {
        let s = sbNode(.storyboard, title: "分镜", y: 100)
        let g = NodeGraph(nodes: [s], edges: [])
        let table = StoryboardAggregator.aggregate(graph: g)
        #expect(table.rows.count == 1)
        #expect(table.rows[0].prompt == "")
        #expect(table.rows[0].nodeIDs == [s.id])
        #expect(table.sourceNodeID == nil)
    }

    @Test("已展开：N 个分镜节点按 y 排序、sceneIndex 连续、title 取节点标题")
    func expandedNodesOrderedByY() {
        let s1 = sbNode(.storyboard, title: "分镜1", y: 300, params: ["content": "镜一"])
        let s2 = sbNode(.storyboard, title: "分镜2", y: 100, params: ["content": "镜二"])
        let s3 = sbNode(.storyboard, title: "分镜3", y: 200, params: ["content": "镜三"])
        let g = NodeGraph(nodes: [s1, s2, s3], edges: [])
        let table = StoryboardAggregator.aggregate(graph: g)
        #expect(table.rows.count == 3)
        #expect(table.rows.map(\.sceneIndex) == [1, 2, 3])
        #expect(table.rows.map(\.title) == ["分镜2", "分镜3", "分镜1"])
        #expect(table.rows.map(\.prompt) == ["镜二", "镜三", "镜一"])
        #expect(table.sourceNodeID == nil)
    }

    @Test("混合形态：分镜1 有下游带节点组，分镜2..N 无连线为纯文本行")
    func mixedFormFirstShotWithDownstream() {
        let s1 = sbNode(.storyboard, title: "分镜1", y: 100, params: ["content": "镜一"])
        let vp1 = sbNode(.videoPrompt, title: "视频提示词1", y: 300, params: ["content": "VP1 全文"])
        let vg1 = sbNode(.videoGen, title: "视频生成1", y: 500)
        let rg1 = sbNode(.reviewGate, title: "审核1", y: 700, params: ["review.status": "PASS"])
        let s2 = sbNode(.storyboard, title: "分镜2", y: 260, params: ["content": "镜二"])
        let s3 = sbNode(.storyboard, title: "分镜3", y: 420, params: ["content": "镜三"])
        let g = NodeGraph(
            nodes: [s1, vp1, vg1, rg1, s2, s3],
            edges: [sbEdge(s1, vp1), sbEdge(vp1, vg1), sbEdge(vp1, rg1)]
        )
        let table = StoryboardAggregator.aggregate(graph: g)
        #expect(table.rows.count == 3)
        let row1 = table.rows[0]
        #expect(row1.prompt == "VP1 全文")
        #expect(row1.reviewStatus == .pass)
        #expect(row1.nodeIDs == [s1.id, vp1.id, vg1.id, rg1.id])
        #expect(table.rows[1].nodeIDs == [s2.id])
        #expect(table.rows[1].prompt == "镜二")
        #expect(table.rows[2].nodeIDs == [s3.id])
        #expect(table.rows[2].prompt == "镜三")
    }

    @Test("用户手动为分镜2 连线 → 自动升级为完整行（提示词/视频/节点组齐全）")
    func manualWiringUpgradesLaterShot() {
        let s1 = sbNode(.storyboard, title: "分镜1", y: 100, params: ["content": "镜一"])
        let s2 = sbNode(.storyboard, title: "分镜2", y: 260, params: ["content": "镜二"])
        let vp2 = sbNode(.videoPrompt, title: "视频提示词2", y: 460, params: ["content": "VP2 全文"])
        let vg2 = sbNode(.videoGen, title: "视频生成2", y: 660,
                         params: ["result.path": "/shots/shot2.mp4", "result.kind": "video"])
        let g = NodeGraph(nodes: [s1, s2, vp2, vg2], edges: [sbEdge(s2, vp2), sbEdge(vp2, vg2)])
        let table = StoryboardAggregator.aggregate(graph: g)
        #expect(table.rows.count == 2)
        let row2 = table.rows[1]
        #expect(row2.prompt == "VP2 全文")
        #expect(row2.videoRefs == ["/shots/shot2.mp4"])
        #expect(row2.nodeIDs == [s2.id, vp2.id, vg2.id])
    }

    @Test("imageRefs：imageGen 结果（kind==image）+ 上游 assetRef 资产，去重保序")
    func imageRefsDedupedPreservingOrder() {
        let s1 = sbNode(.storyboard, title: "分镜1", y: 100, params: ["content": "镜一"])
        let ig1 = sbNode(.imageGen, y: 300, params: ["result.path": "/gen/a.png", "result.kind": "image"])
        let ig2 = sbNode(.imageGen, y: 400, params: ["result.path": "/gen/d.png", "result.kind": "image"])
        let asset = sbNode(.assetRef, y: 200,
                           params: ["asset.images": #"["/asset/b.png","/gen/a.png","/asset/c.png"]"#])
        let g = NodeGraph(nodes: [s1, ig1, ig2, asset],
                          edges: [sbEdge(s1, ig1), sbEdge(s1, ig2), sbEdge(asset, ig1)])
        let row = StoryboardAggregator.aggregate(graph: g).rows[0]
        #expect(row.imageRefs == ["/gen/a.png", "/gen/d.png", "/asset/b.png", "/asset/c.png"])
        #expect(!row.nodeIDs.contains(asset.id)) // assetRef 不入主链
    }

    @Test("imageRefs：result.kind 非 image 不入图参考")
    func imageRefsSkipNonImageKind() {
        let s = sbNode(.storyboard, title: "分镜1", y: 100)
        let ig = sbNode(.imageGen, y: 300, params: ["result.path": "/gen/v.mp4", "result.kind": "video"])
        let g = NodeGraph(nodes: [s, ig], edges: [sbEdge(s, ig)])
        #expect(StoryboardAggregator.aggregate(graph: g).rows[0].imageRefs.isEmpty)
    }

    @Test("reviewStatus：PASS/REJECT/PENDING/未知→pending/缺失→pending")
    func reviewStatusMapping() {
        func row(for params: [String: String]?) -> StoryboardRow? {
            let s = sbNode(.storyboard, title: "分镜1", y: 100)
            let rg = sbNode(.reviewGate, y: 300, params: params)
            let g = NodeGraph(nodes: [s, rg], edges: [sbEdge(s, rg)])
            return StoryboardAggregator.aggregate(graph: g).rows.first
        }
        #expect(row(for: ["review.status": "PASS"])?.reviewStatus == .pass)
        #expect(row(for: ["review.status": "REJECT"])?.reviewStatus == .reject)
        #expect(row(for: ["review.status": "PENDING"])?.reviewStatus == .pending)
        #expect(row(for: ["review.status": "未知值"])?.reviewStatus == .pending)
        #expect(row(for: nil)?.reviewStatus == .pending)
    }

    @Test("notes：读取 reviewGate 的 review.reason（只读支持，不写入）")
    func notesFromReviewReason() {
        let s = sbNode(.storyboard, title: "分镜1", y: 100)
        let rg = sbNode(.reviewGate, y: 300,
                        params: ["review.status": "REJECT", "review.reason": "首帧穿帮"])
        let g = NodeGraph(nodes: [s, rg], edges: [sbEdge(s, rg)])
        let row = StoryboardAggregator.aggregate(graph: g).rows[0]
        #expect(row.reviewStatus == .reject)
        #expect(row.notes == "首帧穿帮")
    }

    @Test("videoRefs：params 未回填时从 outputs[\"video\"] 兜底读取")
    func videoRefsFallbackToOutputs() {
        let s = sbNode(.storyboard, title: "分镜1", y: 100)
        let vp = sbNode(.videoPrompt, y: 300, params: ["content": "VP"])
        let vg = sbNode(.videoGen, y: 500)
        let g = NodeGraph(nodes: [s, vp, vg], edges: [sbEdge(s, vp), sbEdge(vp, vg)])
        let table = StoryboardAggregator.aggregate(graph: g,
                                                   outputs: [vg.id: ["video": "/shots/shot1.mp4"]])
        #expect(table.rows[0].videoRefs == ["/shots/shot1.mp4"])
    }

    @Test("videoRefs：params 已回填 result.path（kind==video）优先于 outputs 兜底")
    func videoRefsParamsPrecedeOutputsFallback() {
        let s = sbNode(.storyboard, title: "分镜1", y: 100)
        let vp = sbNode(.videoPrompt, y: 300, params: ["content": "VP"])
        let vg = sbNode(.videoGen, y: 500,
                        params: ["result.path": "/shots/from-params.mp4", "result.kind": "video"])
        let g = NodeGraph(nodes: [s, vp, vg], edges: [sbEdge(s, vp), sbEdge(vp, vg)])
        let table = StoryboardAggregator.aggregate(graph: g,
                                                   outputs: [vg.id: ["video": "/shots/from-outputs.mp4"]])
        #expect(table.rows[0].videoRefs == ["/shots/from-params.mp4"])
    }

    @Test("canonical MediaAsset ID 优先提供生成媒体路径，避免依赖 result.*")
    func canonicalMediaAssetsProvideGeneratedPaths() {
        let canvasID = UUID()
        let imageNode = sbNode(.imageGen, y: 300, params: [
            "asset.id": "00000000-0000-0000-0000-000000000001"
        ])
        let videoNode = sbNode(.videoGen, y: 500, params: [
            "asset.id": "00000000-0000-0000-0000-000000000002"
        ])
        let storyboard = sbNode(.storyboard, title: "分镜", y: 100)
        let imageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let videoID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let image = MediaAsset(
            id: imageID,
            kind: .image,
            source: .generated,
            localURL: "/canonical/generated.png",
            sourceCanvasID: canvasID,
            sourceNodeID: imageNode.id
        )
        let video = MediaAsset(
            id: videoID,
            kind: .video,
            source: .generated,
            localURL: "/canonical/generated.mp4",
            sourceCanvasID: canvasID,
            sourceNodeID: videoNode.id
        )
        let graph = NodeGraph(
            nodes: [storyboard, imageNode, videoNode],
            edges: [sbEdge(storyboard, imageNode), sbEdge(storyboard, videoNode)]
        )

        let table = StoryboardAggregator.aggregate(
            graph: graph,
            mediaAssets: [image, video]
        )

        #expect(table.rows[0].imageRefs == ["/canonical/generated.png"])
        #expect(table.rows[0].videoRefs == ["/canonical/generated.mp4"])
    }

    @Test("图存在环：visited 截断不 deadlock，nodeIDs 有限且无重复")
    func cycleDoesNotDeadlock() {
        let s = sbNode(.storyboard, title: "分镜1", y: 100)
        let vp = sbNode(.videoPrompt, y: 300, params: ["content": "VP"])
        let ig = sbNode(.imageGen, y: 500)
        let g = NodeGraph(nodes: [s, vp, ig], edges: [sbEdge(s, vp), sbEdge(vp, ig), sbEdge(ig, vp)])
        let row = StoryboardAggregator.aggregate(graph: g).rows[0]
        #expect(row.nodeIDs == [s.id, vp.id, ig.id])
        #expect(Set(row.nodeIDs).count == row.nodeIDs.count)
    }

    @Test("多个分镜接同一 assetRef：资产路径并入各行（共享不独占）")
    func sharedAssetRefMergedIntoEachRow() {
        let s1 = sbNode(.storyboard, title: "分镜1", y: 100)
        let vp1 = sbNode(.videoPrompt, y: 300, params: ["content": "VP1"])
        let vg1 = sbNode(.videoGen, y: 500)
        let s2 = sbNode(.storyboard, title: "分镜2", y: 700)
        let vp2 = sbNode(.videoPrompt, y: 900, params: ["content": "VP2"])
        let vg2 = sbNode(.videoGen, y: 1100)
        let asset = sbNode(.assetRef, y: 200, params: ["asset.videos": #"["/asset/ref.mp4"]"#])
        let g = NodeGraph(
            nodes: [s1, vp1, vg1, s2, vp2, vg2, asset],
            edges: [sbEdge(s1, vp1), sbEdge(vp1, vg1), sbEdge(asset, vg1),
                    sbEdge(s2, vp2), sbEdge(vp2, vg2), sbEdge(asset, vg2)]
        )
        let table = StoryboardAggregator.aggregate(graph: g)
        #expect(table.rows.count == 2)
        #expect(table.rows[0].videoRefs == ["/asset/ref.mp4"])
        #expect(table.rows[1].videoRefs == ["/asset/ref.mp4"])
        #expect(!table.rows[0].nodeIDs.contains(asset.id))
    }

    @Test("prompt 优先级：videoPrompt → imagePrompt → 分镜节点自身内容")
    func promptPriorityChain() {
        let s = sbNode(.storyboard, title: "分镜1", y: 100, params: ["content": "锚点内容"])
        let vp = sbNode(.videoPrompt, y: 300, params: ["content": "VP 内容"])
        let ip = sbNode(.imagePrompt, y: 400, params: ["content": "IP 内容"])
        let g = NodeGraph(nodes: [s, vp, ip], edges: [sbEdge(s, vp), sbEdge(s, ip)])
        #expect(StoryboardAggregator.aggregate(graph: g).rows[0].prompt == "VP 内容")

        let g2 = NodeGraph(nodes: [s, ip], edges: [sbEdge(s, ip)])
        #expect(StoryboardAggregator.aggregate(graph: g2).rows[0].prompt == "IP 内容")

        let g3 = NodeGraph(nodes: [s], edges: [])
        #expect(StoryboardAggregator.aggregate(graph: g3).rows[0].prompt == "锚点内容")
    }

    @Test("防串镜：两分镜共享同一 videoPrompt → 两行都不收集（前驱未全来自本镜）")
    func sharedDownstreamBlockedForBothShots() {
        let s1 = sbNode(.storyboard, title: "分镜1", y: 100, params: ["content": "镜一"])
        let s2 = sbNode(.storyboard, title: "分镜2", y: 300, params: ["content": "镜二"])
        let sharedVP = sbNode(.videoPrompt, y: 500, params: ["content": "共享 VP"])
        let g = NodeGraph(nodes: [s1, s2, sharedVP],
                          edges: [sbEdge(s1, sharedVP), sbEdge(s2, sharedVP)])
        let table = StoryboardAggregator.aggregate(graph: g)
        #expect(table.rows.count == 2)
        #expect(table.rows[0].nodeIDs == [s1.id])
        #expect(table.rows[1].nodeIDs == [s2.id])
        #expect(table.rows[0].prompt == "镜一")
        #expect(table.rows[1].prompt == "镜二")
    }

    @Test("一键流水线图：单分镜（无内容）→ 1 行完整节点组（BFS 顺序 锚点→提示词→生成→审核→质检）")
    func fullPipelineSingleRow() {
        let graph = ManjuPipelineTemplate.makeManjuPipeline()
        let table = StoryboardAggregator.aggregate(graph: graph)
        #expect(table.rows.count == 1)
        let row = table.rows[0]
        let types = row.nodeIDs.compactMap { graph.node(id: $0)?.type }
        #expect(types == ["storyboard", "imagePrompt", "videoPrompt",
                          "imageGen", "videoGen", "reviewGate", "qcCheck"])
        #expect(row.reviewStatus == .pending)
        #expect(!row.nodeIDs.isEmpty)
    }
}
