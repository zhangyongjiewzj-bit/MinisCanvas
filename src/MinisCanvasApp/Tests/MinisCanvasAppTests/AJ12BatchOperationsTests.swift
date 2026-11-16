import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-12 多选批量操作（批量删除 / 批量移动 / 批量改配置）

@Suite("AJ-12 多选批量操作")
@MainActor
struct AJ12BatchOperationsTests {

    // MARK: - 批量移动（拖动整组）

    @Test func moveSelectedNodesMovesAllSelectedByDelta() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        let b = try! #require(store.addNode(ofType: "text", at: Point(x: 500, y: 300)))
        let c = try! #require(store.addNode(ofType: "llm", at: Point(x: 50, y: 900)))
        // 选中 a、b（c 不选）
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        let posA0 = try! #require(store.graph.node(id: a.id)).position
        let posB0 = try! #require(store.graph.node(id: b.id)).position
        let posC0 = try! #require(store.graph.node(id: c.id)).position

        let delta = Point(x: 40, y: -25)
        store.moveSelectedNodes(by: delta)

        // 选中节点同步平移 delta
        #expect(store.graph.node(id: a.id)?.position.x == posA0.x + delta.x)
        #expect(store.graph.node(id: a.id)?.position.y == posA0.y + delta.y)
        #expect(store.graph.node(id: b.id)?.position.x == posB0.x + delta.x)
        #expect(store.graph.node(id: b.id)?.position.y == posB0.y + delta.y)
        // 未选中节点不被移动
        #expect(store.graph.node(id: c.id)?.position.x == posC0.x)
        #expect(store.graph.node(id: c.id)?.position.y == posC0.y)
        // 相对位置保持不变（Optional 解包后比较）
        let bX = store.graph.node(id: b.id)?.position.x ?? 0
        let aX = store.graph.node(id: a.id)?.position.x ?? 0
        #expect(bX - aX == posB0.x - posA0.x)
    }

    @Test func moveSelectedNodesKeepsSelectionIntact() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        let before = store.selectedNodeIDs

        store.moveSelectedNodes(by: Point(x: 10, y: 10))

        // 多选集合不被批量移动破坏
        #expect(store.selectedNodeIDs == before)
        #expect(store.selectedNodeIDs.count == 2)
    }

    @Test func moveNodesFiltersMissingAndNoOpOnEmpty() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        let posA0 = try! #require(store.graph.node(id: a.id)).position

        // 部分不存在 → 过滤后移动存在节点
        store.moveNodes([a.id, UUID()], by: Point(x: 5, y: 5))
        #expect(store.graph.node(id: a.id)?.position.x == posA0.x + 5)
        // 空集合 no-op
        store.moveNodes([], by: Point(x: 99, y: 99))
        #expect(store.graph.node(id: a.id)?.position.x == posA0.x + 5)
        // 全部不存在 no-op
        store.moveNodes([UUID(), UUID()], by: Point(x: 99, y: 99))
        #expect(store.graph.node(id: a.id)?.position.x == posA0.x + 5)
    }

    @Test func moveSelectedNodesWithEdgeFollowsAnchor() {
        let store = CanvasStore()
        let from = try! #require(store.addNode(ofType: "llm", at: Point(x: 100, y: 100)))
        let to = try! #require(store.addNode(ofType: "llm", at: Point(x: 500, y: 300)))
        #expect(store.connectNodes(fromID: from.id, toID: to.id))
        store.selectNode(id: from.id)
        store.toggleSelectNode(id: to.id)

        store.moveSelectedNodes(by: Point(x: 30, y: 20))

        // 连线端点跟随移动后的节点端口锚点（连线跟随）
        let edge = try! #require(store.graph.edges.first)
        let endpoints = try! #require(store.edgeEndpoints(edge))
        let fromMoved = try! #require(store.graph.node(id: from.id))
        let fromPort = try! #require(fromMoved.outputs.first)
        let expectedFrom = store.portAnchor(for: fromMoved, port: fromPort)
        #expect(endpoints.from.x == expectedFrom.x)
        #expect(endpoints.from.y == expectedFrom.y)
    }

    // MARK: - 批量删除

    @Test func deleteSelectedRemovesAllSelectedNodes() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let c = try! #require(store.addNode(ofType: "llm"))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)

        #expect(store.deleteSelected())
        // 选中节点被删除，未选中的保留
        #expect(store.graph.node(id: a.id) == nil)
        #expect(store.graph.node(id: b.id) == nil)
        #expect(store.graph.node(id: c.id) != nil)
        // 删除后多选集合清空
        #expect(store.selectedNodeIDs.isEmpty)
    }

    @Test func deleteSelectedRejectsEmptySelection() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        store.deselectAll()
        #expect(!store.deleteSelected())
        #expect(store.graph.node(id: a.id) != nil)
    }

    // MARK: - 批量改配置

    @Test func updateSelectedBackendConfigAppliesToAllSelected() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let c = try! #require(store.addNode(ofType: "llm"))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        // 记录未选中节点 c 的初始模型（默认可能是 qwen3.8-max-preview），断言其后保持不变
        let cInitialModel = store.graph.node(id: c.id)?.backendConfig?.modelID

        let config = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview"
        )
        store.updateSelectedBackendConfig(config)

        // 选中节点全部应用新配置
        #expect(store.graph.node(id: a.id)?.backendConfig?.modelID == "qwen3.8-max-preview")
        #expect(store.graph.node(id: b.id)?.backendConfig?.modelID == "qwen3.8-max-preview")
        // 未选中节点不受影响（保持初始配置）
        #expect(store.graph.node(id: c.id)?.backendConfig?.modelID == cInitialModel)
        // 多选集合不被破坏
        #expect(store.selectedNodeIDs.count == 2)
    }

    @Test func updateSelectedBackendConfigNoSelectionIsNoOp() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let original = store.graph.node(id: a.id)?.backendConfig
        store.deselectAll()

        store.updateSelectedBackendConfig(
            NodeBackendConfig(providerType: .cloud, providerID: "bailian", modelID: "x2")
        )
        #expect(store.graph.node(id: a.id)?.backendConfig?.modelID == original?.modelID)
    }

    @Test func clearSelectedBackendConfigClearsAllSelected() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let c = try! #require(store.addNode(ofType: "llm"))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)

        store.clearSelectedBackendConfig()

        // 选中节点配置被清空
        #expect(store.graph.node(id: a.id)?.backendConfig == nil)
        #expect(store.graph.node(id: b.id)?.backendConfig == nil)
        // 未选中节点保留配置
        #expect(store.graph.node(id: c.id)?.backendConfig != nil)
        // 多选集合不被破坏
        #expect(store.selectedNodeIDs.count == 2)
    }
}