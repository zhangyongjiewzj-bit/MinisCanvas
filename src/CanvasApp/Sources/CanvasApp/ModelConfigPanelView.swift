import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CanvasCore

// MARK: - 节点级模型选择面板
//
// 对齐 OpenMinis 手机客户端交互：点节点 → 弹面板 → provider 分组 → 常用置顶 ⭐
// → 点选即生效（一个 tap 更新节点 backendConfig，无确认按钮）。
// A2-v03：本地组接真实探测数据（在线状态点 + Ollama 真实模型名）；
// 云端组暂为静态目录（M2b 合拢后切换到 ProviderFactory.registeredTypes 注册表驱动）。

// MARK: 节点能力（决定面板显示哪些模型/参数）

enum NodeCapability: String {
    case llm, image, video

    /// 节点类型 → 能力映射（text 视作 llm 能力）
    static func forNodeType(_ type: String) -> NodeCapability {
        switch type {
        case "image": return .image
        case "video": return .video
        default: return .llm
        }
    }
}

// MARK: 模型目录（云端静态 + 本地动态）

enum ModelCatalog {
    struct Entry: Identifiable {
        let id: String            // modelID
        let displayName: String   // 面板显示名
        let capability: NodeCapability
        /// ⭐ 常用置顶（由 pinnedModelIDs 派生，单一事实来源）
        var starred: Bool { ModelCatalog.isPinned(id) }
    }

    struct Provider: Identifiable {
        let id: String            // providerID
        let name: String
        let icon: String
        let entries: [Entry]
    }

    struct Group: Identifiable {
        let id: String            // "local" / "cloud"
        let title: String
        let icon: String
        let providers: [Provider]
    }

    // MARK: 常用模型置顶清单（面板内维护；M2b 合拢后可并入注册表）
    // 云端常用：百炼 qwen3.8-max-preview / GPT-5.5 / Claude Sonnet 4.5 /
    // Gimage2 gpt-image-2-official / 可灵 kling-v2 / 即梦 seedance-v2 / DeepSeek V3
    static let pinnedModelIDs: Set<String> = [
        "qwen3.8-max-preview", "gpt-5.5", "claude-sonnet-4.5",
        "gpt-image-2-official", "kling-v2", "seedance-v2", "deepseek-v3",
    ]

    static func isPinned(_ id: String) -> Bool { pinnedModelIDs.contains(id) }

    /// ⭐ 置顶排序：starred 在前，组内保持目录原始相对顺序
    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.filter(\.starred) + entries.filter { !$0.starred }
    }

    // MARK: 云端静态目录（M2b 注册表驱动前保留）

    static let cloudProviders: [Provider] = [
        Provider(id: "bailian", name: "百炼", icon: "sparkles",
                 entries: sorted([
                    Entry(id: "qwen3.8-max-preview", displayName: "通义千问 3.8 Max", capability: .llm),
                    Entry(id: "qwen3.8-plus", displayName: "通义千问 3.8 Plus", capability: .llm),
                    Entry(id: "qwen3-vl", displayName: "通义千问 VL 视觉", capability: .llm),
                 ])),
        Provider(id: "openai", name: "GPT", icon: "brain",
                 entries: sorted([
                    Entry(id: "gpt-5.5", displayName: "GPT-5.5", capability: .llm),
                    Entry(id: "gpt-4.1-mini", displayName: "GPT-4.1 mini", capability: .llm),
                 ])),
        Provider(id: "claude", name: "Claude", icon: "bubble.left.and.bubble.right",
                 entries: sorted([
                    Entry(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", capability: .llm),
                    Entry(id: "claude-opus-4.6", displayName: "Claude Opus 4.6", capability: .llm),
                 ])),
        Provider(id: "gimage2", name: "Gimage2", icon: "photo.on.rectangle.angled",
                 entries: sorted([
                    Entry(id: "gpt-image-2-official", displayName: "GPT Image 2 Official", capability: .image),
                    Entry(id: "gpt-image-2-fast", displayName: "GPT Image 2 Fast", capability: .image),
                 ])),
        Provider(id: "kling", name: "可灵", icon: "video.fill",
                 entries: sorted([
                    Entry(id: "kling-v2", displayName: "可灵 2.0", capability: .video),
                    Entry(id: "kling-v1", displayName: "可灵 1.6", capability: .video),
                 ])),
        Provider(id: "jimeng", name: "即梦", icon: "wand.and.stars",
                 entries: sorted([
                    Entry(id: "seedance-v2", displayName: "Seedance 2.0", capability: .video),
                    Entry(id: "seedance-v1", displayName: "Seedance 1.0", capability: .video),
                    Entry(id: "seedream-v2", displayName: "Seedream 2.0", capability: .image),
                 ])),
        Provider(id: "deepseek", name: "DeepSeek", icon: "number",
                 entries: sorted([
                    Entry(id: "deepseek-v3", displayName: "DeepSeek V3", capability: .llm),
                    Entry(id: "deepseek-r1", displayName: "DeepSeek R1", capability: .llm),
                 ])),
    ]

    // MARK: 本地组（真实探测数据驱动）

    /// ComfyUI 在线时的静态工作流模型占位（生图/生视频模型由工作流/检查点提供，无法探测，与 LocalBackends.models(for:) 返回 [] 一致）
    private static let comfyEntries: [Entry] = [
        Entry(id: "flux-dev", displayName: "FLUX.1 Dev", capability: .image),
        Entry(id: "sd3.5", displayName: "SD 3.5 Large", capability: .image),
        Entry(id: "sdxl", displayName: "SDXL Base", capability: .image),
    ]

    private static let sdEntries: [Entry] = [
        Entry(id: "sdxl", displayName: "SDXL Base", capability: .image),
        Entry(id: "sd15", displayName: "SD 1.5", capability: .image),
    ]

    private static let wanEntries: [Entry] = [
        Entry(id: "wan2.1-t2v", displayName: "Wan 2.1 文生视频", capability: .video),
        Entry(id: "wan2.1-i2v", displayName: "Wan 2.1 图生视频", capability: .video),
    ]

    /// 按节点能力 + 真实探测结果构建本地 provider 列表：
    /// - Ollama 在线 → 真实模型名（glm-5.2 / llama3.2 等）；离线 → 空 entries（面板显示"未检测到本地后端"）
    /// - ComfyUI/SD/Wan 仅显示在线状态点，模型列表在线时用静态占位（工作流提供，不可探测）
    static func localProviders(
        status: [LocalBackendKind: Bool],
        ollamaModels: [String],
        capability: NodeCapability
    ) -> [Provider] {
        var providers: [Provider] = []
        if capability == .llm {
            let online = status[.ollama] == true
            let entries = online
                ? sorted(ollamaModels.map { Entry(id: $0, displayName: $0, capability: .llm) })
                : []
            providers.append(Provider(id: "ollama", name: "Ollama", icon: "cpu", entries: entries))
        }
        if capability == .image {
            let comfyOnline = status[.comfyui] == true
            providers.append(Provider(
                id: "comfyui-local", name: "ComfyUI", icon: "square.stack.3d.up",
                entries: comfyOnline ? sorted(comfyEntries) : []
            ))
            let sdOnline = status[.sdWebUI] == true
            providers.append(Provider(
                id: "stable-diffusion-local", name: "SD 本地", icon: "photo",
                entries: sdOnline ? sorted(sdEntries) : []
            ))
        }
        if capability == .video {
            let wanOnline = status[.wan] == true
            providers.append(Provider(
                id: "wan-local", name: "Wan 本地", icon: "film",
                entries: wanOnline ? sorted(wanEntries) : []
            ))
        }
        return providers
    }

    /// 全部 provider（summaryLine 查找用）
    static func allProviders(
        status: [LocalBackendKind: Bool],
        ollamaModels: [String],
        capability: NodeCapability
    ) -> [Provider] {
        localProviders(status: status, ollamaModels: ollamaModels, capability: capability) + cloudProviders
    }
}

// MARK: - 面板视图

struct ModelConfigPanelView: View {
    /// 目标节点 ID（每次从 store 取实时数据，避免快照过期）
    let nodeID: UUID
    let store: CanvasStore

    @Environment(\.dismiss) private var dismiss

    /// 本地后端探测结果缓存（onAppear Task 探测，面板消失自动取消）
    @State private var localStatus: [LocalBackendKind: Bool] = [:]
    @State private var ollamaModels: [String] = []
    @State private var probing = true

    /// 实时节点（store 为 @Observable，配置变更自动刷新）
    private var node: CanvasNode? { store.graph.node(id: nodeID) }

    private var capability: NodeCapability {
        node.map { NodeCapability.forNodeType($0.type) } ?? .llm
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if node == nil {
                Spacer()
                Text("节点不存在")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        globalDefaultRow
                        providerSections
                        paramsSection
                        jobTicketSection
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 370, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await refreshLocalBackends()
        }
    }

    // MARK: 本地后端探测（异步，结果缓存到 @State）

    private func refreshLocalBackends() async {
        probing = true
        let status = await LocalBackendProbe.shared.detect()
        let models = await LocalBackendProbe.shared.ollamaModels()
        localStatus = status
        ollamaModels = models
        probing = false
    }

    // MARK: 顶部：节点标题 + 当前模型摘要

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(node?.status.color ?? .gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(node?.title ?? "节点")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 当前所选模型摘要：如 "百炼 · 通义千问 3.8 Max"
    private var summaryLine: String {
        guard let config = node?.backendConfig, !config.modelID.isEmpty else {
            return "默认（跟随全局）"
        }
        let providers = ModelCatalog.allProviders(
            status: localStatus, ollamaModels: ollamaModels, capability: capability
        )
        let providerName = providers.first { $0.id == config.providerID }?.name ?? config.providerID
        let modelName = providers
            .flatMap(\.entries)
            .first { $0.id == config.modelID }?.displayName ?? config.modelID
        return "\(providerName) · \(modelName)"
    }

    // MARK: 跟随全局默认

    private var globalDefaultRow: some View {
        Button {
            store.clearBackendConfig(for: nodeID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .frame(width: 16)
                Text("默认（跟随全局）")
                    .font(.system(size: 13))
                Spacer()
                if node?.backendConfig == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    // MARK: Provider 分组列表（本地 | 云端）

    @ViewBuilder
    private var providerSections: some View {
        // 本地组（真实探测）——探测中先显示进度，完成后按结果渲染
        VStack(alignment: .leading, spacing: 6) {
            Label("本地", systemImage: "internaldrive")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if probing && localStatus.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在探测本地后端…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            } else {
                ForEach(localProviders) { provider in
                    providerSection(provider, kind: .local, localOnline: localOnline(for: provider.id))
                }
            }
        }

        // 云端组（静态目录，M2b 注册表驱动）
        let cloud = cloudGroup
        if let cloud {
            VStack(alignment: .leading, spacing: 6) {
                Label(cloud.title, systemImage: cloud.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(cloud.providers) { provider in
                    providerSection(provider, kind: .cloud, localOnline: nil)
                }
            }
        }
    }

    /// 本地 provider 列表（按能力过滤，全部 4 种后端都显示，离线显示"未检测到本地后端"）
    private var localProviders: [ModelCatalog.Provider] {
        ModelCatalog.localProviders(
            status: localStatus, ollamaModels: ollamaModels, capability: capability
        )
    }

    /// 云端组（只保留包含当前能力模型的 provider）
    private var cloudGroup: ModelCatalog.Group? {
        let providers = ModelCatalog.cloudProviders
            .map { provider in
                ModelCatalog.Provider(
                    id: provider.id, name: provider.name, icon: provider.icon,
                    entries: provider.entries.filter { $0.capability == capability }
                )
            }
            .filter { !$0.entries.isEmpty }
        guard !providers.isEmpty else { return nil }
        return ModelCatalog.Group(id: "cloud", title: "云端", icon: "icloud", providers: providers)
    }

    /// local providerID → LocalBackendKind rawValue（"comfyui-local"/"stable-diffusion-local"/"wan-local" → 探测 key）
    private func localKindID(_ providerID: String) -> String {
        switch providerID {
        case "comfyui-local": return "comfyui"
        case "stable-diffusion-local": return "sdWebUI"
        case "wan-local": return "wan"
        default: return providerID
        }
    }

    /// 该本地 provider 的实时在线状态（nil = 非本地 provider）
    private func localOnline(for providerID: String) -> Bool? {
        guard let kind = LocalBackendKind(rawValue: localKindID(providerID)) else { return nil }
        return localStatus[kind]
    }

    private func providerSection(_ provider: ModelCatalog.Provider, kind: ProviderKind, localOnline: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: provider.icon)
                    .font(.system(size: 11))
                Text(provider.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if let localOnline {
                    // 真实在线状态：绿点=在线 / 灰点=离线
                    Circle()
                        .fill(localOnline ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray))
                        .frame(width: 7, height: 7)
                    Text(localOnline ? "在线" : "离线")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if provider.entries.isEmpty {
                if localOnline == false {
                    Text("未检测到本地后端")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                } else {
                    Text("暂无可用模型")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                }
            } else {
                ForEach(provider.entries) { entry in
                    modelRow(entry, providerID: provider.id, kind: kind)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
    }

    /// 模型单选行：⭐ 常用置顶标记 + 点选即生效
    private func modelRow(_ entry: ModelCatalog.Entry, providerID: String, kind: ProviderKind) -> some View {
        Button {
            apply(providerID: providerID, kind: kind, modelID: entry.id)
        } label: {
            HStack(spacing: 6) {
                if entry.starred {
                    Text("⭐")
                        .font(.system(size: 10))
                } else {
                    Color.clear.frame(width: 12, height: 10)
                }
                Text(entry.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected(providerID: providerID, modelID: entry.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected(providerID: providerID, modelID: entry.id)
                          ? Color(nsColor: .systemBlue).opacity(0.12)
                          : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 参数区（按节点能力动态显示）

    @ViewBuilder
    private var paramsSection: some View {
        Divider()
        switch capability {
        case .llm:
            llmParams
        case .image:
            imageParams
        case .video:
            videoParams
        }
    }

    private var llmParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参数")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("Temperature")
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%.2f", temperatureBinding.wrappedValue))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: temperatureBinding, in: 0...2, step: 0.05)
            HStack {
                Text("Max Tokens")
                    .font(.system(size: 12))
                Spacer()
                TextField("2048", text: paramBinding("maxTokens", fallback: "2048"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .font(.system(size: 12))
            }
        }
    }

    private var imageParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参数")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("尺寸")
                    .font(.system(size: 12))
                Spacer()
                Picker("尺寸", selection: paramBinding("size", fallback: "1024x1024")) {
                    Text("1024×1024").tag("1024x1024")
                    Text("1280×720").tag("1280x720")
                    Text("768×1344").tag("768x1344")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }
        }
    }

    private var videoParams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参数")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("时长")
                    .font(.system(size: 12))
                Spacer()
                Picker("时长", selection: paramBinding("duration", fallback: "5s")) {
                    Text("5 秒").tag("5s")
                    Text("10 秒").tag("10s")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            HStack {
                Text("分辨率")
                    .font(.system(size: 12))
                Spacer()
                Picker("分辨率", selection: paramBinding("resolution", fallback: "720p")) {
                    Text("720p").tag("720p")
                    Text("1080p").tag("1080p")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
        }
    }

    // MARK: 任务单（M1f：生图/生视频节点任务单模式）

    /// 任务单区块：一键复制提示词 / 导出 .md / 导入结果回填 + 提示词预览。
    /// 只在生图（imageGen）/生视频（videoGen）节点显示。
    @ViewBuilder
    private var jobTicketSection: some View {
        if let node, store.isJobTicketNode(node.id), let ticket = store.jobTicket(for: node.id) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("任务单", systemImage: "list.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if ticket.isFallback {
                        Text("占位")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(nsColor: .systemOrange).opacity(0.16)))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .help("上游提示词节点尚未产出完整槽位文本，当前为资产锁定槽位兜底拼装，标「（待填）」处需手动补全")
                    }
                    Spacer()
                    Text(ticket.suggestedPlatform)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 操作按钮：复制提示词 / 导出 .md / 导入结果
                HStack(spacing: 8) {
                    Button {
                        store.copyPrompt(ticket)
                    } label: {
                        Label("复制提示词", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("一键复制 \(ticket.slotCount) 槽完整提示词到剪贴板，粘贴到网页版")

                    Button {
                        exportTicket(ticket)
                    } label: {
                        Label("导出 .md", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .help("导出任务单 Markdown（完整提示词 + FORBID 段 + 参考图清单 + 铁律说明）")

                    Button {
                        importResult(for: node)
                    } label: {
                        Label("导入结果", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .help("选择网页端生成的结果文件（图片/视频），回填到本节点")
                }

                // 已导入结果展示（缩略图/图标 + 路径）
                if let path = node.backendConfig?.params["result.path"] {
                    importedResultRow(path: path)
                }

                // FORBID 段单独标注（铁律4）
                if !ticket.forbid.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("FORBID")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(nsColor: .systemRed))
                        Text(ticket.forbid)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .systemRed).opacity(0.08))
                    )
                }

                // 完整提示词预览（可选中复制）
                ScrollView {
                    Text(ticket.prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
            }
        }
    }

    /// 已导入结果行：图片显示缩略图，视频显示胶片图标
    @ViewBuilder
    private func importedResultRow(path: String) -> some View {
        let kind = node?.backendConfig?.params["result.kind"] ?? ""
        HStack(spacing: 8) {
            if kind == "image", let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: kind == "video" ? "film.fill" : "photo.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node?.backendConfig?.params["result.name"] ?? (path as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    /// 导出任务单：NSSavePanel 选目录保存 .md
    private func exportTicket(_ ticket: JobTicket) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "任务单-\(ticket.nodeTitle)-\(formatter.string(from: Date())).md"
        panel.message = "导出任务单 Markdown（含完整提示词 + FORBID 段 + 参考图清单 + 铁律说明）"
        if panel.runModal() == .OK, let url = panel.url {
            store.exportTicket(ticket, to: url)
        }
    }

    /// 导入结果：NSOpenPanel 选图片/视频文件回填节点
    private func importResult(for node: CanvasNode) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = "选择网页端生成的结果文件（图片/视频）"
        if panel.runModal() == .OK, let url = panel.url {
            store.importResult(into: node.id, from: url)
        }
    }

    // MARK: 数据读写

    private func isSelected(providerID: String, modelID: String) -> Bool {
        guard let config = node?.backendConfig else { return false }
        return config.providerID == providerID && config.modelID == modelID
    }

    /// 点选即生效：一个 tap 更新节点 backendConfig（保留已有 params）
    private func apply(providerID: String, kind: ProviderKind, modelID: String) {
        guard let node else { return }
        var config = node.backendConfig ?? NodeBackendConfig()
        config.providerType = kind
        config.providerID = providerID
        config.modelID = modelID
        store.updateBackendConfig(config, for: node.id)
    }

    /// params 字符串绑定（读实时节点，写回 store）
    private func paramBinding(_ key: String, fallback: String) -> Binding<String> {
        Binding(
            get: { node?.backendConfig?.params[key] ?? fallback },
            set: { newValue in
                guard let node else { return }
                var config = node.backendConfig ?? NodeBackendConfig()
                config.params[key] = newValue
                store.updateBackendConfig(config, for: node.id)
            }
        )
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: {
                guard let raw = node?.backendConfig?.params["temperature"] else { return 0.7 }
                return Double(raw) ?? 0.7
            },
            set: { value in
                guard let node else { return }
                var config = node.backendConfig ?? NodeBackendConfig()
                config.params["temperature"] = String(format: "%.2f", value)
                store.updateBackendConfig(config, for: node.id)
            }
        )
    }
}

// MARK: - 徽标短名

extension NodeBackendConfig {
    /// 节点右上角徽标短名：取 modelID 首个 '.' 前片段（如 "qwen3.8-max-preview" → "qwen3.8"）
    var badgeShortName: String {
        guard !modelID.isEmpty else { return "默认" }
        let short = modelID.split(separator: ".").first.map(String.init) ?? modelID
        return String(short.prefix(12))
    }
}
