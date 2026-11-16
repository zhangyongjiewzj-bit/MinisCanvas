import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - P1 分镜批量展开（画布逻辑审查 P1 缺口修复：一集几十镜一键铺开）

@Suite("P1 分镜批量展开")
@MainActor
struct ManjuStoryboardExpandTests {

    /// 模板图：storyboard 节点带 text 输入 / text+frames 输出，下游 imagePrompt/videoPrompt/blenderPreview
    private func templateStore(script: String) -> CanvasStore {
        let store = CanvasStore(graph: ManjuPipelineTemplate.makeManjuPipeline(assets: .demo))
        let sb = store.graph.nodes.first { $0.type == ManjuNodeType.storyboard.rawValue }!
        store.setContent(nodeID: sb.id, content: script)
        return store
    }

    private func storyboardNode(_ store: CanvasStore) -> CanvasNode {
        store.graph.nodes.first { $0.type == ManjuNodeType.storyboard.rawValue }!
    }

    @Test("按镜号切分展开：3 段 → 3 个分镜节点，内容分段写入")
    func expandByMarkers() throws {
        let script = """
        第1镜：魏衔踏雾而来。
        第2镜：大殿香炉青烟。
        第3镜：神像暗部。
        """
        let store = templateStore(script: script)
        let before = store.graph.nodes.count
        let sb = storyboardNode(store)

        let count = store.expandStoryboard(nodeID: sb.id)

        #expect(count == 3)
        #expect(store.graph.nodes.count == before + 2)
        let expanded = store.graph.nodes.filter { $0.type == ManjuNodeType.storyboard.rawValue }
        #expect(expanded.count == 3)
        #expect(expanded.map(\.title).sorted() == ["分镜1", "分镜2", "分镜3"])
        // 内容分段写入各节点
        #expect(expanded.first { $0.title == "分镜1" }?.backendConfig?.params["content"]?.contains("第1镜") == true)
        #expect(expanded.first { $0.title == "分镜2" }?.backendConfig?.params["content"]?.contains("第2镜") == true)
        #expect(expanded.first { $0.title == "分镜3" }?.backendConfig?.params["content"]?.contains("第3镜") == true)
    }

    @Test("原入/出边迁移到分镜1：主链与下游支线不丢")
    func edgesMigrateToFirstSegment() throws {
        let store = templateStore(script: "第1镜：A。\n第2镜：B。")
        let sb = storyboardNode(store)
        let scriptNode = store.graph.nodes.first { $0.type == ManjuNodeType.script.rawValue }!
        let imagePrompt = store.graph.nodes.first { $0.type == ManjuNodeType.imagePrompt.rawValue }!
        let videoPrompt = store.graph.nodes.first { $0.type == ManjuNodeType.videoPrompt.rawValue }!
        let blender = store.graph.nodes.first { $0.type == ManjuNodeType.blenderPreview.rawValue }!

        store.expandStoryboard(nodeID: sb.id)

        let first = try #require(store.graph.nodes.first { $0.title == "分镜1" })
        // 入边：script → 分镜1（原 storyboard 的入边迁移）
        #expect(!store.graph.edges(from: scriptNode.id, to: first.id).isEmpty)
        // 出边：分镜1 → imagePrompt / videoPrompt / blenderPreview（原 storyboard 的出边迁移）
        #expect(!store.graph.edges(from: first.id, to: imagePrompt.id).isEmpty)
        #expect(!store.graph.edges(from: first.id, to: videoPrompt.id).isEmpty)
        #expect(!store.graph.edges(from: first.id, to: blender.id).isEmpty)
        // 原节点已删除
        #expect(store.graph.node(id: sb.id) == nil)
        // 无悬空边（所有边两端节点都存在）
        for edge in store.graph.edges {
            #expect(store.graph.node(id: edge.fromNode) != nil)
            #expect(store.graph.node(id: edge.toNode) != nil)
        }
    }

    @Test("分镜节点纵向排列（x 相同，y 递增 160）")
    func positionsStackVertically() throws {
        let store = templateStore(script: "第1镜：A。\n第2镜：B。\n第3镜：C。")
        let sb = storyboardNode(store)
        let baseY = sb.position.y

        store.expandStoryboard(nodeID: sb.id)

        let expanded = store.graph.nodes
            .filter { $0.type == ManjuNodeType.storyboard.rawValue }
            .sorted { $0.position.y < $1.position.y }
        #expect(expanded.count == 3)
        #expect(expanded[0].position.x == sb.position.x)
        #expect(expanded[0].position.y == baseY)
        #expect(expanded[1].position.y == baseY + 160)
        #expect(expanded[2].position.y == baseY + 320)
    }

    @Test("非分镜节点/内容不足 2 段 → 不改图")
    func noOpOnInvalidInput() {
        // 非分镜节点
        let store = CanvasStore()
        let llm = try! #require(store.addNode(ofType: "llm"))
        #expect(store.expandStoryboard(nodeID: llm.id) == 0)
        #expect(store.graph.nodes.count == 1)

        // 内容仅 1 段 → 返回 1 不改图
        let store2 = templateStore(script: "只有一个镜头。")
        let sb = storyboardNode(store2)
        let before = store2.graph.nodes.count
        #expect(store2.expandStoryboard(nodeID: sb.id) == 1)
        #expect(store2.graph.nodes.count == before)
    }

    @Test("空内容分镜 → 不展开（返回 0）")
    func emptyContentNoExpand() {
        let store = templateStore(script: "")
        let sb = storyboardNode(store)
        let before = store.graph.nodes.count
        #expect(store.expandStoryboard(nodeID: sb.id) == 0)
        #expect(store.graph.nodes.count == before)
    }
}
