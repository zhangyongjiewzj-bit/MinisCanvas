import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CanvasCore
@testable import MinisCanvasApp

// MARK: - M6 资产预览区：生成/导入素材集中预览
//
// 覆盖 4 项：
// 1. 集中收集画布所有节点的媒体结果（图片/视频）→ assetItems
// 2. 无结果节点跳过；节点结果按顺序聚合
// 3. AssetItem URL 归一化（本地路径 / 远程 URL）与 isLocalFile 判定
// 4. AssetZoomModel 缩放夹取（min/max / 复位 / isZoomed）

@Suite("M6 资产预览区")
@MainActor
struct AssetPanelTests {

    /// 构造一个带结果媒体的节点并加入 store 图。
    /// - Parameters:
    ///   - type: 节点类型（imageGen / videoGen）
    ///   - path: 结果路径（写入 backendConfig.params["result.path"]）
    @discardableResult
    private func makeNode(in store: CanvasStore, type: String, title: String, path: String) -> CanvasNode {
        let config = NodeBackendConfig(
            providerID: "test",
            modelID: "",
            params: ["result.path": path, "result.kind": type == ManjuNodeType.videoGen.rawValue ? "video" : "image"]
        )
        let node = CanvasNode(type: type, title: title, backendConfig: config)
        store.graph.addNode(node)
        return node
    }

    // MARK: - 1) 集中收集节点媒体结果

    @Test func collectsImageAndVideoAssets() {
        let store = CanvasStore()
        makeNode(in: store, type: ManjuNodeType.imageGen.rawValue, title: "生图A", path: "/tmp/a.png")
        makeNode(in: store, type: ManjuNodeType.videoGen.rawValue, title: "生视频B", path: "/tmp/b.mp4")

        let items = store.assetItems
        #expect(items.count == 2, "应收集 2 个素材")
        #expect(items[0].kind == "image")
        #expect(items[0].nodeTitle == "生图A")
        #expect(items[0].path == "/tmp/a.png")
        #expect(items[1].kind == "video")
        #expect(items[1].nodeTitle == "生视频B")
    }

    // MARK: - 2) 无结果节点跳过；顺序聚合

    @Test func skipsNodesWithoutResult() {
        let store = CanvasStore()
        // 有结果的生图节点
        makeNode(in: store, type: ManjuNodeType.imageGen.rawValue, title: "有结果", path: "/tmp/x.png")
        // 无结果的 LLM 节点（无 result.path → resultMedia 返回 nil）
        store.graph.addNode(CanvasNode(type: "llm", title: "无结果"))
        // 无结果的生图节点（无 result.path）
        store.graph.addNode(CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "无结果图"))

        let items = store.assetItems
        #expect(items.count == 1, "仅收集有结果媒体的节点")
        #expect(items[0].nodeTitle == "有结果")
    }

    // MARK: - 3) URL 归一化与 isLocalFile

    @Test func assetURLNormalization() {
        let local = AssetItem(nodeID: UUID(), nodeTitle: "本地", kind: "image",
                              path: "/tmp/foo.png", name: "foo.png")
        #expect(local.isLocalFile)
        #expect(local.url.isFileURL)
        #expect(local.url.lastPathComponent == "foo.png")

        let remote = AssetItem(nodeID: UUID(), nodeTitle: "远程", kind: "video",
                               path: "https://cdn.example.com/v.mp4", name: "v.mp4")
        #expect(!remote.isLocalFile)
        #expect(remote.url.absoluteString == "https://cdn.example.com/v.mp4")
    }

    // MARK: - 4) 缩放模型夹取

    @Test func zoomClampsToBounds() {
        var zoom = AssetZoomModel()
        #expect(zoom.scale == 1.0)
        #expect(!zoom.isZoomed)

        // 放大到上限
        zoom.zoom(by: 1000)
        #expect(zoom.scale == AssetZoomModel.maxScale)
        #expect(zoom.isZoomed)

        // 缩小到底限
        zoom.zoom(by: 0.0001)
        #expect(zoom.scale == AssetZoomModel.minScale)

        // 复位
        zoom.reset()
        #expect(zoom.scale == 1.0)
        #expect(!zoom.isZoomed)
    }

    @Test func zoomIncremental() {
        var zoom = AssetZoomModel()
        zoom.setScale(2.0)
        #expect(zoom.scale == 2.0)
        zoom.zoom(by: 1.5)
        #expect(zoom.scale == 3.0)
        // 夹取到上限
        zoom.zoom(by: 100)
        #expect(zoom.scale == AssetZoomModel.maxScale)
    }

    // MARK: - 5) 大图预览解码器（AssetImageLoader：限幅解码 + NSCache，防主线程卡死）

    /// 1x1 透明 PNG（真实可解码图片）
    private func makeTinyPNG() -> URL {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let data = Data(base64Encoded: base64)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-tiny-\(UUID().uuidString).png")
        try? data.write(to: url)
        return url
    }

    /// 生成宽高像素的真实大图 PNG（用于验证限幅解码）
    private func makeLargePNG(pixelsWide: Int, pixelsHigh: Int) -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        let image = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-large-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    @Test func previewImageCachesAndReturnsSameInstance() throws {
        let url = makeTinyPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = AssetImageLoader.previewImage(path: url.path)
        #expect(first != nil)
        let second = AssetImageLoader.previewImage(path: url.path)
        #expect(second === first)  // 第二次命中缓存，同一实例（防 body 重算反复解码）
        // 不存在的文件 → nil（不崩溃、走占位）
        #expect(AssetImageLoader.previewImage(path: "/tmp/m6-no-such-image.png") == nil)
    }

    @Test func previewImageRejectsTextFileDisguisedAsImage() throws {
        // 文本内容 + .png 扩展名：CGImageSource 只读文件头即拒绝
        // （旧实现 NSImage(contentsOfFile:) 会主线程全量解码后才发现不可读 —— 卡死根因回归防护）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M6Fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("fake.png")
        try Data("not an image at all".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AssetImageLoader.previewImage(path: fake.path) == nil)
    }

    @Test func previewImageRejectsRemoteURL() {
        // 远程 URL 不本地解码（contentsOfFile 语义本就只支持本地文件）
        #expect(AssetImageLoader.previewImage(path: "https://cdn.example.com/big.png") == nil)
    }

    @Test func previewImageDownscalesLargeImage() throws {
        // 4000×3000 大图：限幅解码后最大边 ≤ previewMaxPixel（2048），
        // 内存/耗时随最大边平方级下降（旧实现全分辨率解码 ≈48MB 位图）
        let url = makeLargePNG(pixelsWide: 4000, pixelsHigh: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(AssetImageLoader.previewImage(path: url.path))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(cg.width, cg.height) <= Int(AssetImageLoader.previewMaxPixel))
        #expect(cg.width == 2048)  // 4000→2048 等比（高度 1536）
        #expect(cg.height == 1536)
    }
}