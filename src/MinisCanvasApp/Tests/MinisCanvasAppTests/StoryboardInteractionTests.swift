import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - P2 分镜表交互增强（issues/p2_storyboard_interaction_20260805.md）
//
// ① 互斥：文本面板（textInspectorNodeID）与分镜表（showStoryboardWorkbench）
//    在 CanvasStore 层 didSet 协调，两个右侧悬浮面板不再同侧叠盖。
// ② 包围盒中心：boundingBoxCenter(of:in:) = 节点组 min/max 中点（行 reveal 定位锚点）。
// ③ 列表体验：选中行滚动可见为视图层（ScrollViewReader + scrollTo），本文件覆盖其可测逻辑
//    （选中态由 store.storyboardSelectedNodeID 驱动）。
//
// 冲突面评估（① 的结论）：分镜表行节点类型（storyboard/videoPrompt/imageGen/videoGen/
// reviewGate/qcCheck/assetRef）均不属于 textNodeTypes（text/novelImport/blenderPreview），
// 因此 selectRow 的 selectNode 不会弹文本面板——互斥 didSet 不会因行单击误关工作台；
// 真实冲突面只有「文本面板开着 → 打开工作台」与「工作台开着 → 画布点文本节点」两个方向。

@Suite("P2 分镜表交互：互斥 + 包围盒定位")
@MainActor
struct StoryboardInteractionTests {

    private func makeNode(_ type: String, _ title: String, _ p: Point) -> CanvasNode {
        CanvasNode(type: type, title: title, position: p, inputs: [], outputs: [])
    }

    // MARK: ② 包围盒中心（纯函数）

    @Test func bboxCenterOfSingleNodeIsItsPosition() {
        let n = makeNode(ManjuNodeType.storyboard.rawValue, "分镜1", Point(x: 100, y: 200))
        let graph = NodeGraph(nodes: [n], edges: [])
        let center = CanvasStore.boundingBoxCenter(of: [n.id], in: graph)
        #expect(center != nil)
        #expect(abs(center!.x - 100) < 0.001 && abs(center!.y - 200) < 0.001,
                "单节点：包围盒中心退化为节点自身 position（与旧行为一致）")
    }

    @Test func bboxCenterIsMinMaxMidpointOfGroup() {
        // 镜头生产链四节点组：x ∈ [100, 300]，y ∈ [100, 500] → 中心 (200, 300)
        let nodes = [
            makeNode(ManjuNodeType.storyboard.rawValue, "分镜1", Point(x: 100, y: 100)),
            makeNode(ManjuNodeType.videoPrompt.rawValue, "提示词", Point(x: 300, y: 100)),
            makeNode(ManjuNodeType.videoGen.rawValue, "生成", Point(x: 100, y: 500)),
            makeNode(ManjuNodeType.reviewGate.rawValue, "审核", Point(x: 300, y: 500)),
        ]
        let graph = NodeGraph(nodes: nodes, edges: [])
        let center = CanvasStore.boundingBoxCenter(of: nodes.map(\.id), in: graph)
        #expect(center != nil)
        #expect(abs(center!.x - 200) < 0.001 && abs(center!.y - 300) < 0.001,
                "组包围盒中心 = min/max 中点，而非首节点位置")
    }

    @Test func bboxCenterEmptyOrAllMissingReturnsNil() {
        let graph = NodeGraph(nodes: [], edges: [])
        #expect(CanvasStore.boundingBoxCenter(of: [], in: graph) == nil, "空组 → nil（调用方跳过 reveal）")
        #expect(CanvasStore.boundingBoxCenter(of: [UUID()], in: graph) == nil, "节点全部缺失 → nil")
    }

    @Test func bboxCenterIgnoresMissingIDsAmongValidOnes() {
        let a = makeNode(ManjuNodeType.storyboard.rawValue, "分镜1", Point(x: 10, y: 20))
        let b = makeNode(ManjuNodeType.videoGen.rawValue, "生成", Point(x: 110, y: 120))
        let graph = NodeGraph(nodes: [a, b], edges: [])
        // 混入两个不存在的 id：只取有效节点参与 min/max
        let center = CanvasStore.boundingBoxCenter(of: [UUID(), a.id, UUID(), b.id], in: graph)
        #expect(center != nil)
        #expect(abs(center!.x - 60) < 0.001 && abs(center!.y - 70) < 0.001)
    }

    // MARK: ① 互斥（store 层 didSet 协调）

    @Test func openingWorkbenchClosesTextInspector() {
        let store = CanvasStore()
        store.textInspectorNodeID = UUID()          // 文本面板先开
        #expect(store.showStoryboardWorkbench == false)
        store.showStoryboardWorkbench = true        // 打开分镜表 → 文本面板让位
        #expect(store.textInspectorNodeID == nil, "打开分镜表必须收起文本面板（消除叠盖）")
        #expect(store.showStoryboardWorkbench == true)
    }

    @Test func openingTextInspectorClosesWorkbench() {
        let store = CanvasStore()
        store.showStoryboardWorkbench = true
        store.textInspectorNodeID = UUID()          // 打开文本面板 → 工作台让位
        #expect(store.showStoryboardWorkbench == false, "打开文本面板必须收起分镜表（消除叠盖）")
        #expect(store.textInspectorNodeID != nil)
    }

    @Test func closingTextInspectorDoesNotReopenWorkbench() {
        let store = CanvasStore()
        store.showStoryboardWorkbench = true
        store.textInspectorNodeID = UUID()
        #expect(store.showStoryboardWorkbench == false)
        store.textInspectorNodeID = nil             // 用户手动关闭文本面板
        #expect(store.showStoryboardWorkbench == false, "关文本面板不得复活分镜表（互斥单向）")
    }

    @Test func closingWorkbenchKeepsTextInspectorClosed() {
        let store = CanvasStore()
        store.textInspectorNodeID = UUID()
        store.showStoryboardWorkbench = true        // 互斥后文本面板已被收起
        store.showStoryboardWorkbench = false       // 再关工作台
        #expect(store.textInspectorNodeID == nil, "关工作台不得复活文本面板（互斥单向）")
    }

    @Test func closeStoryboardWorkbenchClearsAnchorAndKeepsExclusion() {
        let n = makeNode(ManjuNodeType.storyboard.rawValue, "分镜1", Point(x: 10, y: 10))
        let store = CanvasStore(graph: NodeGraph(nodes: [n], edges: []))
        store.showStoryboardWorkbench = true
        store.storyboardSelectedNodeID = n.id
        store.closeStoryboardWorkbench()
        #expect(store.showStoryboardWorkbench == false)
        #expect(store.storyboardSelectedNodeID == nil, "关闭工作台清空选中锚点，避免下次打开残留高亮")
        #expect(store.textInspectorNodeID == nil)
    }

    // MARK: ① 冲突面评估（行联动不弹文本面板的回归守护）

    @Test func selectingStoryboardRowAnchorDoesNotOpenTextInspector() {
        // 分镜表行锚点节点（storyboard 类型）不属于文本类 → selectNode 不弹文本面板，
        // 互斥 didSet 不会因行单击误关工作台（任务 ①「冲突面小」结论的回归守护）。
        let n = makeNode(ManjuNodeType.storyboard.rawValue, "分镜1", Point(x: 10, y: 10))
        let store = CanvasStore(graph: NodeGraph(nodes: [n], edges: []))
        store.showStoryboardWorkbench = true
        store.selectNode(id: n.id)
        #expect(store.selectedNodeIDs == [n.id])
        #expect(store.textInspectorNodeID == nil, "storyboard 节点不属于文本类，不弹文本面板")
        #expect(store.showStoryboardWorkbench == true, "行单击联动保持工作台打开")
    }

    @Test func selectingCanvasTextNodeWhileWorkbenchOpenClosesWorkbench() {
        // 真实冲突面：工作台开着时在画布点 text 节点 → 文本面板弹出 → 互斥收起工作台
        let n = makeNode("text", "文本", Point(x: 10, y: 10))
        let store = CanvasStore(graph: NodeGraph(nodes: [n], edges: []))
        store.showStoryboardWorkbench = true
        store.selectNode(id: n.id)
        #expect(store.textInspectorNodeID == n.id, "text 节点属于文本类，应弹文本面板")
        #expect(store.showStoryboardWorkbench == false, "文本面板弹出 → 互斥收起分镜表")
    }

    @Test func openStoryboardWorkbenchEntryClosesTextInspector() {
        // 入口1（双击分镜节点）与互斥的整合：文本面板开着时双击分镜节点打开工作台
        let n = makeNode(ManjuNodeType.storyboard.rawValue, "分镜1", Point(x: 10, y: 10))
        let store = CanvasStore(graph: NodeGraph(nodes: [n], edges: []))
        store.textInspectorNodeID = UUID()
        let opened = store.openStoryboardWorkbench(for: n.id)
        #expect(opened)
        #expect(store.showStoryboardWorkbench == true)
        #expect(store.textInspectorNodeID == nil, "工作台入口打开 → 文本面板让位")
    }

    @Test func openStoryboardWorkbenchRejectsNonStoryboardNode() {
        let n = makeNode("text", "文本", Point(x: 10, y: 10))
        let store = CanvasStore(graph: NodeGraph(nodes: [n], edges: []))
        store.showStoryboardWorkbench = true
        let opened = store.openStoryboardWorkbench(for: n.id)
        #expect(!opened, "非分镜节点不得打开工作台")
        #expect(store.showStoryboardWorkbench == true, "拒绝打开不改任何状态（guard 早退）")
        #expect(store.storyboardSelectedNodeID == nil)
    }
}
