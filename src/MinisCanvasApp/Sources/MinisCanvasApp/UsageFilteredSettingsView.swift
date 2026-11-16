import Foundation
import SwiftUI

/// The transient filter state owned by `UsageFilteredSettingsView`.
///
/// This is deliberately not persisted and does not mirror provider settings.
/// A nil provider means "all providers"; legacy records without a stable
/// provider ID remain in that scope and are rendered as explicitly unbound.
struct UsageFilteredSettingsFilterState: Equatable, Sendable {
    var providerRecordID: String?
    var startDate: Date?
    var endDate: Date?
    var models: Set<String>
    var timeZone: TimeZone

    init(
        providerRecordID: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        models: Set<String> = [],
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.providerRecordID = providerRecordID
        self.startDate = startDate
        self.endDate = endDate
        self.models = models
        self.timeZone = timeZone
    }

    /// Date controls and buckets use the user's local day, including DST.
    /// Absolute timestamps remain unchanged in persisted usage records.
    var normalizedDateInterval: DateInterval? {
        guard let startDate, let endDate else { return nil }
        guard startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite else { return nil }
        let start = UsageFilteredSettingsView.localStartOfDay(startDate, timeZone: timeZone)
        let end = UsageFilteredSettingsView.localStartOfDay(endDate, timeZone: timeZone)
        guard start <= end else { return nil }
        return DateInterval(start: start, end: end)
    }

    var hasInvalidDateRange: Bool {
        guard let startDate, let endDate else {
            return startDate != nil || endDate != nil
        }
        guard startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite else { return true }
        return UsageFilteredSettingsView.localStartOfDay(startDate, timeZone: timeZone)
            > UsageFilteredSettingsView.localStartOfDay(endDate, timeZone: timeZone)
    }

    var isFiltering: Bool {
        providerRecordID != nil || startDate != nil || endDate != nil || !models.isEmpty
    }
}

/// Small, testable gate used by refresh tasks. A result computed for an older
/// filter selection cannot clear the spinner or replace a newer selection.
struct UsageFilteredSettingsRefreshGate: Equatable, Sendable {
    private(set) var latestToken = 0

    mutating func begin(for filters: UsageFilteredSettingsFilterState) -> Request {
        latestToken += 1
        return Request(token: latestToken, filters: filters)
    }

    mutating func invalidate() { latestToken += 1 }

    func accepts(_ request: Request, currentFilters: UsageFilteredSettingsFilterState) -> Bool {
        request.token == latestToken && request.filters == currentFilters
    }

    struct Request: Equatable, Sendable {
        let token: Int
        let filters: UsageFilteredSettingsFilterState
    }
}

struct UsageFilteredSettingsProviderOption: Identifiable, Equatable, Sendable {
    let recordID: String
    let displayName: String
    let status: UsageProviderProjectionStatus

    var id: String { recordID }

    var label: String {
        status == .deleted ? "\(displayName)（已删除）" : displayName
    }
}

/// A complete usage consumer for the Settings surface. The PKG lane owns the
/// one-line SettingsView entry-point wiring; this view owns only transient
/// filters and reads the already-composed canonical UsageStore instance.
struct UsageFilteredSettingsView: View {
    let usageStore: UsageStore
    let chatStore: ChatStore?

    @Environment(\.typographyTokens) private var typography
    @State private var selectedProviderID: String?
    @State private var selectedModels: Set<String> = []
    @State private var dateRangeEnabled = false
    @State private var startDate: Date = Self.localStartOfDay(Date().addingTimeInterval(-30 * 86_400))
    @State private var endDate: Date = Self.localStartOfDay(Date().addingTimeInterval(86_400))
    @State private var isRefreshing = false
    @State private var refreshGate = UsageFilteredSettingsRefreshGate()
    @State private var pendingClear = false

    init(usageStore: UsageStore, chatStore: ChatStore? = nil) {
        self.usageStore = usageStore
        self.chatStore = chatStore
    }

    /// Nonisolated by design: this is pure `Calendar`/`Date` value math over a
    /// locally constructed calendar and reads no main-actor state, so the
    /// nonisolated `UsageFilteredSettingsFilterState` computed properties can
    /// call it without entering the main actor. `UsageFilteredSettingsView`
    /// itself is main-actor isolated only because it conforms to `View`.
    nonisolated static func localStartOfDay(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    static func providerOptions(
        from projections: [UsageProviderModelProjection]
    ) -> [UsageFilteredSettingsProviderOption] {
        var seen = Set<String>()
        return projections.compactMap { projection in
            guard let recordID = projection.providerRecordID, seen.insert(recordID).inserted else {
                return nil
            }
            return UsageFilteredSettingsProviderOption(
                recordID: recordID,
                displayName: projection.providerDisplayName,
                status: projection.status
            )
        }
        .sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.recordID < $1.recordID
        }
    }

    @MainActor
    static func queryResult(
        from usageStore: UsageStore,
        filters: UsageFilteredSettingsFilterState
    ) -> UsageQueryResult? {
        guard !filters.hasInvalidDateRange else { return nil }
        return usageStore.query(
            providerRecordID: filters.providerRecordID,
            dateInterval: filters.normalizedDateInterval,
            models: filters.models
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                currentSessionSummary
                Divider()
                Text("全局用量与日期筛选").font(typography?.headline ?? .headline)
                filterControls
                resultContent
                attributionControls
                pricingControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("settings.usage.filtered")
        .onChange(of: currentFilters) { _, _ in invalidateRefresh() }
        .onDisappear { invalidateRefresh() }
        .confirmationDialog(
            "清空全部用量统计？",
            isPresented: $pendingClear,
            titleVisibility: .visible
        ) {
            Button("清空用量统计", role: .destructive) {
                usageStore.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会清空全部用量历史记录，无法恢复。")
        }
    }

    private var currentFilters: UsageFilteredSettingsFilterState {
        UsageFilteredSettingsFilterState(
            providerRecordID: selectedProviderID,
            startDate: dateRangeEnabled ? startDate : nil,
            endDate: dateRangeEnabled ? endDate : nil,
            models: selectedModels
        )
    }

    private var providerOptions: [UsageFilteredSettingsProviderOption] {
        Self.providerOptions(from: usageStore.providerUsageProjection)
    }

    private var modelOptions: [String] {
        usageStore.sortedModelUsage.map(\.model).sorted()
    }

    @ViewBuilder
    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用量筛选")
                    .font((typography?.headline ?? .headline).weight(.semibold))
                Spacer()
                Button("刷新") { refresh() }
                    .disabled(isRefreshing)
                    .accessibilityIdentifier("settings.usage.filtered.refresh")
                Button("重置") { resetFilters() }
                    .disabled(!currentFilters.isFiltering && !dateRangeEnabled)
                    .accessibilityIdentifier("settings.usage.filtered.reset")
            }

            HStack(spacing: 12) {
                Menu {
                    Button("全部供应商") { selectedProviderID = nil }
                    if !providerOptions.isEmpty { Divider() }
                    ForEach(providerOptions) { option in
                        Button {
                            selectedProviderID = option.recordID
                        } label: {
                            if selectedProviderID == option.recordID {
                                Label { Text(option.label) } icon: { MinisIconView(.check, size: 14) }
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Text(providerFilterLabel)
                }
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    MinisIconView(.database, size: 14)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("供应商筛选")
                .accessibilityValue(providerFilterLabel)
                .accessibilityIdentifier("settings.usage.filtered.provider")

                Menu {
                    Button("全部模型") { selectedModels.removeAll() }
                    if !modelOptions.isEmpty { Divider() }
                    ForEach(modelOptions, id: \.self) { model in
                        Button {
                            if selectedModels.contains(model) {
                                selectedModels.remove(model)
                            } else {
                                selectedModels.insert(model)
                            }
                        } label: {
                            if selectedModels.contains(model) {
                                Label { Text(model) } icon: { MinisIconView(.check, size: 14) }
                            } else {
                                Text(model)
                            }
                        }
                    }
                } label: {
                    Text(modelFilterLabel)
                }
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    MinisIconView(.filter, size: 14)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("模型筛选")
                .accessibilityValue(modelFilterLabel)
                .accessibilityIdentifier("settings.usage.filtered.model")
            }

            Toggle("启用日期范围", isOn: $dateRangeEnabled)
                .accessibilityIdentifier("settings.usage.filtered.date.enabled")
            if dateRangeEnabled {
                HStack(spacing: 12) {
                    DatePicker(
                        "开始（含，本地时间）",
                        selection: $startDate,
                        displayedComponents: .date
                    )
                    DatePicker(
                        "结束（不含，本地时间）",
                        selection: $endDate,
                        displayedComponents: .date
                    )
                }
                .font(typography?.caption ?? .caption)
                .environment(\.timeZone, TimeZone.autoupdatingCurrent)
                .accessibilityIdentifier("settings.usage.filtered.date.range")
                if currentFilters.hasInvalidDateRange {
                    Text("日期范围无效：结束日必须晚于开始日。")
                        .modifier(ReadableStatusForeground(status: .danger))
                        .font(typography?.caption ?? .caption)
                        .accessibilityIdentifier("settings.usage.filtered.date.error")
                } else {
                    Text("按本地时区日界计算，范围为 [开始，结束)。")
                        .foregroundStyle(.secondary)
                        .font(typography?.caption ?? .caption)
                }
            }

            if providerOptions.contains(where: { $0.status == .deleted }) {
                Text("已删除供应商的历史用量仍独立保留。未绑定的旧记录会显示为“未绑定”，不会归入同名供应商。")
                    .foregroundStyle(.secondary)
                    .font(typography?.caption ?? .caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var providerFilterLabel: String {
        guard let selectedProviderID,
              let option = providerOptions.first(where: { $0.recordID == selectedProviderID }) else {
            return "全部供应商"
        }
        return option.label
    }

    private var modelFilterLabel: String {
        selectedModels.isEmpty ? "全部模型" : "模型（\(selectedModels.count)）"
    }

    @ViewBuilder
    private var resultContent: some View {
        if isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在刷新用量…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings.usage.filtered.refreshing")
        }

        switch usageStore.usageQueryState {
        case .loading:
            ProgressView("正在读取用量…")
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.usage.filtered.loading")
        case .error:
            VStack(alignment: .leading, spacing: 8) {
                Text("暂时无法读取用量数据。")
                Text("请稍后刷新；记录和历史不会因读取失败而被清空。")
                    .foregroundStyle(.secondary)
                Button("重试") { refresh() }
            }
            .accessibilityIdentifier("settings.usage.filtered.error")
        case .empty:
            emptyState(text: "暂无用量数据。")
        case .ready:
            if currentFilters.hasInvalidDateRange {
                emptyState(text: "请先修正日期范围。")
            } else if let interval = currentFilters.normalizedDateInterval {
                filteredResult(dateInterval: interval)
            } else {
                filteredResult(dateInterval: nil)
            }
        }
    }

    @ViewBuilder
    private func filteredResult(dateInterval: DateInterval?) -> some View {
        let result = usageStore.query(
            providerRecordID: selectedProviderID,
            dateInterval: dateInterval,
            models: selectedModels
        )
        if result.availability == .unknown {
            emptyState(text: "当前筛选没有匹配的调用记录。")
        } else {
            let records = result.records
            VStack(alignment: .leading, spacing: 12) {
                summarySection(records: records)
                modelSummarySection(records: records)
                Divider()
                if records.isEmpty {
                    Text("暂无调用记录。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("调用明细")
                        .font((typography?.headline ?? .headline).weight(.semibold))
                    ForEach(records.prefix(50), id: \.id) { record in
                        recordRow(record)
                    }
                }
                Button("清空全部用量统计", role: .destructive) {
                    pendingClear = true
                }
                .disabled(usageStore.totalCalls == 0)
                .accessibilityIdentifier("settings.usage.filtered.clear")
            }
        }
    }

    /// This is deliberately independent of the global Provider/date controls.
    static func sessionRecords(from store: UsageStore, sessionID: String?) -> [UsageRecord] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        return store.callHistory.filter { $0.sessionID == sessionID }
    }

    static func childTokenShare(records: [UsageRecord]) -> Double? {
        let total = records.reduce(0) { saturatingAdd($0, $1.totalTokensIncludingCache) }
        guard total > 0 else { return nil }
        let child = records.filter { $0.attribution?.kind == .subagent }
            .reduce(0) { saturatingAdd($0, $1.totalTokensIncludingCache) }
        return Double(child) / Double(total)
    }

    static func mcpServerShare(serverID: String, records: [UsageMCPCallRecord]) -> Double? {
        guard !records.isEmpty else { return nil }
        return Double(records.filter { $0.serverID == serverID }.count) / Double(records.count)
    }

    private var currentSessionSummary: some View {
        let sessionID = chatStore?.activeSessionID
        let records = Self.sessionRecords(from: usageStore, sessionID: sessionID?.uuidString)
        let createdAt = chatStore?.sessions.first(where: { $0.id == sessionID })?.createdAt
        let child = records.filter { $0.attribution?.kind == .subagent }
        let tokens = records.reduce(0) { Self.saturatingAdd($0, $1.totalTokensIncludingCache) }
        let childTokens = child.reduce(0) { Self.saturatingAdd($0, $1.totalTokensIncludingCache) }
        let messages = sessionID.flatMap { chatStore?.messages(forSession: $0) } ?? []
        let turns = messages.filter { $0.role == .assistant && $0.turnTiming?.representsModelTurn != false }
        let durations = turns.compactMap { $0.turnTiming?.durationMilliseconds }
        let milliseconds = durations.reduce(0, Self.saturatingAdd)
        let unknownDurations = turns.count - durations.count
        let share = Self.childTokenShare(records: records)
        let unassociated = usageStore.callHistory.filter { $0.sessionID == nil }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("当前会话").font(typography?.headline ?? .headline)
            if sessionID == nil {
                Text("未选择会话。")
            } else {
                LabeledContent("会话 token（含子智能体）", value: records.isEmpty ? "未报告" : ChatStore.formatTokenCount(tokens))
                LabeledContent("估算费用", value: UsageModelPricing.display(records: records, prices: usageStore.modelPricing))
                LabeledContent("子智能体 token", value: ChatStore.formatTokenCount(childTokens))
                LabeledContent("子智能体 / 会话 token", value: share.map { String(format: "%.1f%%", $0 * 100) } ?? "无法计算（未报告分母）")
                if let createdAt, createdAt.timeIntervalSince1970.isFinite, createdAt <= Date() {
                    LabeledContent("会话历时（含等待）") { Text(createdAt, style: .timer) }
                } else {
                    LabeledContent("会话历时（含等待）", value: "未报告")
                }
                LabeledContent("转录中已完成回合耗时", value: durations.isEmpty ? "未报告" : String(format: "%.2f 秒", Double(milliseconds) / 1000))
                if unknownDurations > 0 { Text("另有 \(unknownDurations) 个回合未报告终止耗时。") }
                if records.isEmpty { Text("当前会话暂无已关联的用量记录；不代表未发生调用。") }
            }
            if unassociated > 0 { Text("\(unassociated) 条旧记录或未验证来源未关联会话，仍保留在全局用量中。") }
            Text("会话汇总不受下方全局筛选影响；子智能体只计可信父会话定位的记录。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("settings.usage.current-session")
    }

    private var attributionControls: some View {
        let records = Self.queryResult(from: usageStore, filters: currentFilters)?.records ?? []
        let grouped = Dictionary(grouping: records) { $0.attribution?.label ?? "未归因（旧记录或未报告）" }
        let interval = currentFilters.normalizedDateInterval
        let mcp = currentFilters.hasInvalidDateRange ? [] : usageStore.mcpCalls.filter { record in
            guard let interval else { return true }
            return record.timestamp >= interval.start && record.timestamp < interval.end
        }
        let byServer = Dictionary(grouping: mcp, by: \.serverID)
        return VStack(alignment: .leading, spacing: 8) {
            Text("来源归因").font(.headline)
            ForEach(grouped.keys.sorted(), id: \.self) { source in
                let rows = grouped[source] ?? []
                let total = rows.reduce(0) { Self.saturatingAdd($0, $1.totalTokensIncludingCache) }
                LabeledContent(source, value: "\(rows.count) 次 · \(ChatStore.formatTokenCount(total)) token")
            }
            if grouped.isEmpty { Text("暂无已报告的模型用量归因。").foregroundStyle(.secondary) }
            Text("只统计实际报告的用量；旧记录、CLI 或缺失遥测不猜归属，也不按 0 计。子智能体服务路由尚未报告时不猜价格。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("MCP 近期调用尝试（最多 \(UsageStore.maxRecentCalls) 条，按日期筛选）").font(.subheadline)
            Text("服务器占比按日期筛选后已保留的 MCP 记录次数计算，不受模型 Provider 筛选影响；不估算 MCP token 或费用。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            ForEach(byServer.keys.sorted(), id: \.self) { server in
                let rows = byServer[server] ?? []
                let share = Self.mcpServerShare(serverID: server, records: mcp)
                LabeledContent("服务器调用次数占比", value: share.map { String(format: "%.1f%%", $0 * 100) } ?? "无法计算")
                LabeledContent(server, value: "\(rows.count) 次 · 成功 \(rows.filter(\.succeeded).count) 次")
            }
            Text("MCP 仅保留近期明细，模型调用明细保留全历史；MCP 未单独计量模型 token 或费用，这些近期次数不叠加成模型调用或虚构账单，不受模型/供应商筛选；权限拒绝且未实际调用 MCP 的请求不计入。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pricingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("估算单价").font(.headline)
            Text("仅按你填写的四类 token 单价估算，不代表实际账单；逐笔累计已配置且字段完整的估价，按币种分别显示；不能估算的调用单列次数。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(usageStore.modelUsage.keys.sorted(), id: \.self) { key in
                if let row = usageStore.modelUsage[key], UsageModelPricing.canPrice(provider: row.provider, model: row.model) {
                    UsageModelPricingEditor(usageStore: usageStore, key: key,
                        title: (row.providerDisplaySnapshot ?? row.provider) + " · " + row.model)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func summarySection(records: [UsageRecord]) -> some View {
        let input = records.reduce(0) { Self.saturatingAdd($0, $1.totalInputTokens) }
        let output = records.reduce(0) { Self.saturatingAdd($0, $1.outputTokens) }
        let cacheRead = records.reduce(0) { Self.saturatingAdd($0, $1.cacheReadTokens ?? 0) }
        let cacheCreation = records.reduce(0) { Self.saturatingAdd($0, $1.cacheCreationTokens ?? 0) }
        let total = Self.saturatingAdd(input, output)

        return VStack(alignment: .leading, spacing: 8) {
            Text(currentFilters.isFiltering ? "筛选结果" : "总消耗")
                .font((typography?.headline ?? .headline).weight(.semibold))
            HStack {
                LabeledContent("调用", value: "\(records.count) 次")
                Spacer()
                LabeledContent("合计 token", value: ChatStore.formatTokenCount(total))
            }
            HStack {
                LabeledContent("输入", value: ChatStore.formatTokenCount(input))
                Spacer()
                LabeledContent("输出", value: ChatStore.formatTokenCount(output))
            }
            LabeledContent("估算费用", value: UsageModelPricing.display(records: records, prices: usageStore.modelPricing))
            LabeledContent("缓存命中率", value: UsageCacheHitProjection(
                records: records, expectedCallCount: currentFilters.isFiltering ? nil : usageStore.totalCalls
            ).text)
            HStack {
                LabeledContent("缓存读取", value: ChatStore.formatTokenCount(cacheRead))
                Spacer()
                LabeledContent("缓存写入", value: ChatStore.formatTokenCount(cacheCreation))
            }
        }
        .accessibilityIdentifier("settings.usage.filtered.summary")
    }

    private struct ModelGroupKey: Hashable {
        let providerID: String?
        let legacyProvider: String?
        let model: String
    }

    @ViewBuilder
    private func modelSummarySection(records: [UsageRecord]) -> some View {
        let grouped = Dictionary(grouping: records) { record in
            ModelGroupKey(providerID: record.providerRecordID,
                          legacyProvider: record.providerRecordID == nil ? record.provider : nil,
                          model: record.model)
        }
        let keys = grouped.keys.sorted {
            ($0.model, $0.providerID ?? "", $0.legacyProvider ?? "")
                < ($1.model, $1.providerID ?? "", $1.legacyProvider ?? "")
        }
        if !keys.isEmpty {
            Text("分模型")
                .font((typography?.headline ?? .headline).weight(.semibold))
            ForEach(keys, id: \.self) { key in
                let values = grouped[key] ?? []
                let input = values.reduce(0) { Self.saturatingAdd($0, $1.totalInputTokens) }
                let output = values.reduce(0) { Self.saturatingAdd($0, $1.outputTokens) }
                let read = values.reduce(0) { Self.saturatingAdd($0, $1.cacheReadTokens ?? 0) }
                let creation = values.reduce(0) { Self.saturatingAdd($0, $1.cacheCreationTokens ?? 0) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(values.first.map { providerText(for: $0) } ?? "未绑定供应商") · \(ModelMenuButton.modelShortName(key.model))")
                        Spacer()
                        Text("\(values.count) 次调用")
                    }
                    Text("输入 \(ChatStore.formatTokenCount(input)) · 输出 \(ChatStore.formatTokenCount(output))")
                    Text("缓存读 \(ChatStore.formatTokenCount(read)) · 缓存写 \(ChatStore.formatTokenCount(creation))")
                }
                .font(typography?.caption ?? .caption)
                .accessibilityIdentifier("settings.usage.filtered.model-summary")
            }
        }
    }

    private func recordRow(_ record: UsageRecord) -> some View {
        let providerText = providerText(for: record)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(providerText) · \(ModelMenuButton.modelShortName(record.model))")
                    .font((typography?.body ?? .body).weight(.medium))
                Spacer()
                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            Text("↑\(record.totalInputTokens)\(record.cacheReadTokens.map { "（缓存读 \($0)）" } ?? "") ↓\(record.outputTokens) · 共 \(record.totalTokensIncludingCache) token")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("settings.usage.filtered.record.\(record.id.uuidString)")
    }

    private func providerText(for record: UsageRecord) -> String {
        guard let recordID = record.providerRecordID,
              let projection = usageStore.providerUsageProjection.first(where: { $0.providerRecordID == recordID }) else {
            let legacy = record.providerDisplaySnapshot ?? record.provider
            return "未绑定供应商（原记录：\(legacy)）"
        }
        let historical = record.providerDisplaySnapshot ?? record.provider
        let renamed = projection.providerDisplayName == historical
            ? projection.providerDisplayName
            : "\(projection.providerDisplayName)（历史：\(historical)）"
        return projection.status == .deleted ? "\(renamed)（已删除）" : renamed
    }

    private func emptyState(text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .accessibilityIdentifier("settings.usage.filtered.empty")
    }

    private func resetFilters() {
        selectedProviderID = nil
        selectedModels.removeAll()
        dateRangeEnabled = false
    }

    private func invalidateRefresh() {
        refreshGate.invalidate()
        isRefreshing = false
    }

    private func refresh() {
        let filters = currentFilters
        let request = refreshGate.begin(for: filters)
        isRefreshing = true
        Task { @MainActor in
            _ = await usageStore.waitForPersistence()
            guard !Task.isCancelled,
                  refreshGate.accepts(request, currentFilters: currentFilters) else {
                return
            }
            isRefreshing = false
        }
    }
}
