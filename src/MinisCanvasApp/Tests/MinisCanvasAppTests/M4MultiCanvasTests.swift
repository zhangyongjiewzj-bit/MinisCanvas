import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - M4 多画布 UI 状态（tab bar 驱动，测 store 状态驱动）

@Suite("M4 多画布")
@MainActor
struct M4MultiCanvasTests {

    /// 便捷：新建 N 个画布并返回它们的 id 列表（含初始「画布 1」）。
    private func makeStore(withNewCanvasCount count: Int) -> (store: CanvasStore, ids: [UUID]) {
        let store = CanvasStore()
        var ids = [store.currentCanvasID]
        for _ in 0..<count {
            let doc = store.createCanvas()
            ids.append(doc.id)
        }
        return (store, ids)
    }

    /// 初始即有一个「画布 1」，且为当前画布，草稿 key 兼容旧版。
    @Test func initialSeedsSingleCanvas() {
        let store = CanvasStore()
        #expect(store.canvasDocuments.count == 1)
        #expect(store.currentCanvas.name == "画布 1")
        #expect(store.currentCanvasID == store.canvasDocuments[0].id)
        #expect(store.currentDraftKey == DraftStore.canvasKey)
    }

    /// 新建画布 → 列表 +1、自动成为当前画布、名称按序号递增。
    @Test func createCanvasAddsAndBecomesCurrent() {
        let store = CanvasStore()
        let first = store.createCanvas()
        #expect(store.canvasDocuments.count == 2)
        #expect(store.currentCanvasID == first.id)
        #expect(store.currentCanvas.name == "画布 2")
        let second = store.createCanvas(name: "  我的画布  ")
        #expect(store.canvasDocuments.count == 3)
        #expect(store.currentCanvasID == second.id)
        #expect(store.currentCanvas.name == "我的画布")  // 空白被裁剪
    }

    @Test func canvasStatusAndDraftKeysUseActualValues() throws {
        let store = CanvasStore()
        let firstID = store.currentCanvasID
        let second = store.createCanvas(name: "第二画布")
        #expect(store.statusMessage == "已新建画布「第二画布」")

        #expect(store.renameCanvas(id: second.id, to: "重命名画布"))
        #expect(store.statusMessage == "已重命名为「重命名画布」")

        #expect(store.switchCanvas(to: firstID))
        #expect(store.statusMessage == "已切换到「画布 1」")
        #expect(store.deleteCanvas(id: firstID))
        #expect(store.statusMessage == "已删除画布「画布 1」")

        let imageNode = try #require(store.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-status-image-\(UUID().uuidString).png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try png.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        #expect(store.importImage(fileURL: imageURL, for: imageNode.id))
        #expect(store.statusMessage == "已导入图片：\(imageURL.lastPathComponent)")

        let videoNode = try #require(store.addNode(ofType: "video"))
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-status-video-\(UUID().uuidString).mp4")
        try Data().write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        #expect(store.importVideo(fileURL: videoURL, for: videoNode.id))
        #expect(store.statusMessage == "已导入视频：\(videoURL.lastPathComponent)")

        let draftKeyA = CanvasStore.canvasDraftKey(for: UUID())
        let draftKeyB = CanvasStore.canvasDraftKey(for: UUID())
        #expect(draftKeyA != draftKeyB)
        #expect(draftKeyA.hasPrefix("canvas."))
    }

    /// 切换画布 → currentCanvasID 变化、currentCanvas 跟随、图互不干扰。
    @Test func switchCanvasChangesCurrentAndIsolatesGraph() {
        let (store, ids) = makeStore(withNewCanvasCount: 2)
        // 在画布 3 上放一个节点
        store.addNode(ofType: "text")
        #expect(store.graph.nodes.count == 1)
        // 切回画布 1 → 空图（各画布独立状态）
        #expect(store.switchCanvas(to: ids[0]) == true)
        #expect(store.currentCanvasID == ids[0])
        #expect(store.currentCanvas.name == "画布 1")
        #expect(store.graph.nodes.isEmpty)
        // 切到画布 2 → 仍空
        #expect(store.switchCanvas(to: ids[1]) == true)
        #expect(store.graph.nodes.isEmpty)
        // 切回画布 3 → 节点还在（互不覆盖）
        #expect(store.switchCanvas(to: ids[2]) == true)
        #expect(store.graph.nodes.count == 1)
        // 切到不存在 / 当前 id → 拒绝
        #expect(store.switchCanvas(to: UUID()) == false)
        #expect(store.switchCanvas(to: ids[2]) == false)
    }

    /// 重命名 → 列表对应项名称更新；空串/纯空白/同名校安全忽略。
    @Test func renameCanvasUpdatesNameAndIgnoresInvalid() {
        let (store, ids) = makeStore(withNewCanvasCount: 1)
        #expect(store.renameCanvas(id: ids[0], to: "主画布") == true)
        #expect(store.canvasDocuments.first { $0.id == ids[0] }?.name == "主画布")
        // 重命名非当前画布不改变 currentCanvas（当前是新建的「画布 2」）
        #expect(store.currentCanvas.name == "画布 2")
        // 空串 / 纯空白 → 忽略
        #expect(store.renameCanvas(id: ids[0], to: "   ") == false)
        #expect(store.renameCanvas(id: ids[0], to: "") == false)
        // 同名 → 忽略
        #expect(store.renameCanvas(id: ids[0], to: "主画布") == false)
        // 不存在的 id → 忽略
        #expect(store.renameCanvas(id: UUID(), to: "x") == false)
    }

    /// 删除当前画布 → 切到相邻剩余画布、列表 -1；删除非当前 → 当前不变。
    @Test func deleteCanvasRemovesAndSelectsNeighbor() {
        let (store, ids) = makeStore(withNewCanvasCount: 2)
        // 当前在画布 3（ids[2]），删除它 → 切到画布 2（ids[1]）
        #expect(store.currentCanvasID == ids[2])
        #expect(store.deleteCanvas(id: ids[2]) == true)
        #expect(store.canvasDocuments.count == 2)
        #expect(store.currentCanvasID == ids[1])
        // 删除非当前画布 1（ids[0]）→ 当前仍为画布 2
        #expect(store.deleteCanvas(id: ids[0]) == true)
        #expect(store.canvasDocuments.count == 1)
        #expect(store.currentCanvasID == ids[1])
        // 只剩一个画布时删除 → 拒绝（至少保留一个）
        #expect(store.deleteCanvas(id: ids[1]) == false)
        #expect(store.canvasDocuments.count == 1)
    }

    /// 各画布独立草稿 key（新建后当前画布草稿 key 与首画布不同）。
    @Test func eachCanvasHasIndependentDraftKey() {
        let store = CanvasStore()
        let firstKey = store.currentDraftKey
        let second = store.createCanvas()
        #expect(second.draftKey == CanvasStore.canvasDraftKey(for: second.id))
        #expect(store.currentDraftKey == second.draftKey)
        #expect(store.currentDraftKey != firstKey)
        #expect(store.canvasDocuments[0].draftKey == DraftStore.canvasKey)
    }
}
