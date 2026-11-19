import SwiftUI
import AppKit
import Observation
import CanvasCore
import MinisCore
import WebKit
import AVKit
import ImageIO
import Darwin
import CryptoKit
import CoreServices
import PDFKit

/// Read-only App projection of the durable compact/lineage consumer.
struct SessionCompactProjection: Sendable, Equatable {
    enum State: String, Sendable, Equatable {
        case unavailable
        /// 存储服务已装配，但这个会话还没有落盘（如刚打开的欢迎会话，发第一条消息后才生成会话文件）。
        case sessionNotSaved
        case noCheckpoint
        case unverified = "UNVERIFIED"
        case checkpointed
        case blocked
    }

    struct CheckpointIdentity: Hashable, Sendable {
        let sessionID: String
        let checkpointID: String
        let resultRevision: UInt64
    }

    let state: State
    let summaryIdentity: CheckpointIdentity?
    let undoIdentity: CheckpointIdentity?
    let sessionID: String?
    let checkpointID: String?
    let sourceRevision: UInt64?
    let resultRevision: UInt64?
    let rootSessionID: String?
    let parentSessionID: String?
    let forkedThroughRevision: UInt64?
    let forkedThroughMessageID: String?

    var stateLabel: String {
        switch state {
        case .unavailable:
            return "持久化未装配"
        case .sessionNotSaved:
            return "尚无会话文件（发送第一条消息后生成）"
        case .noCheckpoint:
            return "暂无压缩检查点"
        case .unverified:
            return "检查点状态待核验"
        case .checkpointed:
            return "检查点可恢复"
        case .blocked:
            return "检查点校验阻断"
        }
    }

    init(sessionID: String?, store: SessionStore?) {
        self.sessionID = sessionID
        let session = sessionID.flatMap { id in store?.loadSession(id: id) }
        guard let sessionID, let store, let session else {
            state = (sessionID != nil && store != nil) ? .sessionNotSaved : .unavailable
            summaryIdentity = nil
            undoIdentity = nil
            checkpointID = nil
            sourceRevision = nil
            resultRevision = nil
            rootSessionID = nil
            parentSessionID = nil
            forkedThroughRevision = nil
            forkedThroughMessageID = nil
            return
        }

        rootSessionID = session.rootSessionID
        parentSessionID = session.parentSessionID
        forkedThroughRevision = session.forkedThroughTranscriptRevision
        forkedThroughMessageID = session.forkedThroughMessageID
        do {
            let availability = try store.compactionCheckpointAvailability(sessionID: sessionID)
            guard case .available(let checkpoint) = availability else {
                if case .quarantined = availability {
                    state = .blocked
                } else {
                    state = .noCheckpoint
                }
                summaryIdentity = nil
                undoIdentity = nil
                checkpointID = nil
                sourceRevision = nil
                resultRevision = nil
                return
            }
            state = .checkpointed
            checkpointID = checkpoint.checkpointID
            sourceRevision = checkpoint.sourceTranscriptRevision
            resultRevision = checkpoint.resultTranscriptRevision
            let identity = CheckpointIdentity(sessionID: checkpoint.sessionID,
                                              checkpointID: checkpoint.checkpointID,
                                              resultRevision: checkpoint.resultTranscriptRevision)
            let segmented = checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion
            let lossy = checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion
            summaryIdentity = segmented || lossy ? identity : nil
            undoIdentity = checkpoint.lineage == session.lineageIdentity
                && checkpoint.retainsCanonicalTranscript
                ? identity : nil
        } catch {
            state = .blocked
            summaryIdentity = nil
            undoIdentity = nil
            checkpointID = nil
            sourceRevision = nil
            resultRevision = nil
        }
    }

    static func readSummary(
        _ identity: CheckpointIdentity, store: SessionStore, redactor: ChatTranscriptRedactor
    ) -> String? {
        guard let checkpoint = try? store.compactionCheckpointForPreview(
            sessionID: identity.sessionID,
            expectedCheckpointID: identity.checkpointID,
            expectedResultRevision: identity.resultRevision
        ) else { return nil }
        let text = redactor.redactVisibleConversationBody(generatedSummaryText(checkpoint))
        return text.isEmpty ? nil : text
    }

    private struct SourceAnchoredSummaryText: Decodable {
        let version: Int
        let purpose: String
        let assistantSummary: String
    }

    /// Core has already validated the checkpoint, including the size and
    /// source of every span. Decode only the prose field for presentation;
    /// older formats and exact user/tool/media spans are not prose summaries.
    private static func generatedSummaryText(_ checkpoint: CompactionCheckpoint) -> String {
        let prefix = "<context-summary>\n"
        let suffix = "\n</context-summary>"
        if checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion {
            let content = checkpoint.summaryMessage.content
            guard content.hasPrefix(prefix), content.hasSuffix(suffix) else { return "" }
            return String(content.dropFirst(prefix.count).dropLast(suffix.count))
        }
        guard checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion,
              let spans = checkpoint.projectionSpans else { return "" }
        let decoder = JSONDecoder()
        return spans.compactMap { span -> String? in
            guard span.source.kind == .naturalText, span.projectedRange.count == 1,
                  let index = span.projectedRange.first,
                  checkpoint.replacementHistory.indices.contains(index) else { return nil }
            let content = checkpoint.replacementHistory[index].content
            guard content.hasPrefix(prefix), content.hasSuffix(suffix) else { return nil }
            let body = content.dropFirst(prefix.count).dropLast(suffix.count)
            guard let summary = try? decoder.decode(SourceAnchoredSummaryText.self, from: Data(body.utf8)),
                  summary.version == 1, summary.purpose == "source-anchored-history",
                  !summary.assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return summary.assistantSummary
        }.joined(separator: "\n\n")
    }
}

// MARK: - E14 右栏：上下文面板（Codex 风格，~300px，可折叠 ⌥⌘→）
//
// 波4：右栏 tab 交互参照 OpenMinis；会话、预览与浏览器 owner 使用本工程结构。
// 顶部 tab 条：节点/聊天 · 文件 · 终端 · 浏览器。点 tab 切换独立内容视图；
// 右上角 xmark 关闭面板（onCollapse，由 ContentView 持有展示状态）。
// 现有内容（节点详情 / 聊天信息 / 节点对话）归入「节点/聊天」tab；
// 文件 tab 已实装（AJ-31：目录树 + 搜索过滤 + 文件预览）；
// 终端 tab 已实装（AJ-32：bash/直跑执行 + TerminalGuard 命令白名单 + 危险命令确认条 +
//   交互/常驻命令超时兜底：SIGTERM → SIGKILL + 有界输出 drain，防 isRunning 卡死）；
// 浏览器 tab 已实装（AJ-34：WKWebView + http/https 白名单）。

// MARK: - Tab 定义

/// 右栏 tab 枚举：每项一个独立内容视图。
enum ContextTab: String, CaseIterable, Identifiable {
    case node
    case files
    case changes
    case terminal
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .node: return "节点/聊天"
        case .files: return "文件"
        case .changes: return "本回合改动"
        case .terminal: return "终端"
        case .browser: return "浏览器"
        }
    }

    var icon: String {
        switch self {
        case .node: return "scope"
        case .files: return "folder"
        case .changes: return "" // Catalog icon only; no new SF Symbol.
        case .terminal: return "terminal"
        case .browser: return "globe"
        }
    }

    var catalogIcon: MinisIcon? {
        switch self {
        case .node: return nil // Existing phase-four scope symbol stays deferred.
        case .files: return .folder
        case .changes: return .document
        case .terminal: return .terminal
        case .browser: return .globe
        }
    }
}

/// Keeps hover-driven cursor changes paired when SwiftUI sends duplicate
/// enter/leave events or removes the divider while it is hovered.
struct PreviewCursorPairingGate: Equatable {
    private(set) var isPushed = false

    mutating func enter() -> Bool {
        guard !isPushed else { return false }
        isPushed = true
        return true
    }

    mutating func leave() -> Bool {
        guard isPushed else { return false }
        isPushed = false
        return true
    }
}

// MARK: - 主视图

/// 聊天来源的预览请求。每次点击生成独立身份，即使目标 URL 相同也重新归属聊天来源。
struct ChatAttachmentPreviewSelection: Equatable {
    let sessionID: UUID
    let url: URL
    let requestID: UUID
    /// Present only for a verified ordinary Agent file result. A chat
    /// attachment continues using its existing independent preview contract.
    let agentWorkspaceRoot: URL?
    /// Existing bounded PDF extraction owned by the attachment. This is a
    /// read-only preview snapshot; the URL remains the external-open target.
    let extractedPDFText: String?

    init(sessionID: UUID, url: URL, requestID: UUID = UUID(), agentWorkspaceRoot: URL? = nil,
         extractedPDFText: String? = nil) {
        self.sessionID = sessionID
        self.url = url
        self.requestID = requestID
        self.agentWorkspaceRoot = agentWorkspaceRoot
        self.extractedPDFText = agentWorkspaceRoot == nil ? extractedPDFText : nil
    }

    init(sessionID: UUID, attachment: ChatAttachment, url: URL) {
        let text: String? = attachment.status == .ready && attachment.kind == .text
            && attachment.mimeType?.lowercased() == "application/pdf"
            ? attachment.data.flatMap { String(data: $0, encoding: .utf8) } : nil
        self.init(sessionID: sessionID, url: url, extractedPDFText: text)
    }

    func visible(in activeSessionID: UUID?) -> Self? {
        guard let activeSessionID, sessionID == activeSessionID else { return nil }
        return self
    }
}

/// A tab can disappear briefly without retiring its browser, but a different
/// conversation/workspace must never inherit the old session's WebView or store.
struct BrowserPaneOwnerIdentity: Hashable {
    let sessionID: UUID?
    let workspaceID: String
}

@MainActor
protocol BrowserTabLifecycleResource: AnyObject {
    func hideBrowserTab()
    func retireBrowserTab()
}

extension BrowserSession: BrowserTabLifecycleResource {
    func hideBrowserTab() {
        cancelNavigation()
        setUserVisible(false)
    }

    func retireBrowserTab() { close() }
}

/// The parent panel outlives a tab switch. Its one retained resource survives
/// that short hide; a scope change or panel teardown retires it exactly once.
@MainActor
final class BrowserTabSessionOwner {
    private(set) var identity: BrowserPaneOwnerIdentity?
    private(set) var resource: (any BrowserTabLifecycleResource)?

    func currentResource(for identity: BrowserPaneOwnerIdentity) -> (any BrowserTabLifecycleResource)? {
        self.identity == identity ? resource : nil
    }

    func retain(_ resource: any BrowserTabLifecycleResource, for identity: BrowserPaneOwnerIdentity) {
        if let current = self.resource {
            if self.identity != identity {
                // Never relabel an old browser as a new conversation's resource.
                retire()
                guard ObjectIdentifier(current) != ObjectIdentifier(resource) else { return }
            } else if ObjectIdentifier(current) != ObjectIdentifier(resource) {
                retire()
            }
        }
        self.identity = identity
        self.resource = resource
    }

    func hide(_ resource: any BrowserTabLifecycleResource) {
        guard let current = self.resource,
              ObjectIdentifier(current) == ObjectIdentifier(resource) else { return }
        current.hideBrowserTab()
    }

    func retire(ifDifferentFrom identity: BrowserPaneOwnerIdentity) {
        guard self.identity != nil, self.identity != identity else { return }
        retire()
    }

    func retire() {
        let previous = resource
        resource = nil
        identity = nil
        previous?.retireBrowserTab()
    }
}

struct ContextPanelView: View {
    @Bindable var chat: ChatStore
    /// Canvas enters only for the canvas inspector branch; chat receives nil.
    let canvas: CanvasStore?
    /// Immutable chat-only projection supplied by ContentView.
    var nodeContext: NodeContextInfo?
    var chatSnapshot: ChatInspectorSnapshot = .empty
    /// 折叠回调（ContentView 持有展示状态）
    var onCollapse: () -> Void
    var onCompact: (() -> Void)? = nil
    var budgetResetBlockedReason: String? = nil
    var onConfirmBudgetReset: ((SessionBudgetResetTarget) -> Void)? = nil
    var onReadCompactionSummary: (SessionCompactProjection.CheckpointIdentity) -> String? = { _ in nil }
    /// Child navigation returns to the existing Task Center sheet owned by ContentView.
    var onOpenChildSession: (TaskCenterChildSessionNavigation) -> Void = { _ in }
    /// Request the next bounded page from the current chat session.
    var onLoadOlderToolEvents: () -> Void = {}
    /// Ordinary Agent file actions are revalidated by ContentView at click time.
    var onFileOutputAction: ((AgentFileChangeRecord, AgentFileOutputIntent) -> AgentFileOutputOutcome)? = nil
    var onArtifactOutputAction: ((ProducedFileArtifactEvidence, AgentFileOutputIntent) -> AgentFileOutputOutcome)? = nil
    /// N2-02: callbacks retain explicit session/child/path identity through review.
    var childFileCheckpointSummaries: ((UUID, String, String) -> [FileCheckpointStore.Summary])? = nil
    var onRequestRestoreChildFileCheckpoint: ((UUID, UUID, String, String) async -> String)? = nil
    /// 仅当前会话的聊天附件请求可打开右侧预览。
    var attachmentPreviewSelection: ChatAttachmentPreviewSelection? = nil

    var visibleAttachmentPreview: ChatAttachmentPreviewSelection? {
        attachmentPreviewSelection?.visible(in: chat.activeSessionID)
    }

    /// 文件页根目录：当前会话的项目工作目录。
    private var activeSessionRoot: URL? {
        guard let sessionID = chat.activeSessionID else { return nil }
        return FileTreeStore.sessionRoot(path: chat.sessions.first(where: { $0.id == sessionID })?.workingDirectory)
    }

    /// 当前激活的 tab（面板内部状态）
    @State private var selectedTab: ContextTab = .node
    @State private var changeRecoveryPath: String?
    @State private var childRecoveryRequest: ChildTaskFileReviewRecoveryRequest?
    @State private var browserSessionOwner = BrowserTabSessionOwner()
    private let terminalSessionOwner = TerminalPTYSessionOwner.shared
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    private var browserPaneIdentity: BrowserPaneOwnerIdentity {
        BrowserPaneOwnerIdentity(
            sessionID: chat.activeSessionID,
            workspaceID: chat.composerWorkspaceID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content
        }
        // 侧栏背景比主区更暗（Codex 深色层次）
        .font(typography?.contextBody ?? .body)
        .background((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor)).opacity(0.55))
        .onAppear {
            if visibleAttachmentPreview != nil { selectedTab = .files }
        }
        .onChange(of: visibleAttachmentPreview) { _, selection in
            if selection != nil { selectedTab = .files }
        }
        .onChange(of: browserPaneIdentity) { _, newIdentity in
            browserSessionOwner.retire(ifDifferentFrom: newIdentity)
        }
        // 终端按会话保留：会话删除与安全开关的清理由常驻的 TerminalLifecycleObserver 负责
        // （右栏标签不在终端、或右栏/任务中心不挂载时也要生效）。
        .onDisappear {
            browserSessionOwner.retire()
        }
        .onChange(of: chat.activeSessionID) { _, _ in childRecoveryRequest = nil }
        .sheet(item: $childRecoveryRequest) { request in
            if let summaries = childFileCheckpointSummaries,
               let restore = onRequestRestoreChildFileCheckpoint {
                ChildTaskFileReviewRecoveryView(
                    sessionID: request.sessionID, childTaskID: request.childTaskID,
                    absolutePath: request.absolutePath,
                    summaries: { summaries(request.sessionID, request.childTaskID, request.absolutePath) },
                    onRequestRestore: { checkpointID in
                        await restore(checkpointID, request.sessionID, request.childTaskID, request.absolutePath)
                    })
            }
        }
        .sheet(isPresented: Binding(
            get: { changeRecoveryPath != nil },
            set: { if !$0 { changeRecoveryPath = nil } }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if let path = changeRecoveryPath {
                    Text("请求查看恢复：\(path)")
                        .font(typography?.caption ?? .caption).padding(.horizontal, 20)
                }
                FileCheckpointRecoveryView(chat: chat, focusPath: changeRecoveryPath)
            }
        }
    }

    private var selectedNode: CanvasNode? {
        guard let canvas, let id = canvas.selectedNodeID else { return nil }
        return canvas.graph.node(id: id)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 6) {
            MinisIconView(.sidebarRight, size: 12)
                .foregroundPalette(.tertiary)
                .font(.system(size: 10))
            Text("上下文")
                .font((typography?.sidebarTitle ?? .system(size: 11)).weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onCollapse()
            } label: {
                MinisIconView(.close, size: 12)
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("折叠上下文面板（快捷键在工具栏 ⌥⌘→ 可配置）")
            .accessibilityLabel("折叠上下文面板")
            .accessibilityHint("隐藏右侧上下文面板")
            .accessibilityIdentifier("context.panel.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Tab 条

    private var tabBar: some View {
        // 宽度够就显示图标+文字；不够时只显示图标（悬停有提示），不换行。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(ContextTab.allCases) { tab in
                    tabButton(tab, iconOnly: false)
                }
            }
            HStack(spacing: 2) {
                ForEach(ContextTab.allCases) { tab in
                    tabButton(tab, iconOnly: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabButton(_ tab: ContextTab, iconOnly: Bool) -> some View {
        let isActive = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                if let catalogIcon = tab.catalogIcon {
                    MinisIconView(catalogIcon, state: isActive ? .active : .normal, size: 12)
                        .foregroundPalette(isActive ? Color.primary : Color.secondary)
                        .font(.system(size: 10, weight: .medium))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: tab.icon)
                        .font(.system(size: 10, weight: .medium))
                }
                if !iconOnly {
                    Text(tab == .node ? "上下文" : tab == .changes ? "改动" : tab.title)
                        .font((typography?.caption ?? .system(size: 10)).weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.secondary.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("切换到\(tab.title)")
        // G-05：有可见文字时读屏名与可见字一致（上下文/改动）；纯图标时读完整名。
        .accessibilityLabel(iconOnly ? tab.title : (tab == .node ? "上下文" : tab == .changes ? "改动" : tab.title))
        .accessibilityHint("切换到\(tab.title)标签")
        .accessibilityIdentifier("context.panel.tab.\(tab.rawValue)")
    }

    // MARK: 内容（按 tab 分发）

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .node:
            nodeTabContent
        case .changes:
            TurnFileChangesView(
                changes: chatSnapshot.turnFileChanges,
                canSendComment: canSendChangeComment,
                onSendComment: sendChangeComment,
                onReviewRecovery: { changeRecoveryPath = $0 },
                onReviewChildRecovery: childFileCheckpointSummaries != nil && onRequestRestoreChildFileCheckpoint != nil
                    ? { childID, path in
                        guard let sessionID = chat.activeSessionID,
                              chatSnapshot.sessionID == sessionID.uuidString else { return }
                        childRecoveryRequest = ChildTaskFileReviewRecoveryRequest(
                            sessionID: sessionID, childTaskID: childID, absolutePath: path)
                    } : nil,
                workspaceDirectory: activeSessionRoot?.path
            )
            .id(chatSnapshot.sessionID)
        case .files:
            FileTreeTabView(attachmentSelection: visibleAttachmentPreview, sessionRoot: activeSessionRoot)
        case .terminal:
            // 终端按“会话 + 工作目录”定身份（不含 turnID/taskID，否则每个回合都会杀掉 shell）。
            // shell 由面板持有者保管，切 tab 不结束，换会话/关面板才结束。
            TerminalTabView(
                contextSnapshot: terminalContextSnapshot,
                settings: SettingsCenter.active,
                owner: terminalSessionOwner
            )
                .id(terminalPanelIdentity)
        case .browser:
            // P3-BROWSER-01 (b)（lane DEV-193，154 披露残差）：`session` 只在
            // onAppear 按当时的 conversationSessionID 构造一次，对话切换不会自动
            // 换 scope；这里按仓库既有身份模式（上方 .terminal 分支的
            // `.id(terminalContextSnapshot)`）把面板视图身份绑定到可信会话和
            // 工作区。短暂切 tab 由父面板保留资源；身份变化则先关闭旧资源，
            // 新面板再以新 scope 建立独立 WebView。
            BrowserTabView(
                settings: SettingsCenter.active,
                conversationSessionID: chat.activeSessionID,
                workspaceID: chat.composerWorkspaceID,
                lifecycleOwner: browserSessionOwner
            )
                .id(browserPaneIdentity)
        }
    }

    private var canSendChangeComment: Bool {
        chatSnapshot.sessionID != nil
            && chat.activeSessionID?.uuidString == chatSnapshot.sessionID
            && !chat.hasDraft && chat.pendingAttachments.isEmpty
            && chat.activePastedTextDrafts.isEmpty && !chat.isEditingMessage
            && !chat.isComposerCredentialPreflightPending
            && !chat.isComposerAttachmentPreflightPending
    }

    private func sendChangeComment(_ text: String) async -> Bool {
        guard canSendChangeComment, let session = chat.activeSessionID else { return false }
        return await chat.submitChangeComment(text, expectedSessionID: session)
    }

    private var terminalPanelIdentity: TerminalPTYIdentity? {
        terminalContextSnapshot.map {
            TerminalPTYIdentity(sessionID: $0.sessionID, workdir: $0.workdir)
        }
    }

    private var terminalContextSnapshot: TerminalContextSnapshot? {
        TerminalContextSnapshot.current(from: chat)
    }

    // MARK: 节点/聊天 tab（Canvas 与 Chat 分支）

    private var nodeTabContent: some View {
        Group {
            if let canvas, let nodeContext {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        NodeContextCard(context: nodeContext)
                        if let node = selectedNode {
                            // B12：Canvas-owned 节点属性编辑区，保持原 .id 隔离。
                            NodeInspectorView(node: node, store: canvas)
                                .id(node.id)
                            nodeDetailSection(node)
                        }
                    }
                    .padding(10)
                }
                .accessibilityIdentifier("canvas-inspector")
            } else if let canvas {
                canvasOverview(canvas)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let result = chat.compactionPresentation, let sessionID = result.sessionID,
                       sessionID == chat.activeSessionID {
                        Text(result.message)
                            .font(.caption)
                            .foregroundStyle(result.state == .failed ? (theme?.statusWarningText ?? AppStatusColor.warning) : Color.secondary)
                            .padding(.horizontal, 10)
                            .accessibilityIdentifier("context.compaction.result")
                    }
                    ChatInspectorView(
                    snapshot: chatSnapshot,
                    onCompact: onCompact,
                    onOpenChildSession: onOpenChildSession,
                    onLoadOlderToolEvents: onLoadOlderToolEvents,
                    contextOccupancy: chatSnapshot.sessionID == chat.activeSessionID?.uuidString
                        ? chat.contextOccupancy : nil,
                    activeSessionID: chat.activeSessionID?.uuidString,
                    onReadCompactionSummary: onReadCompactionSummary,
                    onUndoCompaction: { chat.undoCompactionProjection($0) },
                    budgetResetTarget: chat.sessionBudgetResetTarget,
                    budgetResetBlockedReason: budgetResetBlockedReason,
                    onConfirmBudgetReset: onConfirmBudgetReset,
                    onCompactWithHint: onCompact == nil ? nil : { (hint: String) in chat.compactContext(hint: hint) }
                )
                    .environment(\.agentFileOutputAction, onFileOutputAction)
                    .environment(\.agentArtifactOutputAction, onArtifactOutputAction)
                    TaskBoardInspectorView(chat: chat)
                    if let result = chat.compactionUndoFeedback, result.sessionID == chat.activeSessionID {
                        Text(result.succeeded
                             ? "已撤销上下文压缩。"
                             : "未确认撤销压缩。请检查会话是否空闲，以及检查点是否仍然有效。")
                            .font(.caption)
                            .foregroundStyle(result.succeeded ? Color.secondary : (theme?.statusWarningText ?? AppStatusColor.warning))
                            .padding(.horizontal, 10)
                            .accessibilityIdentifier("context.compaction.undo-result")
                    }
                }
            }
        }
    }

    /// Canvas-only fallback when no node is selected. This keeps canvas facts
    /// visible without allowing them to enter the chat inspector projection.
    private func canvasOverview(_ canvas: CanvasStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("画布", icon: "square.grid.2x2")
                infoRow("节点", "\(canvas.graph.nodes.count)")
                infoRow("连线", "\(canvas.graph.edges.count)")
                if let statusMessage = canvas.statusMessage {
                    infoRow("状态", statusMessage)
                }
            }
            .padding(10)
        }
        .accessibilityIdentifier("canvas-inspector")
    }

    // MARK: 节点详情

    private func nodeDetailSection(_ node: CanvasNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("节点详情", icon: "square.grid.2x2")
            infoRow("类型", node.type)
            infoRow("状态", node.status.label, tint: node.status.color)
            Divider()
            sectionTitle("端口", icon: "arrow.left.arrow.right")
            infoRow("输入", node.inputs.map(\.name).joined(separator: " / "))
            infoRow("输出", node.outputs.map(\.name).joined(separator: " / "))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.10))
        )
    }

    // MARK: 小组件

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font((typography?.caption ?? .system(size: 10)).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func infoRow(_ key: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(typography?.caption ?? .system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(typography?.contextBody ?? .system(size: 10))
                .foregroundStyle(tint ?? Color.primary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 文件树 tab（AJ-31：目录树 + 搜索过滤 + 文件预览）

/// 文件类型（用于预览分发与图标选择）。
enum FileKind: Equatable, Sendable {
    case text, json, image, svg, video, other

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "json", "ipynb": self = .json
        // P3-MEDIA-01：SVG 是矢量/XML 文本，不是位图——从 .image 拆分，预览按文本处理，
        // 不再伪装成光栅图片进入位图解码/图片通道（LUNA SVG 污染缺陷的 UI 侧分类根因）。
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff": self = .image
        case "svg": self = .svg
        // .ts 绝大多数是 TypeScript，归文本；真正的 MPEG-TS 视频在预览时嗅探到二进制再改判。
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "flv", "wmv",
             "quicktime", "m2ts", "mts": self = .video
        case "txt", "md", "markdown", "swift", "py", "js", "html", "css", "c", "h",
             "cpp", "java", "go", "rs", "yaml", "yml", "toml", "xml", "sh", "env", "plist",
             "sql", "log", "csv", "gitignore", "modulemap", "entitlements",
             "ts", "tsx", "jsx", "mjs", "cjs", "rb", "php", "kt", "kts", "vue", "svelte",
             "ini", "conf", "cfg", "lock", "hpp", "cc", "cxx", "m", "mm", "cs", "scala", "lua",
             "pl", "dart", "r", "ex", "exs", "hs", "clj", "zsh", "bash", "fish", "bat", "ps1",
             "scss", "sass", "less", "tsv", "jsonl", "ndjson", "properties", "proto", "graphql",
             "gql", "tf", "hcl", "nix", "zig", "gradle", "tex", "rst", "adoc", "diff", "patch",
             "xcconfig", "strings", "resolved", "editorconfig", "gitattributes", "npmrc", "dockerignore":
            self = .text
        case "":
            // 无扩展名的常见文本文件（Dockerfile、Makefile 等）。
            let names: Set<String> = ["dockerfile", "makefile", "gnumakefile", "rakefile", "gemfile",
                                      "podfile", "procfile", "vagrantfile", "license", "readme",
                                      "changelog", "authors", "codeowners", "jenkinsfile"]
            self = names.contains(url.lastPathComponent.lowercased()) ? .text : .other
        default: self = .other
        }
    }

    var icon: String {
        switch self {
        case .json: return "curlybraces.square"
        case .image: return "photo"
        case .svg: return "scribble"
        case .video: return "film"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }

    var supportsAgentOutputPreview: Bool {
        switch self {
        case .text, .json, .svg, .image, .video: return true
        case .other: return false
        }
    }

    /// 智能体产出预览：除按类型支持外，PDF 也可预览（只读 PDFView）。
    static func agentPreviewSupported(for url: URL) -> Bool {
        FileKind(url: url).supportsAgentOutputPreview || url.pathExtension.lowercased() == "pdf"
    }
}

/// 目录树节点（纯值类型，可单测）。
struct FileTreeNode: Identifiable, Equatable {
    /// 以路径为 id：刷新、重新扫描后节点身份不变，展开状态得以保留。
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileTreeNode] = []
    /// 目录的子项是否已读入；大目录与深层目录先不读，展开时再加载。
    var isLoaded: Bool = true
}

/// 文件树纯逻辑：目录扫描（按需加载）+ 文件名搜索过滤（可单测）。
enum FileTreeLogic {
    /// 一次扫描默认向下读入的目录层数；更深的目录显示出来、展开时再读。
    static let maxDepth = 2

    /// 不显示的版本控制元数据与系统噪声。
    static let hiddenAlwaysNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store"]

    /// 显示但默认折叠、展开时才读取的大目录（构建产物/依赖/缓存）。
    static let skippedDirNames: Set<String> = [
        ".build", "DerivedData", "node_modules", "Pods",
        ".xcuserdata", ".swiftpm", ".hermes", ".venv", "venv", "dist", "build", "Carthage",
    ]

    /// 扫描目录，返回排序后的树节点。显示点开头的文件（.git 等除外）；
    /// 大目录与深于 `maxDepth` 的目录只给出节点，`expanded` 里的路径（用户已展开的）会读入。
    static func scanDirectory(at url: URL, skipHidden: Bool = true, depth: Int = 0,
                              maxDepth: Int = FileTreeLogic.maxDepth,
                              expanded: Set<String> = []) -> [FileTreeNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }

        return entries
            .filter { entry in
                !(skipHidden && hiddenAlwaysNames.contains(entry.lastPathComponent))
            }
            .map { entry -> FileTreeNode in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let isDir = values?.isDirectory ?? false
                var node = FileTreeNode(
                    id: entry.path, url: entry, name: entry.lastPathComponent, isDirectory: isDir
                )
                if isDir {
                    let heavy = skippedDirNames.contains(entry.lastPathComponent)
                    let load = expanded.contains(entry.path) || (!heavy && depth < maxDepth)
                    if load {
                        node.children = scanDirectory(at: entry, skipHidden: skipHidden, depth: depth + 1,
                                                      maxDepth: maxDepth, expanded: expanded)
                    } else {
                        node.isLoaded = false
                    }
                }
                return node
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 把某个目录（按路径）的子项换成新读到的结果，其余节点原样保留。
    static func replacingChildren(in nodes: [FileTreeNode], path: String, with children: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            guard node.isDirectory else { return node }
            var copy = node
            if node.id == path {
                copy.children = children
                copy.isLoaded = true
            } else if path.hasPrefix(node.id + "/") {
                copy.children = replacingChildren(in: node.children, path: path, with: children)
            }
            return copy
        }
    }

    /// 按关键字过滤目录树：匹配文件名的文件保留；目录保留匹配自身或含匹配子项者。
    /// 返回过滤后的树（根节点为容器，不参与匹配）。
    static func filter(nodes: [FileTreeNode], query: String) -> [FileTreeNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nodes }

        func keep(_ node: FileTreeNode) -> FileTreeNode? {
            let nameMatch = node.name.lowercased().contains(q)
            if node.isDirectory {
                let kept = node.children.compactMap { keep($0) }
                if nameMatch || !kept.isEmpty {
                    var keptNode = node
                    keptNode.children = kept
                    return keptNode
                }
                return nil
            }
            return nameMatch ? node : nil
        }
        return nodes.compactMap { keep($0) }
    }
}

/// 监听目录树的文件变化（FSEvents），变化合并后通知一次；对象释放时自动停止。
final class FileTreeWatcher: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        func fire() { lock.lock(); let h = handler; lock.unlock(); h?() }
        func clear() { lock.lock(); handler = nil; lock.unlock() }
    }

    /// 构建产物、版本库内部的改动不触发刷新。
    private static let ignoredFragments = ["/.git/", "/.build/", "/node_modules/", "/DerivedData/", "/.DS_Store", "/.swiftpm/"]

    let path: String
    private let box: Box
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "miniscanvas.filetree.watcher", qos: .utility)

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        let box = Box(onChange)
        self.box = box
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let paths = (Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            let relevant = paths.prefix(count).contains { changed in
                !FileTreeWatcher.ignoredFragments.contains { changed.contains($0) }
            }
            if relevant { Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().fire() }
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            Unmanaged<Box>.fromOpaque(context.info!).release()
            return nil
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    deinit {
        box.clear()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// 文件预览：加载后的文本 / 图片 / 视频 / 元信息。
struct FilePreview: Sendable {
    let kind: FileKind
    let text: String?
    let imageData: Data?
    let videoURL: URL?
    let sizeText: String
    let error: String?
    /// 智能体产出的 PDF（只读 PDFView 渲染）；其余预览为 nil。
    var pdfURL: URL? = nil
    /// 文本内容是 Markdown，按 Markdown 渲染。
    var isMarkdown: Bool = false

    /// 智能体 PDF / 视频预览的大小上限。
    static let agentMediaByteLimit = 100 * 1024 * 1024
    /// 文本预览上限（截断超大文件，避免卡 UI）。
    static let textLimit = 200_000
    /// Agent output preview is deliberately smaller than the generic file
    /// tree reader: this path is reached from a model-produced file result.
    static let agentTextByteLimit = 1 * 1024 * 1024
    static let agentImageByteLimit = 8 * 1024 * 1024

    /// 文件树预览最多读入的字节数（超大文件只读开头一段）。
    static let readByteLimit = 1 * 1024 * 1024

    /// 从字节解码文本（utf8 优先；带 BOM 的 utf16；GB18030；最后回落 utf16）。
    /// `mayBeCut` 为 true 表示末尾可能把一个多字节字符截断了。
    static func text(from data: Data, mayBeCut: Bool = false) -> String? {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let hasBOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let encodings: [String.Encoding] = hasBOM ? [.utf16, .utf8, gb] : [.utf8, gb, .utf16]
        for encoding in encodings {
            for drop in 0...(mayBeCut ? 3 : 0) where data.count >= drop {
                if let value = String(data: data.prefix(data.count - drop), encoding: encoding) { return value }
            }
        }
        return nil
    }

    /// 截断到上限。
    static func truncated(_ s: String, limit: Int = textLimit) -> String {
        s.count <= limit ? s : String(s.prefix(limit))
    }

    /// 只读文件开头至多 `limit` 字节；`cut` 表示文件比这更长。
    static func readPrefix(of url: URL, limit: Int) -> (data: Data, cut: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        return data.count > limit ? (data.prefix(limit), true) : (data, false)
    }

    /// 嗅探开头 8 KB：没有 NUL 字节且能按文本解码就算文本（用于无扩展名或未知扩展名的文件）。
    static func sniffsAsText(_ url: URL) -> Bool {
        guard let (head, cut) = readPrefix(of: url, limit: 8 * 1024) else { return false }
        if head.isEmpty { return true }
        if head.contains(0) && !(head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])) { return false }
        return text(from: head, mayBeCut: cut) != nil
    }

    /// PDF 预览：抽取前若干页文字；没有文字层时给出说明。
    static func pdfText(from url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "（无法打开这个 PDF）" }
        var collected = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.string,
                  !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            collected += "[第 \(index + 1) 页]\n" + pageText + "\n\n"
            if collected.count >= textLimit { break }
        }
        return collected.isEmpty ? "（这个 PDF 没有可提取的文字，可能是扫描件；请用系统打开查看。）" : collected
    }

    static func load(url: URL) -> FilePreview {
        // 凭据类文件（.env、私钥、令牌等，含符号链接指向的目标）不读取、不预览。
        if SensitiveFilePolicy.contains(url.path) || SensitiveFilePolicy.contains(url.resolvingSymlinksInPath().path) {
            return FilePreview(kind: .other, text: nil, imageData: nil, videoURL: nil, sizeText: "",
                               error: "可能含密钥，未读取")
        }
        var kind = FileKind(url: url)
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        // .ts 既可能是 TypeScript 也可能是 MPEG-TS 视频：内容是二进制才按视频处理。
        if ext == "ts", kind == .text, !sniffsAsText(url) { kind = .video }
        if kind == .other, ext == "pdf" {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                return FilePreview(kind: .other, text: nil, imageData: nil, videoURL: nil, sizeText: sizeText, error: "无法读取文件")
            }
            // 文件树里的 PDF 与产物预览一致：直接用 PDFView 显示（含扫描件），不再只给提取的文字。
            return FilePreview(kind: .other, text: nil, imageData: nil, videoURL: nil,
                               sizeText: sizeText, error: nil, pdfURL: url)
        }
        if kind == .other, FileManager.default.isReadableFile(atPath: url.path), sniffsAsText(url) { kind = .text }
        // 视频：不读进内存（大文件），只存 URL 供 AVPlayer 播放。
        if kind == .video {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil,
                                   sizeText: "", error: "视频文件缺失或无权限读取，预览已阻止。")
            }
            return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: url, sizeText: sizeText, error: nil)
        }
        switch kind {
        case .image:
            guard size <= 25 * 1024 * 1024 else {
                return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil, sizeText: sizeText,
                                   error: "图片超过 25MB，未在面板中预览，请用系统打开。")
            }
            guard let data = try? Data(contentsOf: url) else {
                return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil, sizeText: sizeText, error: "无法读取文件")
            }
            return FilePreview(kind: kind, text: nil, imageData: data, videoURL: nil, sizeText: sizeText, error: nil)
        case .text, .json, .svg:
            // 只读开头一段（1 MB），大文件不整份读入内存。
            guard let (data, cut) = readPrefix(of: url, limit: readByteLimit) else {
                return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil, sizeText: sizeText, error: "无法读取文件")
            }
            var decoded = truncated(text(from: data, mayBeCut: cut) ?? "（无法解码为文本）")
            // 先截断再追加提示，避免提示被截掉。
            if cut { decoded += "\n\n…（文件较大，仅显示前 \(readByteLimit / 1024 / 1024) MB）" }
            return FilePreview(kind: kind, text: decoded, imageData: nil, videoURL: nil, sizeText: sizeText, error: nil)
        case .video, .other:
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil, sizeText: sizeText, error: "无法读取文件")
            }
            return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil, sizeText: sizeText, error: nil)
        }
    }

    /// The ordinary Agent preview rechecks the same root immediately before
    /// background IO, then reads at most limit + 1 bytes. It never calls the
    /// generic unbounded `load(url:)` after checking the file size.
    static func loadAgentOutput(url: URL, workspaceRoot: URL,
                                expectedSHA256: String? = nil,
                                validateBinding: @Sendable () -> Bool = { true },
                                authorizeTarget: @Sendable (URL) -> Bool = { _ in true }) -> FilePreview {
        let kind = FileKind(url: url)
        func failed(_ message: String) -> FilePreview {
            FilePreview(kind: kind, text: nil, imageData: nil, videoURL: nil, sizeText: "", error: message)
        }
        if expectedSHA256 != nil {
            guard validateBinding() else {
                return failed(AgentFileOutputFailure.unbound.message)
            }
            guard workspaceRoot.resolvingSymlinksInPath().standardizedFileURL == workspaceRoot.standardizedFileURL else {
                return failed(AgentFileOutputFailure.outOfBounds.message)
            }
        }
        let target: URL
        switch AgentFileOutputTargetResolver.resolve(
            path: url.path,
            workspaceRoot: workspaceRoot.path,
            probe: AgentFileOutputTargetResolver.fileSystemProbe
        ) {
        case .success(let approved): target = approved
        case .failure(let reason): return failed(reason.message)
        }
        guard FileKind.agentPreviewSupported(for: url) else {
            return failed(AgentFileOutputFailure.previewUnsupported.message)
        }
        guard expectedSHA256 == nil || authorizeTarget(target) else {
            return failed(AgentFileOutputFailure.outOfBounds.message)
        }
        let targetExtension = target.pathExtension.lowercased()
        if kind == .video || targetExtension == "pdf" {
            // PDF / 视频只读预览：不读进内存，只在大小上限内交给 PDFView / AVPlayer。
            guard let mediaSize = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return failed("无法核验文件大小，预览已阻止。")
            }
            guard mediaSize <= agentMediaByteLimit else {
                return failed("文件超过当前预览大小上限，请在变更文件或产物行里点“系统打开”（会重新核验）。")
            }
            if let expectedSHA256 {
                guard AgentFileOutputTargetResolver.generatedFileDigest(target) == expectedSHA256 else {
                    return failed(AgentFileOutputFailure.stale.message)
                }
                guard validateBinding() else { return failed(AgentFileOutputFailure.unbound.message) }
                guard authorizeTarget(target) else { return failed(AgentFileOutputFailure.outOfBounds.message) }
            }
            let mediaSizeText = ByteCountFormatter.string(fromByteCount: Int64(mediaSize), countStyle: .file)
            if targetExtension == "pdf" {
                return FilePreview(kind: .other, text: nil, imageData: nil, videoURL: nil,
                                   sizeText: mediaSizeText, error: nil, pdfURL: target)
            }
            return FilePreview(kind: kind, text: nil, imageData: nil, videoURL: target,
                               sizeText: mediaSizeText, error: nil)
        }
        let maxBytes = kind == .image ? agentImageByteLimit : agentTextByteLimit
        guard let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return failed("无法核验文件大小，预览已阻止。")
        }
        guard size <= maxBytes else {
            return failed("文件超过当前预览大小上限，请在变更文件或产物行里点“系统打开”（会重新核验）。")
        }
        let data: Data
        do {
            let handle: FileHandle
            if expectedSHA256 != nil {
                guard let verified = AgentFileOutputTargetResolver.generatedFileHandle(target) else {
                    return failed(AgentFileOutputFailure.stale.message)
                }
                handle = verified
            } else {
                handle = try FileHandle(forReadingFrom: target)
            }
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            if let expectedSHA256 {
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expectedSHA256,
                      AgentFileOutputTargetResolver.generatedFileStillMatches(handle, url: target) else {
                    return failed(AgentFileOutputFailure.stale.message)
                }
                guard validateBinding() else { return failed(AgentFileOutputFailure.unbound.message) }
                guard authorizeTarget(target) else { return failed(AgentFileOutputFailure.outOfBounds.message) }
            }
        } catch {
            return failed("文件读取失败，预览已阻止。")
        }
        guard data.count <= maxBytes else {
            return failed("文件超过当前预览大小上限，请在变更文件或产物行里点“系统打开”（会重新核验）。")
        }
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        if kind == .image {
            return FilePreview(kind: kind, text: nil, imageData: data, videoURL: nil, sizeText: sizeText, error: nil)
        }
        guard let decoded = text(from: data) else {
            return failed("无法解码为文本，预览已阻止。")
        }
        return FilePreview(kind: kind, text: truncated(decoded), imageData: nil, videoURL: nil, sizeText: sizeText, error: nil,
                           isMarkdown: ["md", "markdown"].contains(targetExtension))
    }
}

/// 文件树状态（@MainActor 视图状态，逻辑委托给 FileTreeLogic）。
@MainActor
@Observable
final class FileTreeStore {
    /// 当前根目录：跟随当前会话的项目工作目录；会话没有项目目录时为 nil（不扫描）。
    var rootURL: URL?
    var rootNodes: [FileTreeNode] = []
    var searchText: String = ""
    var selectedURL: URL?
    var preview: FilePreview?
    /// 仅聊天附件打开的选择可在会话切换时清除；手动文件选择保持独立。
    private var chatAttachmentRequestID: UUID?
    private var agentWorkspaceRoot: URL?
    var agentPreviewOnly: Bool { agentWorkspaceRoot != nil }
    func canShowPreview(for selection: ChatAttachmentPreviewSelection?) -> Bool {
        guard let agentWorkspaceRoot else { return true }
        return selection?.requestID == chatAttachmentRequestID
            && selection?.agentWorkspaceRoot == agentWorkspaceRoot
            && selection?.url == selectedURL
    }
    /// 最近一次系统外部打开的可观察错误；成功或重新选择文件时清除。
    var externalOpenError: String?
    /// 已展开目录的路径（与节点 id 一致，刷新后保持）。
    var expandedIDs: Set<String> = []
    private var watcher: FileTreeWatcher?
    private var loadingPaths: Set<String> = []
    /// 进行中的预览加载任务（点文件串行化，防并发读文件卡 UI）。
    private var previewTask: Task<Void, Never>?
    /// 进行中的目录扫描任务（reload 串行化，防重复扫描并发打满 CPU——闪退根因）。
    private var scanTask: Task<Void, Never>?

    /// 不再回落到进程工作目录：从访达启动时它是 "/"，测试档下会露出启动终端所在的真实目录。
    init(rootURL: URL? = nil) {
        self.rootURL = rootURL
        reload()
    }

    /// 会话工作目录 → 文件页根目录；空白或目录不存在时为 nil。
    static func sessionRoot(path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 切换会话或打开文件页时跟随会话目录；手动更换的根目录保留到会话变化为止。
    func followSession(root: URL?) {
        guard root?.standardizedFileURL != rootURL?.standardizedFileURL else { return }
        changeRoot(root)
    }

    func reload() {
        // 后台线程扫描，避免大目录（如 .build）阻塞主线程 UI（用户反馈：点文件按钮卡死）。
        // 串行化：取消上一次扫描，同一时刻只有一个扫描在跑（防重复扫描并发打满 CPU——闪退根因）。
        scanTask?.cancel()
        guard let url = rootURL else {
            rootNodes = []
            watcher = nil
            return
        }
        // 监听目录变化：新文件、删除、改名自动出现在树里（FSEvents 已合并延迟，这里再串行化扫描）。
        if watcher?.path != url.path {
            watcher = FileTreeWatcher(path: url.path) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        }
        let expanded = expandedIDs
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let nodes = FileTreeLogic.scanDirectory(at: url, expanded: expanded)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // AJ-69：不再自动展开顶层目录——工作台打开时树保持收起（合理初始大小，不抢焦点）。
                self.rootNodes = nodes
            }
        }
        scanTask = task
    }

    /// 展示用节点：应用搜索过滤（空查询返回全树）。
    var displayNodes: [FileTreeNode] {
        FileTreeLogic.filter(nodes: rootNodes, query: searchText)
    }

    func toggle(_ node: FileTreeNode) {
        if expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
        } else {
            expandedIDs.insert(node.id)
            loadChildren(of: node)
        }
    }

    /// 大目录、深层目录展开时才读取它的直接子项。
    func loadChildren(of node: FileTreeNode) {
        guard node.isDirectory, !node.isLoaded, !loadingPaths.contains(node.id) else { return }
        loadingPaths.insert(node.id)
        let url = node.url
        let expanded = expandedIDs
        Task.detached(priority: .userInitiated) { [weak self] in
            let children = FileTreeLogic.scanDirectory(at: url, maxDepth: 0, expanded: expanded)
            await MainActor.run {
                guard let self else { return }
                self.loadingPaths.remove(url.path)
                self.rootNodes = FileTreeLogic.replacingChildren(in: self.rootNodes, path: url.path, with: children)
            }
        }
    }

    func select(_ url: URL) {
        chatAttachmentRequestID = nil
        agentWorkspaceRoot = nil
        loadPreview(for: url)
    }

    func selectAttachment(_ selection: ChatAttachmentPreviewSelection) {
        chatAttachmentRequestID = selection.requestID
        agentWorkspaceRoot = selection.agentWorkspaceRoot
        if let text = selection.extractedPDFText {
            previewTask?.cancel()
            previewTask = nil
            selectedURL = selection.url
            externalOpenError = nil
            preview = FilePreview(kind: .text, text: FilePreview.truncated(text), imageData: nil,
                                  videoURL: nil, sizeText: "\(text.count) 字符（已提取文本）", error: nil)
            return
        }
        loadPreview(for: selection.url)
    }

    func clearChatAttachmentSelection() {
        guard chatAttachmentRequestID != nil else { return }
        chatAttachmentRequestID = nil
        agentWorkspaceRoot = nil
        previewTask?.cancel()
        previewTask = nil
        selectedURL = nil
        preview = nil
        externalOpenError = nil
    }

    private func loadPreview(for url: URL) {
        selectedURL = url
        preview = nil
        externalOpenError = nil
        let requestID = chatAttachmentRequestID
        let authorizedRoot = agentWorkspaceRoot
        // 卡顿专项（P0）：FilePreview.load 内含 Data(contentsOf:) 同步读文件，移后台避免主线程阻塞（用户反馈：点文件卡死）。
        // 用 Task 串行化：同一时刻只有一个预览加载在跑，先点先到。
        previewTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let p = authorizedRoot.map {
                FilePreview.loadAgentOutput(url: url, workspaceRoot: $0)
            } ?? FilePreview.load(url: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled,
                      self.selectedURL == url,
                      self.chatAttachmentRequestID == requestID,
                      self.agentWorkspaceRoot == authorizedRoot else { return }
                self.preview = p
            }
        }
        previewTask = task
    }

    /// 使用系统默认应用打开当前文件；失败原因写入状态，交给右侧预览显示。
    func openSelectedExternally() {
        guard !agentPreviewOnly else {
            externalOpenError = "智能体产出需重新核验后才能打开：请在对话里该文件的变更文件或产物行点“系统打开”。"
            return
        }
        guard let selectedURL else {
            externalOpenError = "请先选择一个文件。"
            return
        }
        if SensitiveFilePolicy.contains(selectedURL.path) || SensitiveFilePolicy.contains(selectedURL.resolvingSymlinksInPath().path) {
            externalOpenError = "该文件可能含密钥，不交给系统打开。"
            return
        }
        // 与对话里的文件链接同一套类型拦截：可执行/自动运行类型只在访达显示，脚本用文本编辑器查看。
        switch TranscriptLocalFileLink.openDisposition(for: selectedURL) {
        case .revealOnly:
            NSWorkspace.shared.activateFileViewerSelecting([selectedURL])
            externalOpenError = "该类型的文件可能自动运行，已改为在访达中显示，没有直接打开。"
            return
        case .textEditor:
            externalOpenError = TranscriptLocalFileLink.openInTextEditor(selectedURL) ? nil : "没有找到文本编辑器，无法查看该脚本。"
            return
        case .systemOpen:
            break
        }
        do {
            try ChatAttachmentExternalOpener().open(url: selectedURL)
            externalOpenError = nil
        } catch let error as ChatAttachmentOpenError {
            externalOpenError = error.localizedDescription
        } catch {
            externalOpenError = "系统打开此文件失败，请稍后重试。"
        }
    }

    func changeRoot(_ url: URL?) {
        rootURL = url
        chatAttachmentRequestID = nil
        previewTask?.cancel()
        previewTask = nil
        selectedURL = nil
        preview = nil
        expandedIDs.removeAll()
        reload()
    }
}

/// 文件树 tab：目录树 + 搜索过滤 + 文件预览。
struct FileTreeTabView: View {
    /// 外部聊天附件预览目标；不要求该文件位于文件树根目录内。
    let attachmentSelection: ChatAttachmentPreviewSelection?
    /// 当前会话的项目工作目录；nil 表示会话未归属项目。
    let sessionRoot: URL?
    @State private var store = FileTreeStore()

    // AJ-69：树/预览可拖拽分配高度——预览面板高度由用户拖拽决定，默认合理初始值。
    /// 预览面板当前高度。
    @State private var previewHeight: CGFloat = 200
    /// 拖拽起始高度（nil = 未在拖拽中）。
    @State private var previewDragStart: CGFloat?
    /// previewDivider owns one cursor push at a time, including view teardown.
    @State private var previewCursorGate = PreviewCursorPairingGate()

    /// 预览高度可调范围（拖拽钳制，防拖没/拖爆）。
    private static let previewHeightRange: ClosedRange<CGFloat> = 120...480

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    init(attachmentSelection: ChatAttachmentPreviewSelection? = nil, sessionRoot: URL? = nil) {
        self.attachmentSelection = attachmentSelection
        self.sessionRoot = sessionRoot
    }

    var body: some View {
        VStack(spacing: 0) {
            rootBar
            Divider()
            searchField
            Divider()
            treeBody
            if let preview = store.preview, store.canShowPreview(for: attachmentSelection) {
                previewDivider
                previewPane(preview)
                    .frame(height: previewHeight)
            }
        }
        // 波次3：文件树右键挂点（浮动菜单：刷新/折叠全部/展开全部/更换根目录）。
        // 菜单渲染复用主窗口全局 FloatingMenuOverlay（ContentView 根 overlay），此处只挂捕获层。
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(fileTreeContextMenuItems(), at: windowPoint)
        })
        .onAppear {
            store.followSession(root: sessionRoot)
            applyAttachmentSelection()
        }
        .onChange(of: sessionRoot) { _, root in store.followSession(root: root) }
        .onChange(of: attachmentSelection) { _, _ in applyAttachmentSelection() }
    }

    private func applyAttachmentSelection() {
        if let attachmentSelection {
            store.selectAttachment(attachmentSelection)
        } else {
            store.clearChatAttachmentSelection()
        }
    }

    /// 波次3：文件树右键菜单项（刷新 / 展开全部 / 折叠全部 / 更换根目录）。
    private func fileTreeContextMenuItems() -> [FloatingMenuItem] {
        [
            FloatingMenuItem(kind: .button(title: "刷新目录", icon: "arrow.clockwise", role: nil, help: "重新扫描当前根目录") {
                store.reload()
            }, catalogIcon: .refresh),
            FloatingMenuItem(kind: .button(title: "展开全部", icon: "arrow.triangle.branch", role: nil, help: "展开所有目录") {
                store.expandedIDs.formUnion(allDirectoryIDs(in: store.rootNodes))
            }),
            FloatingMenuItem(kind: .button(title: "折叠全部", icon: "arrow.uturn.left", role: nil, help: "收起所有目录") {
                store.expandedIDs.removeAll()
            }),
            FloatingMenuItem(kind: .divider),
            FloatingMenuItem(kind: .button(title: "更换根目录…", icon: "folder.badge.plus", role: nil, help: "重新选择文件树根目录") {
                chooseRoot()
            }),
        ]
    }

    /// 递归收集全部目录节点 id（「展开全部」用，目录展开状态由 store.expandedIDs 驱动）。
    private func allDirectoryIDs(in nodes: [FileTreeNode]) -> Set<String> {
        var ids = Set<String>()
        func visit(_ node: FileTreeNode) {
            // 还没读入的大目录不随“展开全部”一起读，需要时单独点开。
            if node.isDirectory, node.isLoaded {
                ids.insert(node.id)
                for child in node.children { visit(child) }
            }
        }
        for node in nodes { visit(node) }
        return ids
    }

    // MARK: 树/预览拖拽分隔条（AJ-69）

    /// 树与预览之间的拖拽分隔条：上下拖动重新分配预览高度（树占剩余空间）。
    private var previewDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(
                Rectangle()
                    .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.6))
                    .frame(height: 1)
            )
            .contentShape(Rectangle())
            .gesture(previewDragGesture)
            .onHover { inside in
                if inside, previewCursorGate.enter() {
                    NSCursor.resizeUpDown.push()
                } else if !inside, previewCursorGate.leave() {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if previewCursorGate.leave() { NSCursor.pop() }
            }
            .help("拖拽调整预览高度")
    }

    private var previewDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = previewDragStart ?? previewHeight
                previewDragStart = start
                let target = start - value.translation.height
                previewHeight = min(max(target, Self.previewHeightRange.lowerBound), Self.previewHeightRange.upperBound)
            }
            .onEnded { _ in previewDragStart = nil }
    }

    // MARK: 根目录栏

    private var rootBar: some View {
        HStack(spacing: 6) {
            MinisIconView(.folder, size: 12)
                .foregroundPalette(.tertiary)
                .font(.system(size: 10))
            Text(store.rootURL?.lastPathComponent ?? "未选择目录")
                .font((typography?.caption ?? .system(size: 10)).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.rootURL?.path ?? "当前会话未归属项目，可点右侧按钮选择要浏览的文件夹")
            Spacer()
            Button {
                store.reload()
            } label: {
                MinisIconView(.refresh, size: 12)
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("刷新目录")
            .accessibilityLabel("刷新目录")
            .accessibilityHint("重新加载当前根目录")
            Button {
                chooseRoot()
            } label: {
                MinisIconView(.folderAdd, size: 12)
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("切换根目录")
            .accessibilityLabel("切换根目录")
            .accessibilityHint("选择要浏览的文件夹")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                store.changeRoot(url)
            }
        }
    }

    // MARK: 搜索

    private var searchField: some View {
        HStack(spacing: 4) {
            MinisIconView(.search, size: 12)
                .foregroundPalette(.tertiary)
                .font(.system(size: 10))
            TextField("搜索文件名…", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(typography?.contextBody ?? .system(size: 11))
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    MinisIconView(.close, size: 12)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("清空搜索")
                .accessibilityLabel("清空搜索")
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.10))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: 目录树

    private var treeBody: some View {
        ScrollView {
            if store.displayNodes.isEmpty {
                Text(store.rootURL == nil ? "当前会话未归属项目" : (store.searchText.isEmpty ? "空目录" : "无匹配文件"))
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
            } else {
                // 性能：目录树用 LazyVStack，顶部节点按需渲染（避免大目录全量 layout -> 滚动卡顿）
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.displayNodes) { node in
                        FileTreeRow(node: node, store: store)
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: 预览

    @ViewBuilder
    private func previewPane(_ preview: FilePreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: preview.kind.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(store.selectedURL?.lastPathComponent ?? "")
                    .font((typography?.caption ?? .system(size: 10)).weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(preview.sizeText)
                    .font(typography?.caption2 ?? .system(size: 9))
                    .foregroundStyle(.tertiary)
                Button {
                    store.openSelectedExternally()
                } label: {
                    MinisIconView(.externalLink, size: 12)
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .disabled(store.selectedURL == nil || store.agentPreviewOnly)
                .help(store.agentPreviewOnly ? "智能体产出需重新核验：请在变更文件或产物行点“系统打开”" : "在系统中打开")
                .accessibilityLabel("在系统中打开")
                .accessibilityHint("使用系统默认应用打开文件或图片")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // AJ-69：预览内容整体可滚动——高度由拖拽分隔条分配，内容超限时滚动查看。
            // 图片预览高度跟随面板高度（至少 160），点击可放大。
            GeometryReader { panel in
                ScrollView {
                    FilePreviewContents(
                        preview: preview,
                        imageCacheKey: store.agentPreviewOnly ? "" : (store.selectedURL.map { FileTreePreviewCache.cacheKey(for: $0) } ?? ""),
                        imageHeight: max(160, panel.size.height - 12))
                }
            }
            if let error = preview.error {
                Text(error)
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(theme?.aj38.danger.swiftUIColor ?? .red)
                    .padding(.horizontal, 10)
            }
            if let externalOpenError = store.externalOpenError {
                Label { Text(externalOpenError) } icon: { MinisIconView(.warning, size: 14).foregroundPalette(theme?.aj38.danger.swiftUIColor ?? .red) }
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(theme?.aj38.danger.swiftUIColor ?? .red)
                    .padding(.horizontal, 10)
                    .accessibilityLabel("外部打开失败")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.08))
    }

    /// 卡顿专项（P0）：文件预览图片此前用 NSImage(data:) 在 SwiftUI body（主线程）全分辨率
    /// 解码大图，点开大图片时整帧阻塞（用户反馈：点文件卡死）。现改为 ImageIO 限幅缩略图解码，
    /// 最大边 ≤ 1024px —— 预览框仅 160pt 高 + scaledToFit，画质无损且解码内存/耗时大幅下降。
    /// 再按文件路径键控 NSCache 有界缓存：body 每重算一次（分隔条拖动/选中切换/窗口 resize）
    /// 不再重复解码同一文件（此前每次重算都重新缩略图解码）。
}

/// 智能体产出 PDF 的只读预览（路径已由 loadAgentOutput 复验）。
struct AgentPDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url { nsView.document = PDFDocument(url: url) }
    }

    /// PDF 里的链接不直接交给系统：网页先确认，本地文件按类型拦截（脚本、可执行类型不运行）。
    @MainActor final class Coordinator: NSObject, @preconcurrency PDFViewDelegate {
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            handle(url, in: sender)
        }

        @MainActor private func handle(_ url: URL, in view: PDFView) {
            if let web = TranscriptExternalLink.allowedURL(url) {
                let alert = NSAlert()
                alert.messageText = "打开外部链接？"
                alert.informativeText = "将使用默认浏览器打开：\n\(TranscriptExternalLink.confirmationDisplay(for: web))"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "打开链接")
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(web) }
                return
            }
            guard let local = TranscriptLocalFileLink.resolve(url) else { return }
            let action = TranscriptLocalFileLink.action(for: local)
            let alert = NSAlert()
            alert.messageText = "打开本地文件？"
            alert.informativeText = TranscriptLocalFileLink.confirmationText(for: action)
            if case .missing = action {
                alert.messageText = "无法打开"
                alert.addButton(withTitle: "好")
                alert.runModal()
                return
            }
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "继续")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            switch action {
            case .open(let target):
                switch TranscriptLocalFileLink.openDisposition(for: target) {
                case .systemOpen: NSWorkspace.shared.open(target)
                case .textEditor: _ = TranscriptLocalFileLink.openInTextEditor(target)
                case .revealOnly: NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            case .revealFolder(let target), .revealBlocked(let target, _):
                NSWorkspace.shared.activateFileViewerSelecting([target])
            case .missing:
                break
            }
        }
    }
}

/// Shared rendering of already validated preview bytes; it never reads a path.
struct FilePreviewContents: View {
    let preview: FilePreview
    let imageCacheKey: String
    /// 图片预览高度；nil 沿用默认 160。
    var imageHeight: CGFloat? = nil
    @Environment(\.typographyTokens) private var typography
    @State private var enlargedImage: NSImage?
    @State private var showsEnlarged = false
    @State private var enlargedFitsWindow = true
    var body: some View {
                Group {
                    switch preview.kind {
                    case .image:
                        if let data = preview.imageData,
                           let img = FileTreePreviewCache.image(
                               from: data,
                               key: imageCacheKey
                           ) {
                            GeometryReader { geo in
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                            .frame(height: imageHeight ?? 160)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                enlargedImage = FileTreePreviewCache.enlargedImage(from: data) ?? img
                                showsEnlarged = true
                            }
                            .help("点击放大")
                            .sheet(isPresented: $showsEnlarged) {
                                VStack(spacing: 8) {
                                    if let enlargedImage {
                                        if enlargedFitsWindow {
                                            Image(nsImage: enlargedImage)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        } else {
                                            ScrollView([.horizontal, .vertical]) {
                                                Image(nsImage: enlargedImage)
                                            }
                                        }
                                    }
                                    HStack {
                                        Button(enlargedFitsWindow ? "放大查看（最长边 2048 像素，可滚动）" : "适合窗口") {
                                            enlargedFitsWindow.toggle()
                                        }
                                        Button("关闭") { showsEnlarged = false }
                                            .keyboardShortcut(.cancelAction)
                                    }
                                }
                                .padding(12)
                                .frame(minWidth: 640, minHeight: 480)
                            }
                        } else {
                            Text("无法加载图片")
                                .font(typography?.caption ?? .system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    case .text, .json, .svg:
                        if preview.isMarkdown, let source = preview.text {
                            Text(AttributedString(MarkdownAttributedTextBuilder.build(content: source, isMarkdown: true, baseSize: 12)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        } else {
                            Text(preview.text ?? "")
                                .font(typography?.monospaced ?? .system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    case .video:
                        if let url = preview.videoURL {
                            // AVPlayerContainerView：规避 SwiftUI VideoPlayer 的 _AVKit_SwiftUI 元数据崩溃。
                            AVPlayerContainerView(url: url)
                                .frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text("无法加载视频")
                                .font(typography?.caption ?? .system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    case .other:
                        if let pdfURL = preview.pdfURL {
                            AgentPDFPreviewView(url: pdfURL)
                                .frame(height: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text("二进制文件，无文本预览")
                                .font(typography?.caption ?? .system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(10)
                        }
                    }
                }
    }
}

/// 文件树图片预览缩略图：CGImageSource 限幅解码（最大边 ≤ 1024px）+ NSCache 有界缓存。
/// @MainActor 隔离（NSCache 非 Sendable，Swift 6 严格并发下由主线程独占访问）。
@MainActor
enum FileTreePreviewCache {
    /// 本缓存的基线内存预算（字节）= 接入 memoryLimitMB consumer 前的硬编码上限。
    static let baselineTotalCostBytes = 48 * 1024 * 1024

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 16
        cache.totalCostLimit = baselineTotalCostBytes
        return cache
    }()

    /// 测试/诊断：当前生效的内存预算（字节）= min(基线, storage.memoryLimitMB)。
    static var currentTotalCostLimitBytes: Int { cache.totalCostLimit }

    /// 缓存键：路径 + 修改时间 + 文件大小，同名图片重新生成后不会命中旧缓存。
    static func cacheKey(for url: URL) -> String {
        // 不用 URL.resourceValues：同一个 URL 对象会缓存读过的修改时间，读到的可能是旧值。
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return "\(url.path)|\(stamp)|\(size)"
    }

    /// 点击放大时按需解码的大图（最大边 ≤ 2048px），不入缓存。
    static func enlargedImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSZeroSize)
    }

    /// 预览缩略图：命中缓存直接返回；未命中限幅解码后入缓存（cost 按原图字节近似）。
    /// key = 文件路径；空 key（无选中路径的防御分支）跳过缓存，不共享条目。
    static func image(from data: Data, key: String) -> NSImage? {
        let cacheKey = key as NSString
        if !key.isEmpty, let hit = cache.object(forKey: cacheKey) { return hit }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSZeroSize)
        if !key.isEmpty {
            // P3-P1-03 consumer：入缓存前应用规范内存上限（未配置 = 保持基线）。
            MemoryLimitCachePolicy.applyTotalCostLimit(baseline: baselineTotalCostBytes, to: cache)
            cache.setObject(image, forKey: cacheKey, cost: data.count)
        }
        return image
    }
}

/// 目录树单行（目录可展开，文件可点击预览）。
private struct FileTreeRow: View {
    let node: FileTreeNode
    @Bindable var store: FileTreeStore

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                if !node.isLoaded {
                    Text("加载中…")
                        .font(typography?.caption ?? .system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                        .task { store.loadChildren(of: node) }
                } else if node.children.isEmpty {
                    Text("空")
                        .font(typography?.caption ?? .system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                } else {
                    // 性能：展开目录的子节点也用 LazyVStack 按需渲染，避免大目录一次性全量 layout
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(node.children) { child in
                            FileTreeRow(node: child, store: store)
                        }
                    }
                }
            } label: {
                fileLabel
            }
            .font(typography?.contextBody ?? .system(size: 11))
        } else {
            fileLabel
                .contentShape(Rectangle())
                .onTapGesture { store.select(node.url) }
                .background(
                    store.selectedURL == node.url
                        ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.15)
                        : Color.clear
                )
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { store.expandedIDs.contains(node.id) },
            set: { _ in store.toggle(node) }
        )
    }

    private var fileLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder" : FileKind(url: node.url).icon)
                .font(.system(size: 10))
                .foregroundStyle(node.isDirectory ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.secondary)
            if node.isDirectory {
                Text(node.name)
                    .font(typography?.contextBody ?? .system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(node.name)
                    .font(typography?.contextBody ?? .system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAction(.default) { store.select(node.url) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 4)
    }
}

// MARK: - 终端 tab（AJ-32：shell 集成 + 命令白名单）

/// 已解析的终端命令：头 token = 可执行名，其余为参数。
struct TerminalCommand: Equatable, Sendable {
    let raw: String
    let executable: String
    let args: [String]

    /// Presentation only: keep the exact original command and parsed arguments
    /// for existing confirmation/execution identity, redact before bounding.
    var confirmationPreview: String {
        let safe = ContentSecretRedactor.redact(raw)
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ↵ ")
        return safe.count > 4096 ? String(safe.prefix(4095)) + "…" : safe
    }
}

/// 面板是一次性执行、无伪终端、无标准输入；需要交互终端的程序执行前给出提示，不启动进程。
enum TerminalInteractiveProgramHint {
    static func hint(for line: String) -> String? {
        var tokens = tokenize(line)
        while let first = tokens.first, isEnvAssignment(first) { tokens.removeFirst() }
        if tokens.first == "sudo" {
            tokens.removeFirst()
            while let first = tokens.first, first.hasPrefix("-") || isEnvAssignment(first) {
                tokens.removeFirst()
            }
        }
        guard let head = tokens.first else { return nil }
        let program = (head as NSString).lastPathComponent
        let args = Array(tokens.dropFirst())
        guard isInteractive(program: program, args: args) else { return nil }
        return "此面板暂不支持交互式程序（\(program)）。可改用一次性方式，如 claude -p \"问题\"；或在系统“终端”App 中运行。"
    }

    private static func isInteractive(program: String, args: [String]) -> Bool {
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let positional = args.filter { !$0.hasPrefix("-") }
        switch program {
        case "claude":
            return flags.isDisjoint(with: ["-p", "--print", "-v", "--version", "-h", "--help"])
        case "vim", "vi", "nvim", "nano", "top", "htop", "less", "more", "man", "tmux", "screen":
            return true
        case "emacs":
            return !flags.contains("--batch")
        case "ssh":
            let valued: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-E", "-e", "-m", "-O", "-S", "-w", "-W", "-B", "-I"]
            var count = 0
            var skipNext = false
            for arg in args {
                if skipNext { skipNext = false; continue }
                if arg.hasPrefix("-") {
                    if valued.contains(arg) { skipNext = true }
                } else {
                    count += 1
                }
            }
            return count < 2
        case "node", "irb", "ruby", "python", "python3":
            return positional.isEmpty && flags.isDisjoint(with: ["-c", "-e", "-m", "-p", "--eval", "--print", "-V", "--version", "-h", "--help"])
        case "mysql", "psql":
            return flags.isDisjoint(with: ["-e", "-c", "-f", "--execute", "--command", "--file"])
        case "sqlite3":
            return positional.count < 2
        default:
            if program.hasPrefix("python") {
                return isInteractive(program: "python", args: args)
            }
            return false
        }
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[..<eq]
        return !name.first!.isNumber && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// 命令分类（供白名单判定）。
enum TerminalCommandKind: Equatable, Sendable {
    /// 只读/安全命令，直接执行。
    case allowed
    /// 潜在破坏性命令，需用户确认。
    case confirmation
    /// 明确禁止的命令（弹窗/深链/系统管理类）。
    case denied
    /// 不在白名单内的未知命令。
    case unknown
}

/// 命令解析 + 白名单（纯逻辑，可单测）。
///
/// 安全策略：
/// - 只读/安全命令（ls/pwd/cat/grep…）直接执行；
/// - 写/网络/构建类命令（rm/cp/mv/git/curl…）需确认；
/// - 弹窗/深链/系统管理类（open/osascript/screencapture/shutdown/sudo…）一律拒绝；
/// - 未知命令按 unknown 处理。
enum TerminalGuard {
    /// 只读/安全命令：允许直接执行。
    static var allowedCommands: Set<String> { TerminalPolicySnapshot.defaultAutomaticAllowCommands }

    /// 写/网络/构建类命令：需用户确认。
    static var confirmationCommands: Set<String> { TerminalPolicySnapshot.defaultConfirmationCommands }

    /// 明确禁止的命令：弹窗/深链/系统管理/危险磁盘操作。
    static var deniedCommands: Set<String> { TerminalPolicySnapshot.productHardDeniedCommands }

    /// 把一行输入解析为命令。空行/纯空白返回 nil。
    static func parse(_ line: String) -> TerminalCommand? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = tokenize(trimmed)
        guard let first = tokens.first, !first.isEmpty else { return nil }
        return TerminalCommand(raw: trimmed, executable: first, args: Array(tokens.dropFirst()))
    }

    /// 简单词法切分：支持单引号/双引号/反斜杠转义，保留参数内部空格。
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch == " " && !inSingle && !inDouble {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// 分类命令（依据白名单）。executable 匹配失败归 unknown。
    ///
    /// S5（MC0-P1-09）：复合 shell 语法（分号/管道/重定向/命令替换/后台/分组/换行）
    /// 不得按首个可执行文件自动放行 —— 否则 `echo x > file`、`cat a | cmd`、
    /// `ls && sudo …` 会以允许前缀绕过白名单语义。复用 MinisCore 词法守卫判定
    /// 单命令合法性：不合法 → 串内含被禁可执行文件（如 sudo）直接拒绝，否则
    /// 必须用户显式确认整条命令（未确认前不产生任何副作用）。
    static func classify(
        _ command: TerminalCommand,
        policy: TerminalPolicySnapshot = .default
    ) -> TerminalCommandKind {
        switch policy.classify(command: command.raw) {
        case .allowed: return .allowed
        case .confirmation: return .confirmation
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }

    /// 分类一行输入（parse + classify 的便捷入口）。
    static func classify(
        _ line: String,
        policy: TerminalPolicySnapshot = .default
    ) -> (command: TerminalCommand?, kind: TerminalCommandKind) {
        guard let cmd = parse(line) else { return (nil, .unknown) }
        return (cmd, classify(cmd, policy: policy))
    }
}

// MARK: - 命令执行（Process + bash，非交互）

/// Immutable identity captured by the terminal tab before a command crosses
/// into the shared boundary.
struct TerminalContextSnapshot: Equatable, Hashable, Sendable {
    let sessionID: String
    let turnID: String
    let taskID: String
    let projectID: String
    let workdir: String

    var scopeID: String { projectID }

    @MainActor
    static func current(from chat: ChatStore) -> Self? {
        guard let sessionID = chat.activeSessionID,
              let session = chat.sessions.first(where: { $0.id == sessionID })
        else {
            return nil
        }
        // 没有项目目录的会话（普通会话）：用会话自己的工作目录，没有就用家目录，
        // 终端随处可用；有项目目录时仍按项目目录和项目身份。
        // 已绑定的项目目录即使消失也保持原路径（由启动决策提示，不静默回落家目录，
        // 也不因此结束原目录里在跑的终端）；只有没绑定时才用家目录。
        let projectID = normalized(session.projectID) ?? "session:\(sessionID.uuidString)"
        let workdir = TerminalPTYPlanner.resolveWorkdir(
            bound: session.workingDirectory, home: NSHomeDirectory())

        let execution = chat.executionSnapshot(forSessionID: sessionID)
        return Self(
            sessionID: sessionID.uuidString,
            turnID: execution?.turnID.map(String.init) ?? "terminal-turn:\(sessionID.uuidString)",
            taskID: execution?.taskID ?? "terminal-task:\(sessionID.uuidString)",
            projectID: projectID,
            workdir: workdir
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 常驻（挂在 ContentView 根上、与右栏是否显示无关）的终端生命周期观察者：
/// 会话被删除时结束该会话全部终端；“浏览器与终端副作用”开关关闭时立即结束所有终端。
/// 单独成视图，观察依赖不会让 ContentView 的 body 失效。
struct TerminalLifecycleObserver: View {
    let chat: ChatStore
    let settings: SettingsCenter?

    private var sideEffectsEnabled: Bool {
        settings?.safetyRuntimeSnapshot.isEnabled(.browserTerminalSideEffects) ?? true
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: chat.sessionIDsBySidebarRevision, initial: true) { _, ids in
                // 按会话身份清理：自动归档会话数先加后减，只看数量会漏清。
                TerminalPTYSessionOwner.shared.retain(sessionIDs: Set(ids.map(\.uuidString)))
            }
            .onChange(of: sideEffectsEnabled) { _, enabled in
                if !enabled { TerminalPTYSessionOwner.shared.retire() }
            }
    }
}

struct TerminalContextPanelAdapter {
    private let snapshot: TerminalContextSnapshot?
    private let boundary: TerminalBoundary?
    private let terminalSideEffectsEnabled: Bool?
    private let configuredPolicy: TerminalPolicy?
    private let configuredSnapshot: TerminalPolicySnapshot?
    private let commandTimeout: Duration

    init(
        snapshot: TerminalContextSnapshot? = nil,
        boundary: TerminalBoundary? = nil,
        policySnapshot: TerminalPolicySnapshot? = nil,
        commandTimeoutSeconds: Int = ShellCommandTimeoutPolicy.defaultSeconds
    ) {
        self.snapshot = snapshot
        self.boundary = boundary
        commandTimeout = .seconds(ShellCommandTimeoutPolicy.seconds(commandTimeoutSeconds))
        terminalSideEffectsEnabled = nil
        configuredPolicy = nil
        configuredSnapshot = policySnapshot
    }

    /// Capture MainActor-owned settings before the async/nonisolated adapter
    /// crosses into the Sendable TerminalBoundary.
    @MainActor
    init(
        snapshot: TerminalContextSnapshot? = nil,
        boundary: TerminalBoundary? = nil,
        settings: SettingsCenter?,
        policySnapshot: TerminalPolicySnapshot? = nil
    ) {
        self.snapshot = snapshot
        self.boundary = boundary
        commandTimeout = .seconds(ShellCommandTimeoutPolicy.seconds(
            settings?.shellCommandTimeoutSeconds ?? ShellCommandTimeoutPolicy.defaultSeconds))
        terminalSideEffectsEnabled = settings?.safetyRuntimeSnapshot
            .isEnabled(.browserTerminalSideEffects)
        let effectiveSnapshot = policySnapshot ?? settings?.terminalPolicySnapshot
        configuredSnapshot = effectiveSnapshot
        configuredPolicy = settings?.terminalPolicy(
            scopeID: snapshot?.scopeID ?? "",
            workdir: snapshot?.workdir ?? "/",
            snapshot: effectiveSnapshot
        )
    }

    func makeRequest(
        command: String,
        cwd: String,
        approved: Bool,
        approvalExpiresAt: Date? = nil
    ) -> TerminalExecutionRequest {
        let context = TerminalExecutionContext(
            sessionID: snapshot?.sessionID ?? "",
            turnID: snapshot?.turnID ?? "",
            taskID: snapshot?.taskID ?? "",
            projectID: snapshot?.projectID ?? "",
            workdir: cwd
        )
        let base = TerminalExecutionRequest(
            capabilityID: snapshot == nil
                || !(terminalSideEffectsEnabled ?? true)
                ? ""
                : "shell_execute",
            command: command,
            context: context,
            timeout: commandTimeout
        )
        let approval = approved
            ? TerminalApproval(
                scopeID: snapshot?.scopeID ?? "",
                requestFingerprint: base.requestFingerprint,
                expiresAt: approvalExpiresAt ?? Date().addingTimeInterval(60)
            )
            : nil
        return TerminalExecutionRequest(
            capabilityID: base.capabilityID,
            command: base.command,
            context: base.context,
            approval: approval,
            timeout: base.timeout
        )
    }

    func execute(
        command: String,
        cwd: String,
        approved: Bool
    ) async -> TerminalReceipt {
        await execute(makeRequest(command: command, cwd: cwd, approved: approved))
    }

    /// Returns the boundary owned by one visible-terminal invocation. Keeping
    /// this instance across execute/stop binds the stop action to one request.
    func makeOwnedBoundary() -> TerminalBoundary {
        boundary ?? makeBoundary()
    }

    func execute(
        _ request: TerminalExecutionRequest,
        using executionBoundary: TerminalBoundary? = nil
    ) async -> TerminalReceipt {
        await (executionBoundary ?? boundary ?? makeBoundary()).execute(request)
    }

    private func makeBoundary() -> TerminalBoundary {
        TerminalBoundary(
            policy: configuredPolicy ?? TerminalPolicy(
                scopeID: snapshot?.scopeID ?? "",
                allowedRoot: URL(fileURLWithPath: snapshot?.workdir ?? "/", isDirectory: true),
                snapshot: configuredSnapshot ?? .default
            )
        )
    }
}

/// 所有终端命令作为独立 /bin/bash -c 进程执行（非 PTY）。
/// 每次执行都在当前 cwd 下启动，cd 由 TerminalStore 本地跟踪。
enum TerminalExecutor {
    struct Result: Sendable {
        let output: String
        let exitCode: Int32
    }

    enum Error: Swift.Error, Equatable {
        case spawnFailed(String)
        case timeout
    }

    private actor ProcessWaiter {
        private var continuation: CheckedContinuation<Int32, Never>?
        private var pendingStatus: Int32?
        func register() async -> Int32 {
            await withCheckedContinuation { cont in
                if let status = pendingStatus {
                    pendingStatus = nil
                    cont.resume(returning: status)
                } else {
                    continuation = cont
                }
            }
        }
        func finish(_ status: Int32) {
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: status)
            } else {
                pendingStatus = status
            }
        }
    }

    private actor TimeoutFlag {
        private var fired = false
        func mark() { fired = true }
        func isFired() -> Bool { fired }
    }

    private final class ProcessBox: @unchecked Sendable { let process: Process; init(_ p: Process) { process = p } }
    private final class PipeBox: @unchecked Sendable { let pipe: Pipe; init(_ p: Pipe) { pipe = p } }

    /// 只有 bash 内建、无独立可执行文件的命令（`cd` 已在 TerminalStore 本地处理）。
    /// 这类命令没有 /usr/bin 二进制，直跑会报 "No such file"，必须走 bash。
    private static let bashOnlyCommands: Set<String> = ["history", "help", "type"]

    /// 决定启动方式：
    /// - 简单命令（无 shell 元字符、非 bash 内建）→ `/usr/bin/env <exe> <args>` 直跑。
    ///   env 通过 exec 变为目标进程、pid 不变，超时 terminate 直接命中命令本身，
    ///   管道必然关闭 —— 交互/常驻命令（python3 REPL、python3 -m http.server…）不会卡死终端。
    /// - 复合命令（管道/重定向/变量展开…）→ `/bin/bash -c`（保留 shell 语义）。
    private static func launchSpec(for command: TerminalCommand) -> (executable: String, arguments: [String]) {
        let shellMeta = "|&;<>()\u{60}$*?[]{}!#=~'\"\\"
        let needsShell = command.raw.contains { shellMeta.contains($0) }
            || bashOnlyCommands.contains(command.executable)
        if needsShell {
            return ("/bin/bash", ["-c", command.raw])
        }
        return ("/usr/bin/env", [command.executable] + command.args)
    }

    /// 有界等待：`op` 与 `grace` 秒宽限竞速，宽限先到返回 nil。
    /// 用于进程死后收管道：bash 路径的残留后代若持有管道写端，`readDataToEndOfFile`
    /// 会一直阻塞；这里保证调用方最迟 `grace` 秒后拿到结果，不会永久挂起
    /// （阻塞读任务随孤儿进程退出自然结束，绝不跨线程 close 读端句柄 —— 会 SIGABRT）。
    private static func awaitGrace<T: Sendable>(_ op: @escaping @Sendable () async -> T, grace: TimeInterval) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(for: .seconds(grace))
                return nil
            }
            // group.next() 返回 T??（元素是 T?，next 再包一层 Optional），?? nil 解包一层。
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 执行命令，返回合并输出 + 退出码。超时默认 30s。
    ///
    /// 超时兜底三级：SIGTERM（terminate）→ 2s 宽限 → SIGKILL（kill(pid) 兜底），
    /// 保证忽略 SIGTERM 的进程/后代最终被清掉；输出 drain 有界等待 3s，
    /// 防 bash 残留后代持管道导致 `isRunning` 永久卡死（终端「不能用」根因）。
    static func run(_ raw: String, cwd: String, timeout: TimeInterval = 30) async throws -> Result {
        // 空命令/纯空白：防御性直接返回（正常路径已被 TerminalStore.submit 拦截）。
        guard let command = TerminalGuard.parse(raw) else {
            return Result(output: "", exitCode: 0)
        }
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let spec = Self.launchSpec(for: command)
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = try ChildProcessEnvironment.values()
        let stdout = Pipe(); let stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let stdoutBox = PipeBox(stdout); let stderrBox = PipeBox(stderr)
        let processBox = ProcessBox(process)
        let waiter = ProcessWaiter(); let timeoutFlag = TimeoutFlag()

        process.terminationHandler = { p in Task { await waiter.finish(p.terminationStatus) } }
        do { try process.run() } catch {
            throw Error.spawnFailed(error.localizedDescription)
        }

        // 两管道并行 drain，防任一管道写满阻塞进程退出。
        let readStdout = Task.detached { stdoutBox.pipe.fileHandleForReading.readDataToEndOfFile() }
        let readStderr = Task.detached { stderrBox.pipe.fileHandleForReading.readDataToEndOfFile() }

        let timeoutTask = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard processBox.process.isRunning else { return }
            await timeoutFlag.mark()
            processBox.process.terminate()          // SIGTERM
            // SIGTERM 无效（进程忽略/后代持管道）时 2s 后 SIGKILL 兜底，保证管道最终关闭。
            try? await Task.sleep(for: .seconds(2))
            if processBox.process.isRunning {
                Darwin.kill(processBox.process.processIdentifier, SIGKILL)
            }
        }
        let status = await waiter.register()
        timeoutTask.cancel()

        // 有界收管道：进程死后最多再等 3s，防 shell 残留后代持管道永久挂起。
        async let outD: Data? = awaitGrace({ await readStdout.value }, grace: 3)
        async let errD: Data? = awaitGrace({ await readStderr.value }, grace: 3)
        let outData = await outD ?? Data()
        let errData = await errD ?? Data()

        if await timeoutFlag.isFired() { throw Error.timeout }
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return Result(output: out.isEmpty ? err : (out + (err.isEmpty ? "" : "\n" + err)), exitCode: status)
    }
}

extension TerminalExecutor.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .spawnFailed(let reason):
            return "进程启动失败：\(reason)"
        case .timeout:
            return "命令超时，已终止（输出可能不完整）"
        }
    }
}

// MARK: - 终端状态（@MainActor）

/// Owns the last terminal boundary for the lifetime cleanup path. The holder
/// is immutable from the `@MainActor` store's point of view, so `deinit` can
/// stop the current process without reaching into an actor-isolated field.
private final class TerminalStoreBoundaryCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var boundary: TerminalBoundary?
    private var executionTask: Task<Void, Never>?

    func install(_ boundary: TerminalBoundary?) {
        lock.lock()
        self.boundary = boundary
        lock.unlock()
    }

    func installExecutionTask(_ task: Task<Void, Never>) {
        lock.lock()
        executionTask = task
        lock.unlock()
    }

    func clear() {
        lock.lock()
        boundary = nil
        executionTask = nil
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let boundary = self.boundary
        let executionTask = self.executionTask
        self.boundary = nil
        self.executionTask = nil
        lock.unlock()
        // Cancellation fences the queued-before-Core-install window. Never
        // call cancellation or the boundary while holding the holder lock.
        executionTask?.cancel()
        boundary?.stop()
    }
}

@MainActor
@Observable
final class TerminalStore {
    private let contextSnapshot: TerminalContextSnapshot?
    private let settings: SettingsCenter?
    nonisolated private let boundaryCleanup = TerminalStoreBoundaryCleanup()
    private var activeBoundary: TerminalBoundary?
    private var activeInvocationID: UUID?
    private var activeExecutionTask: Task<Void, Never>?
    private var policySnapshot: TerminalPolicySnapshot
    static let maximumOutputCharacters = 200_000
    static let truncatedOutputNotice = "（较早输出已截断，仅保留最近 20 万字符）\n"
    static let missingWorkingDirectoryMessage = "请先为当前会话绑定项目工作目录，再使用终端。"
    var hasWorkingDirectory: Bool { !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Bound the shared prompt/receipt history, retaining the newest characters.
    var output: String = "" {
        didSet {
            if output.count > Self.maximumOutputCharacters {
                let retained = Self.maximumOutputCharacters - Self.truncatedOutputNotice.count
                output = Self.truncatedOutputNotice + String(output.suffix(retained))
            }
        }
    }
    /// 当前输入行。
    var input: String = ""
    /// 当前工作目录（cd 记录在本地，不落盘）；空值表示没有项目绑定。
    var cwd: String = ""
    /// The original boundary object is retained only for the exact safe pwd
    /// request. A later command clears it so export cannot reuse stale proof.
    private(set) var lastPwdReceipt: TerminalReceipt?
    var pwdReceiptJSON: String? {
        guard let lastPwdReceipt,
              let data = try? JSONEncoder().encode(lastPwdReceipt) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// 是否有命令在跑。
    var isRunning = false
    /// 待用户确认的潜在破坏性命令（nil = 无待确认项）。
    var pendingConfirmation: TerminalCommand?
    private(set) var pendingConfirmationKind: TerminalCommandKind?

    init(
        contextSnapshot: TerminalContextSnapshot? = nil,
        settings: SettingsCenter? = nil
    ) {
        self.contextSnapshot = contextSnapshot
        self.settings = settings
        self.policySnapshot = settings?.terminalPolicySnapshot ?? .default
        cwd = contextSnapshot?.workdir ?? ""
    }

    deinit {
        boundaryCleanup.stop()
    }

    /// 追加一行提示符 + 回显。
    private func prompt(_ cmd: String) {
        // A receipt is already redacted, but the command echo reaches the same
        // visible history first. Preserve the raw command for execution and
        // approval identity; redact only this presentation.
        let promptLocation = cwd.isEmpty ? "未绑定项目" : cwd
        output += "\(promptLocation) $ \(ContentSecretRedactor.redact(cmd))\n"
    }

    /// 追加输出文本。
    func append(_ text: String) {
        output += text
        if !text.hasSuffix("\n") { output += "\n" }
    }

    /// 提交当前输入行。
    func submit() {
        let line = input
        input = ""
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard hasWorkingDirectory else {
            prompt(line)
            append(Self.missingWorkingDirectoryMessage)
            return
        }
        lastPwdReceipt = nil
        policySnapshot = settings?.terminalPolicySnapshot ?? policySnapshot
        let requestPolicySnapshot = policySnapshot
        let (command, kind) = TerminalGuard.classify(line, policy: requestPolicySnapshot)

        guard let command else {
            prompt(line)
            append("错误：无法解析该命令")
            return
        }

        if kind != .denied, let hint = TerminalInteractiveProgramHint.hint(for: line) {
            prompt(line)
            append(hint)
            return
        }

        switch kind {
        case .allowed:
            prompt(line)
            if command.executable == "cd" {
                handleCD(command)
            } else {
                run(command)
            }
        case .confirmation, .unknown:
            // 两类保留不同显示状态，但仍共用原批准后执行边界。
            // 危险命令：确认条先显示命令文本；**确认后才回显并执行**（取消 = 不留任何执行痕迹，
            // TerminalGuard 测试「确认条取消后不执行」锁定——输入即回显会污染取消语义）。
            pendingConfirmationKind = kind
            pendingConfirmation = command
        case .denied:
            prompt(line)
            append("⛔ 命令被拒绝：\(command.executable) 不在允许范围（弹窗/深链/系统管理类禁止）")
        }
    }

    /// 处理 cd（本地切换 cwd，不启动子进程）。
    private func handleCD(_ command: TerminalCommand) {
        let target = command.args.first ?? "~"
        let expanded = (target as NSString).expandingTildeInPath
        let resolved = expanded.hasPrefix("/")
            ? expanded
            : cwd + "/" + expanded
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            append("cd: 目录不存在：\(target)")
            return
        }
        let policy = settings?.terminalPolicy(
            scopeID: contextSnapshot?.scopeID ?? "",
            workdir: contextSnapshot?.workdir ?? "/",
            snapshot: policySnapshot
        ) ?? TerminalPolicy(
            scopeID: contextSnapshot?.scopeID ?? "",
            allowedRoot: URL(fileURLWithPath: contextSnapshot?.workdir ?? "/", isDirectory: true),
            snapshot: policySnapshot
        )
        guard policy.allowsWorkingDirectory(resolved) else {
            append("cd: 路径超出允许范围：\(target)")
            return
        }
        cwd = (resolved as NSString).standardizingPath
        append("")
    }

    /// 执行命令（异步，非交互）。
    func run(_ command: TerminalCommand, approved: Bool = false) {
        // Cancel the consumer task before stopping the boundary. This closes the
        // pre-install race where stop() arrives after submit() but before the
        // async boundary has installed its invocation control.
        activeExecutionTask?.cancel()
        activeBoundary?.stop()
        lastPwdReceipt = nil
        isRunning = true
        pendingConfirmation = nil
        pendingConfirmationKind = nil
        let cwdCapture = cwd
        let raw = command.raw
        let invocationID = UUID()
        activeInvocationID = invocationID
        let requestPolicySnapshot = policySnapshot
        let adapter = TerminalContextPanelAdapter(
            snapshot: contextSnapshot,
            settings: settings,
            policySnapshot: requestPolicySnapshot
        )
        let invocationBoundary = adapter.makeOwnedBoundary()
        activeBoundary = invocationBoundary
        boundaryCleanup.install(invocationBoundary)
        let request = adapter.makeRequest(
            command: raw,
            cwd: cwdCapture,
            approved: approved
        )
        activeExecutionTask = Task { @MainActor [weak self] in
            let receipt = await adapter.execute(
                request,
                using: invocationBoundary
            )
            guard let self, self.activeInvocationID == invocationID else {
                // A completed old request may arrive after a new request was
                // accepted; it must not mutate the new terminal session.
                return
            }
            // This is the exact structured object returned by the production
            // boundary, never a reconstruction from AX or terminal text.
            lastPwdReceipt = self.contextSnapshot != nil
                && receipt.command == "pwd"
                && receipt.error == nil
                && receipt.exitCode != nil ? receipt : nil
            if !receipt.output.isEmpty {
                append(receipt.output)
            }
            if let error = receipt.error {
                let message = TerminalBoundaryError(rawValue: error)?.actionableMessage ?? error
                append("错误：\(message)")
            } else if let exitCode = receipt.exitCode {
                append("（退出码 \(exitCode)）")
            }
            isRunning = false
            activeBoundary = nil
            boundaryCleanup.clear()
            activeInvocationID = nil
            activeExecutionTask = nil
        }
        if let activeExecutionTask {
            boundaryCleanup.installExecutionTask(activeExecutionTask)
        }
    }

    /// Stops the currently owned invocation; repeated taps are intentionally
    /// harmless and do not affect a later invocation.
    func stop() {
        guard isRunning else { return }
        // Task cancellation covers the window before TerminalBoundary has
        // installed its invocation control; the boundary stop handles the
        // already-installed case and preserves the receipt identity fence.
        activeExecutionTask?.cancel()
        activeBoundary?.stop()
    }

    /// 用户确认执行待确认命令（确认后才回显命令，与 submit 的「确认前不回显」配对）。
    func confirmPending() {
        guard let command = pendingConfirmation else { return }
        pendingConfirmation = nil
        pendingConfirmationKind = nil
        prompt(command.raw)
        run(command, approved: true)
    }

    /// 用户取消待确认命令。
    func cancelPending() {
        pendingConfirmation = nil
        pendingConfirmationKind = nil
    }
}

/// 终端 tab：持久登录 shell + PTY（SwiftTerm），与 Claude Code 桌面版终端面板对齐。
/// 用户亲手敲的命令不再逐条审批；“浏览器与终端副作用”安全开关关闭时不启动 shell。
/// 旧的一次性命令执行路径（TerminalStore/TerminalGuard/TerminalExecutor）保留给
/// 既有测试与模型工具边界，本面板不再使用。
struct TerminalTabView: View {
    /// The terminal's action row uses the same allocation policy as the
    /// adjacent confirmation row and browser toolbar at the actual pane width.
    static var inputRowLayout: AdaptiveControlRowLayout { AdaptiveControlRowLayout(spacing: 6) }

    let contextSnapshot: TerminalContextSnapshot?
    let settings: SettingsCenter?
    private let externalOwner: TerminalPTYSessionOwner?
    @State private var localOwner = TerminalPTYSessionOwner()
    @State private var session: TerminalPTYSession?
    @State private var tabItems: [TerminalPTYTabItem] = []
    @State private var selectedTabNumber: Int?
    @State private var canAddTab = false
    @State private var hasActivated = false
    @State private var blockReason: TerminalPTYBlockReason?

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    init(
        contextSnapshot: TerminalContextSnapshot? = nil,
        settings: SettingsCenter? = nil,
        owner: TerminalPTYSessionOwner? = nil
    ) {
        self.contextSnapshot = contextSnapshot
        self.settings = settings
        self.externalOwner = owner
    }

    private var owner: TerminalPTYSessionOwner { externalOwner ?? localOwner }

    private var sideEffectsEnabled: Bool {
        settings?.safetyRuntimeSnapshot.isEnabled(.browserTerminalSideEffects) ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                if let blockReason {
                    Text(blockReason.message)
                        .font(typography?.caption ?? .system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("terminal.blocked.notice")
                }
                tabBar
                toolbar(session)
                Divider()
                TerminalPTYHostView(
                    session: session,
                    foreground: NSColor(theme?.textPrimary ?? Color(nsColor: .textColor)),
                    background: NSColor(theme?.aj38.backgroundSecondary.swiftUIColor
                        ?? Color(nsColor: .textBackgroundColor)),
                    caret: NSColor(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                )
                .id(ObjectIdentifier(session))
                .accessibilityIdentifier("terminal.pty.host")
                if case .exited(let code) = session.lifecycle.phase {
                    statusBar(
                        text: code.map { "shell 已退出（退出码 \($0)）" } ?? "shell 已退出",
                        session: session
                    )
                } else if case .failed(let message) = session.lifecycle.phase {
                    statusBar(text: message, session: session)
                }
            } else if let blockReason {
                Text(blockReason.message)
                    .font(typography?.caption ?? .system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(12)
                    .accessibilityIdentifier("terminal.blocked")
            } else if hasActivated {
                VStack(spacing: 8) {
                    Text("没有打开的终端")
                        .font(typography?.caption ?? .system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("新建终端") { addTerminal() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("terminal.pty.new")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .accessibilityIdentifier("terminal.pty.empty")
            }
        }
        .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor))
        .onAppear { activate() }
        .onChange(of: sideEffectsEnabled) { _, _ in activate() }
        .onDisappear {
            // 由面板持有者管理时切 tab 不结束 shell；独立使用时随视图结束。
            if externalOwner == nil { localOwner.retire() }
        }
    }

    // MARK: 启动

    private func launchDecision() -> TerminalPTYDecision {
        let environment = ProcessInfo.processInfo.environment
        return TerminalPTYPlanner.decide(
            workdir: contextSnapshot?.workdir,
            sideEffectsEnabled: sideEffectsEnabled,
            shellCandidates: [Self.passwdShell(), environment["SHELL"]],
            baseEnvironment: environment,
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    private func activate() {
        switch launchDecision() {
        case .blocked(let reason):
            applyBlocked(reason)
        case .launch(let plan):
            guard let snapshot = contextSnapshot else { return }
            blockReason = nil
            owner.acquire(
                identity: TerminalPTYIdentity(sessionID: snapshot.sessionID, workdir: snapshot.workdir),
                plan: plan
            )
            hasActivated = true
            refreshTabs()
        }
    }

    /// 启动被拦截：安全开关关闭才结束全部终端；目录不可用只提示，已在跑的终端保持原样。
    private func applyBlocked(_ reason: TerminalPTYBlockReason) {
        if reason.retiresAllTerminals {
            owner.retire()
        } else if let snapshot = contextSnapshot {
            owner.activateExisting(
                identity: TerminalPTYIdentity(sessionID: snapshot.sessionID, workdir: snapshot.workdir))
        }
        blockReason = reason
        refreshTabs()
    }

    /// 从持有者同步标签条状态（只在用户动作和激活时调用，不在 body 里算）。
    private func refreshTabs() {
        tabItems = owner.tabItems
        selectedTabNumber = owner.selectedTabNumber
        canAddTab = owner.canAddTab
        session = owner.session
    }

    private func addTerminal() {
        switch launchDecision() {
        case .blocked(let reason):
            applyBlocked(reason)
        case .launch(let plan):
            guard let snapshot = contextSnapshot else { return }
            blockReason = nil
            owner.addTab(
                identity: TerminalPTYIdentity(sessionID: snapshot.sessionID, workdir: snapshot.workdir),
                plan: plan
            )
            refreshTabs()
        }
    }

    private func closeTerminal(_ number: Int) {
        owner.closeTab(number)
        refreshTabs()
    }

    private func selectTerminal(_ number: Int) {
        owner.selectTab(number)
        refreshTabs()
    }

    private static func passwdShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    // MARK: 工具条与状态条

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabItems) { item in
                        let isSelected = item.number == selectedTabNumber
                        HStack(spacing: 2) {
                            Button { selectTerminal(item.number) } label: {
                                Text(item.displayTitle)
                                    .font(typography?.caption ?? .system(size: 10))
                                    .lineLimit(1)
                                    .frame(maxWidth: 140)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("终端 \(item.number)")
                            .accessibilityIdentifier("terminal.pty.tab.\(item.number)")
                            Button { closeTerminal(item.number) } label: {
                                MinisIconView(.close, size: 10)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("关闭这个终端")
                            .accessibilityLabel("关闭终端 \(item.number)")
                            .accessibilityIdentifier("terminal.pty.close")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
            Button { addTerminal() } label: {
                MinisIconView(.add, size: 12)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!canAddTab)
            .help(canAddTab ? "新建终端" : "最多同时打开 \(TerminalPTYTabList.maxTabs) 个终端，请先关闭一个")
            .accessibilityLabel("新建终端")
            .accessibilityIdentifier("terminal.pty.new")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func toolbar(_ session: TerminalPTYSession) -> some View {
        Self.inputRowLayout {
            Text(session.title.isEmpty ? "终端" : session.title)
                .font(typography?.caption ?? .system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("终端尺寸 \(session.size.label)")
            Spacer()
            Button("A−") { session.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("缩小终端字号（⌘-）")
                .accessibilityLabel("缩小终端字号")
            Button("A+") { session.adjustFontSize(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("放大终端字号（⌘+）")
                .accessibilityLabel("放大终端字号")
            Button("清屏") { session.clearScreen() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("terminal.pty.clear")
            Button("复制") { session.copySelection() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("terminal.pty.copy")
            Button("粘贴") { session.pasteFromClipboard() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("terminal.pty.paste")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func statusBar(text: String, session: TerminalPTYSession) -> some View {
        AdaptiveControlRowLayout(spacing: 6) {
            Text(text)
                .font(typography?.caption ?? .system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("重新启动") { session.restart() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("terminal.pty.restart")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityIdentifier("terminal.pty.status")
    }
}

// MARK: - 浏览器 tab：WKWebView 实现（AJ-34）

/// 浏览器 URL 校验：把用户输入规范化为可加载 URL，只放行 http/https
/// （拒绝 file://、javascript: 等协议以及无主机名的输入）。
enum BrowserURLValidator {
    /// 规范化并校验用户输入；非法或非 http(s) 返回 `nil`。
    static func validatedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 无显式 scheme 时默认补 https://（避免裸域名被当作相对路径）。
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { return nil }
        guard BrowserNavigationPolicy.isValidWebURL(url) else { return nil }
        return url
    }
}

/// Browser-only navigation state. The request id is deliberately owned by
/// the consumer so an old WebKit completion can never publish over a newer
/// address-bar request.
enum BrowserNavigationFailure: Equatable {
    case invalidInput(rawInput: String)
    case failed(target: URL, message: String)
    case cancelled(target: URL)

    var title: String {
        switch self {
        case .invalidInput:
            return "网址未加载"
        case .failed:
            return "网页加载失败"
        case .cancelled:
            return "已取消加载"
        }
    }

    var message: String {
        switch self {
        case .invalidInput(let rawInput):
            let shownInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayInput = shownInput.isEmpty ? "（空输入）" : shownInput
            return "已拒绝“\(displayInput)”：仅支持 http/https 网址，未执行导航。"
        case .failed(_, let message):
            return "\(message)。请检查地址或网络后重试。"
        case .cancelled(let target):
            return "已取消前往 \(target.absoluteString)。"
        }
    }

    var retryURL: URL? {
        switch self {
        case .invalidInput:
            return nil
        case .failed(let target, _), .cancelled(let target):
            return target
        }
    }
}

enum BrowserNavigationPhase: Equatable {
    case idle
    case loading(target: URL, previousURL: URL?)
    case success(URL)
    case failure(BrowserNavigationFailure, previousURL: URL?)
}

enum BrowserNavigationAction: Equatable {
    case none
    case navigate(requestID: UInt64, url: URL)
    case revisit(requestID: UInt64, url: URL)
    case fieldFixture(requestID: UInt64, url: URL)
}

enum BrowserNavigationCompletion: Equatable {
    case success
    case failure(String)
}

/// Small production-consumer state machine used by `BrowserTabView` and its
/// deterministic fixtures. It owns request identity, so cancellation and
/// out-of-order completions are handled at the UI seam without changing the
/// shared `BrowserSession` contract.
struct BrowserNavigationState: Equatable {
    private(set) var requestID: UInt64 = 0
    private(set) var phase: BrowserNavigationPhase = .idle
    private(set) var lastSuccessfulURL: URL?
    private(set) var pendingAction: BrowserNavigationAction = .none

    /// Showing the ordinary tab is not address-bar authorization. Only the
    /// explicitly gated package-field fixture may enqueue its fixed local page.
    mutating func activate(fieldInitialURL: URL?) -> BrowserNavigationAction {
        guard fieldInitialURL == BrowserLocalPackageFieldFixture.localURL,
              let fieldInitialURL else { return .none }
        return start(validatedURL: fieldInitialURL, action: BrowserNavigationAction.fieldFixture)
    }

    mutating func restore(_ url: URL) {
        guard BrowserNavigationPolicy.isValidWebURL(url) else { return }
        _ = start(validatedURL: url, action: BrowserNavigationAction.revisit)
    }

    mutating func start(rawInput: String) -> BrowserNavigationAction {
        guard let url = BrowserURLValidator.validatedURL(from: rawInput) else {
            requestID &+= 1
            pendingAction = .none
            phase = .failure(.invalidInput(rawInput: rawInput), previousURL: lastSuccessfulURL)
            return .none
        }
        return start(validatedURL: url, action: BrowserNavigationAction.navigate)
    }

    mutating func retry() -> BrowserNavigationAction {
        switch phase {
        case .failure(let failure, _):
            guard let url = failure.retryURL else { return .none }
            return start(validatedURL: url, action: BrowserNavigationAction.revisit)
        case .idle, .loading, .success:
            return .none
        }
    }

    @discardableResult
    mutating func complete(
        requestID: UInt64,
        target: URL,
        result: BrowserNavigationCompletion
    ) -> Bool {
        guard self.requestID == requestID,
              case .loading(let expectedTarget, _) = phase,
              expectedTarget == target else {
            return false
        }

        pendingAction = .none
        switch result {
        case .success:
            lastSuccessfulURL = target
            phase = .success(target)
        case .failure(let message):
            phase = .failure(.failed(target: target, message: message), previousURL: lastSuccessfulURL)
        }
        return true
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard case .loading(let target, _) = phase else { return false }
        requestID &+= 1
        pendingAction = .none
        phase = .failure(.cancelled(target: target), previousURL: lastSuccessfulURL)
        return true
    }

    /// Called when the tab closes so a completion from a detached WebKit task
    /// cannot publish after the view is gone.
    mutating func invalidate() {
        requestID &+= 1
        pendingAction = .none
        phase = .idle
    }

    private mutating func start(
        validatedURL url: URL,
        action: (UInt64, URL) -> BrowserNavigationAction
    ) -> BrowserNavigationAction {
        requestID &+= 1
        phase = .loading(target: url, previousURL: lastSuccessfulURL)
        pendingAction = action(requestID, url)
        return pendingAction
    }
}

/// The address consumer's existing authorization/dispatch boundary. Keeping
/// the no-request path here lets state tests observe effects without WebKit.
enum BrowserAddressNavigation {
    @MainActor
    static func dispatch(
        _ action: BrowserNavigationAction,
        authorize: @MainActor (URL) -> Bool,
        navigate: @MainActor (URL) async throws -> Void
    ) async throws {
        switch action {
        case .none:
            return
        case .navigate(_, let target), .fieldFixture(_, let target):
            guard authorize(target) else {
                throw BrowserError.navigationDenied(.domainNotAuthorized)
            }
            try await navigate(target)
        case .revisit(_, let target):
            try await navigate(target)
        }
    }
}

/// 浏览器 tab：内嵌 WKWebView（复用 MinisCore `BrowserSession` 的 webView），
/// 提供地址栏 + 前进/后退/刷新；仅允许 http/https 协议。
enum UserBrowserAddressAction {
    static func allowedURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

struct BrowserTabView: View {
    private let settings: SettingsCenter?
    /// P3-BROWSER-01（A/B 会话隔离）：拥有本浏览器面板的会话标识。
    /// 来源是 `ChatStore.activeSessionID` —— `ChatThread.id` 为 `let UUID`，
    /// 面板折叠/重开不重建 ChatStore，因此同一对话跨重开稳定、跨对话互异。
    /// 该值只在视图构造时捕获；父面板用会话 + 工作区身份重建子视图，
    /// 并在身份变化时退休旧 BrowserSession。
    private let conversationSessionID: UUID?
    /// The owning ChatStore mints this stable workspace identity; browser input cannot choose it.
    private let workspaceID: String
    private let lifecycleOwner: BrowserTabSessionOwner?
    @State private var session: BrowserSession?
    /// Mirrors the current WebKit identity so SwiftUI recreates the embedded
    /// NSView after an idle reclaim/reopen swaps the resource.
    @State private var sessionResourceGeneration: UInt64 = 0
    @State private var addressText = ""
    private enum NavigationAction { case address, back, forward, reload }
    @State private var navigationAction = NavigationAction.address
    @State private var navigationState = BrowserNavigationState()
    @Environment(\.typographyTokens) private var typography

    @Environment(\.browserFieldInitialURL) private var browserFieldInitialURL

    init(
        settings: SettingsCenter? = nil,
        conversationSessionID: UUID? = nil,
        workspaceID: String = "",
        lifecycleOwner: BrowserTabSessionOwner? = nil
    ) {
        self.settings = settings
        self.conversationSessionID = conversationSessionID
        self.workspaceID = workspaceID
        self.lifecycleOwner = lifecycleOwner
    }

    /// The user-side data store is keyed by the trusted surface, profile,
    /// conversation and owning ChatStore workspace. Missing identity stays
    /// ephemeral and cannot inherit a shared login or browser authorization.
    static func userBrowserScope(
        for conversationSessionID: UUID?,
        workspaceID: String
    ) -> BrowserSessionScope {
        guard let conversationSessionID,
              !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .ephemeral() }
        return BrowserSessionScope(
            surface: .userBrowser,
            profile: "production",
            session: conversationSessionID.uuidString,
            workspace: workspaceID
        )
    }

    private var effectiveBrowserSettings: BrowserSettings {
        settings?.effectiveBrowserSettings ?? .default
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let session {
                ZStack(alignment: .top) {
                    BrowserViewportContent(
                        session: session,
                        settings: effectiveBrowserSettings
                    )
                        .id(sessionResourceGeneration)
                    browserOverlay
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let ownerIdentity = BrowserPaneOwnerIdentity(
                sessionID: conversationSessionID,
                workspaceID: workspaceID
            )
            lifecycleOwner?.retire(ifDifferentFrom: ownerIdentity)
            let retained = lifecycleOwner?.currentResource(for: ownerIdentity) as? BrowserSession
            let expectedScope = Self.userBrowserScope(
                for: conversationSessionID, workspaceID: workspaceID
            )
            if let existing = retained ?? session,
               existing.scope == expectedScope,
               existing.resourceState != .closed {
                session = existing
                existing.setUserVisible(true)
                _ = existing.reopenResource()
                sessionResourceGeneration = existing.resourceGeneration
                if case .idle = navigationState.phase,
                   let lastURL = existing.lastKnownURL {
                    addressText = lastURL.absoluteString
                    navigationAction = .address
                    navigationState.restore(lastURL)
                }
                return
            }
            if lifecycleOwner == nil { session?.close() }
            let browserSettings = effectiveBrowserSettings
            let s = BrowserSession(
                frame: BrowserSession.defaultViewport,
                userAgent: browserSettings.resolvedUserAgent(),
                scope: expectedScope,
                idleTimeoutMinutes: browserSettings.idleTabTimeoutMinutes
            )
            s.apply(settings: browserSettings)
            s.setUserVisible(true)
            lifecycleOwner?.retain(s, for: ownerIdentity)
            session = s
            sessionResourceGeneration = s.resourceGeneration
            addressText = ""
            if case .fieldFixture(_, let initialURL) = navigationState.activate(
                fieldInitialURL: browserFieldInitialURL
            ) {
                addressText = initialURL.absoluteString
            }
        }
        .onChange(of: settings?.effectiveBrowserSettings) { _, newSettings in
            guard let session, let newSettings else { return }
            session.apply(settings: newSettings)
            sessionResourceGeneration = session.resourceGeneration
        }
        .onDisappear {
            navigationState.invalidate()
            if let lifecycleOwner, let session {
                lifecycleOwner.hide(session)
            } else {
                session?.close()
            }
        }
        .task(id: navigationState.requestID) {
            await runNavigationIfNeeded()
        }
    }

    @ViewBuilder
    private var browserOverlay: some View {
        switch navigationState.phase {
        case .failure(let failure, let previousURL):
            BrowserErrorView(
                failure: failure,
                previousURL: previousURL,
                onRetry: retryNavigation
            )
        case .loading(let target, _):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载 \(target.absoluteString)")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("取消") { cancelNavigation() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("取消网页加载")
            }
            .font(typography?.caption ?? .system(size: 11))
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        case .idle, .success:
            EmptyView()
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        AdaptiveControlRowLayout(spacing: 6) {
            Button {
                startHistoryNavigation(.back, target: session?.webView.backForwardList.backItem?.url)
            } label: {
                MinisIconView(.caretLeft, size: 12)
            }
            .disabled(isNavigationLoading || session?.webView.canGoBack != true)
            .help("后退")
            .accessibilityLabel("浏览器后退")
            .accessibilityHint("返回上一页")

            Button {
                startHistoryNavigation(.forward, target: session?.webView.backForwardList.forwardItem?.url)
            } label: {
                MinisIconView(.caretRight, size: 12)
            }
            .disabled(isNavigationLoading || session?.webView.canGoForward != true)
            .help("前进")
            .accessibilityLabel("浏览器前进")
            .accessibilityHint("前往下一页")

            Button {
                startHistoryNavigation(.reload, target: session?.currentURL())
            } label: {
                MinisIconView(.refresh, size: 12)
            }
            .help("刷新")
            .accessibilityLabel("刷新页面")
            .accessibilityHint("重新加载当前网页")

            Button {
                guard let url = UserBrowserAddressAction.allowedURL(session?.currentURL()) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                MinisIconView(.globe, size: 14)
            }
            .disabled(UserBrowserAddressAction.allowedURL(session?.currentURL()) == nil)
            .help("在默认浏览器中打开")
            .accessibilityLabel("在默认浏览器中打开")
            .accessibilityIdentifier("browser.user.open-external")

            Button {
                guard let url = UserBrowserAddressAction.allowedURL(session?.currentURL()) else { return }
                copyTextToClipboard(url.absoluteString)
            } label: {
                MinisIconView(.copy, size: 14)
            }
            .disabled(UserBrowserAddressAction.allowedURL(session?.currentURL()) == nil)
            .help("复制当前网页地址")
            .accessibilityLabel("复制当前网页地址")
            .accessibilityIdentifier("browser.user.copy-address")

            TextField("输入网址（仅 http/https）", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .font(typography?.contextBody ?? .system(size: 11))
                .onSubmit { load(addressText) }

            Button {
                load(addressText)
            } label: {
                MinisIconView(.next, size: 18)
            }
            .disabled(isNavigationLoading)
            .help("前往")
            .accessibilityLabel("前往网址")
            .accessibilityHint("加载输入的网址")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: 加载

    private func startHistoryNavigation(_ action: NavigationAction, target: URL?) {
        guard let target else { return }
        load(target.absoluteString)
        navigationAction = action
    }

    private func load(_ raw: String) {
        session?.recordActivity()
        navigationAction = .address
        switch navigationState.start(rawInput: raw) {
        case .none:
            addressText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        case .navigate(_, let url), .revisit(_, let url), .fieldFixture(_, let url):
            addressText = url.absoluteString
        }
    }

    private var isNavigationLoading: Bool {
        if case .loading = navigationState.phase { return true }
        return false
    }

    @MainActor
    private func runNavigationIfNeeded() async {
        guard !Task.isCancelled, let session,
              case .loading(let target, _) = navigationState.phase else { return }
        let requestID = navigationState.requestID
        let addressAction = navigationState.pendingAction

        let lease: BrowserSessionOperationLease
        do {
            lease = try session.acquireOperationLease()
            sessionResourceGeneration = session.resourceGeneration
        } catch {
            guard !Task.isCancelled else { return }
            let message = UserFacingErrorText.describe(error)
            _ = navigationState.complete(
                requestID: requestID,
                target: target,
                result: .failure(message)
            )
            return
        }
        defer { session.releaseOperationLease(lease) }

        do {
            switch navigationAction {
            case .address:
                // The action preserves whether this request is a fresh address
                // submission or a revisit using the existing session policy.
                try await BrowserAddressNavigation.dispatch(
                    addressAction,
                    authorize: { session.authorizeNavigation(to: $0) },
                    navigate: { try await session.navigate(to: $0) }
                )
            case .back: _ = try await session.goBack()
            case .forward: _ = try await session.goForward()
            case .reload: try await session.reload()
            }
            guard !Task.isCancelled else { return }
            _ = navigationState.complete(
                requestID: requestID,
                target: target,
                result: .success
            )
        } catch {
            guard !Task.isCancelled else { return }
            let message = UserFacingErrorText.describe(error)
            _ = navigationState.complete(
                requestID: requestID,
                target: target,
                result: .failure(message)
            )
        }
    }

    private func retryNavigation() {
        navigationAction = .address
        guard case .revisit(_, let url) = navigationState.retry() else { return }
        addressText = url.absoluteString
    }

    private func cancelNavigation() {
        _ = navigationState.cancel()
        session?.recordActivity()
        session?.cancelNavigation()
    }
}

/// The right panel keeps its own width; the page uses the browser's saved
/// viewport. Otherwise SwiftUI resizes the WKWebView to the panel width and
/// `window.innerWidth` silently diverges from BrowserSettings.
struct BrowserViewportContent: View {
    let session: BrowserSession
    let settings: BrowserSettings

    var body: some View {
        let viewport = settings.resolvedViewport()
        ScrollView([.horizontal, .vertical]) {
            WebViewRepresentable(session: session)
                .frame(width: CGFloat(viewport.width), height: CGFloat(viewport.height))
        }
    }
}

/// NSViewRepresentable 包装：把 `BrowserSession` 持有的 WKWebView 嵌入 SwiftUI。
private struct WebViewRepresentable: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 浏览器加载失败 / URL 被拒时的提示视图。
private struct BrowserErrorView: View {
    let failure: BrowserNavigationFailure
    let previousURL: URL?
    let onRetry: () -> Void

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(spacing: 8) {
            MinisIconView(.warning, size: 12)
                .foregroundPalette(theme?.statusWarning ?? .orange)
                .font(.system(size: 24))
            Text(failure.title)
                .font((typography?.caption ?? .system(size: 11)).weight(.semibold))
                .foregroundStyle(.primary)
            Text(failure.message)
                .font(typography?.caption ?? .system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let previousURL {
                Text("上次成功加载：\(previousURL.absoluteString)")
                    .font(typography?.caption ?? .system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if failure.retryURL != nil {
                Button("重试") { onRetry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("重试网页加载")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

/// 通用占位视图：居中图标 + 说明。
private struct PlaceholderTabView: View {
    let icon: String
    let title: String
    let hint: String
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title)
                .font((typography?.body ?? .system(size: 12)).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(typography?.caption ?? .system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}
