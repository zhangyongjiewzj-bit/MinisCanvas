import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - U3 粘贴揭示：粘贴后节点必须可见
//
// 病根（08-04 用户实测"粘贴的节点去哪了看不到"）：paste(at: nil) 默认落点
// nodeSearchPosition 是固定世界坐标 (400,300)，用户平移/缩放视口后该点出屏，
// 粘贴成功但用户看不见 → 感知为"粘贴无效"。
// 修法：paste 后 store 发 revealRequest（粘贴内容 bbox 中心），渲染层自动平移视口。

@Suite("U3 粘贴揭示：粘贴后节点必须可见")
@MainActor
struct U3PasteRevealTests {

    private func makeStoreWithCopiedNode(at position: Point = Point(x: 400, y: 300)) -> CanvasStore {
        let node = CanvasNode(type: "text", title: "源节点", position: position,
                              inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [node], edges: []))
        _ = store.copyNode(id: node.id)
        return store
    }

    @Test func pasteEmitsRevealRequestAtPastedContentCenter() {
        let store = makeStoreWithCopiedNode()
        let target = Point(x: 5000, y: 5000)   // 故意放在远处（模拟视口外落点）
        let pasted = store.paste(at: target)
        #expect(pasted.count == 1)
        let req = store.revealRequest
        #expect(req != nil, "粘贴后必须发出揭示请求")
        // 单节点：中心 = 节点 position
        #expect(req?.center.x == pasted[0].position.x)
        #expect(req?.center.y == pasted[0].position.y)
    }

    @Test func pasteMultiNodeRevealCenterIsBBoxCenter() {
        let a = CanvasNode(type: "text", title: "A", position: Point(x: 100, y: 100),
                           inputs: [], outputs: [])
        let b = CanvasNode(type: "llm", title: "B", position: Point(x: 300, y: 500),
                           inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [a, b], edges: []))
        _ = store.copySubgraph(nodeIDs: [a.id, b.id])
        _ = store.paste(at: Point(x: 0, y: 0))
        guard let req = store.revealRequest else {
            #expect(Bool(false), "多节点粘贴也必须发揭示请求"); return
        }
        // 粘贴后两节点 bbox 中心 = 两节点 position 均值（min/max 中点）
        let nodes = store.graph.nodes.filter { $0.title == "A" || $0.title == "B" }
            .sorted { ($0.title) < ($1.title) }
        let pastedNodes = store.graph.nodes.suffix(2)
        let xs = pastedNodes.map(\.position.x).sorted()
        let ys = pastedNodes.map(\.position.y).sorted()
        #expect(abs(req.center.x - (xs.first! + xs.last!) / 2) < 0.001)
        #expect(abs(req.center.y - (ys.first! + ys.last!) / 2) < 0.001)
        _ = nodes
    }

    @Test func eachPasteGetsFreshRevealToken() {
        let store = makeStoreWithCopiedNode()
        _ = store.paste(at: Point(x: 100, y: 100))
        let t1 = store.revealRequest?.token
        _ = store.paste(at: Point(x: 200, y: 200))
        let t2 = store.revealRequest?.token
        #expect(t1 != nil && t2 != nil)
        #expect(t1 != t2, "每次粘贴 token 必须变化，否则 onChange 不触发视口更新")
    }

    @Test func pasteEmptyClipboardEmitsNoReveal() {
        let store = CanvasStore(graph: NodeGraph(nodes: [], edges: []))
        let pasted = store.paste(at: Point(x: 100, y: 100))
        #expect(pasted.isEmpty)
        #expect(store.revealRequest == nil, "空剪贴板不发揭示请求")
    }

    @Test func pasteWithNanTargetFallsBackToDefaultPoint() {
        // AJ-66 防御：NaN 落点 → 退化为固定默认点 (400,300)，节点位置必须有限
        // （若 NaN 写进节点并落盘，重启恢复的也是 NaN 位置，画布永久不可见）。
        let store = makeStoreWithCopiedNode()
        let pasted = store.paste(at: Point(x: Double.nan, y: Double.nan))
        #expect(pasted.count == 1)
        #expect(pasted[0].position.x.isFinite)
        #expect(pasted[0].position.y.isFinite)
        #expect(pasted[0].position.x == 400)
        #expect(pasted[0].position.y == 300)
        #expect(store.revealRequest != nil, "兜底落点仍发揭示请求")
    }

    @Test func defaultPasteTargetStillWorksButIsRevealed() {
        // paste(at: nil)：落点仍是 nodeSearchPosition（兼容），但现在有揭示请求兜底
        let store = makeStoreWithCopiedNode()
        let pasted = store.paste()
        #expect(pasted.count == 1)
        #expect(store.revealRequest != nil,
                "默认落点粘贴也必须揭示（这正是'粘贴节点看不到'的修复点）")
    }

    @Test func pasteWithAllNonFiniteClipboardPositionsIsRefused() {
        // AJ-66：剪贴板源位置全非有限（历史污染数据）→ 整单拒绝，不产出 NaN 节点
        let store = makeStoreWithCopiedNode(at: Point(x: Double.nan, y: Double.nan))
        let pasted = store.paste(at: Point(x: 100, y: 100))
        #expect(pasted.isEmpty)
        #expect(store.revealRequest == nil)
        #expect(store.graph.nodes.count == 1, "源节点仍在图里（复制≠移动）")
    }

    @Test func pasteSkipsNonFiniteSourceNodeAndStaysFinite() {
        // AJ-66：个别 NaN 源节点跳过，其余正常粘贴；新节点位置与 reveal 中心全部有限
        let nodeA = CanvasNode(type: "text", title: "A", position: Point(x: 100, y: 100),
                               inputs: [], outputs: [])
        let nodeB = CanvasNode(type: "text", title: "B", position: Point(x: Double.nan, y: 200),
                               inputs: [], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [nodeA, nodeB], edges: []))
        store.copySubgraph(nodeIDs: Set([nodeA.id, nodeB.id]))
        let pasted = store.paste(at: Point(x: 400, y: 300))
        #expect(pasted.count == 1, "NaN 源节点被跳过，只粘贴有效节点")
        #expect(pasted[0].position.x.isFinite && pasted[0].position.y.isFinite)
        #expect(store.revealRequest?.center.x.isFinite == true)
        #expect(store.revealRequest?.center.y.isFinite == true)
    }
}
