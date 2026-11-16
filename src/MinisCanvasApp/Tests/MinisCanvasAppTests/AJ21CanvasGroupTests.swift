import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-21 画布组（参照 ComfyUI 组：节点归组 / 移动 / 折叠 / 连线跟随）

@Suite("AJ-21 画布组")
@MainActor
struct AJ21CanvasGroupTests {

    // MARK: - 建组

    @Test func createGroupBoundingBoxSpansNodesWithPadding() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        let b = try! #require(store.addNode(ofType: "text", at: Point(x: 500, y: 300)))
        let group = try! #require(store.createGroup(nodeIDs: [a.id, b.id]))

        let pad = CanvasGroup.padding
        let aHeight = NodeMetrics.nodeHeight(inputs: a.inputs.count, outputs: a.outputs.count)
        let bHeight = NodeMetrics.nodeHeight(inputs: b.inputs.count, outputs: b.outputs.count)
        // 组左上角 = 节点包围盒外扩 padding
        #expect(group.origin.x == 100 - NodeMetrics.nodeWidth / 2 - pad)
        #expect(group.origin.y == 100 - aHeight / 2 - pad)
        // 组尺寸 = 包围盒跨距 + 2*padding（CGSize 浮点 → 容差比较）
        #expect(abs(group.size.width - (500 + NodeMetrics.nodeWidth / 2 - (100 - NodeMetrics.nodeWidth / 2) + pad * 2)) < 0.001)
        #expect(abs(group.size.height - (300 + bHeight / 2 - (100 - aHeight / 2) + pad * 2)) < 0.001)
        // 成员记录
        #expect(group.nodeIDs == [a.id, b.id])
        #expect(store.groups.count == 1)
    }

    @Test func createGroupIgnoresMissingNodesAndRejectsEmpty() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        // 全部节点不存在 → nil
        #expect(store.createGroup(nodeIDs: [UUID(), UUID()]) == nil)
        // 部分不存在 → 过滤后建组
        let group = try! #require(store.createGroup(nodeIDs: [a.id, UUID()]))
        #expect(group.nodeIDs == [a.id])
    }

    @Test func createGroupFromSelectionUsesAccumulatedSelection() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        // Shift+点击累积选中（AJ-12：selectNode 是单选，toggleSelectNode 累积）
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        let group = try! #require(store.createGroupFromSelection())
        #expect(group.nodeIDs == [a.id, b.id])
        // 空白清除后无选中 → 建组失败
        store.deselectAll()
        #expect(store.createGroupFromSelection() == nil)
    }

    @Test func createGroupDefaultTitleAutoIncrements() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let g1 = try! #require(store.createGroup(nodeIDs: [a.id]))
        #expect(g1.title == "组 1")
        let g2 = try! #require(store.createGroup(nodeIDs: [a.id]))
        #expect(g2.title == "组 2")
        // 显式标题
        let g3 = try! #require(store.createGroup(nodeIDs: [a.id], title: "  角色定妆  "))
        #expect(g3.title == "角色定妆")
    }

    // MARK: - 移动（连线跟随）

    @Test func moveGroupMovesOriginAndMemberNodesTogether() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        // 用 llm 作目标（llm 有输入端口；text 无输入无法连线）
        let b = try! #require(store.addNode(ofType: "llm", at: Point(x: 500, y: 300)))
        // 建一条连线，验证移动后连线端点跟随节点（连线锚定节点位置）
        #expect(store.connectNodes(fromID: a.id, toID: b.id))
        #expect(store.graph.edges.count == 1)
        let group = try! #require(store.createGroup(nodeIDs: [a.id, b.id]))
        let origin0 = group.origin
        let posA0 = try! #require(store.graph.node(id: a.id)).position
        let posB0 = try! #require(store.graph.node(id: b.id)).position

        let delta = Point(x: 40, y: -25)
        store.moveGroup(id: group.id, by: delta)

        // 组矩形平移 delta
        let moved = try! #require(store.groups.first { $0.id == group.id })
        #expect(moved.origin.x == origin0.x + delta.x)
        #expect(moved.origin.y == origin0.y + delta.y)
        // 成员节点同步平移 delta
        #expect(store.graph.node(id: a.id)?.position.x == posA0.x + delta.x)
        #expect(store.graph.node(id: a.id)?.position.y == posA0.y + delta.y)
        #expect(store.graph.node(id: b.id)?.position.x == posB0.x + delta.x)
        #expect(store.graph.node(id: b.id)?.position.y == posB0.y + delta.y)
        // 移动后连线端点 = 移动后的节点端口锚点（连线跟随）
        let edge = try! #require(store.graph.edges.first)
        let endpoints = try! #require(store.edgeEndpoints(edge))
        let fromMoved = try! #require(store.graph.node(id: a.id))
        let fromPort = try! #require(fromMoved.outputs.first)
        let expectedFrom = store.portAnchor(for: fromMoved, port: fromPort)
        #expect(endpoints.from.x == expectedFrom.x)
        #expect(endpoints.from.y == expectedFrom.y)
    }

    @Test func moveGroupUnknownGroupIsNoOp() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        let g = try! #require(store.createGroup(nodeIDs: [a.id]))
        store.moveGroup(id: UUID(), by: Point(x: 10, y: 10))
        #expect(store.groups.first?.id == g.id)
        #expect(store.graph.node(id: a.id)?.position.x == 100)
    }

    // MARK: - 折叠

    @Test func toggleGroupCollapsedFlipsStateAndDisplayHeight() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let g = try! #require(store.createGroup(nodeIDs: [a.id]))
        #expect(g.isCollapsed == false)
        #expect(abs(g.displayHeight - g.size.height) < 0.001)

        store.toggleGroupCollapsed(id: g.id)
        let c1 = try! #require(store.groups.first)
        #expect(c1.isCollapsed == true)
        #expect(c1.displayHeight == CanvasGroup.titleBarHeight)

        store.toggleGroupCollapsed(id: g.id)
        #expect(store.groups.first?.isCollapsed == false)
    }

    // MARK: - 重命名 / 删除 / 成员增删

    @Test func renameGroupTrimsAndRejectsEmpty() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let g = try! #require(store.createGroup(nodeIDs: [a.id]))
        #expect(store.renameGroup(id: g.id, title: "  主流程  "))
        #expect(store.groups.first?.title == "主流程")
        #expect(!store.renameGroup(id: g.id, title: "   "))
        #expect(store.groups.first?.title == "主流程")
        #expect(!store.renameGroup(id: UUID(), title: "x"))
    }

    @Test func deleteGroupRemovesContainerButKeepsNodes() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let g = try! #require(store.createGroup(nodeIDs: [a.id]))
        store.deleteGroup(id: g.id)
        #expect(store.groups.isEmpty)
        #expect(store.graph.node(id: a.id) != nil)
    }

    @Test func addAndRemoveNodeFromGroup() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let g = try! #require(store.createGroup(nodeIDs: [a.id]))
        #expect(store.addNodeToGroup(nodeID: b.id, groupID: g.id))
        #expect(store.groups.first?.nodeIDs == [a.id, b.id])
        // 重复加入返回 false
        #expect(!store.addNodeToGroup(nodeID: b.id, groupID: g.id))
        #expect(store.removeNodeFromGroup(nodeID: b.id, groupID: g.id))
        #expect(store.groups.first?.nodeIDs == [a.id])
        // 移出不存在的返回 false
        #expect(!store.removeNodeFromGroup(nodeID: b.id, groupID: g.id))
    }

    @Test func groupContainingNodeLookup() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let g = try! #require(store.createGroup(nodeIDs: [a.id]))
        #expect(store.group(containing: a.id)?.id == g.id)
        #expect(store.group(containing: b.id) == nil)
    }

    @Test func removingNodeCleansUpGroupMembership() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        _ = try! #require(store.createGroup(nodeIDs: [a.id, b.id]))
        store.removeNode(id: a.id)
        #expect(store.groups.first?.nodeIDs == [b.id])
    }
}