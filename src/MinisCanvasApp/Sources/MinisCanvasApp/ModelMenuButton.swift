import SwiftUI
import MinisCore

/// 打开本 App 的设置中心 sheet 并定位到指定页（nil = 默认页）。本 App 没有系统
/// Settings 场景，SwiftUI 的 `openSettings` 在这里是空操作；所有"去设置"入口走
/// 与工具栏 / ⌘, / 深链相同的 `DeepLinkHandler.openSettings(id:)` 路径。
private struct MinisOpenSettingsPageKey: EnvironmentKey {
    static let defaultValue: @MainActor (String?) -> Void = { _ in }
}

extension EnvironmentValues {
    var minisOpenSettingsPage: @MainActor (String?) -> Void {
        get { self[MinisOpenSettingsPageKey.self] }
        set { self[MinisOpenSettingsPageKey.self] = newValue }
    }
}

// MARK: - E24 对话条模型按钮（Codex/Hermes 风格）
//
// 用户反馈：模型切换和速度档位切换要放在对话输入的地方（Hermes/Codex 输入区模型切换器）。
// F9-ui（用户实测反馈）：SwiftUI Menu 点任一项即选中默认值并关闭，无法连续选择 →
// 重做为 Popover + ModelPickerPanel 共享面板（三级状态机 provider → model → tier），
// 侧栏头部 / 顶栏（ChatModelMenu）与全局对话条（ModelMenuButton）共用同一份面板逻辑，
// 避免两套逻辑漂移。对话条按钮为紧凑胶囊：档位图标 + 模型短名。

// MARK: - F9-ui 三级选择状态机（provider → model → tier）
//
// 用户实测反馈：原 SwiftUI Menu 点任一项立即选中默认值并关闭，无法连续选择。
// 重做为 Popover + 三级状态机：
//   ① 点 Provider 只更新选中 + 刷新模型列表（不关闭）
//   ② 点模型只更新选中（不关闭）
//   ③ 点速度档位 = 最终确认（应用到 ChatStore + 关闭）
//   ④ 点面板外部关闭 Popover 时，未确认的选择不生效
//   ⑤ 记忆：每个 Provider 记住上次模型 + 档位（UserDefaults），再次打开自动预选高亮

/// 三级选择状态机（纯逻辑，可单测）。
struct ModelPickerState: Equatable {
    enum Phase: Equatable {
        /// 等待选模型（②）
        case pickingModel
        /// 等待选速度档位（③）
        case pickingTier
        /// 已确认（点了档位）
        case confirmed
    }

    /// 选中的内置 Provider（nil = 未选内置；「演示模式」仅当 customProvider==nil 且本字段==nil）
    var provider: ProviderType?
    /// 选中的自定义供应商记录（U-5 ProviderRecord，nil = 未选自定义）
    var customProvider: EnvVarEntry?
    /// 选中的模型 ID（nil = 默认 / 未选）
    var modelID: String?
    /// 选中的速度档位（nil = 未选）
    var tier: ModelSpeedTier?
    /// 是否已显式选过模型（含「默认」行；Mock/本地无目录时跳过）
    var modelChosen = false
    /// 是否已最终确认（③ 档位点击）
    var confirmed = false

    init(provider: ProviderType?, modelID: String?, tier: ModelSpeedTier?) {
        self.provider = provider
        self.customProvider = nil
        self.modelID = modelID
        self.tier = tier
        self.modelChosen = modelID != nil
    }

    /// 当前选中 Provider 的统一视图（内置 / 自定义 / nil=Mock）。
    var selectedOption: ChatStore.ChatProvider? {
        if let custom = customProvider { return .custom(custom) }
        if let type = provider { return .builtIn(type) }
        return nil
    }

    /// 当前阶段：有模型目录且未选模型 → ②；否则 → ③（Mock/本地无目录，直接选档位确认）。
    var phase: Phase {
        Self.phase(
            hasCatalog: selectedOption?.modelOptions.isEmpty == false,
            modelChosen: modelChosen,
            confirmed: confirmed
        )
    }

    /// 由有效模型目录和选择状态推导当前阶段。
    static func phase(
        hasCatalog: Bool,
        modelChosen: Bool,
        confirmed: Bool
    ) -> Phase {
        if confirmed { return .confirmed }
        if hasCatalog && !modelChosen { return .pickingModel }
        return .pickingTier
    }

    /// ① 选内置 Provider：切换模型列表；有该 Provider 记忆时预选（高亮）上次模型/档位。
    /// 只更新状态，不确认、不关面板。同时清除自定义供应商选择。
    mutating func selectProvider(_ type: ProviderType?, memory: ModelMenuMemory.Entry? = nil) {
        provider = type
        customProvider = nil
        confirmed = false
        applyMemory(memory)
    }

    /// ① 选自定义供应商（U-5 ProviderRecord）：切换模型列表 + 记忆预选；清除内置选择。
    mutating func selectCustomProvider(_ record: EnvVarEntry, memory: ModelMenuMemory.Entry? = nil) {
        customProvider = record
        provider = nil
        confirmed = false
        applyMemory(memory)
    }

    private mutating func applyMemory(_ memory: ModelMenuMemory.Entry?) {
        if let memory {
            modelID = memory.modelID
            tier = memory.tier
            modelChosen = true
        } else {
            modelID = nil
            tier = nil
            modelChosen = false
        }
    }

    /// ② 远程模型沿用已预选档位，或使用会话当前档位。
    mutating func selectModel(_ id: String?, fallbackTier: ModelSpeedTier? = nil) {
        modelID = id
        modelChosen = true
        if let fallbackTier, selectedOption?.isLocal == false {
            selectTier(tier ?? fallbackTier)
        } else {
            tier = nil
            confirmed = false
        }
    }

    /// ③ 单独选择速度档位。
    mutating func selectTier(_ value: ModelSpeedTier) {
        tier = value
        confirmed = true
    }

    /// 把已确认状态应用到 ChatStore，并写入该 Provider 的记忆。
    /// 未确认 / 无档位时为空操作（防御：面板外部关闭不走这里）。
    @MainActor
    @discardableResult
    func apply(to chat: ChatStore, defaults: UserDefaults = .standard) -> Bool {
        guard confirmed, let tier else { return false }

        let didApply: Bool
        if let custom = customProvider {
            // `other` has no wire adapter. Keep the picker and send path
            // fail-closed even when a fixture readiness store says "passed".
            guard custom.protocolType != .other,
                  let modelID = modelID ?? chat.chatModelPickerModels(
                      forProviderID: custom.name
                  ).first?.id else {
                return false
            }
            if chat.providerReadinessStore != nil {
                didApply = chat.applyChatModel(
                    providerID: custom.name,
                    modelID: modelID
                )
            } else {
                chat.setCustomProvider(custom)
                didApply = chat.applyPickedModel(modelID: modelID)
            }
        } else if let provider {
            if chat.providerReadinessStore != nil {
                let modelID = modelID ?? chat.chatModelPickerModels(
                    forProviderID: provider.rawValue
                ).first?.id
                guard let modelID else { return false }
                didApply = chat.applyChatModel(
                    providerID: provider.rawValue,
                    modelID: modelID
                )
            } else {
                chat.setProvider(provider)
                didApply = chat.applyPickedModel(modelID: modelID)
            }
        } else {
            chat.setProvider(nil)
            // Mock has no provider/model readiness identity. setProvider(nil)
            // already clears the session model; the readiness gate for real
            // providers must not reject a confirmed Mock speed selection.
            didApply = true
        }
        guard didApply else { return false }

        // R9：精确写模型 + 同步会话级记录（setProvider/setCustomProvider 只写首模型，
        // 不覆盖会丢用户所选模型——切会话再切回回退首模型）
        chat.modelSpeedTier = tier
        chat.onSpeedTierChanged?(tier)
        switch selectedOption {
        case .builtIn(let type):
            ModelMenuMemory.save(provider: type, entry: .init(modelID: modelID, tier: tier), defaults: defaults)
            if let mid = modelID { ModelMenuUsage.record(modelID: mid, provider: type, defaults: defaults) }
        case .custom(let record):
            ModelMenuMemory.save(custom: record.name, entry: .init(modelID: modelID, tier: tier), defaults: defaults)
            if let mid = modelID { ModelMenuUsage.record(modelID: mid, custom: record.name, defaults: defaults) }
        case nil:
            ModelMenuMemory.save(provider: nil, entry: .init(modelID: modelID, tier: tier), defaults: defaults)
            if let mid = modelID { ModelMenuUsage.record(modelID: mid, provider: nil, defaults: defaults) }
        }
        return true
    }
}

// MARK: - F9-ui 每 Provider 记忆（上次模型 + 速度档位）

/// UserDefaults 存储：每 provider → (lastModelID, lastTier)。
/// Key：`modelMenu.lastUsed.<providerID>`；演示模式为 `modelMenu.lastUsed.mock`。
struct ModelMenuMemory {
    struct Entry: Equatable {
        var modelID: String?
        var tier: ModelSpeedTier?
    }

    static func key(for provider: ProviderType?) -> String {
        "modelMenu.lastUsed." + (provider?.rawValue ?? "mock")
    }

    /// 自定义供应商（U-5 ProviderRecord）的记忆 key。
    static func key(forCustom name: String) -> String {
        "modelMenu.lastUsed.custom." + name
    }

    static func load(provider: ProviderType?, defaults: UserDefaults) -> Entry? {
        load(key: key(for: provider), defaults: defaults)
    }

    /// 自定义供应商记忆读取。
    static func load(custom name: String, defaults: UserDefaults) -> Entry? {
        load(key: key(forCustom: name), defaults: defaults)
    }

    private static func load(key: String, defaults: UserDefaults) -> Entry? {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return nil
        }
        let modelID = obj["modelID"].flatMap { $0.isEmpty ? nil : $0 }
        let tier = obj["tier"].flatMap { ModelSpeedTier(rawValue: $0) }
        guard modelID != nil || tier != nil else { return nil }
        return Entry(modelID: modelID, tier: tier)
    }

    static func save(provider: ProviderType?, entry: Entry, defaults: UserDefaults) {
        save(key: key(for: provider), entry: entry, defaults: defaults)
    }

    /// 自定义供应商记忆写入。
    static func save(custom name: String, entry: Entry, defaults: UserDefaults) {
        save(key: key(forCustom: name), entry: entry, defaults: defaults)
    }

    private static func save(key: String, entry: Entry, defaults: UserDefaults) {
        let obj: [String: String] = [
            "modelID": entry.modelID ?? "",
            "tier": entry.tier?.rawValue ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: key)
    }
}

// MARK: - AJ-40 模型使用频率（智能排序：常用/最近使用排前面）

/// 单个模型的使用统计：使用次数 + 最近使用时间。
struct ModelUsage: Equatable {
    var count: Int
    var lastUsed: Date
}

/// UserDefaults 存储：每 provider → [modelID: (count, lastUsed)]。
/// Key：`modelMenu.usage.<providerID>`；演示模式为 `modelMenu.usage.mock`。
/// 与 ModelMenuMemory（上次模型+档位）互补：前者记录"当前选中的"记忆，后者累计"用得多不多"。
struct ModelMenuUsage {
    static func key(for provider: ProviderType?) -> String {
        "modelMenu.usage." + (provider?.rawValue ?? "mock")
    }

    /// 自定义供应商（U-5 ProviderRecord）的使用频率 key。
    static func key(forCustom name: String) -> String {
        "modelMenu.usage.custom." + name
    }

    static func load(provider: ProviderType?, defaults: UserDefaults) -> [String: ModelUsage] {
        load(key: key(for: provider), defaults: defaults)
    }

    /// 自定义供应商使用频率读取。
    static func load(custom name: String, defaults: UserDefaults) -> [String: ModelUsage] {
        load(key: key(forCustom: name), defaults: defaults)
    }

    private static func load(key: String, defaults: UserDefaults) -> [String: ModelUsage] {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            return [:]
        }
        var result: [String: ModelUsage] = [:]
        for (modelID, dict) in obj {
            let count = (dict["count"] as? Int) ?? 0
            let timestamp = (dict["lastUsed"] as? Double) ?? 0
            result[modelID] = ModelUsage(count: count, lastUsed: Date(timeIntervalSince1970: timestamp))
        }
        return result
    }

    /// 记录一次模型使用：次数 +1、刷新最近使用时间。
    static func record(modelID: String, provider: ProviderType?, defaults: UserDefaults) {
        record(modelID: modelID, key: key(for: provider), defaults: defaults)
    }

    /// 自定义供应商使用记录。
    static func record(modelID: String, custom name: String, defaults: UserDefaults) {
        record(modelID: modelID, key: key(forCustom: name), defaults: defaults)
    }

    private static func record(modelID: String, key: String, defaults: UserDefaults) {
        var usage = load(key: key, defaults: defaults)
        let now = Date()
        if let existing = usage[modelID] {
            usage[modelID] = ModelUsage(count: existing.count + 1, lastUsed: now)
        } else {
            usage[modelID] = ModelUsage(count: 1, lastUsed: now)
        }
        save(usage, key: key, defaults: defaults)
    }

    private static func save(_ usage: [String: ModelUsage], key: String, defaults: UserDefaults) {
        let obj = usage.mapValues { ["count": $0.count, "lastUsed": $0.lastUsed.timeIntervalSince1970] }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: key)
    }

    /// AJ-40 智能排序（纯函数，可单测）：按使用频率降序 → 最近使用降序 → 保持原目录相对顺序（稳定）。
    /// 无使用记录（count=0）的模型归零，排在已使用模型之后，彼此保持原目录顺序。
    static func sortedModels(_ models: [LLMModel], usage: [String: ModelUsage]) -> [LLMModel] {
        models
            .enumerated()
            .sorted { a, b in
                let ua = usage[a.element.id]
                let ub = usage[b.element.id]
                let ca = ua?.count ?? 0
                let cb = ub?.count ?? 0
                if ca != cb { return ca > cb }
                let ta = ua?.lastUsed ?? .distantPast
                let tb = ub?.lastUsed ?? .distantPast
                if ta != tb { return ta > tb }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}

// MARK: - F9-ui 共享模型选择面板（Popover 内容，三级状态机）

/// 共享模型选择面板：侧栏头部 ChatModelMenu 与对话条 ModelMenuButton 弹出同一份面板，
/// 两个入口交互一致。流程 ① Provider → ② 模型 → ③ 速度档位；
/// 只有点速度档位才确认并关闭；点面板外部关闭 Popover（未确认的选择不生效）。
struct ModelPickerPanel: View {
    var chat: ChatStore
    @Binding var isPresented: Bool
    @State private var state: ModelPickerState
    @State private var localModelText: String
    @State private var localProbeTask: Task<Void, Never>?
    @State private var localProbeGeneration = UUID()
    @State private var localProbeInFlight = false
    @State private var localProbeFailed = false
    @Environment(\.themeTokens) private var theme
    @Environment(\.minisOpenSettingsPage) private var openSettingsPage

    @MainActor
    init(chat: ChatStore, isPresented: Binding<Bool>) {
        self.chat = chat
        _isPresented = isPresented
        var state = ModelPickerState(
            provider: chat.selectedProviderType,
            modelID: chat.selectedModelID,
            tier: chat.modelSpeedTier
        )
        state.customProvider = chat.selectedCustomProvider.map { selected in
            chat.providerRecordsSource?().first { $0.id == selected.id } ?? selected
        }
        _state = State(initialValue: state)
        _localModelText = State(initialValue: chat.selectedModelID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("选择模型")
                    .font(.system(size: 11, weight: .semibold))
                Text(phaseHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    providerSection
                    modelSection
                    tierSection
                }
                .padding(10)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 272)
        .onDisappear { cancelLocalProbe() }
    }

    private var phaseHint: String {
        let hasCatalog = state.selectedOption.map {
            !Self.readinessFilteredModels(for: $0, chat: chat).isEmpty
        } ?? false
        switch ModelPickerState.phase(
            hasCatalog: hasCatalog,
            modelChosen: state.modelChosen,
            confirmed: state.confirmed
        ) {
        case .pickingModel: return "点选远程模型即生效，也可单独更改速度档位"
        case .pickingTier: return "下一步：选择速度档位（③）确认"
        case .confirmed: return "已应用"
        }
    }

    /// Provider readiness is the source of truth once the production chat
    /// store has one; keep the raw catalog for preview/test-only stores.
    @MainActor
    static func readinessFilteredModels(
        for option: ChatStore.ChatProvider,
        chat: ChatStore
    ) -> [LLMModel] {
        guard chat.providerReadinessStore != nil else {
            return option.modelOptions
        }

        switch option {
        case .builtIn(let type):
            return chat.chatModelPickerModels(forProviderID: type.rawValue)
        case .custom(let record):
            return chat.chatModelPickerModels(forProviderID: record.name)
        }
    }

    /// Display every configured/catalogued model, including blocked entries.
    /// The existing receipt gate remains the only enablement source.
    @MainActor
    static func visibleModels(for option: ChatStore.ChatProvider, chat: ChatStore) -> [LLMModel] {
        let providerID = ProviderReadinessRevision.canonicalProviderID(option.providerRuntimeID)
        let projected = ConversationModelPickerConsumer(chat: chat).rows.filter { $0.providerID == providerID }
        var models = option.modelOptions
        var seen = Set(models.map(\.id))
        for item in projected where seen.insert(item.modelID).inserted {
            models.append(LLMModel(id: item.modelID, displayName: item.modelID, provider: providerID))
        }
        return models
    }

    @MainActor
    static func modelSelectionEnabled(for option: ChatStore.ChatProvider, modelID: String, chat: ChatStore) -> Bool {
        guard chat.providerReadinessStore != nil else { return true }
        return chat.chatModelPickerReceipt(providerID: option.providerRuntimeID, modelID: modelID) != nil
    }

    private func blockedReason(for option: ChatStore.ChatProvider, modelID: String? = nil) -> String? {
        guard chat.providerReadinessStore != nil, !option.isLocal else { return nil }
        if let modelID {
            guard !Self.modelSelectionEnabled(for: option, modelID: modelID, chat: chat) else { return nil }
        } else if !Self.readinessFilteredModels(for: option, chat: chat).isEmpty { return nil }
        let providerID = ProviderReadinessRevision.canonicalProviderID(option.providerRuntimeID)
        let item = ConversationModelPickerConsumer(chat: chat).rows.first {
            $0.providerID == providerID && (modelID == nil || $0.modelID == modelID)
        }
        return item?.isSelectable == true ? "配置已变化，请重新检查" : item?.statusLabel ?? "尚未配置或未完成检查"
    }

    // MARK: ① Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("① 服务商")
            // P0-C1：候选 = 内置聊天 Provider + 用户自定义供应商记录（U-5）。
            // 就绪供应商在前，演示模式在就绪项之后，未就绪项再后。
            ForEach(providerMenuRows, id: \.id) { menuRow in
                switch menuRow {
                case .mock:
                    row(isSelected: state.selectedOption == nil, icon: "wand.and.stars", keylineIcon: .wandSparkles,
                        title: "演示模式", subtitle: nil) {
                        pickProvider(nil)
                    }
                case .provider(let option):
                    providerOptionRow(option)
                }
            }
        }
    }

    private var providerMenuRows: [ModelPickerProviderRow] {
        let options = ChatStore.chatProviderOptions(customRecords: chat.providerRecordsSource?() ?? [])
        let ready = Set(options.filter { !$0.isLocal && blockedReason(for: $0) == nil }.map(\.providerRuntimeID))
        return ModelPickerState.providerMenuRows(options: options, readyProviderIDs: ready)
    }

    @ViewBuilder
    private func providerOptionRow(_ option: ChatStore.ChatProvider) -> some View {
        let reason = blockedReason(for: option)
        switch option {
        case .builtIn(let type):
            row(isSelected: state.selectedOption == option, icon: providerIcon(type),
                title: type.displayName, subtitle: reason, isEnabled: reason == nil) {
                pickProvider(type)
            }
        case .custom(let record):
            row(isSelected: state.selectedOption == option, icon: "externaldrive", keylineIcon: .database,
                title: chat.presentationProviderLabel(for: record.name),
                subtitle: reason, isEnabled: reason == nil) {
                pickCustomProvider(record)
            }
        }
        if reason != nil {
            Button("去设置 · \(option.displayName)") {
                isPresented = false
                openSettingsPage(ProviderConnectionRoute.id)
            }
                .buttonStyle(.link).font(.caption)
        }
    }

    /// ① 点内置 Provider：只更新选中 + 刷新模型列表（记忆预选），不关闭面板。
    private func pickProvider(_ type: ProviderType?) {
        cancelLocalProbe()
        let memory = ModelMenuMemory.load(
            provider: type,
            defaults: chat.preferencesDefaults
        )
        state.selectProvider(type, memory: memory)
        localModelText = memory?.modelID ?? ""
    }

    /// ① 点自定义供应商（U-5 ProviderRecord）：同上，记忆按供应商名隔离。
    private func pickCustomProvider(_ record: EnvVarEntry) {
        cancelLocalProbe()
        let memory = ModelMenuMemory.load(
            custom: record.name,
            defaults: chat.preferencesDefaults
        )
        state.selectCustomProvider(record, memory: memory)
        localModelText = memory?.modelID ?? ""
    }

    // MARK: ② 模型（随 Provider 刷新）

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("模型（\(state.customProvider.map { chat.presentationProviderLabel(for: $0.name) } ?? state.selectedOption?.displayName ?? "演示模式")）")
            if state.selectedOption == nil {
                Text("演示模式无模型目录，直接选择下方速度档位即可确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else if state.selectedOption?.isLocal == true {
                TextField("自定义模型名（如 qwen2.5）", text: $localModelText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onChange(of: localModelText) { _, newValue in
                        cancelLocalProbe()
                        state.modelID = newValue.isEmpty ? nil : newValue
                        state.modelChosen = true
                    }
                Text("输入已安装的 Ollama 模型名；点档位时检查固定本地端点并确认")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if localProbeInFlight {
                    Text("正在检查本地模型…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else if localProbeFailed {
                    Text("本地模型未通过检查；确认 Ollama 已启动且模型名准确后重试")
                        .font(.system(size: 9))
                        .modifier(ReadableStatusForeground(status: .danger))
                }
            } else if let option = state.selectedOption {
                let models = Self.visibleModels(for: option, chat: chat)
                if !models.isEmpty {
                    row(isSelected: state.modelChosen && state.modelID == nil,
                        icon: "cube.transparent", keylineIcon: .box, title: "默认（服务商推荐）", subtitle: blockedReason(for: option),
                        isEnabled: blockedReason(for: option) == nil) {
                        selectRemoteModel(nil)
                    }
                    // AJ-40 智能排序：常用/最近使用排前面（每 Provider 按使用频率排序）。
                    ForEach(sortedModels(models)) { model in
                        row(isSelected: state.modelID == model.id, icon: "cpu", keylineIcon: .cpu,
                            title: model.displayName,
                            subtitle: blockedReason(for: option, modelID: model.id) ?? (model.id == model.displayName ? nil : model.id),
                            isEnabled: Self.modelSelectionEnabled(for: option, modelID: model.id, chat: chat)) {
                            selectRemoteModel(model.id)
                        }
                    }
                } else {
                    Text("该服务商暂无内置模型目录")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("该服务商暂无内置模型目录")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: ③ 速度档位（点击 = 确认并关闭）

    private var tierSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("③ 速度档位（点击确认并关闭）")
            ForEach(ModelSpeedTier.allCases, id: \.self) { tier in
                let presentation = ModelSpeedTierPresentation(tier)
                row(isSelected: state.tier == tier, icon: nil,
                    keylineIcon: presentation.icon,
                    title: presentation.label, subtitle: nil) {
                    finalize(with: tier)
                }
                .disabled(localProbeInFlight && state.provider == .local)
            }
        }
    }

    private func selectRemoteModel(_ id: String?) {
        state.selectModel(id, fallbackTier: chat.modelSpeedTier)
        guard let tier = state.tier else { return }
        finalize(with: tier)
    }

    /// 应用模型与档位、写入记忆并关闭面板。
    private func finalize(with tier: ModelSpeedTier) {
        if state.selectedOption?.isLocal == true {
            let name = localModelText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                localProbeFailed = true
                return
            }
            if chat.providerReadinessStore != nil {
                startLocalProbe(modelID: name, tier: tier)
                return
            }
            state.modelID = name.isEmpty ? nil : name
            state.modelChosen = true
        }
        state.selectTier(tier)
        guard state.apply(to: chat, defaults: chat.preferencesDefaults) else { return }
        isPresented = false
    }

    private func cancelLocalProbe() {
        localProbeTask?.cancel()
        localProbeTask = nil
        localProbeGeneration = UUID()
        localProbeInFlight = false
        localProbeFailed = false
    }

    private func startLocalProbe(modelID: String, tier: ModelSpeedTier) {
        cancelLocalProbe()
        let generation = localProbeGeneration
        localProbeInFlight = true
        localProbeTask = Task { @MainActor in
            let prepared = await chat.prepareLocalModelSelection(modelID: modelID) {
                localProbeGeneration == generation
                    && isPresented
                    && state.provider == .local
                    && state.customProvider == nil
                    && localModelText.trimmingCharacters(in: .whitespacesAndNewlines) == modelID
            }
            guard !Task.isCancelled,
                  localProbeGeneration == generation,
                  isPresented,
                  state.provider == .local,
                  state.customProvider == nil,
                  localModelText.trimmingCharacters(in: .whitespacesAndNewlines) == modelID else {
                return
            }
            localProbeTask = nil
            localProbeInFlight = false
            guard prepared else {
                localProbeFailed = true
                return
            }
            state.modelID = modelID
            state.modelChosen = true
            state.selectTier(tier)
            guard state.apply(to: chat, defaults: chat.preferencesDefaults) else {
                localProbeFailed = true
                return
            }
            isPresented = false
        }
    }

    /// AJ-40 智能排序：读取当前 Provider 的使用频率，把常用/最近使用模型排前面。
    private func sortedModels(_ models: [LLMModel]) -> [LLMModel] {
        let usage: [String: ModelUsage]
        if let custom = state.customProvider {
            usage = ModelMenuUsage.load(
                custom: custom.name,
                defaults: chat.preferencesDefaults
            )
        } else {
            usage = ModelMenuUsage.load(
                provider: state.provider,
                defaults: chat.preferencesDefaults
            )
        }
        return ModelMenuUsage.sortedModels(models, usage: usage)
    }

    // MARK: 行样式

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }

    private func row(
        isSelected: Bool,
        icon: String?,
        keylineIcon: MinisIcon? = nil,
        title: String,
        subtitle: String?,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let guardedAction = { if isEnabled { action() } }
        return Button(action: guardedAction) {
            HStack(spacing: 6) {
                Group {
                    if let keylineIcon {
                        MinisIconView(
                            keylineIcon,
                            state: isSelected ? .active : .normal,
                            size: 12,
                            accessibilityLabel: title
                        )
                    } else if isSelected {
                        MinisIconView(.check, state: .active, size: 12, accessibilityLabel: "已选中")
                    } else if let icon {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .disabled(!isEnabled)
        .accessibilityAction(.default, guardedAction)
        .accessibilityLabel(subtitle.map { "\(title)，\($0)" } ?? title)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint(isEnabled ? "选择此项" : "不可选择，请到设置检查模型连接")
    }

    private func providerIcon(_ type: ProviderType) -> String {
        switch type {
        case .openAI, .openAIResponses: return "brain"
        case .anthropic: return "bubble.left.and.bubble.right"
        case .gemini: return "sparkles"
        case .openRouter: return "arrow.triangle.branch"
        case .dashScope: return "cloud"
        case .deepSeek: return "water.waves"
        case .local: return "internaldrive"
        default: return "cpu"
        }
    }
}

// MARK: - 侧栏头部 / 顶栏 紧凑模型选择器（原 ChatSidebarView 组件，抽到此处共用）

/// Provider 分组 + 模型列表，紧凑胶囊样式。
/// F9-ui：Menu → Popover + ModelPickerPanel（三级状态机：① Provider → ② 模型 → ③ 速度档位），
/// 与对话条 ModelMenuButton 共用同一面板，两个入口交互一致。
struct ChatModelMenu: View {
    @Bindable var chat: ChatStore
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let presentation = ModelSpeedTierPresentation(chat.modelSpeedTier)
        let mediaBlockReason = chat.composerAttachmentBlockReason
        let modelLabel = Self.menuLabel(
            modelID: chat.selectedModelID,
            providerType: chat.selectedProviderType,
            tier: chat.modelSpeedTier
        )
        let accessibilityLabel = "当前模型 \(modelLabel)，速度档位 \(presentation.accessibilityLabel)"
        HStack(spacing: 5) {
            presentation.iconView(selected: false, size: MinisIconTokens.smallSize)
            Text(modelLabel)
            .font(.system(size: 10))
            .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.4)))
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(mediaBlockReason.map { "当前附件：\($0)" } ?? "附件状态未阻断")
        .help("当前模型状态（只读）：\(chat.providerLabel)" + (mediaBlockReason.map { "；当前附件：\($0)" } ?? ""))
    }

    /// E19 菜单标签：档位名 + 当前模型（Codex 风格紧凑）。
    static func menuLabel(modelID: String?, providerType: ProviderType?, tier: ModelSpeedTier) -> String {
        if let mid = modelID, !mid.isEmpty {
            return "\(ModelSpeedTierPresentation.label(for: tier)) · \(mid)"
        }
        if providerType == nil { return "\(ModelSpeedTierPresentation.label(for: tier)) · Mock" }
        return ModelSpeedTierPresentation.label(for: tier)
    }
}

// MARK: - E24 对话条模型按钮（Codex/Hermes 风格，输入框左侧）

/// 全局对话条左侧的紧凑模型按钮：档位图标 + 模型短名，
/// F9-ui：Menu → Popover + ModelPickerPanel（与侧栏 ChatModelMenu 共用同一面板），
/// 三级状态机 ① Provider → ② 模型 → ③ 速度档位确认，确认后下一条消息用新模型。
struct ModelMenuButton: View {
    @Bindable var chat: ChatStore
    @State private var showPicker = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let presentation = ModelSpeedTierPresentation(chat.modelSpeedTier)
        let mediaBlockReason = chat.composerAttachmentBlockReason
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                presentation.iconView(selected: false, size: MinisIconTokens.smallSize)
                    .fixedSize()
                Text(Self.composerLabel(
                    modelID: chat.selectedModelID,
                    providerType: chat.selectedProviderType,
                    tier: chat.modelSpeedTier
                ))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                MinisIconView(.caretDown, size: 12, accessibilityLabel: "展开模型选择")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.4)))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            ModelPickerPanel(chat: chat, isPresented: $showPicker)
                .escapeShortcut(closePopover: {
                    guard showPicker else { return false }
                    showPicker = false
                    return true
                })
        }
        .accessibilityLabel("选择模型，当前速度档位 \(presentation.accessibilityLabel)")
        .accessibilityHint("点选远程模型即生效，也可单独更改速度档位")
        .accessibilityValue(
            "\(chat.providerLabel)，模型 ID：\(chat.selectedModelID ?? "未选择")"
                + (mediaBlockReason.map { "；当前附件：\($0)" } ?? "")
        )
        .help(
            "当前模型：\(chat.providerLabel)（\(presentation.accessibilityLabel)档）· 点选远程模型即生效，也可单独更改速度档位"
                + (mediaBlockReason.map { "；当前附件：\($0)" } ?? "")
        )
    }

    /// 对话条按钮文案（纯函数，可单测）：档位图标由外层单独渲染，这里只返回模型短名。
    /// - 已选模型 → 模型短名（如 qwen3.8）
    /// - Mock（无 Provider）→ "Mock"
    /// - 有 Provider 无模型 → 档位名
    static func composerLabel(modelID: String?, providerType: ProviderType?, tier: ModelSpeedTier) -> String {
        if let mid = modelID, !mid.isEmpty {
            return modelShortName(mid)
        }
        if providerType == nil { return "演示模式" }
        return tier.displayName
    }

    /// 模型短名：去掉常见速度后缀，胶囊内更紧凑（qwen3.8-max-preview → qwen3.8）。
    static func modelShortName(_ id: String) -> String {
        let suffixes = ["-max-preview", "-preview", "-latest", "-mini-latest", "-lite"]
        var name = id
        for suffix in suffixes where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }
}

/// 模型菜单 ① 的一行：演示模式或某个供应商候选。
enum ModelPickerProviderRow: Equatable {
    case mock
    case provider(ChatStore.ChatProvider)

    var id: String {
        switch self {
        case .mock: return "mock"
        case .provider(let option): return option.id
        }
    }
}

extension ModelPickerState {
    /// 就绪供应商在前，Mock 在就绪项之后，未就绪项再后；都保留可选。
    static func providerMenuRows(
        options: [ChatStore.ChatProvider],
        readyProviderIDs: Set<String>
    ) -> [ModelPickerProviderRow] {
        let ready = options.filter { readyProviderIDs.contains($0.providerRuntimeID) }
        let unready = options.filter { !readyProviderIDs.contains($0.providerRuntimeID) }
        return ready.map { .provider($0) } + [.mock] + unready.map { .provider($0) }
    }
}
