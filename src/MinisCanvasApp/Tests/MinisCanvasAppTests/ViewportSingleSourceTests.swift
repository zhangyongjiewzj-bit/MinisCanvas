import Testing
import Foundation
import CoreGraphics
import CanvasCore
@testable import MinisCanvasApp

// MARK: - W3 viewport durable binding（07-INTERFACE-CONTRACT / 02 任务 4 line 261）
//
// CanvasView 的本地 viewport 变换（zoom + pan，屏幕坐标）必须经明确 seam
// （CanvasStore.commitViewport）投影回 CanvasViewportState（世界中心 + zoom + canvasSize）
// 写入唯一事实源；初始化从 Store 恢复（restoredViewport）。CanvasView 不得另建事实源。

@Suite("W3 viewport 单一事实源：CanvasView 本地变换 ↔ CanvasStore")
@MainActor
struct ViewportSingleSourceTests {

    private func makeDraftStore() -> DraftStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-single-source-\(UUID().uuidString)", isDirectory: true)
        let store = DraftStore(directory: directory)
        store.debounceInterval = .milliseconds(300)
        return store
    }

    // MARK: - seam 写：本地变换 → CanvasViewportState

    @Test func commitViewportWritesThroughToStoreState() {
        let store = CanvasStore()
        // zoom 2, pan (100, -50)，视口 800x600
        // 世界中心 = (800/2 - 100)/2 = 150, (600/2 - (-50))/2 = 175
        let state = store.commitViewport(
            zoom: 2,
            pan: CGPoint(x: 100, y: -50),
            viewportSize: CGSize(width: 800, height: 600),
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        #expect(state != nil)
        #expect(store.viewportState.zoom == 2)
        #expect(store.viewportState.center == Point(x: 150, y: 175))
        #expect(store.viewportState.canvasSize == Size(width: 100_000, height: 100_000))
    }

    @Test func committedViewportPersistsToDraft() throws {
        let drafts = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let store = CanvasStore()
        store.attachDraftStore(drafts)
        store.commitViewport(
            zoom: 1.5,
            pan: CGPoint(x: -200, y: 80),
            viewportSize: CGSize(width: 900, height: 700),
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        store.flushCanvasDraft()

        let payload = try #require(drafts.load(key: DraftStore.canvasKey))
        let draft = try JSONDecoder().decode(CanvasDraft.self, from: payload)
        #expect(draft.viewport == store.viewportState)
        #expect(draft.viewport.zoom == 1.5)
    }

    // MARK: - seam 读：初始化从 Store 恢复

    @Test func restoredViewportRoundTripsCommittedTransform() {
        let store = CanvasStore()
        store.commitViewport(
            zoom: 1.5,
            pan: CGPoint(x: -200, y: 80),
            viewportSize: CGSize(width: 900, height: 700),
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        let restored = store.restoredViewport(viewportSize: CGSize(width: 900, height: 700))
        #expect(restored != nil)
        #expect(abs(Double(restored!.zoom) - 1.5) < 0.0001)
        #expect(abs(Double(restored!.pan.x) - (-200)) < 0.0001)
        #expect(abs(Double(restored!.pan.y) - 80) < 0.0001)
    }

    @Test func freshStoreDoesNotRestoreViewport() {
        // 全新 Store（viewportState 默认，canvasSize 0）→ 不恢复，保持视图默认视口（UI 行为不变）
        let store = CanvasStore()
        #expect(store.restoredViewport(viewportSize: CGSize(width: 800, height: 600)) == nil)
    }

    // MARK: - fail-closed：非法输入拒绝写入

    @Test func commitViewportRejectsInvalidInput() {
        let store = CanvasStore()
        let before = store.viewportState
        // NaN zoom
        store.commitViewport(
            zoom: .nan, pan: CGPoint(x: 100, y: -50),
            viewportSize: CGSize(width: 800, height: 600),
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        // 未布局视口（viewportSize 0）
        store.commitViewport(
            zoom: 2, pan: CGPoint(x: 100, y: -50),
            viewportSize: .zero,
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        #expect(store.viewportState == before)
    }

    // MARK: - 多画布切换隔离：每画布 viewport 独立，切回恢复本画布视口

    @Test func canvasSwitchKeepsViewportPerCanvas() {
        let drafts = makeDraftStore()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }

        let store = CanvasStore()
        store.attachDraftStore(drafts)
        // 画布 A（默认）：提交视口 A
        store.commitViewport(
            zoom: 2, pan: CGPoint(x: 100, y: -50),
            viewportSize: CGSize(width: 800, height: 600),
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        let viewportA = store.viewportState
        #expect(store.currentCanvas.viewport == viewportA)

        // 新建并切到画布 B：提交视口 B（与 A 不同）
        let canvasB = store.createCanvas(name: "画布B")
        store.commitViewport(
            zoom: 0.8, pan: CGPoint(x: -300, y: 120),
            viewportSize: CGSize(width: 900, height: 700),
            canvasSize: Size(width: 100_000, height: 100_000)
        )
        let viewportB = store.viewportState
        #expect(viewportB != viewportA)
        #expect(store.currentCanvas.viewport == viewportB)

        // 切回画布 A：viewportState 恢复 A 的视口（切换隔离，不串用 B）
        #expect(store.switchCanvas(to: store.canvasDocuments[0].id))
        #expect(store.viewportState == viewportA)

        // 再切到画布 B：恢复 B 的视口
        #expect(store.switchCanvas(to: canvasB.id))
        #expect(store.viewportState == viewportB)
    }
}
