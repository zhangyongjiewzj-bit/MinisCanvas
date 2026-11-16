import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - QA 画布/节点/连线 bug 回归测试
//
// 覆盖本线排查发现的修复：
// 1. connectNodes 目标节点无输入端口时 force-unwrap 崩溃（P1）
// 2. deleteSelected 批量删除产生 N 个撤销步 → ⌘Z 只撤销 1 个节点（P2）

@Suite("QA 画布 bug 回归")
@MainActor
struct QACanvasBugTests {

    // MARK: - Bug 1 (P1)：connectNodes 连接无输入端口节点不再崩溃

    @Test func connectNodesToNodeWithoutInputsDoesNotCrash() {
        // 源节点带输出端口（text），目标节点无输入端口（novelImport = 漫剧小说导入）
        let text = CanvasNode(type: "text", title: "源", position: Point(x: 100, y: 100),
                              inputs: [], outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")])
        let novel = CanvasNode(type: ManjuNodeType.novelImport.rawValue, title: "小说",
                               position: Point(x: 400, y: 100), inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [text, novel], edges: []))

        // 旧实现 `to.inputs.first!` 在此崩溃；现在应安全返回 false 且不建线
        let ok = store.connectNodes(fromID: text.id, toID: novel.id)
        #expect(!ok)
        #expect(store.graph.edges.isEmpty)
        #expect(store.graph.nodes.count == 2)   // 两端节点都保留
    }

    @Test func connectNodesToAssetRefWithoutInputsDoesNotCrash() {
        // assetRef 同样无输入端口，也应安全拒绝
        let text = CanvasNode(type: "text", title: "源", position: Point(x: 100, y: 100),
                              inputs: [], outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")])
        let asset = CanvasNode(type: ManjuNodeType.assetRef.rawValue, title: "资产",
                               position: Point(x: 400, y: 100), inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [text, asset], edges: []))

        let ok = store.connectNodes(fromID: text.id, toID: asset.id)
        #expect(!ok)
        #expect(store.graph.edges.isEmpty)
    }

    @Test func connectNodesToNormalInputTargetStillConnects() {
        // 回归：正常目标（有输入端口）仍可连接，修复不破坏既有行为
        let text = CanvasNode(type: "text", title: "源", position: Point(x: 100, y: 100),
                              inputs: [], outputs: [CanvasCore.Port(name: "text", direction: .output, dataType: "string")])
        let llm = CanvasNode(type: "llm", title: "推理", position: Point(x: 400, y: 100),
                             inputs: [CanvasCore.Port(name: "prompt", direction: .input, dataType: "string")],
                             outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [text, llm], edges: []))

        #expect(store.connectNodes(fromID: text.id, toID: llm.id))
        #expect(store.graph.edges.count == 1)
    }

    // MARK: - Bug 2 (P2)：批量删除撤销原子化（⌘Z 一次撤销整批）

    @Test func batchDeleteUndoRestoresAllNodesInOneStep() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "llm"))
        let b = try! #require(store.addNode(ofType: "text"))
        let c = try! #require(store.addNode(ofType: "llm"))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        store.toggleSelectNode(id: c.id)
        #expect(store.selectedNodeIDs.count == 3)

        #expect(store.deleteSelected())
        #expect(store.graph.nodes.isEmpty)

        // 旧实现：3 个节点产生 3 个撤销步，⌘Z 只恢复 1 个；修复后一次撤销恢复全部
        #expect(store.undo())
        #expect(store.graph.nodes.count == 3)
        // 撤销后节点（含连线）完整恢复
        #expect(store.graph.node(id: a.id) != nil)
        #expect(store.graph.node(id: b.id) != nil)
        #expect(store.graph.node(id: c.id) != nil)
    }

    @Test func batchDeleteUndoRestoresEdges() {
        let store = CanvasStore()
        let a = try! #require(store.addNode(ofType: "text", at: Point(x: 100, y: 100)))
        let b = try! #require(store.addNode(ofType: "llm", at: Point(x: 320, y: 100)))
        let c = try! #require(store.addNode(ofType: "image", at: Point(x: 540, y: 100)))
        #expect(store.connectNodes(fromID: a.id, toID: b.id))
        #expect(store.connectNodes(fromID: b.id, toID: c.id))
        store.selectNode(id: a.id)
        store.toggleSelectNode(id: b.id)
        store.toggleSelectNode(id: c.id)

        #expect(store.deleteSelected())
        #expect(store.graph.nodes.isEmpty)
        #expect(store.graph.edges.isEmpty)

        #expect(store.undo())
        #expect(store.graph.nodes.count == 3)
        #expect(store.graph.edges.count == 2)   // 连线一并原子恢复
    }
}