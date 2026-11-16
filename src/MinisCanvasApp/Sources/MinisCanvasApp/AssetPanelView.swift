import SwiftUI
import AppKit
import AVKit
import Observation
import CanvasCore

// MARK: - M6 资产预览区：生成/导入素材集中预览
//
// 把画布上所有节点的生成/导入媒体结果（图片/视频）集中到一个预览区：
// - 缩略图网格（集中预览）
// - 点击放大 / 滚轮 / Pinch 缩放
// - 系统原生预览打开（NSWorkspace.open）
// - 集中对比（选择两张并列）
// - 可开合（工具栏开关，assetPanelPresented）
//
// 数据来源：优先查询当前画布 CanvasAssetStore；旧图节点通过 result.* 兼容迁移后再展示。
// 资产索引按 canvasID 隔离，避免多画布串显；纯逻辑（AssetZoomModel / collectAssets）下沉可单测。

/// 资产条目：画布某节点的生成/导入媒体结果（集中预览网格的最小单元）。
struct AssetItem: Identifiable, Equatable {
    let assetID: UUID
    let nodeID: UUID
    let nodeTitle: String
    /// 媒体类型："image" / "video"
    let kind: String
    /// 本地路径或远程 URL
    let path: String
    /// 文件名（lastPathComponent）
    let name: String

    init(
        assetID: UUID? = nil,
        nodeID: UUID,
        nodeTitle: String,
        kind: String,
        path: String,
        name: String
    ) {
        self.assetID = assetID ?? nodeID
        self.nodeID = nodeID
        self.nodeTitle = nodeTitle
        self.kind = kind
        self.path = path
        self.name = name
    }

    /// 网格身份：同一节点可有多个生成资产，必须使用资产自身的稳定 ID。
    var id: UUID { assetID }

    var isLocalFile: Bool {
        !path.hasPrefix("http://") && !path.hasPrefix("https://")
    }

    /// 统一转 URL（本地路径 → fileURL；http(s) → 远程 URL）
    var url: URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path)
    }

    /// 系统原生预览打开（NSWorkspace.open；本地文件交给「预览」/「快速查看」，远程 URL 交给浏览器）。
    func openInSystem() {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 缩放模型（纯逻辑，可单测）

/// 资产大图缩放状态：scale 夹取 [min, max]，支持滚轮/Pinch 增量缩放与复位。
struct AssetZoomModel: Equatable {
    static let minScale: Double = 0.25
    static let maxScale: Double = 8.0

    var scale: Double = 1.0

    /// 按倍率缩放（夹取到 [min, max]；factor 允许局部「放大/缩小」手势增量）。
    mutating func zoom(by factor: Double) {
        scale = min(max(scale * factor, Self.minScale), Self.maxScale)
    }

    /// 直接置数（夹取到 [min, max]）。
    mutating func setScale(_ value: Double) {
        scale = min(max(value, Self.minScale), Self.maxScale)
    }

    mutating func reset() {
        scale = 1.0
    }

    var isZoomed: Bool { scale != 1.0 }
}

// MARK: - 资产收集（CanvasStore 扩展）

extension CanvasStore {
    /// Legacy synchronous projection retained for toolbar badges and older callers.
    /// AssetPanelView itself uses `indexedAssetItems()` below as the actor-backed source.
    var assetItems: [AssetItem] {
        graph.nodes.compactMap { node in
            guard let media = resultMedia(of: node.id) else { return nil }
            return AssetItem(
                nodeID: node.id,
                nodeTitle: node.title,
                kind: media.kind,
                path: media.path,
                name: (media.path as NSString).lastPathComponent
            )
        }
    }

    /// Query the actor-owned asset index. The graph is used only to decorate an
    /// asset with its source node title, never to define the asset collection.
    func indexedAssetItems() async -> [AssetItem] {
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let assets = await assetStore.assets(canvasID: currentCanvasID)
        return assets.compactMap { asset in
            guard let path = asset.localURL ?? asset.remoteURL else { return nil }
            let sourceNode = asset.sourceNodeID.flatMap { nodesByID[$0] }
            return AssetItem(
                assetID: asset.id,
                nodeID: asset.sourceNodeID ?? asset.id,
                nodeTitle: sourceNode?.title ?? asset.metadata["name"] ?? "未命名资产",
                kind: asset.kind.rawValue,
                path: path,
                name: asset.metadata["name"] ?? (path as NSString).lastPathComponent
            )
        }
    }

    /// 集中预览：切换资产预览区开关（工具栏按钮）。
    func toggleAssetPanel() {
        assetPanelPresented.toggle()
    }
}

// MARK: - 资产预览区视图

/// 资产预览区：集中预览生成/导入素材（缩略图网格 + 放大/系统打开/对比）。
struct AssetPanelView: View {
    let store: CanvasStore
    @Environment(BridgeStore.self) private var bridge
    @Environment(\.themeTokens) private var theme

    /// 过滤：全部 / 图片 / 视频
    private enum AssetFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case image = "图片"
        case video = "视频"
        var id: String { rawValue }
    }

    @State private var filter: AssetFilter = .all
    /// 当前放大预览的资产（非 nil 时正文区显示大图/播放器）
    @State private var openAsset: AssetItem?
    /// 对比模式：选择两张并列
    @State private var compareA: AssetItem?
    @State private var compareB: AssetItem?
    @State private var indexedItems: [AssetItem] = []
    @State private var widthSetting: AssetPanelWidthSetting

    @MainActor
    init(store: CanvasStore, preferencesDefaults: UserDefaults) {
        self.store = store
        _widthSetting = State(initialValue: AssetPanelWidthSetting(defaults: preferencesDefaults))
    }

    private var filteredItems: [AssetItem] {
        switch filter {
        case .all: return indexedItems
        case .image: return indexedItems.filter { $0.kind == "image" }
        case .video: return indexedItems.filter { $0.kind == "video" }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let openAsset {
                largePreview(openAsset)
            } else if compareA != nil || compareB != nil {
                comparisonView
            } else {
                grid
            }
        }
        .frame(width: widthSetting.width)
        .frame(minHeight: 520)
        .overlay(alignment: .bottomTrailing) {
            widthDragHandle
        }
        .onDisappear { widthSetting.endDrag() }
        .task(id: "\(store.currentCanvasID.uuidString)-\(store.assetIndexRevision)") {
            await reloadIndexedItems()
        }
        .onChange(of: store.graph) { _, _ in
            Task { await reloadIndexedItems() }
        }
        .animation(.easeInOut(duration: 0.15), value: openAsset)
        .animation(.easeInOut(duration: 0.15), value: compareA)
        .animation(.easeInOut(duration: 0.15), value: compareB)
    }

    /// The actual sheet resize handle. Pointer and keyboard/AX actions share
    /// the same preference consumer and never write Canvas data.
    private var widthDragHandle: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { widthSetting.applyDragTranslation($0.translation.width) }
                    .onEnded { _ in widthSetting.endDrag() }
            )
            .accessibilityElement()
            .accessibilityLabel("调整资产预览宽度")
            .accessibilityValue("\(Int(widthSetting.width)) 点")
            .accessibilityIdentifier("assetPanel.width")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: widthSetting.adjust(by: 40)
                case .decrement: widthSetting.adjust(by: -40)
                @unknown default: break
                }
            }
            .help("左右拖动调整资产预览宽度")
    }

    // MARK: 头部（标题 + 过滤 + 对比开关 + 关闭）

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 15))
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("资产预览")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(indexedItems.count) 个素材 · 生成 / 导入集中预览")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Picker("过滤", selection: $filter) {
                ForEach(AssetFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                compareA = nil
                compareB = nil
                openAsset = nil
            } label: {
                Label("对比", systemImage: "rectangle.split.2x1")
            }
            .help("对比模式：先在网格点选两张，再点此处并排对比")
            .disabled(compareA == nil || compareB == nil)
            .accessibilityLabel("对比素材")
            .accessibilityHint("并排查看已选的两张素材")

            Button {
                store.assetPanelPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("关闭资产预览区")
            .accessibilityLabel("关闭资产预览")
            .accessibilityHint("返回主画布")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 缩略图网格

    private var grid: some View {
        Group {
            if filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("暂无 \(filter == .all ? "" : filter.rawValue) 素材")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("执行生成节点或导入结果后，素材会集中显示在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        Button {
                            importAsset(kind: .image)
                        } label: {
                            Label("导入图片", systemImage: "photo.badge.plus")
                        }
                        Button {
                            importAsset(kind: .video)
                        } label: {
                            Label("导入视频", systemImage: "video.badge.plus")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 12)],
                              spacing: 12) {
                        ForEach(filteredItems) { item in
                            thumbnailCell(item)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func reloadIndexedItems() async {
        indexedItems = await store.indexedAssetItems()
    }

    private func importAsset(kind: MediaAssetKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kind == .image ? [.image] : [.movie, .video]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let operation: CanvasMutationOperation
        switch kind {
        case .image:
            operation = .addImageAsset(path: url.path, name: nil, position: nil)
        case .video:
            operation = .addVideoAsset(path: url.path, name: nil, position: nil)
        case .frameSet:
            return
        }
        executeAssetMutation(operation)
    }

    /// 单个缩略图：图片显示缩略图，视频显示首帧或播放占位；点击行为 = 放大预览 / 对比选点。
    private func thumbnailCell(_ item: AssetItem) -> some View {
        let inCompare = (compareA?.nodeID == item.nodeID) || (compareB?.nodeID == item.nodeID)
        return Button {
            if compareA != nil && compareB != nil {
                // 已满两张 → 重新开始对比
                compareA = item
                compareB = nil
            } else if compareA == nil {
                compareA = item
            } else {
                compareB = item
            }
            openAsset = item
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    if item.kind == "video" {
                        VideoThumbnailView(path: item.path)
                            .frame(height: 90)
                            .clipped()
                    } else if item.isLocalFile, let nsImage = store.cachedImage(path: item.path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 90)
                            .clipped()
                    } else {
                        Color.black.opacity(0.4)
                            .frame(height: 90)
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    // 对比选中角标
                    if inCompare {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                            .background(Circle().fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)))
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(height: 90)
                .background(Color.black.opacity(0.15))

                HStack(spacing: 4) {
                    Image(systemName: item.kind == "video" ? "play.circle" : "photo")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(item.name)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(inCompare ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : (theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)),
                                  lineWidth: inCompare ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.nodeTitle) · \(item.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("素材：\(item.name)")
        .accessibilityHint("打开素材预览")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: 集中对比（两张并列）

    private var comparisonView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("集中对比")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("返回网格") { compareA = nil; compareB = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            HStack(spacing: 12) {
                if let a = compareA {
                    compareCell(a, label: "A")
                }
                if let b = compareB {
                    compareCell(b, label: "B")
                }
                if compareA == nil || compareB == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("请在网格点选另一张素材")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compareCell(_ item: AssetItem, label: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(label) · \(item.nodeTitle)")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    openSystem(item)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("系统原生预览打开")
                .accessibilityLabel("在系统中打开素材")
                .accessibilityHint("使用系统原生预览打开")
            }
            ZoomableMediaView(key: item.nodeID, asset: item)
            // 底部操作条
            HStack {
                Button("放大") { /* 由 ZoomableMediaView 内部手势处理，占位保持布局稳定 */ }
                    .opacity(0)
                Spacer()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.6)))
    }

    // MARK: 大图预览（点击放大 / 缩放 / 系统打开）

    private func largePreview(_ item: AssetItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    openAsset = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("返回网格")
                .accessibilityLabel("返回素材网格")
                .accessibilityHint("关闭当前大图预览")

                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("· \(item.nodeTitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    openSystem(item)
                } label: {
                    Label("系统打开", systemImage: "arrow.up.forward.app")
                }
                .help("在系统原生预览中打开（本地文件 → 预览/快速查看，远程 URL → 浏览器）")

                Button {
                    if compareA == nil {
                        compareA = item
                    } else if compareB == nil {
                        compareB = item
                    }
                    openAsset = nil
                } label: {
                    Label("加入对比", systemImage: "rectangle.split.2x1")
                }
                .help("加入对比列表")

                // B7：图片素材「加载到画布」——新建资产引用节点（assetRef）引用该图片，
                // 节点卡片显示缩略图（与生图节点右键菜单「加载到画布」同一入口，图片才显示）。
                if item.kind == "image", item.isLocalFile {
                    Button {
                        executeAssetMutation(
                            .addImageAsset(path: item.path, name: item.name, position: nil),
                            closeOpenAsset: true
                        )
                    } label: {
                        Label("加载到画布", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("把该素材生成为画布上的资产引用节点")
                } else if item.kind == "video", item.isLocalFile {
                    // 线G：视频素材「加载到画布」——与图片分支同一入口（视频才显示视频分支，图片分支不动），
                    // 新建 assetRef 节点挂载该视频（assetKind=.video），节点卡片显示视频播放入口。
                    Button {
                        executeAssetMutation(
                            .addVideoAsset(path: item.path, name: item.name, position: nil),
                            closeOpenAsset: true
                        )
                    } label: {
                        Label("加载到画布", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("把该视频素材生成为画布上的资产引用节点")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ZoomableMediaView(key: item.nodeID, asset: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 系统原生预览打开（NSWorkspace.open）。
    private func openSystem(_ item: AssetItem) {
        item.openInSystem()
    }

    private func executeAssetMutation(
        _ operation: CanvasMutationOperation,
        closeOpenAsset: Bool = false
    ) {
        Task { @MainActor in
            do {
                _ = try await bridge.executeCanvasMutation(operation)
                if closeOpenAsset { openAsset = nil }
                await reloadIndexedItems()
            } catch {
                store.statusMessage = "画布操作已拒绝：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 可缩放媒体视图（滚轮 / Pinch）

/// 大图预览解码器：CGImageSource 限幅解码（最大边 ≤ previewMaxPixel）+ NSCache 有界缓存。
/// 卡顿专项（P0）：原实现 ZoomableMediaView.body 里 `NSImage(contentsOfFile:)` 在 SwiftUI body
/// （主线程）同步全分辨率解码大图（4K×3K≈48MB + 数百 ms 阻塞首帧）；且无缓存，body 每重算一次
/// 就重新解码一次。现改为 ImageIO 限幅缩略图解码（2048px，对 ≥720pt 大图预览 + 8x 放大足够清晰，
/// 内存/耗时随最大边平方级下降），命中缓存直接返回同一实例（NSCache：最多 8 张 / 128MB 基线，
/// 且被设置中心 `storage.memoryLimitMB` 向下封顶，见 `MemoryLimitCachePolicy`）。
/// 远程 URL 不在此解码（contentsOfFile 语义本就只支持本地文件，行为不变）。
@MainActor
enum AssetImageLoader {
    static let previewMaxPixel: CGFloat = 2048

    /// 本缓存的基线内存预算（字节）= 接入 memoryLimitMB consumer 前的硬编码上限。
    static let baselineTotalCostBytes = 128 * 1024 * 1024

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = baselineTotalCostBytes
        return cache
    }()

    /// 测试/诊断：当前生效的内存预算（字节）= min(基线, storage.memoryLimitMB)。
    static var currentTotalCostLimitBytes: Int { cache.totalCostLimit }

    /// 读取本地图片供大图预览：命中缓存直接返回；未命中限幅解码后入缓存（cost 按文件字节近似）。
    /// 非本地路径 / 无效图片 / 读取失败 → nil（调用方显示占位）。
    static func previewImage(path: String) -> NSImage? {
        guard !path.hasPrefix("http://"), !path.hasPrefix("https://") else { return nil }
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let thumb = boundedThumbnail(source: source) else { return nil }
        let image = NSImage(cgImage: thumb, size: NSZeroSize)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 1
        // P3-P1-03 consumer：解码后、入缓存前把规范内存上限（storage.memoryLimitMB）落到本缓存；
        // 未配置时等于基线，默认路径不写新值。
        MemoryLimitCachePolicy.applyTotalCostLimit(baseline: baselineTotalCostBytes, to: cache)
        cache.setObject(image, forKey: key, cost: fileSize)
        return image
    }

    /// 限幅缩略图解码：最大边 ≤ previewMaxPixel 等比缩放，保留 EXIF 方向。
    /// 用 ImageIO 缩略图解码而非全图解码，避免把整张原图位图载入内存（卡顿主因）。
    private static func boundedThumbnail(source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 可缩放的媒体大图：图片支持滚轮 + Pinch 缩放；视频用播放器（AVPlayer）。
/// `key` 用于切换资产时重置缩放状态。
struct ZoomableMediaView: View {
    let key: UUID
    let asset: AssetItem
    @State private var zoom = AssetZoomModel()

    var body: some View {
        Group {
            if asset.kind == "video" {
                // AVPlayerContainerView：规避 SwiftUI VideoPlayer 的 _AVKit_SwiftUI 元数据崩溃。
                AVPlayerContainerView(url: asset.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
            } else if let nsImage = AssetImageLoader.previewImage(path: asset.path) {
                imageView(nsImage)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("图片文件无法读取")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(key)
    }

    private func imageView(_ nsImage: NSImage) -> some View {
        ZStack {
            Color.black.opacity(0.3)
            ZoomableImageView(nsImage: nsImage, scale: zoom.scale) { newScale in
                zoom.setScale(newScale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                Text("\(Int(zoom.scale * 100))%")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                if zoom.isZoomed {
                    Button("复位") {
                        zoom.reset()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                }
            }
            .padding(10)
        }
    }
}

// MARK: - 原生可缩放图片视图（滚轮 / Pinch）

/// 用 NSImageView 原生处理滚轮 + Pinch 缩放（本 SDK 的 SwiftUI 无 `onScrollWheel`，
/// 且 NSMagnificationGestureRecognizer 在原生视图上更稳）。缩放状态双向同步：
/// 视图滚轮/Pinch → 回调 `onScale` 上报；SwiftUI 侧复位按钮 → `updateNSView.syncScale` 回写。
struct ZoomableImageView: NSViewRepresentable {
    let nsImage: NSImage
    let scale: Double
    var onScale: (Double) -> Void

    func makeNSView(context: Context) -> ZoomImageView {
        let view = ZoomImageView(image: nsImage)
        view.onScale = onScale
        return view
    }

    func updateNSView(_ view: ZoomImageView, context: Context) {
        view.image = nsImage
        view.onScale = onScale
        view.syncScale(scale)
    }
}

/// NSImageView 子类：支持滚轮 + Pinch 缩放，居中绘制自适应图片。
final class ZoomImageView: NSImageView {
    var onScale: ((Double) -> Void)?
    private var currentScale: CGFloat = 1.0

    override var isFlipped: Bool { false }

    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyDown
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(magnify)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        setScale(currentScale * (1 + gesture.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // 滚轮缩放（普通滚轮 / 触控板均归一化为缩放）
        setScale(currentScale * (1 + delta / 200))
    }

    override func resetCursorRects() {
        // NSCursor.magnify 不存在（SDK 无此成员）；缩放画布用 zoomIn（macOS 15+）。
        // 项目最低部署 macOS 14，旧系统回退 openHand（抓取/平移语义）。
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .zoomIn)
        } else {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    /// 外部（复位按钮）同步缩放值
    func syncScale(_ value: Double) {
        let clamped = min(max(CGFloat(value), 0.25), 8)
        guard abs(clamped - currentScale) > 0.0001 else { return }
        currentScale = clamped
        needsDisplay = true
    }

    private func setScale(_ value: CGFloat) {
        let clamped = min(max(value, 0.25), 8)
        guard abs(clamped - currentScale) > 0.0001 else { return }
        currentScale = clamped
        onScale?(Double(clamped))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            super.draw(dirtyRect)
            return
        }
        let bounds = self.bounds
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW > 0, imgH > 0 else { return }
        // 自适应居中（aspect-fit），再按 currentScale 缩放
        let fitScale = min(bounds.width / imgW, bounds.height / imgH)
        let dest = CGRect(
            x: bounds.midX - (imgW * fitScale) / 2,
            y: bounds.midY - (imgH * fitScale) / 2,
            width: imgW * fitScale,
            height: imgH * fitScale
        )
        NSGraphicsContext.current?.saveGraphicsState()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.interpolationQuality = .high
        ctx?.translateBy(x: bounds.midX, y: bounds.midY)
        ctx?.scaleBy(x: currentScale, y: currentScale)
        ctx?.translateBy(x: -bounds.midX, y: -bounds.midY)
        ctx?.draw(cgImage, in: dest)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// MARK: - 视频缩略图（首帧提取）

/// 视频缩略图：用 AVAssetImageGenerator 异步提取首帧，失败则回退播放占位。
/// 卡顿专项：首帧提取结果按路径缓存（NSCache 有界），LazyVGrid 单元格滚动进出反复
/// `.task` 重算时不再重复解码首帧（AVAssetImageGenerator 逐帧解码也耗 CPU/内存）。
@MainActor
struct VideoThumbnailView: View {
    let path: String
    @State private var thumb: NSImage?

    /// 首帧缓存：最多 32 个视频 / 64MB 基线（受 `storage.memoryLimitMB` 向下封顶）。
    static let baselineTotalCostBytes = 64 * 1024 * 1024

    private static let frameCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = baselineTotalCostBytes
        return cache
    }()

    /// 测试/诊断：当前生效的内存预算（字节）= min(基线, storage.memoryLimitMB)。
    static var currentTotalCostLimitBytes: Int { frameCache.totalCostLimit }

    /// 把规范内存上限落到首帧缓存（`loadThumbnail()` 在入缓存前调用）。
    static func applyConfiguredMemoryLimit() {
        MemoryLimitCachePolicy.applyTotalCostLimit(baseline: baselineTotalCostBytes, to: frameCache)
    }

    private var url: URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color.black.opacity(0.6), Color.black.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        if let hit = Self.frameCache.object(forKey: path as NSString) {
            thumb = hit
            return
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: time).image {
            let image = NSImage(cgImage: cgImage, size: .zero)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 1
            // P3-P1-03 consumer：入缓存前应用规范内存上限（未配置 = 保持基线）。
            Self.applyConfiguredMemoryLimit()
            Self.frameCache.setObject(image, forKey: path as NSString, cost: fileSize)
            thumb = image
        }
    }
}
