import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - 画布交互 Bug 第二轮回归（QA_CANVAS_BUGS2）
//
// 覆盖本轮修复的 7 项：
// 1. 折叠分组清除隐藏成员的选中态（防 Delete 删隐形节点 / ⌘C 复制隐形子图）
// 2. collapsedHiddenNodeIDs 只含折叠组隐藏成员
// 3. 拖线吸附跳过折叠组隐形端口（防连到看不见的端口）
// 4. 右键「粘贴」pasteNode(near:) 不触发 reveal 平移视口（视野不被拉走）
// 5. ⌘A 全选排除折叠组隐形节点
// 6. 折叠后 deleteSelected 不误删隐形成员
// 7. 仅裸 Delete / fn-Delete / ⌘Delete 触发删除（⌥/⌃/⇧ 组合放行）——逻辑守卫随事件处理

@Suite("画布交互 Bug 第二轮回归")
@MainActor
struct CanvasBugs2RegressionTests {

    // MARK: - 1) 折叠分组清除隐藏成员选中态

    @Test func collapsingGroupClearsHiddenMembersFromSelection() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let group = try! #require(store.createGroup(nodeIDs: [a.id]))

        // 多选 A（组内）+ B（组外）
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        #expect(store.selectedNodeIDs == [a.id, b.id])

        // 折叠分组 → A 隐形，从选中集合清除；B 保留
        store.toggleGroupCollapsed(id: group.id)
        #expect(store.selectedNodeIDs == [b.id], "折叠后组内成员须从选中集合移除")
        #expect(store.selectedNodeID == b.id)

        // 展开分组不恢复旧选中（隐形期间的选择变更不回溯）
        store.toggleGroupCollapsed(id: group.id)
        #expect(store.selectedNodeIDs == [b.id])
    }

    @Test func collapsingGroupWithAllSelectedClearsSelectionAndBroadcasts() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let group = try! #require(store.createGroup(nodeIDs: [a.id]))
        store.selectNode(id: a.id)
        #expect(store.selectedNodeID == a.id)

        store.toggleGroupCollapsed(id: group.id)
        #expect(store.selectedNodeIDs.isEmpty)
        #expect(store.selectedNodeID == nil)
    }

    // MARK: - 2) collapsedHiddenNodeIDs 只含折叠组隐藏成员

    @Test func collapsedHiddenNodeIDsReflectsCollapsedState() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let c = try! #require(store.addNode(ofType: "text"))
        let g1 = try! #require(store.createGroup(nodeIDs: [a.id, b.id]))
        let g2 = try! #require(store.createGroup(nodeIDs: [c.id]))

        #expect(store.collapsedHiddenNodeIDs().isEmpty)
        store.toggleGroupCollapsed(id: g1.id)
        #expect(store.collapsedHiddenNodeIDs() == [a.id, b.id], "只含折叠组的成员")
        store.toggleGroupCollapsed(id: g1.id)
        #expect(store.collapsedHiddenNodeIDs().isEmpty)
        store.toggleGroupCollapsed(id: g2.id)
        #expect(store.collapsedHiddenNodeIDs() == [c.id])
    }

    // MARK: - 3) 拖线吸附跳过折叠组隐形端口

    private func makeOutInPair() -> (store: CanvasStore, outNode: CanvasNode, inNode: CanvasNode,
                                     outPort: CanvasCore.Port, inPort: CanvasCore.Port) {
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let outNode = CanvasNode(type: "t", title: "A", position: Point(x: 300, y: 300),
                                 inputs: [], outputs: [outPort])
        let inNode = CanvasNode(type: "t", title: "B", position: Point(x: 600, y: 300),
                                inputs: [inPort], outputs: [])
        return (CanvasStore(graph: NodeGraph(nodes: [outNode, inNode], edges: [])),
                outNode, inNode, outPort, inPort)
    }

    @Test func edgeSnapSkipsPortsOfCollapsedHiddenNodes() {
        let (store, outNode, inNode, outPort, inPort) = makeOutInPair()
        // 对照组：未折叠时拖到 B 的输入口 → 正常吸附
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.updateEdgeEnd(store.portAnchor(for: inNode, port: inPort))
        #expect(store.edgeTarget?.portID == inPort.id, "未折叠时端口应可吸附")

        // B 入组并折叠 → 隐形端口不可吸附
        let group = try! #require(store.createGroup(nodeIDs: [inNode.id]))
        store.toggleGroupCollapsed(id: group.id)
        store.beginEdge(from: outNode.id, portID: outPort.id,
                        at: store.portAnchor(for: outNode, port: outPort))
        store.updateEdgeEnd(store.portAnchor(for: inNode, port: inPort))
        #expect(store.edgeTarget == nil, "折叠组隐形端口不得作为连线目标")
        #expect(store.edgeTargetValid)

        // 落线同样不产生连线
        store.endEdge(at: store.portAnchor(for: inNode, port: inPort))
        #expect(store.graph.edges.isEmpty)
    }

    // MARK: - 4) 右键粘贴不触发 reveal

    @Test func rightClickPasteDoesNotTriggerRevealButCmdVPasteDoes() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        store.selectNode(id: node.id)
        #expect(store.copySelection())

        // 右键「粘贴」贴原节点旁：内容本就可见 → 不发 reveal（视野不被拉走）
        let pasted = store.pasteNode(near: node.id)
        #expect(pasted.count == 1)
        #expect(store.revealRequest == nil, "右键粘贴不应触发 reveal 平移视口")

        // ⌘V 粘贴（默认 reveal: true）→ 发揭示请求
        _ = store.paste(at: Point(x: 800, y: 600))
        #expect(store.revealRequest != nil, "⌘V 粘贴应发 reveal 请求")
        let center = store.revealRequest?.center
        #expect(center != nil)
    }

    // MARK: - 5) ⌘A 全选排除折叠组隐形节点

    @Test func selectAllSkipsCollapsedHiddenMembers() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let c = try! #require(store.addNode(ofType: "text"))
        let group = try! #require(store.createGroup(nodeIDs: [a.id, b.id]))
        store.toggleGroupCollapsed(id: group.id)

        store.selectAllNodes()
        #expect(store.selectedNodeIDs == [c.id], "⌘A 只选可见节点，不选折叠组隐形成员")
    }

    // MARK: - 6) 折叠后 deleteSelected 不误删隐形成员

    @Test func deleteAfterCollapseDoesNotDeleteHiddenMembers() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let group = try! #require(store.createGroup(nodeIDs: [a.id]))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        store.toggleGroupCollapsed(id: group.id)   // A 隐形并从选中清除

        #expect(store.deleteSelected())            // 只删 B
        #expect(store.graph.node(id: b.id) == nil)
        #expect(store.graph.node(id: a.id) != nil, "折叠组隐形成员不得被 Delete 误删")
    }

    // MARK: - 7) Delete 键修饰守卫（放行 ⌥/⌃/⇧ 组合的判定逻辑）

    @Test func deleteKeyCodeStillRecognized() {
        // 裸 Delete / fn-Delete 仍是删除键（keyCode 判定不变）
        #expect(CanvasKeyboardCatcher.isDeleteKeyCode(51))
        #expect(CanvasKeyboardCatcher.isDeleteKeyCode(117))
        #expect(!CanvasKeyboardCatcher.isDeleteKeyCode(53))
    }
}