import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - 线H续：分镜锚点 UI 闭环（CanvasStore 锚点契约 / 导出锚点行 / 预览放大状态机）

@Suite("线H 锚点 UI 闭环")
@MainActor
struct AnchorUIPreviewTests {

    // MARK: CanvasStore 锚点数据契约（params["anchor"] = "x,y"）

    @Test func setAnchorRoundTripsViaParamsContract() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        let a = StoryboardAnchor(x: 0.3, y: 0.7)
        #expect(store.setAnchor(a, for: node.id))
        // 读取还原（StoryboardAnchor.parse 与 encoded 互逆）
        #expect(store.anchor(of: node.id) == a)
        // 持久化契约：params["anchor"] = "x,y" 两位小数
        guard let nodeAfter = store.graph.node(id: node.id),
              let raw = nodeAfter.backendConfig?.params[CanvasStore.anchorKey] else {
            Issue.record("anchor 键未写入 params")
            return
        }
        #expect(raw == "0.30,0.70")
    }

    @Test func setAnchorClampsOutOfRangeAndNilClears() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        // 越界输入 → clamped 到 0...1
        #expect(store.setAnchor(StoryboardAnchor(x: 1.5, y: -0.2), for: node.id))
        #expect(store.anchor(of: node.id) == StoryboardAnchor(x: 1.0, y: 0.0))
        // 清除（nil）→ 移除键
        #expect(store.setAnchor(nil, for: node.id))
        #expect(store.anchor(of: node.id) == nil)
        if let nodeAfter = store.graph.node(id: node.id) {
            #expect(nodeAfter.backendConfig?.params[CanvasStore.anchorKey] == nil)
        }
    }

    @Test func setAnchorPushUndoButLiveDoesNot() {
        let store = CanvasStore()
        guard let node = store.addNode(ofType: "text") else {
            Issue.record("text 节点创建失败")
            return
        }
        // 正式设置 → pushUndoState：undo 可撤销回设置前（anchor 清除）
        #expect(store.setAnchor(StoryboardAnchor(x: 0.2, y: 0.2), for: node.id))
        #expect(store.undo())
        #expect(store.anchor(of: node.id) == nil)
        // 再设一次作为新栈顶，随后拖动实时写回（setAnchorLive）→ 不 pushUndoState：
        // undo 撤销的仍是 setAnchor（栈深不变），锚点回到设置前而非 live 值
        #expect(store.setAnchor(StoryboardAnchor(x: 0.2, y: 0.2), for: node.id))
        store.setAnchorLive(StoryboardAnchor(x: 0.8, y: 0.6), for: node.id)
        #expect(store.anchor(of: node.id) == StoryboardAnchor(x: 0.8, y: 0.6))
        #expect(store.undo())
        #expect(store.anchor(of: node.id) == nil)
    }

    // MARK: StoryboardExporter 锚点行（markdown 导出随行落盘）

    @Test func exportMarkdownIncludesAnchorLine() throws {
        let row = StoryboardRow(
            sceneIndex: 1,
            title: "分镜1",
            prompt: "雨夜巷口",
            anchor: StoryboardAnchor(x: 0.5, y: 0.3)
        )
        let table = StoryboardTable(title: "测试分镜表", rows: [row])
        let md = StoryboardExporter.exportMarkdown(table)
        #expect(md.contains("**锚点**"))
        #expect(md.contains("(0.50, 0.30)"))
    }

    @Test func exportMarkdownOmitsAnchorWhenNil() throws {
        let row = StoryboardRow(sceneIndex: 1, title: "分镜1", prompt: "无锚点")
        let table = StoryboardTable(title: "测试分镜表", rows: [row])
        let md = StoryboardExporter.exportMarkdown(table)
        #expect(md.contains("**锚点**"))
        #expect(md.contains("（无）"))
    }

    // MARK: InspectorPreviewState 预览放大状态机（开 / 缩放钳制 [1,8] / 平移 / 双击还原 / 关闭还原）

    @Test func previewStateOpenedResetsAndClampsZoom() {
        let s = InspectorPreviewState.opened()
        #expect(s.isPresented)
        #expect(s.zoom == 1)
        #expect(s.pan == .zero)
        // 放大 3x
        let z3 = s.magnificationChanged(3)
        #expect(z3.zoom == 3)
        // 钳制上限 8x
        let zBig = s.magnificationChanged(20)
        #expect(zBig.zoom == InspectorPreviewState.zoomRange.upperBound)
        // 钳制下限 1x
        let zSmall = z3.magnificationChanged(0.1)
        #expect(zSmall.zoom == InspectorPreviewState.zoomRange.lowerBound)
        // 手势结束 → 当前缩放成为基准
        let ended = z3.magnificationEnded()
        #expect(ended.lastZoom == 3)
    }

    @Test func previewStatePanAndDismissReset() {
        let s = InspectorPreviewState.opened()
        // 平移累加（以 panStart 为基准，未 panEnded 前基准不变）
        let p1 = s.panChanged(CGSize(width: 50, height: 20))
        #expect(p1.pan == CGSize(width: 50, height: 20))
        let p2 = p1.panChanged(CGSize(width: -10, height: 5))
        #expect(p2.pan == CGSize(width: -10, height: 5))
        // 手势结束 → 当前平移成为基准
        let ended = p2.panEnded()
        #expect(ended.panStart == p2.pan)
        // 关闭还原 → 全复位
        #expect(p2.dismissed() == InspectorPreviewState.closed)
    }

    @Test func previewStateResetTransformKeepsOpen() {
        let s = InspectorPreviewState.opened()
            .magnificationChanged(5)
            .panChanged(CGSize(width: 80, height: 40))
        let r = s.resetTransform()
        #expect(r.isPresented)
        #expect(r.zoom == 1)
        #expect(r.lastZoom == 1)
        #expect(r.pan == .zero)
        #expect(r.panStart == .zero)
    }
}
