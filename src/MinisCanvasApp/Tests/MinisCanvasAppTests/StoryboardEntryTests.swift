import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - P2 分镜表工作台入口（设计文档 issues/p2_storyboard_design_20260805.md §5.1）
//
// 覆盖 4 组：
// 1. shouldOpenWorkbench 纯函数：仅 storyboard 类型打开工作台（双击分派依据）
// 2. openStoryboardWorkbench(for:)：分镜节点 → 面板弹出 + 选中节点 + 记录选中锚点 + reveal；
//    非分镜节点 / 不存在节点 → false 且状态零改动
// 3. storyboardRow(for:)：分镜节点反查所在分镜行；非分镜节点 → nil
// 4. closeStoryboardWorkbench()：关闭面板并清空选中锚点
//
// 注：测试显式构造 CanvasNode（不依赖 NodeTypeRegistry 规格，避免与其他任务并行改动冲突）。
// 选中行用「锚点节点 id」定位而非 StoryboardRow.id——聚合每次重建行、id 随机生成（探针实证）。

@Suite("P2 分镜表工作台入口（双击/右键菜单）")
@MainActor
struct StoryboardEntryTests {

    /// 构造分镜节点并加入 store 图
    private func makeStoryboardNode(in store: CanvasStore, title: String = "分镜",
                                    y: Double = 200) -> CanvasNode {
        let node = CanvasNode(
            type: ManjuNodeType.storyboard.rawValue,
            title: title,
            position: Point(x: 100, y: y)
        )
        store.graph.addNode(node)
        return node
    }

    // MARK: - 1) shouldOpenWorkbench 纯函数（双击分派依据）

    @Test func shouldOpenWorkbenchOnlyForStoryboard() {
        #expect(CanvasStore.shouldOpenWorkbench(nodeType: CanvasStore.storyboardNodeType),
                "storyboard 类型双击应打开工作台")
        #expect(CanvasStore.storyboardNodeType == ManjuNodeType.storyboard.rawValue,
                "常量应与 ManjuNodeType.storyboard 保持一致")
    }

    @Test func shouldOpenWorkbenchFalseForOtherTypes() {
        for type in ManjuNodeType.allCases where type != .storyboard {
            #expect(!CanvasStore.shouldOpenWorkbench(nodeType: type.rawValue),
                    "\(type.rawValue) 双击不应打开工作台（维持内容编辑）")
        }
        #expect(!CanvasStore.shouldOpenWorkbench(nodeType: "unknown"),
                "未知类型不应打开工作台")
        #expect(!CanvasStore.shouldOpenWorkbench(nodeType: ""),
                "空类型不应打开工作台")
    }

    // MARK: - 2) openStoryboardWorkbench(for:) 打开行为

    @Test func openWorkbenchFromStoryboardNode() {
        let store = CanvasStore()
        let node = makeStoryboardNode(in: store)

        #expect(store.openStoryboardWorkbench(for: node.id))
        #expect(store.showStoryboardWorkbench, "面板应弹出")
        #expect(store.selectedNodeIDs.contains(node.id), "应选中该分镜节点（反向高亮对应行）")
        #expect(store.storyboardSelectedNodeID == node.id, "应记录选中锚点 = 该节点 id")
        #expect(store.revealRequest != nil, "应发出 reveal 视口定位")
        #expect(store.revealRequest?.center == node.position, "reveal 中心应为节点位置")

        // 锚点反查：当前聚合结果中应有 nodeIDs 含该节点的行（未展开：切段行 nodeIDs = [锚点]）
        let rows = StoryboardAggregator.aggregate(graph: store.graph).rows
        #expect(rows.contains { $0.nodeIDs.contains(node.id) }, "聚合结果应含该节点所在行")
        // 视图侧定位同一行：nodeIDs 反查命中（与 StoryboardWorkbenchView.selectedRowID 同逻辑）
        #expect(rows.first { $0.nodeIDs.contains(node.id) } != nil)
    }

    @Test func openWorkbenchTwiceKeepsSingleSelection() {
        let store = CanvasStore()
        let node1 = makeStoryboardNode(in: store, y: 200)
        let node2 = makeStoryboardNode(in: store, title: "分镜2", y: 400)

        store.openStoryboardWorkbench(for: node1.id)
        store.openStoryboardWorkbench(for: node2.id)
        #expect(store.showStoryboardWorkbench)
        #expect(store.selectedNodeIDs == [node2.id], "后打开的分镜节点应成为唯一选中")
        #expect(store.storyboardSelectedNodeID == node2.id, "选中锚点应切换为后打开的节点")
        // 反查应命中 node2 所在行（y 排序第二行）
        let rows = StoryboardAggregator.aggregate(graph: store.graph).rows
        let row = rows.first { $0.nodeIDs.contains(node2.id) }
        #expect(row != nil && row?.sceneIndex == 2, "应命中镜号 2 的行")
    }

    @Test func openWorkbenchIgnoresNonStoryboardNode() {
        let store = CanvasStore()
        let node = CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "生图")
        store.graph.addNode(node)

        #expect(!store.openStoryboardWorkbench(for: node.id))
        #expect(!store.showStoryboardWorkbench, "非分镜节点双击不应打开工作台")
        #expect(store.storyboardSelectedNodeID == nil)
        #expect(store.revealRequest == nil)
    }

    @Test func openWorkbenchIgnoresMissingNode() {
        let store = CanvasStore()
        #expect(!store.openStoryboardWorkbench(for: UUID()))
        #expect(!store.showStoryboardWorkbench)
        #expect(store.storyboardSelectedNodeID == nil)
        #expect(store.revealRequest == nil)
    }

    // MARK: - 3) storyboardRow(for:) 反查

    @Test func storyboardRowLookupHitsStoryboardNode() {
        let store = CanvasStore()
        let node = makeStoryboardNode(in: store)
        let row = store.storyboardRow(for: node.id)
        #expect(row != nil, "分镜节点应反查到所在分镜行")
        #expect(row?.nodeIDs.contains(node.id) == true)
    }

    @Test func storyboardRowLookupMissesOtherNode() {
        let store = CanvasStore()
        _ = makeStoryboardNode(in: store)
        let other = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "生视频")
        store.graph.addNode(other)
        #expect(store.storyboardRow(for: other.id) == nil, "非分镜节点不应反查到行")
    }

    // MARK: - 4) closeStoryboardWorkbench() 关闭与清理

    @Test func closeWorkbenchClearsSelection() {
        let store = CanvasStore()
        let node = makeStoryboardNode(in: store)
        store.openStoryboardWorkbench(for: node.id)
        #expect(store.showStoryboardWorkbench)

        store.closeStoryboardWorkbench()
        #expect(!store.showStoryboardWorkbench, "面板应关闭")
        #expect(store.storyboardSelectedNodeID == nil, "选中锚点应清空（避免下次打开残留高亮）")
    }
}
