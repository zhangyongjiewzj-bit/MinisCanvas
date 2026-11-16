import SwiftUI
import AppKit
import CanvasCore
import MinisCore

// MARK: - 节点级模型选择面板（I8：主 App 画布）
//
// 复用 CanvasApp ModelConfigPanelView 的交互与目录逻辑（对齐 OpenMinis 手机客户端）：
// 点节点 → 弹面板 → provider 分组（本地/云端）→ 常用置顶 ⭐ → 点选即生效
// （一个 tap 更新节点 backendConfig，无确认按钮）。
// 差异：本包不依赖 LocalBackendProbe / JobTicket —— 本地组按离线渲染（Ollama 未部署，
// 不做探测）；任务单区块不属于本包范围。云端目录经 MinisCore ProviderIDMap 校验
// （providerID → ProviderType 可解析才展示，与 ProviderFactory 注册表保持一致）。

// MARK: 节点能力（决定面板显示哪些模型/参数）

enum NodeCapability: String {
    case llm, image, video

    /// 节点类型 → 能力映射（text 视作 llm 能力）。
    /// F10 P0-03：漫剧节点实际类型是 `imageGen`/`videoGen`（CanvasStore.manjuSpecs），
    /// 修复前只识别 `image`/`video`，生图/生视频节点被当成 LLM → 面板列出 LLM 模型目录，
    /// UI 选择与实际执行能力完全不一致。现两类命名空间都映射到对应媒体能力。
    static func forNodeType(_ type: String) -> NodeCapability {
        switch type {
        case "image", ManjuNodeType.imageGen.rawValue: return .image
        case "video", ManjuNodeType.videoGen.rawValue: return .video
        default: return .llm
        }
    }

    /// 节点是否支持 LLM 聊天入口（F10 P0-03：生图/生视频节点隐藏 LLM 聊天——
    /// 媒体后端不支持对话，聊天入口只会给出误导性的「未接入」体验）。
    static func supportsLLMChat(nodeType: String) -> Bool {
        forNodeType(nodeType) == .llm
    }
}

// MARK: 模型目录（云端静态 + 本地占位）

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

    // MARK: 常用模型置顶清单（面板内维护；与 CanvasApp ModelCatalog 对齐）
    static let pinnedModelIDs: Set<String> = [
        "qwen3.8-max-preview", "gpt-5.5", "claude-sonnet-4.5",
        "gpt-image-2-official", "kling-v2", "seedance-v2", "deepseek-v3",
    ]

    static func isPinned(_ id: String) -> Bool { pinnedModelIDs.contains(id) }

    /// ⭐ 置顶排序：starred 在前，组内保持目录原始相对顺序
    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.filter(\.starred) + entries.filter { !$0.starred }
    }

    // MARK: 云端静态目录（经 ProviderIDMap 校验后展示）

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
        Provider(id: "gimage2", name: "Gimage2 (Beta)", icon: "photo.on.rectangle.angled",
                 entries: sorted([
                    Entry(id: "gpt-image-2-official", displayName: "GPT Image 2 Official", capability: .image),
                    Entry(id: "gpt-image-2-fast", displayName: "GPT Image 2 Fast", capability: .image),
                 ])),
        Provider(id: "kling", name: "可灵 (Beta)", icon: "video.fill",
                 entries: sorted([
                    Entry(id: "kling-v2", displayName: "可灵 2.0", capability: .video),
                    Entry(id: "kling-v1", displayName: "可灵 1.6", capability: .video),
                 ])),
        Provider(id: "jimeng", name: "即梦 (Beta)", icon: "wand.and.stars",
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

    /// ProviderIDMap 接线：providerID → ProviderType 可解析的云端目录（未知 ID 不展示）。
    /// 保证面板目录与 MinisCore 映射表 / ProviderFactory 注册表同步。
    static var resolvedCloudProviders: [Provider] {
        cloudProviders.filter { ProviderIDMap.providerType(fromID: $0.id) != nil }
    }

    // MARK: 本地组（无探测依赖：默认离线渲染；Ollama 部署好后可接入真实探测）

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

    /// 按节点能力构建本地 provider 列表。status 以 providerID 为 key（与画布命名空间一致），
    /// 默认全离线 → 面板显示"未检测到本地后端"（Ollama 未部署，不做探测）。
    static func localProviders(
        status: [String: Bool] = [:],
        ollamaModels: [String] = [],
        capability: NodeCapability
    ) -> [Provider] {
        var providers: [Provider] = []
        if capability == .llm {
            let online = status["ollama"] == true
            let entries = online
                ? sorted(ollamaModels.map { Entry(id: $0, displayName: $0, capability: .llm) })
                : []
            providers.append(Provider(id: "ollama", name: "Ollama", icon: "cpu", entries: entries))
        }
        if capability == .image {
            let comfyOnline = status["comfyui-local"] == true
            providers.append(Provider(
                id: "comfyui-local", name: "ComfyUI", icon: "square.stack.3d.up",
                entries: comfyOnline ? sorted(comfyEntries) : []
            ))
            let sdOnline = status["stable-diffusion-local"] == true
            providers.append(Provider(
                id: "stable-diffusion-local", name: "SD 本地", icon: "photo",
                entries: sdOnline ? sorted(sdEntries) : []
            ))
        }
        if capability == .video {
            let wanOnline = status["wan-local"] == true
            providers.append(Provider(
                id: "wan-local", name: "Wan 本地", icon: "film",
                entries: wanOnline ? sorted(wanEntries) : []
            ))
        }
        return providers
    }

    /// 全部 provider（summaryLine 查找用）
    static func allProviders(
        status: [String: Bool] = [:],
        ollamaModels: [String] = [],
        capability: NodeCapability
    ) -> [Provider] {
        localProviders(status: status, ollamaModels: ollamaModels, capability: capability) + resolvedCloudProviders
    }
}

// MARK: - 面板视图

struct ModelConfigPanelView: View {
    /// 目标节点 ID（每次从 store 取实时数据，避免快照过期）
    let nodeID: UUID
    let store: CanvasStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeTokens) private var theme

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
            } else if isLLMRetired {
                // AJ-74：节点×LLM 前台下线——llm 节点不再显示模型选择/后端配置 UI。
                // 模型目录与参数区（providerSections/paramsSection）对 llm 节点隐藏，
                // 其他节点（text/生图/生视频等）面板行为不变。
                retiredNotice
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        unconfiguredRow
                        providerSections
                        paramsSection
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 370, height: 520)
        .background(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
    }

    /// AJ-74：目标节点是已下线的「LLM 推理」节点（旧图数据兼容，不可新建、不提供配置）
    private var isLLMRetired: Bool {
        node?.type == "llm"
    }

    /// AJ-74：下线占位（恢复时移除本分支即可；NodeCapability/ModelCatalog 等目录代码全部保留）
    private var retiredNotice: some View {
        VStack(spacing: 8) {
            MinisIconView(.power, size: 28, accessibilityLabel: "LLM 已下线")
            Text("LLM 已下线（AJ-74）")
                .font(.system(size: 13, weight: .semibold))
            Text("节点×LLM 前台功能已下线：模型选择与后端配置暂不可用，该节点按普通节点保留兼容旧图。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: 顶部：节点标题 + 当前模型摘要

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme?.nodeStatusColor(node?.status ?? .pending) ?? node?.status.color ?? .gray)
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
                MinisIconView(.close, size: 16, accessibilityLabel: "关闭")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// provider/model 两者都非空才算画布模型已配置；半配置与空白统一显示未配置。
    private var configuredModel: NodeBackendConfig? {
        guard let config = node?.backendConfig,
              !config.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return config
    }

    /// 当前所选模型摘要：如 "百炼 · 通义千问 3.8 Max"
    private var summaryLine: String {
        guard let config = configuredModel else { return "未配置" }
        let providers = ModelCatalog.allProviders(capability: capability)
        let providerName = providers.first { $0.id == config.providerID }?.name ?? config.providerID
        let modelName = providers
            .flatMap(\.entries)
            .first { $0.id == config.modelID }?.displayName ?? config.modelID
        return "\(providerName) · \(modelName)"
    }

    // MARK: 未配置

    private var unconfiguredRow: some View {
        Button {
            store.clearBackendConfig(for: nodeID)
        } label: {
            HStack(spacing: 8) {
                MinisIconView(.unavailable, size: 16, accessibilityLabel: "未配置")
                Text("未配置")
                    .font(.system(size: 13))
                Spacer()
                if configuredModel == nil {
                    MinisIconView(
                        .check,
                        state: .active,
                        size: 14,
                        accessibilityLabel: "当前选中"
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.6))
        )
    }

    // MARK: Provider 分组列表（本地 | 云端）

    @ViewBuilder
    private var providerSections: some View {
        // 本地组（无探测：默认离线渲染）
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("本地")
            } icon: {
                MinisIconView(.database, size: 16, accessibilityLabel: "本地")
            }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(localProviders) { provider in
                providerSection(provider, kind: .local, localOnline: false)
            }
        }

        // 云端组（经 ProviderIDMap 校验的目录）
        let cloud = cloudGroup
        if let cloud {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(cloud.title)
                } icon: {
                    // K2 fallback: cloud.icon is a dynamic provider/cloud asset
                    // with no stable existing MinisIcon case.
                    Image(systemName: cloud.icon)
                }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(cloud.providers) { provider in
                    providerSection(provider, kind: .cloud, localOnline: nil)
                }
            }
        }
    }

    /// 本地 provider 列表（按能力过滤，全部后端都显示，离线显示"未检测到本地后端"）
    private var localProviders: [ModelCatalog.Provider] {
        ModelCatalog.localProviders(capability: capability)
    }

    /// 云端组（只保留包含当前能力模型的 provider）
    private var cloudGroup: ModelCatalog.Group? {
        let providers = ModelCatalog.resolvedCloudProviders
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

    private func providerSection(_ provider: ModelCatalog.Provider, kind: ProviderKind, localOnline: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // K2 fallback: provider.icon is a dynamic provider asset.
                Image(systemName: provider.icon)
                    .font(.system(size: 11))
                Text(provider.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if let localOnline {
                    // 在线状态点：绿点=在线 / 灰点=离线（当前无探测，恒为离线）
                    Circle()
                        .fill(localOnline ? (theme?.statusSuccess ?? Color(nsColor: .systemGreen)) : (theme?.statusMuted ?? Color(nsColor: .systemGray)))
                        .frame(width: 7, height: 7)
                    Text(localOnline ? "在线" : "离线")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if provider.entries.isEmpty {
                Text(localOnline == false ? "未检测到本地后端" : "暂无可用模型")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            } else {
                ForEach(provider.entries) { entry in
                    modelRow(entry, providerID: provider.id, kind: kind)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor)).opacity(0.45))
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
                    MinisIconView(.success, state: .active, size: 14, accessibilityLabel: "当前选中")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected(providerID: providerID, modelID: entry.id)
                          ? (theme?.aj38.accent.swiftUIColor ?? Color(nsColor: .systemBlue)).opacity(0.12)
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

// MARK: - 对话内 Provider 配置 typed consumer

extension ModelConfigPanelView {
    /// Secret-free state rendered by a chat provider configuration surface.
    /// The panel owns presentation only; SettingsCenter remains the sole
    /// persistence and recovery owner.
    struct ChatProviderSettingsPanelState: Equatable, Sendable {
        let providerID: String
        let projection: ChatProviderSettingsReopenProjection?
        let recoveryState: ChatProviderSettingsRecoveryState?

        var credentialPresent: Bool { projection?.credentialPresent ?? false }
        var metadataRevision: String? { projection?.metadataRevision }

        var nextAction: ChatProviderSettingsPanelAction? {
            switch recoveryState {
            case .retryable: return .retry
            case .reopenRequired: return .reopen
            case .blockedTransactionUnknown: return .replaceCredential
            case nil: return nil
            }
        }
    }

    enum ChatProviderSettingsPanelAction: String, Equatable, Sendable {
        case retry
        case reopen
        case replaceCredential = "replace_credential"
    }

    enum ChatProviderSettingsPanelError: Error, Equatable, Sendable {
        case validation(ChatProviderSettingsValidationError)
        case dispatch(BL6SettingsDispatchError)
        case reopenUnavailable
    }

    /// Reopen the current SettingsCenter projection after a save or a
    /// recoverable failure. This deliberately returns metadata only and never
    /// accepts or returns a credential value.
    static func chatProviderSettingsPanelState(
        center: SettingsCenter,
        providerID: String,
        recoveryState: ChatProviderSettingsRecoveryState? = nil
    ) -> ChatProviderSettingsPanelState {
        ChatProviderSettingsPanelState(
            providerID: providerID,
            projection: center.chatProviderSettingsProjection(providerID: providerID),
            recoveryState: recoveryState
        )
    }

    /// Complete the production consumer path used by the chat-facing editor:
    /// live revision capture → typed preview → approval/CAS dispatch →
    /// persisted metadata reopen. The receipt is not treated as the UI state;
    /// the state is re-read from SettingsCenter after persistence.
    static func submitChatProviderSettings(
        center: SettingsCenter,
        requestID: String = UUID().uuidString,
        providerID: String,
        baseURL: String,
        modelIDs: [String],
        protocolType: ProviderWireProtocol,
        credential: BL6ProviderCredentialMutation = .keepExisting,
        approvalReceiptID: String
    ) -> Result<ChatProviderSettingsPanelState, ChatProviderSettingsPanelError> {
        let preview: ChatProviderSettingsPreview
        switch center.makeChatProviderSettingsPreview(
            requestID: requestID,
            providerID: providerID,
            baseURL: baseURL,
            modelIDs: modelIDs,
            protocolType: protocolType,
            credential: credential
        ) {
        case .success(let value): preview = value
        case .failure(let error): return .failure(.validation(error))
        }

        switch center.confirmChatProviderSettings(preview, approvalReceiptID: approvalReceiptID) {
        case .success:
            guard center.chatProviderSettingsProjection(providerID: providerID) != nil else {
                return .failure(.reopenUnavailable)
            }
            return .success(chatProviderSettingsPanelState(center: center, providerID: providerID))
        case .failure(let error):
            return .failure(.dispatch(error))
        }
    }

    /// Chat configuration callers use this pure adapter to create the same
    /// validated preview as SettingsCenter. It intentionally does not touch
    /// the canvas node or apply a backend change; confirmation is a separate
    /// SettingsCenter operation.
    static func makeChatProviderSettingsPreview(
        requestID: String = UUID().uuidString,
        providerID: String,
        baseURL: String,
        modelIDs: [String],
        protocolType: ProviderWireProtocol,
        credential: BL6ProviderCredentialMutation = .keepExisting,
        expectedRevision: String,
        expectedProviderRevision: String? = nil
    ) -> Result<ChatProviderSettingsPreview, ChatProviderSettingsValidationError> {
        do {
            return .success(try ChatProviderSettingsPreview(
                requestID: requestID,
                providerID: providerID,
                baseURL: baseURL,
                modelIDs: modelIDs,
                protocolType: protocolType,
                credential: credential,
                expectedRevision: expectedRevision,
                expectedProviderRevision: expectedProviderRevision
            ))
        } catch let error as ChatProviderSettingsValidationError {
            return .failure(error)
        } catch {
            return .failure(.invalidBaseURL)
        }
    }
}
