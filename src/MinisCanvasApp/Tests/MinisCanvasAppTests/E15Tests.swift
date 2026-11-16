import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - E15 节点内容输入/编辑（setContent 写回 + 编辑器状态）

@Suite("E15 节点内容编辑")
@MainActor
struct E15ContentEditorTests {

    // MARK: setContent 写回

    @Test func setContentWritesNodeContent() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        // 初始为空
        #expect(store.content(of: node.id) == "")

        let novel = "第一章 夜色如墨\n\n深秋的巷口…"
        store.setContent(nodeID: node.id, content: novel)
        #expect(store.content(of: node.id) == novel)
    }

    @Test func setContentOverwritesPrevious() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "llm") else {
            Issue.record("llm 节点创建失败")
            return
        }
        store.setContent(nodeID: node.id, content: "旧内容")
        store.setContent(nodeID: node.id, content: "新内容")
        #expect(store.content(of: node.id) == "新内容")
    }

    @Test func setContentIgnoresUnknownNode() {
        let store = CanvasStore()
        // 不存在的节点：安全忽略，不崩溃、不写入
        store.setContent(nodeID: UUID(), content: "孤儿内容")
        #expect(store.content(of: UUID()) == "")
    }

    // MARK: 编辑器状态（打开 / 关闭 / 保存）

    @Test func presentEditorSelectsAndOpens() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "novelImport") else {
            Issue.record("novelImport 节点创建失败")
            return
        }
        store.presentContentEditor(for: node.id)
        #expect(store.selectedNodeID == node.id)
        #expect(store.contentEditorNodeID == node.id)
        store.closeContentEditor()
        #expect(store.contentEditorNodeID == nil)
    }

    @Test func saveFlowPersistsContent() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        // 模拟编辑器：打开 → 输入 → 保存（setContent）→ 关闭
        store.presentContentEditor(for: node.id)
        #expect(store.contentEditorNodeID == node.id)
        store.setContent(nodeID: node.id, content: "保存后的内容")
        store.closeContentEditor()
        #expect(store.contentEditorNodeID == nil)
        #expect(store.content(of: node.id) == "保存后的内容")
    }

    @Test func cancelFlowKeepsDraft() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "script") else {
            Issue.record("script 节点创建失败")
            return
        }
        // 先写入旧内容，模拟「编辑后取消」：不改写
        store.setContent(nodeID: node.id, content: "旧内容")
        store.presentContentEditor(for: node.id)
        store.closeContentEditor() // 取消：不调 setContent
        #expect(store.content(of: node.id) == "旧内容")
    }

    @Test func removeNodeClearsContent() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        store.setContent(nodeID: node.id, content: "将被删除")
        store.presentContentEditor(for: node.id)
        store.removeNode(id: node.id)
        // 内容随节点删除而消失（存储于 backendConfig.params，节点即内容载体）
        #expect(store.graph.node(id: node.id) == nil)
        #expect(store.content(of: node.id) == "")
        #expect(store.contentEditorNodeID == nil)
    }

    // MARK: 内容跨图替换保留（执行后 graph 被 scheduler 整体替换）

    @Test func contentSurvivesGraphReplacement() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        store.setContent(nodeID: node.id, content: "执行前的内容")
        // 模拟 scheduler.applying 产生的新图（节点 ID 不变）
        var newGraph = store.graph
        newGraph.nodes[0].status = .succeeded
        store.graph = newGraph
        #expect(store.content(of: node.id) == "执行前的内容")
    }

    // MARK: 多节点内容隔离

    @Test func contentsAreIsolatedPerNode() {
        let store = CanvasStore()
        guard let a = store.addNode(ofType: "text"),
              let b = store.addNode(ofType: "llm") else {
            Issue.record("节点创建失败")
            return
        }
        store.setContent(nodeID: a.id, content: "A 的内容")
        store.setContent(nodeID: b.id, content: "B 的内容")
        #expect(store.content(of: a.id) == "A 的内容")
        #expect(store.content(of: b.id) == "B 的内容")
        #expect(store.content(of: a.id) != store.content(of: b.id))
    }
}
