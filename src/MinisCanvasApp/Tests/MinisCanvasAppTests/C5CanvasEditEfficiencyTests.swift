import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - C5 画布编辑效率（学 ComfyUI LiteGraph showSearchBox / copyToClipboard）：
// 双击空白搜索面板（过滤 15 类节点 + 回车创建于鼠标位置）+
// ⌘C/⌘V 复制粘贴（节点 + 连线相对 id 映射）+ ⌘D 删除选中 + ⌘Z 撤销（快照栈）

@Suite("C5 画布编辑效率")
@MainActor
struct C5CanvasEditEfficiencyTests {

    // MARK: - 搜索面板：过滤（Phase B 瘦身后 6 类生成类；AJ-74：llm 已下线不进新建/搜索）

    @Test func searchEmptyKeywordReturnsAllCreatableTypes() {
        let store = CanvasStore()
        let all = store.nodeSearchResults(matching: "")
        #expect(all.count == 6)
        // AJ-74：llm 已从新建入口移除，搜索不得再返回
        #expect(!all.contains { $0.type == "llm" })
        #expect(all.contains { $0.type == ManjuNodeType.qcCheck.rawValue })
        #expect(all.contains { $0.type == ManjuNodeType.imageGen.rawValue })
        // Phase B：文本创作类不进搜索/新建入口
        #expect(!all.contains { $0.type == ManjuNodeType.storyboard.rawValue })
    }

    @Test func searchFiltersByTypeTitleSummary() {
        let store = CanvasStore()
        // AJ-74：llm 下线——type 搜索不得命中（锁定下线行为，防止误回归）
        let llm = store.nodeSearchResults(matching: "llm")
        #expect(llm.isEmpty)
        // 中文 title 过滤（生图 = imageGen 的注册标题）
        let image = store.nodeSearchResults(matching: "生图")
        #expect(image.contains { $0.type == ManjuNodeType.imageGen.rawValue })
        // summary 过滤（QC 检查摘要含「结构+审美」）
        let qc = store.nodeSearchResults(matching: "结构+审美")
        #expect(qc.contains { $0.type == ManjuNodeType.qcCheck.rawValue })
        // 无匹配 → 空
        #expect(store.nodeSearchResults(matching: "不存在的节点类型xyz").isEmpty)
    }

    @Test func searchIsCaseInsensitive() {
        let store = CanvasStore()
        // AJ-74：llm 下线——大小写变体同样不得命中
        #expect(store.nodeSearchResults(matching: "LLM").isEmpty)
        // Phase B：基础 image 占位已出新建入口，"Image" 命中生图（imageGen）
        #expect(store.nodeSearchResults(matching: "Image").contains { $0.type == ManjuNodeType.imageGen.rawValue })
        #expect(store.nodeSearchResults(matching: "  LLM  ").isEmpty)  // 首尾空白裁剪 + llm 下线
    }

    // MARK: - 搜索面板：双击位置创建

    @Test func doubleClickPresentsSearchAndEnterCreatesAtPosition() {
        let store = CanvasStore()
        store.presentNodeSearch(at: Point(x: 1234, y: 567))
        #expect(store.isNodeSearchPresented)
        #expect(store.nodeSearchPosition == Point(x: 1234, y: 567))

        let created = store.createNodeFromSearch(type: "llm")
        #expect(created != nil)
        #expect(!store.isNodeSearchPresented)                       // 回车后关闭面板
        #expect(created?.position == Point(x: 1234, y: 567))        // 创建于双击世界坐标
        #expect(store.selectedNodeID == created?.id)                // 创建后自动选中
        #expect(store.graph.nodes.count == 1)
    }

    @Test func dismissSearchPanelClearsPresentation() {
        let store = CanvasStore()
        store.presentNodeSearch(at: Point(x: 10, y: 10))
        store.dismissNodeSearch()
        #expect(!store.isNodeSearchPresented)
    }

    @Test func createUnknownTypeFromSearchIsNoOp() {
        let store = CanvasStore()
        store.presentNodeSearch(at: Point(x: 10, y: 10))
        let created = store.createNodeFromSearch(type: "no_such_type")
        #expect(created == nil)
        #expect(store.graph.nodes.isEmpty)
        #expect(!store.isNodeSearchPresented)
    }

    // MARK: - 复制粘贴：单节点（⌘C / ⌘V）

    @Test func copyPasteSingleNodeCreatesFreshCopy() {
        let store = CanvasStore()
        let node = store.addNode(ofType: "llm", at: Point(x: 100, y: 100))!
        store.selectNode(id: node.id)

        #expect(store.copySelection())
        #expect(store.clipboard?.nodes.count == 1)
        #expect(store.clipboard?.edges.isEmpty == true)

        let pasted = store.paste(at: Point(x: 500, y: 300))
        #expect(pasted.count == 1)
        #expect(store.graph.nodes.count == 2)
        let copy = pasted[0]
        #expect(copy.id != node.id)                                 // 新 UUID
        #expect(copy.type == node.type)
        #expect(copy.inputs.count == node.inputs.count)
        #expect(copy.outputs.count == node.outputs.count)
        #expect(copy.inputs[0].id != node.inputs[0].id)             // 端口也换新 UUID
        #expect(copy.outputs[0].id != node.outputs[0].id)
        // 子图左上角（单节点即自身）平移到目标点
        #expect(copy.position == Point(x: 500, y: 300))
        #expect(store.selectedNodeID == copy.id)                    // 粘贴后选中新节点
    }

    @Test func copyPastePreservesContentAndBackendConfig() {
        let store = CanvasStore()
        let node = store.addNode(ofType: "llm", at: Point(x: 100, y: 100))!
        store.updateNodeContent("你好，世界", for: node.id)
        store.selectNode(id: node.id)
        store.copySelection()

        let pasted = store.paste(at: Point(x: 400, y: 200))[0]
        #expect(store.content(of: pasted.id) == "你好，世界")       // 内容随节点拷贝
        #expect(pasted.backendConfig?.modelID == node.backendConfig?.modelID)
        #expect(pasted.status == .pending)                          // 状态重置（全新节点）
    }

    @Test func copyWithoutSelectionFails() {
        let store = CanvasStore()
        #expect(!store.copySelection())
        #expect(store.clipboard == nil)
    }

    @Test func pasteEmptyClipboardIsNoOp() {
        let store = CanvasStore()
        #expect(store.paste(at: Point(x: 0, y: 0)).isEmpty)
        #expect(store.graph.nodes.isEmpty)
    }

    // MARK: - 复制粘贴：子图 + 连线相对 id 映射

    @Test func copyPasteSubgraphRemapsEdgesWithRelativeIDs() {
        let store = CanvasStore()
        // text → llm → image：复制 {llm, image} 子图及其内部连线
        let text = store.addNode(ofType: "text", at: Point(x: 100, y: 100))!
        let llm = store.addNode(ofType: "llm", at: Point(x: 320, y: 100))!
        let image = store.addNode(ofType: "image", at: Point(x: 540, y: 100))!
        store.connectNodes(fromID: text.id, toID: llm.id)
        store.connectNodes(fromID: llm.id, toID: image.id)

        // 子图内部连线 = llm→image（1 条）；text→llm 端点在子图外，不复制
        #expect(store.copySubgraph(nodeIDs: [llm.id, image.id]))
        #expect(store.clipboard?.nodes.count == 2)
        #expect(store.clipboard?.edges.count == 1)

        let pasted = store.paste(at: Point(x: 900, y: 500))
        #expect(pasted.count == 2)
        #expect(store.graph.nodes.count == 5)                       // 3 旧 + 2 新
        let newLLM = pasted.first { $0.type == "llm" }!
        let newImage = pasted.first { $0.type == "image" }!
        #expect(newLLM.id != llm.id && newImage.id != image.id)

        // 连线重建：两端均为新 UUID，端口映射到拷贝后的新端口
        let newEdges = store.graph.edges.filter { $0.fromNode == newLLM.id }
        #expect(newEdges.count == 1)
        #expect(newEdges[0].toNode == newImage.id)
        #expect(newEdges[0].fromPort == newLLM.outputs.first?.id)
        #expect(newEdges[0].toPort == newImage.inputs.first?.id)

        // 旧连线不受影响
        #expect(store.graph.edges.contains { $0.fromNode == text.id && $0.toNode == llm.id })

        // 位置：子图左上角 (320,100) → 目标 (900,500)，整体平移
        let dx = 900 - 320
        let dy = 500 - 100
        #expect(newLLM.position == Point(x: 320 + Double(dx), y: 100 + Double(dy)))
        #expect(newImage.position == Point(x: 540 + Double(dx), y: 100 + Double(dy)))
    }

    @Test func copySubgraphWithUnknownIDsFails() {
        let store = CanvasStore()
        #expect(!store.copySubgraph(nodeIDs: [UUID()]))
        #expect(store.clipboard == nil)
    }

    // MARK: - 删除选中（⌘D）

    @Test func deleteSelectedRemovesNodeAndItsEdges() {
        let store = CanvasStore()
        let text = store.addNode(ofType: "text", at: Point(x: 100, y: 100))!
        let llm = store.addNode(ofType: "llm", at: Point(x: 320, y: 100))!
        store.connectNodes(fromID: text.id, toID: llm.id)
        store.selectNode(id: llm.id)

        #expect(store.deleteSelected())
        #expect(store.graph.nodes.count == 1)
        #expect(store.graph.edges.isEmpty)                          // 关联连线一并删除
        #expect(store.selectedNodeID == nil)                        // 选中态清空
        #expect(store.graph.node(id: llm.id) == nil)
        #expect(store.graph.node(id: text.id) != nil)
    }

    @Test func deleteWithoutSelectionFails() {
        let store = CanvasStore()
        let node = store.addNode(ofType: "text")!
        store.deselectAll()
        #expect(!store.deleteSelected())
        #expect(store.graph.node(id: node.id) != nil)
    }

    // MARK: - 键盘 Delete 键删除（AJ-13：裸 Delete keyCode 51 / fn-Delete keyCode 117）

    @Test func deleteKeyCodeRecognizesDeleteAndFnDelete() {
        // AJ-64/65：isDeleteKeyCode 已从 Coordinator 上提到 CanvasKeyboardCatcher 顶层（纯逻辑可单测）
        #expect(CanvasKeyboardCatcher.isDeleteKeyCode(51))    // 裸 Delete / Backspace
        #expect(CanvasKeyboardCatcher.isDeleteKeyCode(117))   // fn-Delete
        #expect(!CanvasKeyboardCatcher.isDeleteKeyCode(36))   // Return
        #expect(!CanvasKeyboardCatcher.isDeleteKeyCode(0))    // 'A'
        #expect(!CanvasKeyboardCatcher.isDeleteKeyCode(53))   // Escape
    }

    @Test func deleteKeyPathReusesDeleteSelected() {
        // 键盘 Delete 分支复用 store.deleteSelected()：选中节点删除、连线一并清理、选中态清空。
        let store = CanvasStore()
        let text = store.addNode(ofType: "text", at: Point(x: 100, y: 100))!
        let llm = store.addNode(ofType: "llm", at: Point(x: 320, y: 100))!
        store.connectNodes(fromID: text.id, toID: llm.id)
        store.selectNode(id: llm.id)
        #expect(store.deleteSelected())
        #expect(store.graph.nodes.count == 1)
        #expect(store.graph.edges.isEmpty)
        #expect(store.selectedNodeID == nil)
    }

    // MARK: - 撤销（⌘Z：结构变更前快照栈）

    @Test func undoAddNodeRemovesIt() {
        let store = CanvasStore()
        store.addNode(ofType: "llm")
        #expect(store.graph.nodes.count == 1)
        #expect(store.undo())
        #expect(store.graph.nodes.isEmpty)
        // 空栈再撤销 → false
        #expect(!store.undo())
    }

    @Test func undoDeleteRestoresNodeAndEdges() {
        let store = CanvasStore()
        let text = store.addNode(ofType: "text", at: Point(x: 100, y: 100))!
        let llm = store.addNode(ofType: "llm", at: Point(x: 320, y: 100))!
        store.connectNodes(fromID: text.id, toID: llm.id)
        store.selectNode(id: llm.id)
        store.deleteSelected()
        #expect(store.graph.nodes.count == 1)

        #expect(store.undo())                                       // 撤销删除
        #expect(store.graph.nodes.count == 2)
        #expect(store.graph.edges.count == 1)                       // 连线一并恢复
    }

    @Test func undoConnectRestoresReplacedInputEdge() {
        let store = CanvasStore()
        let text = store.addNode(ofType: "text", at: Point(x: 100, y: 100))!
        let llmA = store.addNode(ofType: "llm", at: Point(x: 320, y: 100))!
        let llmB = store.addNode(ofType: "llm", at: Point(x: 540, y: 100))!
        store.connectNodes(fromID: text.id, toID: llmA.id)
        // 改接：llmA 输出 → llmB.prompt（输入口单连线语义）
        store.connectNodes(fromID: llmA.id, toID: llmB.id)
        #expect(store.graph.edges.count == 2)

        store.undo()                                                // 撤销改接
        #expect(store.graph.edges.count == 1)
        #expect(store.graph.edges.contains { $0.fromNode == text.id && $0.toNode == llmA.id })
    }

    @Test func undoPasteRemovesPastedNodes() {
        let store = CanvasStore()
        let node = store.addNode(ofType: "llm", at: Point(x: 100, y: 100))!
        store.selectNode(id: node.id)
        store.copySelection()
        store.paste(at: Point(x: 400, y: 400))
        #expect(store.graph.nodes.count == 2)

        store.undo()                                                // 撤销粘贴
        #expect(store.graph.nodes.count == 1)
        #expect(store.graph.node(id: node.id) != nil)
    }

    @Test func undoPasteSubgraphRemovesNodesAndRemappedEdges() {
        let store = CanvasStore()
        let llm = store.addNode(ofType: "llm", at: Point(x: 320, y: 100))!
        let image = store.addNode(ofType: "image", at: Point(x: 540, y: 100))!
        store.connectNodes(fromID: llm.id, toID: image.id)
        store.copySubgraph(nodeIDs: [llm.id, image.id])
        store.paste(at: Point(x: 900, y: 500))
        #expect(store.graph.nodes.count == 4)
        #expect(store.graph.edges.count == 2)

        store.undo()
        #expect(store.graph.nodes.count == 2)                       // 粘贴的 2 节点撤销
        #expect(store.graph.edges.count == 1)                       // 重建的连线一并撤销
    }

    // MARK: - AJ-66 防线完备性：节点位置写点 NaN/Infinity 拒绝

    @Test func addNodeWithNonFinitePositionFallsBackToGridDefault() {
        // AJ-66：非有限落点（视口污染时 world() 退化产物）→ 网格默认点，绝不写 NaN 进节点
        let store = CanvasStore()
        let node = store.addNode(ofType: "text", at: Point(x: Double.nan, y: Double.nan))
        #expect(node != nil)
        #expect(node!.position.x.isFinite && node!.position.y.isFinite)
        #expect(node!.position.x > 0 && node!.position.y > 0)
    }

    @Test func moveNodeWithNonFinitePositionIsNoOp() {
        // AJ-66：非有限目标位置拒绝写入，节点保持原位
        let node = CanvasNode(type: "text", title: "A", position: Point(x: 100, y: 100),
                              inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [node], edges: []))
        store.moveNode(id: node.id, to: Point(x: Double.nan, y: 50))
        #expect(store.graph.nodes[0].position.x == 100)
        #expect(store.graph.nodes[0].position.y == 100)
        store.moveNode(id: node.id, to: Point(x: 10, y: Double.infinity))
        #expect(store.graph.nodes[0].position.x == 100)
    }

    @Test func moveNodesRejectsNonFiniteDeltaAndSkipsNonFiniteResult() {
        // AJ-66：非有限位移整批拒绝；结果非有限（起点已污染）跳过该节点不扩散
        let nodeA = CanvasNode(type: "text", title: "A", position: Point(x: 100, y: 100),
                               inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [nodeA], edges: []))
        store.moveNodes([nodeA.id], by: Point(x: Double.nan, y: 5))
        #expect(store.graph.nodes[0].position.x == 100)
        store.moveNodes([nodeA.id], by: Point(x: 50, y: 0))
        #expect(store.graph.nodes[0].position.x == 150, "有限位移仍正常工作")
        // 起点已被污染（历史 NaN 数据）→ 结果 NaN → 跳过，保持原值
        let nanNode = CanvasNode(type: "text", title: "B", position: Point(x: Double.nan, y: 100),
                                 inputs: [], outputs: [])
        let store2 = CanvasStore(graph: NodeGraph(nodes: [nanNode], edges: []))
        store2.moveNodes([nanNode.id], by: Point(x: 10, y: 10))
        #expect(store2.graph.nodes[0].position.x.isNaN, "起点已污染：跳过不写，保持原值")
    }

    @Test func presentNodeSearchWithNonFiniteWorldKeepsLastPosition() {
        // AJ-66：非有限世界坐标 → 丢弃，保持上次有效 nodeSearchPosition（回车建节点不落 NaN）
        let store = CanvasStore()
        store.presentNodeSearch(at: Point(x: 300, y: 200))
        #expect(store.isNodeSearchPresented)
        store.presentNodeSearch(at: Point(x: Double.nan, y: 500))
        #expect(store.nodeSearchPosition.x == 300)
        #expect(store.nodeSearchPosition.y == 200)
        store.presentNodeSearch(at: Point(x: 10, y: Double.infinity))
        #expect(store.nodeSearchPosition.x == 300)
    }
}
