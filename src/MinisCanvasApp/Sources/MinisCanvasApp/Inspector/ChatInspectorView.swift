import SwiftUI
import MinisCore

/// Bounded source metadata projected from one accepted ContextManifest entry.
/// It deliberately contains no source content and does not discover files.
struct ChatInspectorSourceItem: Sendable, Equatable, Hashable, Identifiable {
    let identifier: String
    let provenance: String
    let tokenCost: Int
    let required: Bool
    let level: ContextItem.Level
    let scope: String

    var id: String {
        "\(identifier)|\(provenance)|\(tokenCost)|\(required)"
    }

    init(entry: ContextManifest.Entry) {
        identifier = entry.identifier
        provenance = entry.provenance
        tokenCost = entry.tokenCost
        required = entry.required
        level = entry.level
        scope = entry.scope
    }
}

/// A bounded construction summary, never prompt or dialog content. The values
/// come from the same immutable manifest/receipt, not current Settings or model.
struct ChatInspectorContextSummary: Sendable, Equatable {
    let runID: String
    let turnID: Int
    let snapshot: ConversationContextSnapshotV1
    let entries: [ContextManifest.Entry]
    let receipt: ContextManifestReceipt
}

/// Immutable chat-only view model assembled by the production composition root.
/// After capture it holds only value projections and no mutable store reference.
enum ChatInspectorListPresentation {
    static func summary(count: Int, limit: Int, unit: String) -> String {
        count == limit ? "最近 \(limit) 项（上限）" : "\(count) \(unit)"
    }

    static func pathParts(_ path: String) -> (fileName: String, parent: String) {
        let parts = path.split(separator: "/").map(String.init)
        let fileName = parts.last ?? path
        let parents = Array(parts.dropLast())
        let parent = path.hasPrefix("/") && !parents.isEmpty
            ? "…/" + parents.suffix(2).joined(separator: "/")
            : parents.joined(separator: "/")
        return (fileName, parent)
    }
}

struct ChatInspectorSnapshot: Sendable, Equatable {
    static let maxActivityRows = 40
    static let maxToolRows = 40
    static let maxFileChangeRows = 40

    let sessionID: String?
    let providerLabel: String
    let modelLabel: String
    let engineLabel: String
    let messageCount: Int
    let activeSessionCount: Int
    let archivedSessionCount: Int
    let tokenUsageLabel: String
    let budgetIsWarning: Bool
    let budgetIsOverLimit: Bool
    let currentTaskID: String?
    let taskSnapshots: [AgentTaskSnapshot]
    let receiptRows: [TaskCenterReceiptRow]
    let sourceItems: [ChatInspectorSourceItem]
    let contextSummary: ChatInspectorContextSummary?
    /// D-OUTPUT-01：canonical 工具生命周期事件本体；呈现由 ToolEventCard 的
    /// 可折叠摘要卡负责（展开面经 ConversationEventProjection.display 脱敏）。
    let toolEvents: [MinisCore.ConversationEvent]
    let omittedToolEventCount: Int
    struct ActivityRow: Equatable, Sendable {
        let display: ConversationEventDisplayProjection
        let occurredAt: Date
        let actionLabel: String?
    }
    let activityEvents: [ActivityRow]
    let omittedActivityEventCount: Int
    /// D-OUTPUT-02：智能体 file_write/file_edit 成功事实（可展开变更列表 +
    /// 逐文件有界脱敏 Diff），由 RecordingToolExecutor 缝产出，纯值消费。
    let fileChanges: [AgentFileChangeRecord]
    let turnFileChanges: [TurnFileChange]
    /// Exact successful write attempts projected from the production ledger
    /// and canonical terminal facts; old or failed calls are absent.
    let fileArtifacts: [ProducedFileArtifactEvidence]
    let artifactPersistenceUnavailable: Bool
    let persistence: SessionCompactProjection

    init(
        sessionID: String?,
        providerLabel: String,
        modelLabel: String,
        engineLabel: String,
        messageCount: Int,
        activeSessionCount: Int,
        archivedSessionCount: Int,
        tokenUsageLabel: String,
        budgetIsWarning: Bool,
        budgetIsOverLimit: Bool,
        currentTaskID: String?,
        taskSnapshots: [AgentTaskSnapshot],
        receiptRows: [TaskCenterReceiptRow],
        sourceItems: [ChatInspectorSourceItem],
        contextSummary: ChatInspectorContextSummary? = nil,
        toolEvents: [MinisCore.ConversationEvent],
        omittedToolEventCount: Int,
        activityEvents: [ActivityRow],
        omittedActivityEventCount: Int,
        fileChanges: [AgentFileChangeRecord] = [],
        turnFileChanges: [TurnFileChange] = [],
        fileArtifacts: [ProducedFileArtifactEvidence] = [],
        artifactPersistenceUnavailable: Bool = false,
        persistence: SessionCompactProjection
    ) {
        self.sessionID = sessionID
        self.providerLabel = providerLabel
        self.modelLabel = modelLabel
        self.engineLabel = engineLabel
        self.messageCount = max(0, messageCount)
        self.activeSessionCount = max(0, activeSessionCount)
        self.archivedSessionCount = max(0, archivedSessionCount)
        self.tokenUsageLabel = tokenUsageLabel
        self.budgetIsWarning = budgetIsWarning
        self.budgetIsOverLimit = budgetIsOverLimit
        self.currentTaskID = currentTaskID
        self.taskSnapshots = taskSnapshots
        self.receiptRows = receiptRows
        self.sourceItems = sourceItems
        self.contextSummary = contextSummary
        self.toolEvents = toolEvents
        self.omittedToolEventCount = max(0, omittedToolEventCount)
        self.activityEvents = activityEvents
        self.omittedActivityEventCount = max(0, omittedActivityEventCount)
        self.fileChanges = fileChanges
        self.turnFileChanges = turnFileChanges
        self.fileArtifacts = fileArtifacts
        self.artifactPersistenceUnavailable = artifactPersistenceUnavailable
        self.persistence = persistence
    }

    static let empty = ChatInspectorSnapshot(
        sessionID: nil,
        providerLabel: "未标识",
        modelLabel: "默认",
        engineLabel: "不可用",
        messageCount: 0,
        activeSessionCount: 0,
        archivedSessionCount: 0,
        tokenUsageLabel: "已用 0 / 0 tokens",
        budgetIsWarning: false,
        budgetIsOverLimit: false,
        currentTaskID: nil,
        taskSnapshots: [],
        receiptRows: [],
        sourceItems: [],
        toolEvents: [],
        omittedToolEventCount: 0,
        activityEvents: [],
        omittedActivityEventCount: 0,
        persistence: SessionCompactProjection(sessionID: nil, store: nil)
    )
}

/// A7-A right-side chat inspector. It is a pure value consumer and never owns
/// chat, bridge, canvas, task, or persistence authority.
struct ChatInspectorView: View {
    let snapshot: ChatInspectorSnapshot
    /// The existing compaction entry remains the sole mutation owner.
    let onCompact: (() -> Void)?
    /// The composition root routes this ledger-bound identity through the
    /// existing Task Center navigation stack. The inspector never changes
    /// the active chat session or reads a child transcript itself.
    let onOpenChildSession: (TaskCenterChildSessionNavigation) -> Void
    let onLoadOlderToolEvents: () -> Void
    let contextOccupancy: ChatContextOccupancy?
    let activeSessionID: String?
    let onReadCompactionSummary: (SessionCompactProjection.CheckpointIdentity) -> String?
    let onUndoCompaction: ((SessionCompactProjection.CheckpointIdentity) -> Void)?
    let budgetResetTarget: SessionBudgetResetTarget?
    let budgetResetBlockedReason: String?
    let onConfirmBudgetReset: ((SessionBudgetResetTarget) -> Void)?
    @State private var pendingBudgetReset: SessionBudgetResetTarget?

    init(
        snapshot: ChatInspectorSnapshot,
        onCompact: (() -> Void)? = nil,
        onOpenChildSession: @escaping (TaskCenterChildSessionNavigation) -> Void,
        onLoadOlderToolEvents: @escaping () -> Void = {},
        contextOccupancy: ChatContextOccupancy? = nil,
        activeSessionID: String? = nil,
        onReadCompactionSummary: @escaping (SessionCompactProjection.CheckpointIdentity) -> String? = { _ in nil },
        onUndoCompaction: ((SessionCompactProjection.CheckpointIdentity) -> Void)? = nil,
        budgetResetTarget: SessionBudgetResetTarget? = nil,
        budgetResetBlockedReason: String? = nil,
        onConfirmBudgetReset: ((SessionBudgetResetTarget) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onCompact = onCompact
        self.onOpenChildSession = onOpenChildSession
        self.onLoadOlderToolEvents = onLoadOlderToolEvents
        self.contextOccupancy = contextOccupancy
        self.activeSessionID = activeSessionID
        self.onReadCompactionSummary = onReadCompactionSummary
        self.onUndoCompaction = onUndoCompaction
        self.budgetResetTarget = budgetResetTarget
        self.budgetResetBlockedReason = budgetResetBlockedReason
        self.onConfirmBudgetReset = onConfirmBudgetReset
    }

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                overviewSection
                InspectorSection(
                    identifier: "chat-inspector.current-task",
                    title: "当前任务",
                    icon: "checklist",
                    catalogIcon: .task,
                    summary: snapshot.currentTaskID == nil ? "暂无" : "已绑定"
                ) {
                    TaskSummaryView(
                        currentTaskID: snapshot.currentTaskID,
                        viewerSessionID: snapshot.sessionID,
                        taskSnapshots: snapshot.taskSnapshots,
                        receiptRows: snapshot.receiptRows,
                        onOpenChildSession: onOpenChildSession
                    )
                }
                sourceSection
                toolSection
                fileChangesSection
                activitySection
                persistenceSection
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-inspector")
        .sessionBudgetResetConfirmation($pendingBudgetReset) { target in
            onConfirmBudgetReset?(target)
        }
    }

    private var overviewSection: some View {
        InspectorSection(
            identifier: "chat-inspector.overview",
            title: "会话",
            icon: "bubble.left.and.bubble.right",
            catalogIcon: .messages,
            summary: snapshot.sessionID == nil ? "未选择" : "活动"
        ) {
            InspectorValueRow("服务商", snapshot.providerLabel)
            InspectorValueRow("模型", snapshot.modelLabel)
            InspectorValueRow("智能体", snapshot.engineLabel)
            InspectorValueRow("消息", "\(snapshot.messageCount)")
            InspectorValueRow("会话", "\(snapshot.activeSessionCount) 活动 · \(snapshot.archivedSessionCount) 归档")
            if snapshot.budgetIsOverLimit {
                Text("预算已超限")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(theme?.statusDangerText ?? .red)
                if let target = budgetResetTarget, let activeSessionID,
                   snapshot.sessionID == activeSessionID, target.sessionID.uuidString == activeSessionID,
                   onConfirmBudgetReset != nil {
                    Button("重置本会话预算") { pendingBudgetReset = target }
                        .accessibilityIdentifier("chat-inspector.budget-reset")
                        .disabled(budgetResetBlockedReason != nil)
                    if let reason = budgetResetBlockedReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if snapshot.budgetIsWarning {
                Text("用量接近上限")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(theme?.statusWarningText ?? .orange)
            }
        }
    }

    private var sourceSection: some View {
        InspectorSection(
            identifier: "chat-inspector.sources",
            title: "来源文件",
            icon: "doc.text",
            catalogIcon: .document,
            summary: "\(snapshot.sourceItems.count) 项"
        ) {
            InspectorValueRow("最近回报占用", contextOccupancy?.display ?? "—")
            if let context = snapshot.contextSummary {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前回合来源摘要")
                    InspectorValueRow("回合", "\(context.turnID)")
                    InspectorValueRow("来源已选", "\(context.receipt.usedBudget) tokens（估算）")
                    InspectorValueRow("条目", "\(context.entries.count) 已选 · \(context.receipt.droppedEntryIDs.count) 未选")
                    DisclosureGroup("技术详情") {
                    InspectorValueRow("Provider / 模型", "\(context.snapshot.providerID) / \(context.snapshot.modelID)")
                    InspectorValueRow("配置指纹", context.snapshot.configurationFingerprint)
                    }
                }
                .accessibilityIdentifier("chat-inspector.context-summary")
            } else {
                Text("还没有本轮上下文记录，发送消息后可在这里查看。")
                    .accessibilityIdentifier("chat-inspector.context-summary")
            }
            if snapshot.sourceItems.isEmpty {
                InspectorEmptyState(text: "当前回合没有可显示的结构化来源")
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.sourceItems.enumerated()), id: \.offset) { item in
                        let source = item.element
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.identifier)
                                .font(typography?.contextBody ?? .system(size: 10))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(source.provenance)
                                Text("\(source.tokenCost) tokens")
                                DisclosureGroup("技术详情") {
                                    Text("\(source.level.rawValue) · \(source.scope)")
                                }
                                if source.required { Text("必需") }
                            }
                            .font(typography?.caption ?? .system(size: 10))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var toolSection: some View {
        InspectorSection(
            identifier: "chat-inspector.tools",
            title: "工具",
            icon: "wrench.and.screwdriver",
            summary: ChatInspectorListPresentation.summary(count: snapshot.toolEvents.count, limit: ChatInspectorSnapshot.maxToolRows, unit: "条")
        ) {
            if snapshot.toolEvents.isEmpty {
                InspectorEmptyState(text: "暂无工具生命周期事实")
            } else {
                // D-OUTPUT-01：每条工具/子智能体生命周期事实呈现为可折叠摘要卡
                // （ToolEventCard：标题行=类型+终态；展开=脱敏摘要+耗时/Provider/
                // Model/错误类别等详情）。
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.toolEvents) { event in
                        ToolEventCard(event: event, concurrentEvents: snapshot.toolEvents)
                    }
                }
            }
            if snapshot.omittedToolEventCount > 0 {
                Button("加载更早的工具事实（尚有 \(snapshot.omittedToolEventCount) 条）") {
                    onLoadOlderToolEvents()
                }
                .buttonStyle(.plain)
                .font(typography?.caption ?? .system(size: 10))
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .accessibilityIdentifier("chat-inspector.tools.load-older")
                .accessibilityHint("按需加载较早的工具事实摘要")
            }
        }
    }

    private var fileChangesSection: some View {
        InspectorSection(
            identifier: "chat-inspector.file-changes",
            title: "变更文件",
            icon: "doc.on.doc",
            summary: snapshot.artifactPersistenceUnavailable ? "引用记录不可用" : ChatInspectorListPresentation.summary(count: snapshot.fileChanges.count, limit: ChatInspectorSnapshot.maxFileChangeRows, unit: "项")
        ) {
            if snapshot.artifactPersistenceUnavailable {
                InspectorEmptyState(text: "产物引用记录读取或保存失败；文件可能已写入，引用暂不可用。原记录未被清空。")
            }
            if !snapshot.fileChanges.isEmpty {
                // D-OUTPUT-02：可展开变更列表（每文件一行），展开查看逐文件
                // 有界脱敏 Diff。列表本身是纯值投影，不做任何目录扫描。
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.fileChanges.enumerated()), id: \.element.id) { _, change in
                        FileChangeRow(change: change)
                    }
                }
            }
            if !snapshot.fileArtifacts.isEmpty {
                Text("已证实产物 · \(snapshot.fileArtifacts.count) 项")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.fileArtifacts.enumerated()), id: \.offset) { _, artifact in
                        FileArtifactEvidenceRow(artifact: artifact)
                    }
                }
            }
        }
    }

    private var activitySection: some View {
        InspectorSection(
            identifier: "chat-inspector.activity",
            title: "活动日志",
            icon: "clock.arrow.circlepath",
            summary: ChatInspectorListPresentation.summary(count: snapshot.activityEvents.count, limit: ChatInspectorSnapshot.maxActivityRows, unit: "条")
        ) {
            if snapshot.activityEvents.isEmpty {
                InspectorEmptyState(text: "暂无活动日志")
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.activityEvents.enumerated()), id: \.offset) { item in
                        let event = item.element.display
                        HStack(spacing: 6) {
                            Text(item.element.actionLabel ?? event.kindLabel)
                                .font((typography?.caption ?? .system(size: 10)).weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(event.kind == .tool ? event.summary.replacingOccurrences(
                                of: "仅显示统计，结果正文未在此展示；", with: "仅显示统计 · "
                            ) : event.summary)
                                .font(typography?.contextBody ?? .system(size: 10))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Text(event.statusLabel)
                                .font(typography?.caption ?? .system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(item.element.occurredAt, style: .time)
                                .font(typography?.caption ?? .system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .help(event.summary)
                    }
                }
            }
            if snapshot.omittedActivityEventCount > 0 {
                Text("另有 \(snapshot.omittedActivityEventCount) 条较早活动")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var persistenceSection: some View {
        InspectorSection(
            identifier: "chat-inspector.persistence",
            title: "压缩与恢复",
            icon: "arrow.clockwise.circle",
            summary: snapshot.persistence.stateLabel
        ) {
            if let checkpointID = snapshot.persistence.checkpointID {
                InspectorValueRow("Checkpoint", String(checkpointID.prefix(12)))
            }
            if let sourceRevision = snapshot.persistence.sourceRevision,
               let resultRevision = snapshot.persistence.resultRevision {
                InspectorValueRow("Revision", "\(sourceRevision) → \(resultRevision)")
            }
            if let identity = snapshot.persistence.summaryIdentity,
               identity.sessionID == activeSessionID {
                CompactionSummaryDisclosure { onReadCompactionSummary(identity) }
                    .id(identity)
            }
            if let identity = snapshot.persistence.undoIdentity,
               identity.sessionID == activeSessionID, let onUndoCompaction {
                Button("撤销压缩") { onUndoCompaction(identity) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("让后续对话使用原始上下文，保留聊天记录、附件和文件。")
                    .accessibilityIdentifier("chat-inspector.compaction-undo")
            }
            if let parentSessionID = snapshot.persistence.parentSessionID {
                InspectorValueRow("父会话", String(parentSessionID.prefix(12)))
            }
            if let forkedThroughRevision = snapshot.persistence.forkedThroughRevision {
                InspectorValueRow("分叉边界", "rev \(forkedThroughRevision)")
            }
            if let onCompact {
                Divider()
                Button(action: onCompact) {
                    Label { Text("压缩上下文（保留最近 3 条）") } icon: {
                        MinisIconView(.activity, size: 14)
                    }
                    .font((typography?.caption ?? .system(size: 10)).weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(
                    snapshot.budgetIsOverLimit
                        ? (theme?.aj38.danger.swiftUIColor ?? .red)
                        : (snapshot.budgetIsWarning
                            ? (theme?.statusWarning ?? .orange)
                            : (theme?.aj38.accent.swiftUIColor ?? Color.accentColor))
                )
                .help("把早前对话折叠成摘要，保留最近 3 条消息（MinisCore Compactor）")
            }
        }
    }
}

private struct CompactionSummaryDisclosure: View {
    let readSummary: () -> String?
    @Environment(\.typographyTokens) private var typography
    @State private var summary: String?

    var body: some View {
        DisclosureGroup("查看摘要", isExpanded: Binding(
            get: { summary != nil },
            set: { expanded in
                summary = expanded ? (readSummary() ?? "摘要不可用") : nil
            }
        )) {
            if let summary {
                Text(verbatim: summary)
                    .font(typography?.contextBody ?? .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat-inspector.compaction-summary.text")
            }
        }
        .accessibilityIdentifier("chat-inspector.compaction-summary")
        .onDisappear { summary = nil }
    }
}

struct FileArtifactEvidenceRow: View {
    let artifact: ProducedFileArtifactEvidence
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                Text("生成时 SHA-256（写入字节）：\(artifact.outputSHA256)")
                Text("工具：\(artifact.producerToolName)")
                Text("Attempt：\(artifact.producerAttemptID)")
                Text("Receipt：\(artifact.producerReceiptID)")
                Text("Diff：\(artifact.diffID)")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        } label: {
            HStack(spacing: 6) {
                Text(artifact.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("已验证产物引用 · 展开查看验证信息")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
        }
    }
}

/// One expandable changed-file row with its bounded, redacted per-file diff.
struct FileChangeRow: View {
    let change: AgentFileChangeRecord

    @State private var isExpanded = false
    @State private var actionFeedback: String?
    @Environment(\.agentFileOutputAction) private var onFileOutputAction
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                Text(change.diffText.isEmpty ? "（无逐文件 Diff 可显示）" : change.diffText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                if let onFileOutputAction {
                    Text("操作前将重新核验文件与授权工作区。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("右侧预览") {
                            let result = onFileOutputAction(change, .preview)
                            actionFeedback = result == .completed ? "已送至右侧预览。" : result.message
                        }
                        Button("系统打开") {
                            actionFeedback = onFileOutputAction(change, .systemOpen).message
                        }
                        Button("在 Finder 中显示") {
                            actionFeedback = onFileOutputAction(change, .finderReveal).message
                        }
                        Button("复制安全路径") {
                            actionFeedback = onFileOutputAction(change, .copySafePath).message
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let actionFeedback {
                        Text(actionFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat-inspector.file-output-feedback")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(change.kind.label)
                    .font((typography?.caption ?? .system(size: 10)).weight(.medium))
                    .foregroundStyle(
                        change.kind == .created
                            ? (theme?.statusSuccess ?? .green)
                            : Color.secondary
                    )
                VStack(alignment: .leading, spacing: 2) {
                    let path = ChatInspectorListPresentation.pathParts(change.path)
                    Text(path.fileName)
                        .font(typography?.contextBody ?? .system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !path.parent.isEmpty {
                        Text(path.parent)
                            .font(typography?.caption ?? .system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(change.path)
                Spacer(minLength: 4)
                Text("+\(change.additions) −\(change.deletions)")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(change.timestamp, style: .time)
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(typography?.caption ?? .system(size: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AgentFileChangePresentation.accessibilityLabel(for: change))
    }
}


extension View {
    func sessionBudgetResetConfirmation(
        _ target: Binding<SessionBudgetResetTarget?>,
        onConfirm: @escaping (SessionBudgetResetTarget) -> Void
    ) -> some View {
        confirmationDialog(
            "重置本会话预算？",
            isPresented: Binding(
                get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: target.wrappedValue
        ) { target in
            Button("确认重置预算", role: .destructive) { onConfirm(target) }
                .accessibilityIdentifier("chat-inspector.budget-reset.confirm")
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会清零本会话的预算计数、未完成的请求租约和子任务去重记录。预算上限与用量历史保持不变。")
        }
    }
}
