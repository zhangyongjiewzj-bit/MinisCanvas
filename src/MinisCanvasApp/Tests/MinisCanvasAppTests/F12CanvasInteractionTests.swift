import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - F12 画布节点交互增强（用户实测反馈，参照 ComfyUI）：
// ① 节点改名（标题写回 graph）② 文本节点内联编辑（params["content"] 单一存储）
// ③ 图片节点直接上传（canonical asset.id）④ 图片/视频点击预览（有结果才弹）
// ⑤ 复制粘贴（节点数+1 / 内容一致 / id 不同）⑥ 右键加节点在指定坐标创建
// 08-06 交互定案：上述 ②③ 入口从「单击节点」收敛为 contentPanelTray 明确位置
// （文本面板点击=内联编辑 / 图片面板点击=上传 / 视频面板点击=导入）+ 双击 + 右键菜单；
// 单击节点 = 纯选中（store 层 API 不变，本组 store 层断言继续有效）。

@Suite("F12 画布节点交互")
@MainActor
struct F12CanvasInteractionTests {

    // MARK: - ① 节点改名

    @Test func renameUpdatesGraphNodeTitle() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "llm"))
        let ok = store.renameNode(id: node.id, title: "我的推理节点")
        #expect(ok)
        #expect(store.graph.node(id: node.id)?.title == "我的推理节点")
    }

    @Test func renameTrimsWhitespaceAndEmptyFallsBack() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "text"))
        // 前后空白被裁掉
        #expect(store.renameNode(id: node.id, title: "  改名后  "))
        #expect(store.graph.node(id: node.id)?.title == "改名后")
        // 空串 / 纯空白 → 拒绝改名，保留原标题
        #expect(!store.renameNode(id: node.id, title: "   "))
        #expect(!store.renameNode(id: node.id, title: ""))
        #expect(store.graph.node(id: node.id)?.title == "改名后")
    }

    @Test func renameUnknownNodeIsNoOp() {
        let store = CanvasStore()
        #expect(!store.renameNode(id: UUID(), title: "幽灵"))
    }

    @Test func beginRenameOnlyForExistingNode() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "llm"))
        store.beginRename(id: node.id)
        #expect(store.renamingNodeID == node.id)
        store.endRename()
        #expect(store.renamingNodeID == nil)
        // 未知节点不进入重命名态
        store.beginRename(id: UUID())
        #expect(store.renamingNodeID == nil)
    }

    // MARK: - ② 文本节点内联编辑（存 params["content"]，与双击编辑器同一份）

    @Test func textNodeKindClassification() {
        #expect(CanvasStore.contentKind(of: "text") == .text)
        #expect(CanvasStore.contentKind(of: ManjuNodeType.novelImport.rawValue) == .text)
        #expect(CanvasStore.contentKind(of: ManjuNodeType.imageGen.rawValue) == .image)
        #expect(CanvasStore.contentKind(of: "image") == .image)
        #expect(CanvasStore.contentKind(of: ManjuNodeType.assetRef.rawValue) == .image)
        #expect(CanvasStore.contentKind(of: "video") == .video)
        #expect(CanvasStore.contentKind(of: ManjuNodeType.videoGen.rawValue) == .video)
        #expect(CanvasStore.contentKind(of: "llm") == nil)
        #expect(CanvasStore.contentKind(of: ManjuNodeType.qcCheck.rawValue) == nil)
    }

    @Test func contentSummaryFoldsNewlinesAndTruncates() {
        // 换行折叠为空格
        let summary = CanvasStore.contentSummary("第一行\n第二行\n第三行")
        #expect(summary == "第一行 第二行 第三行")
        // 超长截断加省略号
        let long = String(repeating: "字", count: 200)
        let cut = CanvasStore.contentSummary(long, limit: 80)
        #expect(cut.count == 81)
        #expect(cut.hasSuffix("…"))
        // 空白折叠后为空 → 空串
        #expect(CanvasStore.contentSummary("   \n  ") == "")
    }

    @Test func inlineEditWritesToParamsContentSingleSource() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "text"))
        // 卡片内联编辑提交 = updateNodeContent（写 backendConfig.params["content"]）
        #expect(store.updateNodeContent("卡片上直接输入的内容", for: node.id))
        let params = store.graph.node(id: node.id)?.backendConfig?.params
        #expect(params?[CanvasStore.nodeContentKey] == "卡片上直接输入的内容")
        // 与双击编辑器 content(of:) 读的是同一份（无平行存储）
        #expect(store.content(of: node.id) == "卡片上直接输入的内容")
    }

    @Test func beginInlineContentEditOnlyForTextNodes() {
        let store = CanvasStore()
        let text = try! #require(store.addNode(ofType: "text"))
        let image = try! #require(store.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        store.beginInlineContentEdit(nodeID: text.id)
        #expect(store.editingContentNodeID == text.id)
        store.endInlineContentEdit()
        // 非文本节点不进入内联编辑态
        store.beginInlineContentEdit(nodeID: image.id)
        #expect(store.editingContentNodeID == nil)
    }

    // MARK: - ③ 图片节点直接上传（写 canonical asset.id，legacy result.* 不新写）

    @Test func importImageRegistersCanonicalAssetForImageNodes() async throws {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: ManjuNodeType.imageGen.rawValue))
        // 用真实 PNG（1x1 像素）落临时文件，NSImage 可读
        let url = makeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.importImage(fileURL: url, for: node.id))
        let params = store.graph.node(id: node.id)?.backendConfig?.params
        let assetIDString = try #require(params?[CanvasStore.assetIDKey])
        let assetID = try #require(UUID(uuidString: assetIDString))
        try? await Task.sleep(for: .milliseconds(20))
        let assets = await store.assetStore.assets(
            canvasID: store.currentCanvasID,
            includingDeleted: true
        )
        let asset = try #require(assets.first { $0.id == assetID })
        #expect(asset.kind == .image)
        #expect(asset.localURL == url.path)
        #expect(asset.sourceNodeID == node.id)
        #expect(store.resultMedia(of: node.id)?.path == url.path)
        #expect(params?["result.path"] == nil)
        #expect(params?["result.kind"] == nil)
        #expect(params?["result.name"] == nil)
    }

    @Test func importImageRejectsNonImageNodeAndBadFile() {
        let store = CanvasStore()
        let llm = try! #require(store.addNode(ofType: "llm"))
        let url = makeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        // 非图片节点拒绝
        #expect(!store.importImage(fileURL: url, for: llm.id))
        #expect(store.graph.node(id: llm.id)?.backendConfig?.params["result.path"] == nil)
        // 不存在的文件拒绝
        let image = try! #require(store.addNode(ofType: "image"))
        #expect(!store.importImage(fileURL: URL(fileURLWithPath: "/tmp/f12-no-such-image.png"), for: image.id))
    }

    @Test func importImageRejectsTextFileDisguisedAsImage() throws {
        let store = CanvasStore()
        let image = try #require(store.addNode(ofType: "image"))
        // 文本内容 + .png 扩展名：CGImageSource 只读文件头即拒绝
        // （旧实现 NSImage(contentsOf:) 会主线程全量解码后才发现不可读 —— 卡死根因回归防护）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("F12Fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("fake.png")
        try Data("not an image at all".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!store.importImage(fileURL: fake, for: image.id))
        #expect((store.statusMessage ?? "").contains("读取失败"))
    }

    @Test func cachedImageHitsCacheAndReturnsSameInstance() throws {
        let store = CanvasStore()
        let url = makeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = store.cachedImage(path: url.path)
        #expect(first != nil)
        let second = store.cachedImage(path: url.path)
        #expect(second === first)  // 第二次命中缓存，同一实例（防 body 重算反复解码）
        let miss = store.cachedImage(path: "/tmp/f12-no-such-image.png")
        #expect(miss == nil)
    }

    // MARK: - ④ 图片/视频点击预览（有结果才弹，无结果 no-op）

    @Test func presentPreviewOnlyWhenResultExists() {
        let store = CanvasStore()
        let image = try! #require(store.addNode(ofType: "image"))
        // 无结果 → 不弹
        #expect(!store.presentPreview(for: image.id))
        #expect(store.previewNodeID == nil)
        // 写入结果 → 弹
        let url = makeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.importImage(fileURL: url, for: image.id))
        #expect(store.presentPreview(for: image.id))
        #expect(store.previewNodeID == image.id)
        store.closePreview()
        #expect(store.previewNodeID == nil)
    }

    @Test func resultMediaReadsParamsAndVideoFallback() {
        let store = CanvasStore()
        let video = try! #require(store.addNode(ofType: "video"))
        // 无结果 → nil
        #expect(store.resultMedia(of: video.id) == nil)
        // params[result.path/result.kind] 优先
        var config = video.backendConfig ?? NodeBackendConfig()
        config.params["result.path"] = "/tmp/demo.mp4"
        config.params["result.kind"] = "video"
        store.updateBackendConfig(config, for: video.id)
        let media = store.resultMedia(of: video.id)
        #expect(media?.kind == "video")
        #expect(media?.path == "/tmp/demo.mp4")
    }

    // MARK: - ⑤ 复制粘贴（右键入口 copyNode/pasteNode：节点数+1、内容一致、id 不同）

    @Test func copyPasteViaRightClickEntryCreatesFreshCopy() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "llm"))
        store.updateNodeContent("待复制的内容", for: node.id)
        // 重新读图内最新快照（CanvasNode 为值类型，局部变量不会随图变更更新）
        let fresh = try! #require(store.graph.node(id: node.id))
        let before = store.graph.nodes.count
        #expect(store.copyNode(id: node.id))
        let pasted = store.pasteNode(near: node.id)
        #expect(pasted.count == 1)
        // 节点数 +1
        #expect(store.graph.nodes.count == before + 1)
        let copy = pasted[0]
        // id 不同（新 UUID）
        #expect(copy.id != node.id)
        // 内容一致（type / title / backendConfig / params["content"] 全保留）
        #expect(copy.type == fresh.type)
        #expect(copy.title == fresh.title)
        #expect(copy.backendConfig == fresh.backendConfig)
        #expect(store.content(of: copy.id) == "待复制的内容")
        // 位置偏移（不完全重叠）
        #expect(copy.position != fresh.position)
    }

    @Test func pasteWithEmptyClipboardIsNoOp() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "llm"))
        let pasted = store.pasteNode(near: node.id)
        #expect(pasted.isEmpty)
        #expect(store.graph.nodes.count == 1)
    }

    // MARK: - ⑥ 右键加节点（NodeTypeRegistry.creatableSpecs 分组 + 指定坐标创建）

    @Test func addNodeMenuGroupsCoverCreatable7Specs() {
        let store = CanvasStore()
        let groups = store.addNodeMenuGroups()
        // 三个面板分组全部出现
        #expect(groups.map(\.group).contains(.basic))
        #expect(groups.map(\.group).contains(.manjuFlow))
        #expect(groups.map(\.group).contains(.manjuTools))
        // Phase B：菜单保留（用户明确要求），条目随 registry 瘦身为 6 类生成类节点（AJ-74：llm 下线）
        let total = groups.reduce(0) { $0 + $1.specs.count }
        #expect(total == NodeTypeRegistry.creatableSpecs.count)
        #expect(total == 6)
        // 文本创作类不出现在菜单
        let menuTypes = Set(groups.flatMap(\.specs).map(\.type))
        for type in NodeTypeRegistry.textCreativeTypes {
            #expect(!menuTypes.contains(type), "文本创作类 \(type) 不应出现在右键菜单")
        }
    }

    @Test func rightClickAddNodeCreatesAtSpecifiedCoordinate() {
        let store = CanvasStore()
        // 模拟右键菜单选中「LLM 推理」，落点 = 右键世界坐标 (777, 333)
        let spec = try! #require(NodeTypeRegistry.spec(for: "llm"))
        let created = store.addNode(ofType: spec.type, at: Point(x: 777, y: 333))
        let node = try! #require(created)
        #expect(node.position == Point(x: 777, y: 333))
        #expect(store.graph.nodes.count == 1)
        #expect(store.graph.nodes[0].type == "llm")
        #expect(store.selectedNodeID == node.id)
    }

    @Test func rightClickAddUnknownTypeIsNoOp() {
        let store = CanvasStore()
        #expect(store.addNode(ofType: "不存在类型", at: Point(x: 10, y: 10)) == nil)
        #expect(store.graph.nodes.isEmpty)
    }

    // MARK: - 删除节点清理 F12 状态

    @Test func removeNodeClearsF12States() {
        let store = CanvasStore()
        let text = try! #require(store.addNode(ofType: "text"))
        let image = try! #require(store.addNode(ofType: "image"))
        store.beginRename(id: text.id)
        store.beginInlineContentEdit(nodeID: text.id)
        let url = makeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        store.importImage(fileURL: url, for: image.id)
        store.presentPreview(for: image.id)
        #expect(store.renamingNodeID == text.id)
        #expect(store.editingContentNodeID == text.id)
        #expect(store.previewNodeID == image.id)
        store.removeNode(id: text.id)
        #expect(store.renamingNodeID == nil)
        #expect(store.editingContentNodeID == nil)
        store.removeNode(id: image.id)
        #expect(store.previewNodeID == nil)
    }

    // MARK: - 辅助：1x1 PNG 临时文件

    private func makeTinyPNG() -> URL {
        // 1x1 透明 PNG（真实可解码图片，NSImage(contentsOf:) 可读）
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let data = Data(base64Encoded: base64)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("f12-test-\(UUID().uuidString).png")
        try? data.write(to: url)
        return url
    }
}
