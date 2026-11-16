import SwiftUI
import AppKit
import CanvasCore

// MARK: - B12 右侧栏节点属性编辑（批次 B 第 12 条：右栏改文本/标题/设置，改动即时写回）
//
// 画布是活动页面，右侧栏相对稳定好操作：选中节点后右栏「节点/聊天」tab 顶部
// 出现属性编辑区（ContextPanelView 内嵌本视图，以 .id(node.id) 锚定）：
//   · 标题：TextField 即时写回（store.renameNode，空串安全忽略，与 F12 重命名同源）
//   · 文本内容（text 类节点）：TextEditor 即时写回（store.updateNodeContent，
//     与 A2 右侧浮动面板 / E15 双击编辑器共用 backendConfig.params["content"]，
//     同一事实来源，互不覆盖）
//   · 生视频参数（videoGen / video 节点）：视频模型 Picker（读模型目录）+ 生成模式
//     （图生视频/文生视频/首尾帧）+ 分辨率 + 时长 + 带声音 Toggle，改动即时写回
//     backendConfig（providerID/modelID/params.mode/resolution/duration/audio，
//     与执行器读取键一一对应）。注意：LLM 节点的模型选择 UI 已按 AJ-74 产品方向
//     下线，此处仅对生视频节点开放可编辑模型入口，其他节点保持只读摘要。
//   · 关键设置：节点级模型配置摘要（backendConfig 只读展示；生视频节点除外——
//     模型在「生视频参数」区可编辑）
// 切换选中节点时视图整体重建（.id 变化）→ onAppear 重载草稿，防跨节点串稿。

/// 右侧栏节点属性编辑区（紧凑版，适配 ~300px 右栏宽度）。
struct NodeInspectorView: View {
    let node: CanvasNode
    let store: CanvasStore

    @Environment(BridgeStore.self) private var bridge
    @Environment(\.themeTokens) private var theme
    @State private var titleDraft = ""
    @State private var contentDraft = ""
    /// P2 预览放大状态机（开 / 关 / 关闭还原；Esc/✕ 关闭，双击还原缩放平移）——纯逻辑可单测
    @State private var previewState = InspectorPreviewState.closed

    /// 文本类节点才显示内容编辑（与 F12 卡片面板判定同源：text / novelImport / blenderPreview）
    private var isTextNode: Bool {
        CanvasStore.contentKind(of: node.type) == .text
    }

    /// 生视频节点（videoGen / 裸 video）才显示可编辑参数面板
    private var isVideoNode: Bool {
        NodeCapability.forNodeType(node.type) == .video
    }

    /// 生图节点（imageGen / 裸 image）才显示可编辑参数面板
    private var isImageNode: Bool {
        NodeCapability.forNodeType(node.type) == .image
    }

    /// 实时节点（store 为 @Observable，绑定读取实时数据，避免 let 快照过期）
    private var liveNode: CanvasNode? {
        store.graph.node(id: node.id)
    }

    /// 生视频参数面板已提供编辑控件的键；「关键设置」摘要对这些键不再逐行重复展示
    private static let videoEditedParamKeys: Set<String> = ["mode", "resolution", "duration", "audio"]

    /// 生图参数面板已提供编辑控件的键；「关键设置」摘要对这些键不再逐行重复展示
    private static let imageEditedParamKeys: Set<String> = ["size", "negativePrompt"]

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                header
                titleField
                mediaPreviewSection
                if isTextNode { contentEditor }
                if isVideoNode { videoParamsEditor }
                if isImageNode { imageParamsEditor }
                settingsSummary
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.10))
            )
            .onAppear {
                titleDraft = node.title
                contentDraft = store.content(of: node.id)
            }
        }
        // P2 预览放大弹层：overlay/stack 实现（禁新建 NSWindow），覆盖本面板可用区域
        .overlay { zoomOverlay }
        .animation(.easeInOut(duration: 0.18), value: previewState.isPresented)
    }

    // MARK: 头部（区标题 + 节点类型）

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("属性编辑")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(ManjuNodeType(rawValue: node.type)?.displayName ?? node.type)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: 标题（即时写回）

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("标题", systemImage: "character.cursor.ibeam")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("节点标题", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onChange(of: titleDraft) { _, newValue in
                    // 即时写回画布节点；空串由 renameNode 内部兜底忽略（保留原标题）
                    bridge.dispatchCanvasMutation(
                        .renameNode(id: node.id, title: newValue)
                    )
                }
        }
    }

    // MARK: P2 结果预览（image 结果 → 缩略图 + 点击放大弹层）
    // 大图加载走 store.cachedImage（AttachedCache/NSCache 有界解码，不阻塞主线程），
    // 与画布卡片缩略图同源同缓存，弹层打开零重复解码。

    /// 图片结果（image 类结果路径；视频结果在画布卡片已有播放入口，此处仅图片）
    private var previewMedia: (path: String, image: NSImage)? {
        guard let media = store.resultMedia(of: node.id),
              media.kind == "image",
              let image = store.cachedImage(path: media.path) else { return nil }
        return (media.path, image)
    }

    /// 放大弹层内的大图（与缩略图同一 NSCache 源，命中即取）
    private var zoomImage: NSImage? {
        guard let path = previewMedia?.path else { return nil }
        return store.cachedImage(path: path)
    }

    private var mediaPreviewSection: some View {
        Group {
            if let media = previewMedia {
                VStack(alignment: .leading, spacing: 4) {
                    Label("结果预览", systemImage: "photo.badge.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            previewState = .opened()
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: media.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .frame(height: 132)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, Color.accentColor)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                                .padding(6)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("放大结果预览")
                    .accessibilityIdentifier("canvas.node-inspector.preview")
                    .help("点击放大预览（Esc 或 ✕ 关闭；捏合/滚轮缩放、拖拽平移、双击还原）")
                }
            }
        }
    }

    // MARK: P2 预览放大弹层（overlay/stack 实现，禁新建 NSWindow；Esc/✕ 关闭，动画轻量）

    private var zoomOverlay: some View {
        Group {
            if previewState.isPresented, let image = zoomImage {
                ZStack {
                    Color.black.opacity(0.62)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Text(node.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                closePreview()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .help("关闭（Esc）")
                        }
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(previewState.zoom)
                            .offset(previewState.pan)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .contentShape(Rectangle())
                            .gesture(magnificationGesture)
                            .simultaneousGesture(panGesture)
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    previewState = previewState.resetTransform()
                                }
                            }
                    }
                    .padding(14)
                }
                .transition(.opacity)
            }
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                previewState = previewState.magnificationChanged(value)
            }
            .onEnded { _ in
                previewState = previewState.magnificationEnded()
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                previewState = previewState.panChanged(value.translation)
            }
            .onEnded { _ in
                previewState = previewState.panEnded()
            }
    }

    private func closePreview() {
        withAnimation(.easeInOut(duration: 0.18)) {
            previewState = previewState.dismissed()
        }
    }

    // MARK: 文本内容（text 类节点；即时写回，与 A2 浮动面板同源）

    private var contentEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("文本内容", systemImage: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(contentDraft.count) 字")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: $contentDraft)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(height: 140)
                .onChange(of: contentDraft) { _, newValue in
                    // 即时写回节点内容（与 A2 面板 / E15 编辑器共用 params["content"]）
                    bridge.dispatchCanvasMutation(
                        .updateNodeContent(content: newValue, id: node.id)
                    )
                }
        }
    }

    // MARK: 生视频参数（videoGen / video 节点可编辑，即时写回 config）

    /// 视频模型下拉选项（读 ModelCatalog 生视频能力目录：本地 + 云端）
    private var videoModelOptions: [VideoModelOption] {
        var options: [VideoModelOption] = []
        for provider in ModelCatalog.localProviders(capability: .video) {
            for entry in provider.entries where entry.capability == .video {
                options.append(VideoModelOption(
                    id: entry.id, providerID: provider.id, providerKind: .local,
                    displayName: "\(provider.name) · \(entry.displayName)"
                ))
            }
        }
        for provider in ModelCatalog.resolvedCloudProviders {
            for entry in provider.entries where entry.capability == .video {
                options.append(VideoModelOption(
                    id: entry.id, providerID: provider.id, providerKind: .cloud,
                    displayName: "\(provider.name) · \(entry.displayName)"
                ))
            }
        }
        return options
    }

    private var videoParamsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("生视频参数", systemImage: "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // 视频模型（选择即写 providerID + modelID；「未配置」清空模型）
            VStack(alignment: .leading, spacing: 4) {
                Text("视频模型")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Picker("视频模型", selection: modelBinding) {
                    Text("未配置").tag("")
                    ForEach(videoModelOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 生成模式：图生视频 / 文生视频 / 首尾帧（params["mode"]）
            paramPickerRow("生成模式", picker: modePicker)
            // 分辨率：720p / 1080p / 2K（params["resolution"]）
            paramPickerRow("分辨率", picker: resolutionPicker)
            // 时长：5s / 10s / 15s（params["duration"]）
            paramPickerRow("时长", picker: durationPicker)
            // 带声音（params["audio"] = on / off；可灵 settings.audio）
            HStack(spacing: 8) {
                Text("带声音")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Toggle("带声音", isOn: audioBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }

    /// 参数行：左侧标签 + 右侧 Picker（右栏紧凑排版）
    private func paramPickerRow(_ label: String, picker: some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            picker
        }
    }

    private var modePicker: some View {
        Picker("生成模式", selection: paramBinding("mode", fallback: "i2v")) {
            Text("图生视频").tag("i2v")
            Text("文生视频").tag("t2v")
            Text("首尾帧").tag("r2v")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
    }

    private var resolutionPicker: some View {
        Picker("分辨率", selection: paramBinding("resolution", fallback: "720p")) {
            Text("720p").tag("720p")
            Text("1080p").tag("1080p")
            Text("2K").tag("2K")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
    }

    private var durationPicker: some View {
        Picker("时长", selection: paramBinding("duration", fallback: "5s")) {
            Text("5 秒").tag("5s")
            Text("10 秒").tag("10s")
            Text("15 秒").tag("15s")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
    }

    // MARK: 生图参数（imageGen / image 节点可编辑，即时写回 config）

    /// 图片模型下拉选项（读 ModelCatalog 生图能力目录：本地 + 云端；与生视频面板同源）
    private var imageModelOptions: [ImageModelOption] {
        var options: [ImageModelOption] = []
        for provider in ModelCatalog.localProviders(capability: .image) {
            for entry in provider.entries where entry.capability == .image {
                options.append(ImageModelOption(
                    id: entry.id, providerID: provider.id, providerKind: .local,
                    displayName: "\(provider.name) · \(entry.displayName)"
                ))
            }
        }
        for provider in ModelCatalog.resolvedCloudProviders {
            for entry in provider.entries where entry.capability == .image {
                options.append(ImageModelOption(
                    id: entry.id, providerID: provider.id, providerKind: .cloud,
                    displayName: "\(provider.name) · \(entry.displayName)"
                ))
            }
        }
        return options
    }

    /// 尺寸预设（OpenAI Images 兼容「宽x高」；即梦另支持 1K/2K/4K——
    /// CloudImageRequest.size 注释明确这两类取值，全部作为合法预设提供）。
    private static let presetImageSizes: [ImageSizeOption] = [
        ImageSizeOption(label: "1:1 · 1024×1024", id: "1024x1024"),
        ImageSizeOption(label: "3:2 · 1536×1024", id: "1536x1024"),
        ImageSizeOption(label: "2:3 · 1024×1536", id: "1024x1536"),
        ImageSizeOption(label: "16:9 · 1792×1024", id: "1792x1024"),
        ImageSizeOption(label: "9:16 · 1024×1792", id: "1024x1792"),
        ImageSizeOption(label: "即梦 1K", id: "1K"),
        ImageSizeOption(label: "即梦 2K", id: "2K"),
        ImageSizeOption(label: "即梦 4K", id: "4K"),
    ]

    /// 尺寸下拉选项：预设 + 当前自定义值（不在预设列表时追加「自定义 · <值>」，
    /// 保证面板切换不丢用户已填的第三方尺寸）。
    private var imageSizeOptions: [ImageSizeOption] {
        var options = Self.presetImageSizes
        if let current = paramValue("size"), !current.isEmpty,
           !options.contains(where: { $0.id == current }) {
            options.append(ImageSizeOption(label: "自定义 · \(current)", id: current))
        }
        return options
    }

    private var imageParamsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("生图参数", systemImage: "photo.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // 图片模型（选择即写 providerID + modelID；「未配置」清空模型）
            VStack(alignment: .leading, spacing: 4) {
                Text("图片模型")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Picker("图片模型", selection: imageModelBinding) {
                    Text("未配置").tag("")
                    ForEach(imageModelOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 尺寸（params["size"]；OpenAI 宽x高 / 即梦 1K/2K/4K，逐字透传服务方）
            paramPickerRow("尺寸", picker: imageSizePicker)
            // 负向提示词（params["negativePrompt"] → CloudImageRequest.negativePrompt →
            // Gimage2Provider payload negative_prompt；空串视为未设置）
            VStack(alignment: .leading, spacing: 4) {
                Text("负向提示词")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("排除的内容（可选）", text: negativePromptBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
    }

    private var imageSizePicker: some View {
        Picker("尺寸", selection: paramBinding("size", fallback: "")) {
            Text("默认（跟随服务方）").tag("")
            ForEach(imageSizeOptions) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 140)
    }

    /// 负向提示词绑定：读实时节点 params["negativePrompt"]，写回 store
    private var negativePromptBinding: Binding<String> {
        Binding(
            get: { paramValue("negativePrompt") ?? "" },
            set: { setParam("negativePrompt", $0) }
        )
    }

    // MARK: 关键设置（模型配置摘要，只读展示；生视频节点模型在参数区可编辑）

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("关键设置", systemImage: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if let config = node.backendConfig {
                settingRow("后端", config.providerID.isEmpty ? "未配置" : config.providerID)
                settingRow("模型", config.modelID.isEmpty ? "未配置" : config.modelID)
                // 其余自定义参数（排除内容与审核状态等内部键；生视频节点再排除
                // 参数面板已可编辑的 mode/resolution/duration/audio，避免重复展示）
                ForEach(
                    config.params.keys.sorted()
                        .filter { key in
                            key != CanvasStore.nodeContentKey
                                && key != CanvasStore.reviewStatusKey
                                && key != CanvasStore.anchorKey
                                && !(isVideoNode && Self.videoEditedParamKeys.contains(key))
                                && !(isImageNode && Self.imageEditedParamKeys.contains(key))
                        },
                    id: \.self
                ) { key in
                    settingRow(key, config.params[key] ?? "")
                }
            } else {
                settingRow("模型", "未配置")
            }
        }
    }

    private func settingRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: 数据读写（与 ModelConfigPanelView 同一哲学：Binding 读实时节点，写回 store）

    /// 视频模型选择绑定：选中模型 → 写 providerID + modelID；「未配置」→ 清空两者（保留 params）
    private var modelBinding: Binding<String> {
        Binding(
            get: { liveNode?.backendConfig?.modelID ?? "" },
            set: { newValue in
                guard let node = liveNode else { return }
                let config = Self.applyingModelSelection(
                    to: node.backendConfig,
                    modelID: newValue,
                    providerID: videoModelOptions.first(where: { $0.id == newValue })?.providerID ?? "",
                    providerType: videoModelOptions.first(where: { $0.id == newValue })?.providerKind ?? .cloud
                )
                bridge.dispatchCanvasMutation(
                    .updateBackendConfig(config: config, id: node.id)
                )
            }
        )
    }

    /// 图片模型选择绑定：选中模型 → 写 providerID + modelID；「未配置」→ 清空两者（保留 params）
    private var imageModelBinding: Binding<String> {
        Binding(
            get: { liveNode?.backendConfig?.modelID ?? "" },
            set: { newValue in
                guard let node = liveNode else { return }
                let config = Self.applyingModelSelection(
                    to: node.backendConfig,
                    modelID: newValue,
                    providerID: imageModelOptions.first(where: { $0.id == newValue })?.providerID ?? "",
                    providerType: imageModelOptions.first(where: { $0.id == newValue })?.providerKind ?? .cloud
                )
                bridge.dispatchCanvasMutation(
                    .updateBackendConfig(config: config, id: node.id)
                )
            }
        )
    }

    /// 带声音开关：params["audio"] == "on"（缺省视为 off，与可灵 settings.audio 默认一致）
    private var audioBinding: Binding<Bool> {
        Binding(
            get: { (liveNode?.backendConfig?.params["audio"] ?? "off") == "on" },
            set: { newValue in
                setParam("audio", newValue ? "on" : "off")
            }
        )
    }

    private func paramValue(_ key: String) -> String? {
        liveNode?.backendConfig?.params[key]
    }

    private func setParam(_ key: String, _ value: String) {
        guard let node = liveNode else { return }
        bridge.dispatchCanvasMutation(
            .updateBackendConfig(
                config: Self.applyingParam(key, value, to: node.backendConfig),
                id: node.id
            )
        )
    }

    /// params 字符串绑定（读实时节点，写回 store）
    private func paramBinding(_ key: String, fallback: String) -> Binding<String> {
        Binding(
            get: { paramValue(key) ?? fallback },
            set: { setParam(key, $0) }
        )
    }

    // MARK: 写回辅助（纯函数，可单测——生图/生视频面板共用）

    /// 应用一次 params 键值写回：返回新 config（nil 入参 → 新建），原 config 不变。
    static func applyingParam(_ key: String, _ value: String, to config: NodeBackendConfig?) -> NodeBackendConfig {
        var config = config ?? NodeBackendConfig()
        config.params[key] = value
        return config
    }

    /// 应用一次模型选择写回：非空 modelID → 写 providerID + providerType + modelID；
    /// 空串 → 清空 providerID + modelID（保留 params，执行前需重新选择）。
    static func applyingModelSelection(
        to config: NodeBackendConfig?,
        modelID: String,
        providerID: String,
        providerType: ProviderKind
    ) -> NodeBackendConfig {
        var config = config ?? NodeBackendConfig()
        let selectedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedModelID.isEmpty || selectedProviderID.isEmpty {
            config.providerID = ""
            config.modelID = ""
        } else {
            config.providerType = providerType
            config.providerID = selectedProviderID
            config.modelID = selectedModelID
        }
        return config
    }
}

/// 图片模型下拉选项（id = modelID，选择时同时写 providerID + providerType）
private struct ImageModelOption: Identifiable {
    let id: String            // modelID
    let providerID: String
    let providerKind: ProviderKind
    let displayName: String
}

/// 视频模型下拉选项（id = modelID，选择时同时写 providerID + providerType）
private struct VideoModelOption: Identifiable {
    let id: String            // modelID
    let providerID: String
    let providerKind: ProviderKind
    let displayName: String
}

/// 图片尺寸下拉选项（id = 传给服务方的 size 值，label = 展示文案）
private struct ImageSizeOption: Identifiable {
    let label: String
    let id: String            // 尺寸值（如 "1024x1024" / "1K"）
}

// MARK: - P2 预览放大状态机（纯逻辑，可单测；NodeInspectorView 弹层驱动）

/// 检查器图片预览放大状态机：开 / 关 / 关闭还原。
/// · opened()：开（缩放 1x、平移归零、手势基准复位）
/// · dismissed()：关，且「关闭还原」——缩放/平移/手势基准全部复位
/// · 缩放钳制 [1, 8]（放大 8x 足够看细节且不过度采样）；平移累加；
/// · resetTransform()：双击还原（保持打开态，缩放/平移复位）
struct InspectorPreviewState: Equatable {
    var isPresented: Bool
    var zoom: CGFloat
    var pan: CGSize
    /// MagnificationGesture 基准（手势结束前保持；结束 = 当前缩放）
    var lastZoom: CGFloat
    /// DragGesture 基准（手势结束前保持；结束 = 当前平移）
    var panStart: CGSize

    /// 关闭态（全复位）；「关闭还原」的终点
    static let closed = InspectorPreviewState(isPresented: false, zoom: 1, pan: .zero, lastZoom: 1, panStart: .zero)

    /// 打开态（1x 居中，基准复位）
    static func opened() -> InspectorPreviewState {
        InspectorPreviewState(isPresented: true, zoom: 1, pan: .zero, lastZoom: 1, panStart: .zero)
    }

    /// 缩放范围 [1, 8]（钳制）
    static let zoomRange: ClosedRange<CGFloat> = 1...8

    /// MagnificationGesture onChanged：以手势基准 lastZoom × 当前倍数，钳制到 [1, 8]
    func magnificationChanged(_ value: CGFloat) -> InspectorPreviewState {
        var s = self
        s.zoom = min(max(lastZoom * value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        return s
    }

    /// MagnificationGesture onEnded：当前缩放成为下一手势基准
    func magnificationEnded() -> InspectorPreviewState {
        var s = self
        s.lastZoom = s.zoom
        return s
    }

    /// DragGesture onChanged：以拖拽基准 panStart + 本次平移量
    func panChanged(_ translation: CGSize) -> InspectorPreviewState {
        var s = self
        s.pan = CGSize(width: panStart.width + translation.width, height: panStart.height + translation.height)
        return s
    }

    /// DragGesture onEnded：当前平移成为下一手势基准
    func panEnded() -> InspectorPreviewState {
        var s = self
        s.panStart = s.pan
        return s
    }

    /// 双击还原：保持打开，缩放/平移/手势基准全部复位（1x / 居中）
    func resetTransform() -> InspectorPreviewState {
        var s = self
        s.zoom = 1
        s.lastZoom = 1
        s.pan = .zero
        s.panStart = .zero
        return s
    }

    /// 关闭并还原（Esc / ✕ 按钮）：全部复位——「关闭还原」语义
    func dismissed() -> InspectorPreviewState {
        .closed
    }
}
