import SwiftUI
import AppKit
import MinisCore

// MARK: - E14 左栏：会话侧栏（Codex 风格，紧凑列表，可折叠）
//
// 左栏 = 会话列表（图标 + 标题 + 时间），collapsed 时整个面板 0 宽完全隐藏
// （F5-ui：不再留 56px 图标栏，由 ContentView 侧 frame 收 0 实现）；
// collapsedRail 折叠窄栏代码保留备用，当前不再显示；
// 聊天主区（消息流 + 输入区）见下方 ChatMainView。

// MARK: - P3-SESSION-02 全局置顶区投影（纯函数；视图与聚焦测试共用）
//
// ChatStore.sessionGroups 只保证组内置顶优先（组内排序），置顶会话跨组时没有
// 全局聚合。本投影把各组的 pinned 行收敛到侧栏顶部的单一「置顶」区，组区
// 不再重复渲染这些行。不发明新状态：置顶仍是会话上的同一个 Bool（AJ-29），
// 组头与组成员数继续按未投影的 sessionGroups 渲染——置顶改变的是展示区，
// 不改变组归属/计数语义（归档区不参与本投影）。
enum SessionSidebarPinnedSection {
    /// 跨组聚合的置顶行：最近活动优先；同刻按会话 ID 稳定排序。
    static func pinnedItems(from groups: [ChatStore.SessionGroup]) -> [ChatStore.SessionListItem] {
        groups
            .flatMap { $0.items }
            .filter { $0.session.pinned }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return lhs.lastActivityAt > rhs.lastActivityAt
                }
                return lhs.session.id.uuidString < rhs.session.id.uuidString
            }
    }

    /// 组区内应渲染的非置顶行（保持组内原有顺序）。
    static func visibleItems(in group: ChatStore.SessionGroup) -> [ChatStore.SessionListItem] {
        group.items.filter { !$0.session.pinned }
    }
}

/// A session keeps its canonical UUID while its lazy row changes presentation
/// domains. Active and archived controls must never inherit each other's view.
private struct SessionSidebarScopedRow: Identifiable {
    enum Scope: Hashable {
        case pinned
        case group(String)
        case archived
    }
    struct ID: Hashable {
        let scope: Scope
        let sessionID: UUID
    }
    let item: ChatStore.SessionListItem
    let scope: Scope
    var id: ID { ID(scope: scope, sessionID: item.id) }
}

/// The archive row projection and its two UI actions share one consumer. The
/// store owns persistence; this layer only rejects stale rows and returns the
/// active row that may receive keyboard focus after a successful transition.
@MainActor
enum SessionSidebarArchiveConsumer {
    /// 侧栏手动归档：会话（含当前会话）正在生成回复时不执行，请用户先停止。
    /// 归档当前会话会先停掉回复，之后磁盘归档若失败，回复已经白白中断，所以在动手前拦下。
    static func generatingBlockMessage(for id: UUID, in chat: ChatStore) -> String? {
        guard chat.isSessionGenerating(id) else { return nil }
        return id == chat.activeSessionID
            ? "归档未执行：当前会话正在生成回复，请先点停止，再归档。"
            : "归档未执行：该会话正在生成回复，请先切过去停止，或等它完成后再归档。"
    }

    static func visibleArchivedItems(
        _ archived: [ChatStore.SessionListItem],
        activeIDs: Set<UUID>
    ) -> [ChatStore.SessionListItem] {
        var seen = Set<UUID>()
        return archived.filter { item in
            guard !activeIDs.contains(item.session.id) else { return false }
            return seen.insert(item.session.id).inserted
        }
    }

    static func visibleArchivedItems(in chat: ChatStore) -> [ChatStore.SessionListItem] {
        visibleArchivedItems(chat.archivedList, activeIDs: chat.sidebarSessionIDs)
    }

    static func archive(
        _ id: UUID,
        in chat: ChatStore,
        visibleActiveIDs: () -> Set<UUID>
    ) -> UUID? {
        guard chat.sessions.contains(where: { $0.id == id }) else { return nil }
        chat.archiveSession(id: id)
        guard let activeID = chat.activeSessionID,
              visibleActiveIDs().contains(activeID) else { return nil }
        return activeID
    }

    static func restore(
        _ id: UUID,
        in chat: ChatStore,
        visibleActiveIDs: () -> Set<UUID>
    ) -> UUID? {
        guard visibleArchivedItems(in: chat).contains(where: { $0.session.id == id }) else {
            return nil
        }
        chat.restoreSession(id: id)
        guard chat.activeSessionID == id, visibleActiveIDs().contains(id) else { return nil }
        return id
    }
}

@MainActor
struct SessionSidebarAttachmentChipInfo {
    let fileName: String
    let typeLabel: String
    let statusText: String?

    init(_ attachment: ChatAttachment) {
        fileName = attachment.fileName
        typeLabel = ComposerAttachmentPresentation.typeLabel(for: attachment)
        statusText = attachment.statusText
    }
}

struct SessionSidebarView: View {
    @Bindable var chat: ChatStore
    /// true = 整个侧栏完全隐藏（0 宽，工具栏 ⌘⇧C 切换；ContentView 侧 frame 收 0）
    var collapsed: Bool
    /// Field-only seam that still evaluates the production row from this
    /// view's body, after SwiftUI has installed environment typography.
    var typographyInstrumentationItem: ChatStore.SessionListItem?
    /// Persistent producer for the row's lifecycle state.
    private let sessionBadgeStore: SessionBadgeStore
    private let badgeDiagnosticsEnabled: Bool

    init(
        chat: ChatStore,
        collapsed: Bool,
        typographyInstrumentationItem: ChatStore.SessionListItem? = nil,
        sessionBadgeStore: SessionBadgeStore = .shared,
        badgeDiagnosticsEnabled: Bool = SessionSidebarView.badgeDiagnosticsRequested(
            arguments: ProcessInfo.processInfo.arguments
        )
    ) {
        self.chat = chat
        self.collapsed = collapsed
        self.typographyInstrumentationItem = typographyInstrumentationItem
        self.sessionBadgeStore = sessionBadgeStore
        self.badgeDiagnosticsEnabled = badgeDiagnosticsEnabled
        _sessionSearchModel = State(initialValue: SessionSearchModel(chat: chat))
    }

    @Environment(BridgeStore.self) private var bridge: BridgeStore?
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    private static let conversationIndicatorSlotWidth: CGFloat = 18
    private static let conversationIndicatorSlotHeight: CGFloat = 16

    /// 重命名弹窗目标会话
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    /// AJ-30 归入项目弹窗目标会话 + 输入
    @State private var projectTargetID: UUID?
    @State private var projectNameText = ""
    @State private var projectDirText = ""
    @State private var invalidProjectDirectory = false

    /// AJ-59 新建组弹窗
    @State private var newGroupPresented = false
    @State private var newGroupText = ""

    /// AJ-59 重命名组弹窗（目标组 ID + 输入）
    @State private var renameGroupID: UUID?
    @State private var renameGroupText = ""

    /// AJ-73：hover 的会话行 id（决定是否显示置顶/归档快捷图标）
    @State private var hoveredSessionID: UUID?
    /// AJ-73：归档面板是否展开（底部「已归档（N）」入口控制）
    @State private var showArchived = false
    @State private var showEmptySessionGroups = false
    /// 删除预览只在用户明确启动后保存；确认 token 由 sheet 中的用户输入产生。
    @State private var pendingDeletion: PendingSessionDeletion?
    @State private var deletionFeedback: String?
    @State private var projectAuthorizationFeedback: String?
    @State private var projectAuthorizationNeedsRoot = false
    @Environment(\.minisOpenSettingsPage) private var openSettingsPage
    @State private var lastDeletionReceipt: DeletionReceipt?
    /// Exact message search projection; ChatStore remains the canonical source.
    @State private var sessionSearchModel: SessionSearchModel
    /// Focus identity is the concrete session UUID, never a title or array index.
    @FocusState private var focusedSessionID: UUID?

    /// G-09：提示里的快捷键读用户当前绑定，不写死默认值；拿不到绑定时不显示快捷键。
    private func shortcutHint(_ title: String, _ action: ShortcutAction) -> String {
        guard let bridge else { return title }
        return "\(title)（\(bridge.shortcutStore.binding(for: action).displayString)）"
    }

    /// Focused field instrumentation seam; returns the production row view
    /// without duplicating its layout or typography behavior.
    @MainActor
    internal func typographyInstrumentationRow(
        _ item: ChatStore.SessionListItem
    ) -> AnyView {
        AnyView(SessionSidebarView(
            chat: chat,
            collapsed: false,
            typographyInstrumentationItem: item,
            sessionBadgeStore: sessionBadgeStore
        ))
    }

    var body: some View {
        Group {
            if let typographyInstrumentationItem {
                sessionRow(typographyInstrumentationItem)
            } else if collapsed {
                collapsedRail
            } else {
                expandedList
            }
        }
        .font(typography?.body ?? .body)
        // 侧栏背景比主区更暗（Codex 深色层次：侧栏暗 / 主区标准）
        // C3-2：改用 semantic token（sidebarBackground，亮暗各一套映射）。
        // AJ-38：伪仙色板叠加——侧栏用 backgroundSecondary（暗一档）。
        .background(
            theme?.aj38.backgroundSecondary.swiftUIColor
                ?? theme?.sidebarBackground
                ?? Color(nsColor: .underPageBackgroundColor).opacity(0.55)
        )
        .alert("重命名会话", isPresented: isRenaming) {
            TextField("会话标题", text: $renameText)
            Button("确定") {
                if let id = renameTargetID {
                    chat.renameSession(id: id, title: renameText)
                }
                renameTargetID = nil
            }
            Button("取消", role: .cancel) { renameTargetID = nil }
        }
        // AJ-30：归入项目（Codex 对话项目）：项目名 + 工作目录
        .alert("工作目录不可用", isPresented: $invalidProjectDirectory) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请选择已存在的文件夹，可使用绝对路径或 ~/ 开头的路径；目录选择不会授予文件访问权限。")
        }
        .alert("归入项目", isPresented: isProjecting) {
            TextField("项目名称", text: $projectNameText)
            TextField("工作目录（如 /Users/me/MyProject）", text: $projectDirText)
            Button("确定") {
                if let id = projectTargetID {
                    let name = projectNameText.trimmingCharacters(in: .whitespaces)
                    if name.isEmpty {
                        chat.setProject(nil, forSession: id) // 空名 = 解除归属
                    } else if let directory = SessionSidebarPresentation.projectDirectory(projectDirText) {
                        chat.setProject(
                            ChatStore.SessionProject(
                                id: ChatStore.projectID(for: name),
                                name: name,
                                workingDirectory: directory.path
                            ),
                            forSession: id
                        )
                    } else {
                        invalidProjectDirectory = true
                    }
                }
                projectTargetID = nil
            }
            Button("取消", role: .cancel) { projectTargetID = nil }
        } message: {
            Text("归入项目只关联会话和工作目录。若工作目录尚未授权，请先到「设置 → 隐私 → 挂载文件夹」添加该目录，再发送消息。")
        }
        // AJ-59：新建自定义组（真实组实体，可容纳会话）
        .alert("新建组", isPresented: $newGroupPresented) {
            TextField("组名称", text: $newGroupText)
            Button("创建") {
                chat.createGroup(named: newGroupText)
                newGroupText = ""
            }
            Button("取消", role: .cancel) { newGroupText = "" }
        }
        // AJ-59：重命名自定义组
        .alert("重命名组", isPresented: isRenamingGroup) {
            TextField("组名称", text: $renameGroupText)
            Button("确定") {
                if let id = renameGroupID {
                    chat.renameGroup(id: id, to: renameGroupText)
                }
                renameGroupID = nil
            }
            Button("取消", role: .cancel) { renameGroupID = nil }
        }
        .sheet(item: $pendingDeletion) { request in
            SessionDeletionPrompt(
                request: request,
                onCancel: { cancelDeletion(request) },
                onConfirm: { confirmedIntent in
                    executeDeletion(request, confirmedIntent: confirmedIntent)
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let feedback = projectAuthorizationFeedback ?? deletionFeedback {
                // 侧栏很窄：文字在上、按钮在下，文字按整行宽度换行，不再被按钮挤成一竖条。
                VStack(alignment: .leading, spacing: 6) {
                    Text(feedback).accessibilityAddTraits(.isStaticText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if projectAuthorizationFeedback != nil, projectAuthorizationNeedsRoot {
                        Button("设置可访问根目录") { openSettingsPage("隐私") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    if projectAuthorizationFeedback == nil,
                       feedback.hasPrefix("已移入回收站"),
                       let receipt = lastDeletionReceipt,
                       chat.lastSessionDeletionReceipt?.operationID == receipt.operationID,
                       chat.canUndoLastSessionDeletion {
                        Button("撤销") {
                            guard chat.lastSessionDeletionReceipt?.operationID == receipt.operationID else { return }
                            _ = chat.undoLastSessionDeletion()
                            deletionFeedback = chat.sessionTrashFeedback
                            lastDeletionReceipt = nil
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("chat.deletion.undo")
                    }
                }
                .font(typography?.body ?? .callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.deletion.feedback")
                .padding(.bottom, 12)
            }
        }
        .task(id: projectAuthorizationFeedback) {
            guard let shown = projectAuthorizationFeedback, !projectAuthorizationNeedsRoot else { return }
            await ChatAuthorizationFeedbackExpiry.waitToClear(expected: shown,
                current: { projectAuthorizationFeedback }, clear: { projectAuthorizationFeedback = nil })
        }
        .task(id: deletionFeedback) {
            guard let shown = deletionFeedback else { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if deletionFeedback == shown { deletionFeedback = nil; lastDeletionReceipt = nil }
        }
        .onChange(of: deletionFeedback) { _, feedback in
            guard let feedback else { return }
            ChatTranscriptAccessibility.announce(feedback)
        }
        .onAppear {
            sessionSearchModel.refresh()
            reconcileSessionRowFocus()
        }
        .onChange(of: chat.sidebarRevision) { _, _ in
            // 只在标题/时间/置顶/分组/消息数等摘要变化时触发，流式片段不进来；检索放后台。
            sessionSearchModel.refreshInBackground()
            reconcileSessionRowFocus()
        }
        .onChange(of: chat.archivedSessions) { _, _ in
            sessionSearchModel.refresh()
            reconcileSessionRowFocus()
        }
        .onChange(of: chat.searchText) { _, _ in
            reconcileSessionRowFocus()
        }
        .onChange(of: collapsed) { _, _ in
            reconcileSessionRowFocus()
        }
        .onDisappear {
            // A collapsed or removed projection must never leave a hidden row focused.
            focusedSessionID = nil
        }
    }

    private var visibleSessionRowIDs: Set<UUID> {
        if let typographyInstrumentationItem {
            return [typographyInstrumentationItem.session.id]
        }
        guard !collapsed, chat.searchText.isEmpty else { return [] }
        return Set(chat.sessionGroups.flatMap { $0.items }.map { $0.session.id })
    }

    private var visibleArchivedList: [ChatStore.SessionListItem] {
        SessionSidebarArchiveConsumer.visibleArchivedItems(in: chat)
    }

    private func reconcileSessionRowFocus() {
        guard let focusedID = focusedSessionID else { return }
        guard visibleSessionRowIDs.contains(focusedID) else {
            focusedSessionID = nil
            return
        }
    }

    private func sessionRowFill(isActive: Bool, isHovered: Bool) -> Color {
        guard let palette = theme?.aj38 else {
            return isActive ? Color.accentColor.opacity(0.14)
                : Color(nsColor: .quaternaryLabelColor).opacity(isHovered ? 0.06 : 0)
        }
        let style = SessionRowSurfaceStyle.resolve(isActive: isActive, isHovered: isHovered, palette: palette)
        return style.fillColor.swiftUIColor.opacity(style.fillOpacity)
    }

    private func sessionRowEdge(isActive: Bool) -> Color {
        guard let palette = theme?.aj38 else { return isActive ? Color.accentColor.opacity(0.4) : .clear }
        let style = SessionRowSurfaceStyle.resolve(isActive: isActive, isHovered: false, palette: palette)
        return style.fillColor.swiftUIColor.opacity(style.edgeOpacity)
    }

    private func activateSessionRow(_ id: UUID) {
        guard visibleSessionRowIDs.contains(id) else { return }
        chat.switchSession(id: id)
        guard chat.activeSessionID == id, visibleSessionRowIDs.contains(id) else { return }
        focusedSessionID = id
    }

    private func archiveSession(_ id: UUID) {
        if let message = SessionSidebarArchiveConsumer.generatingBlockMessage(for: id, in: chat) {
            deletionFeedback = message
            return
        }
        if let reason = chat.backgroundArchiveBlockReason(sessionID: id.uuidString) {
            deletionFeedback = reason
            return
        }
        if let activeID = SessionSidebarArchiveConsumer.archive(
            id, in: chat, visibleActiveIDs: { visibleSessionRowIDs }
        ) {
            focusedSessionID = activeID
        } else {
            reconcileSessionRowFocus()
        }
    }

    private func restoreArchivedSession(_ id: UUID) {
        if let restoredID = SessionSidebarArchiveConsumer.restore(
            id, in: chat, visibleActiveIDs: { visibleSessionRowIDs }
        ) {
            focusedSessionID = restoredID
        } else {
            reconcileSessionRowFocus()
        }
    }

    private var isRenamingGroup: Binding<Bool> {
        Binding(
            get: { renameGroupID != nil },
            set: { if !$0 { renameGroupID = nil } }
        )
    }

    private var isProjecting: Binding<Bool> {
        Binding(
            get: { projectTargetID != nil },
            set: { if !$0 { projectTargetID = nil } }
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )
    }

    // MARK: 折叠态（56px 图标栏）

    private var collapsedRail: some View {
        VStack(spacing: 14) {
            Button {
                chat.newSession()
            } label: {
                MinisIconView(.edit, size: 14)
                    .foregroundPalette(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(shortcutHint("新建会话", .newSession))

            Divider()

            // 会话数量徽标（点击展开侧栏）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { toggleCollapse() }
            } label: {
                VStack(spacing: 3) {
                    MinisIconView(.messages, size: 14)
                        .font(.system(size: 14))
                    Text("\(chat.sessionList.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("会话列表（\(chat.sessionList.count) 个）— 展开")

            Spacer()

            MinisIconView(.sidebarLeft, size: 12)
                .foregroundPalette(.tertiary)
                .font(.system(size: 11))
                .help(shortcutHint("展开会话侧栏", .toggleSessionSidebar))
        }
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
    }

    /// 折叠/展开由 ContentView 持有状态；这里发通知给外部切换
    private func toggleCollapse() {
        NotificationCenter.default.post(name: .minisCanvasToggleSessionSidebar, object: nil)
    }

    private func authorizeProjectFolder() {
        guard let handler = chat.projectSessionHandler else { return }
        projectAuthorizationFeedback = nil
        projectAuthorizationNeedsRoot = false
        let panel = NSOpenPanel()
        panel.message = "选择用于项目任务的文件夹。选中即授权：该文件夹会加入 Agent 可访问目录（不能选根目录、主目录或系统目录）。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "授权项目"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        Task { @MainActor in
        do {
            let authorized: Bool
            do {
                authorized = try await handler.authorizeFolderAndOpenSessionWithInstructionConsent(selected)
            } catch BuiltinToolExecutor.ProjectDirectoryAuthorizationError.outsideAccessibleRoots {
                // 用户在原生选择框里选中即是明确授权：把该文件夹加入可访问目录后重试一次，
                // 不再要求去设置里重复添加。根目录、主目录和系统目录不自动加入。
                guard let path = ProjectFolderAutoMount.eligiblePath(for: selected) else {
                    throw ProjectFolderAutoMount.Failure.ineligibleFolder
                }
                guard let settings = SettingsCenter.active else {
                    throw ProjectFolderAutoMount.Failure.mountFailed
                }
                guard settings.mountFolder(path) else {
                    throw settings.effectiveMountedFolders.count >= PrivacySettings.maxMountedFolders
                        ? ProjectFolderAutoMount.Failure.mountLimitReached
                        : ProjectFolderAutoMount.Failure.mountFailed
                }
                // 挂载后的执行器重组是异步的：等它生效再重试，否则重试仍按旧的可访问目录判断，
                // 刚挂上的目录会被撤掉（11/16 现场"新建项目选普通文件夹也提示不能加入"的根因）。
                await settings.pendingFileAccessAttachment?.value
                do {
                    authorized = try await handler.authorizeFolderAndOpenSessionWithInstructionConsent(selected)
                } catch {
                    // 重试仍失败（例如在拒绝目录内）时撤掉刚挂上的目录，不留残留授权。
                    settings.unmountFolder(path)
                    throw error
                }
                if !authorized { settings.unmountFolder(path) }
            }
            projectAuthorizationFeedback = authorized ? "项目目录已授权，已在该项目下新建会话。" : "项目授权已取消。"
        } catch let failure as ProjectFolderAutoMount.Failure {
            projectAuthorizationNeedsRoot = true
            projectAuthorizationFeedback = failure.message
        } catch BuiltinToolExecutor.ProjectDirectoryAuthorizationError.outsideAccessibleRoots {
            projectAuthorizationNeedsRoot = true
            projectAuthorizationFeedback = ProjectFolderAutoMount.Failure.stillOutsideAfterMount.message
        } catch BuiltinToolExecutor.ProjectDirectoryAuthorizationError.directoryUnavailable {
            projectAuthorizationFeedback = "所选文件夹不存在或已不可用，请重新选择现有文件夹。"
        } catch ProjectSessionAppError.grantUnavailable {
            projectAuthorizationFeedback = "未能授权此项目：目录可能受保护或授权已不可用，请选择其他目录后重试。"
        } catch let error as ProjectSessionAppError {
            projectAuthorizationFeedback = "项目授权未完成：\(error.userMessage)"
        } catch {
            projectAuthorizationFeedback = "项目授权未完成：原因未识别。请重试；若目录受访问策略限制，请在设置 → 隐私中检查权限。"
        }
        }
    }

    // MARK: 展开态

    private var expandedList: some View {
        VStack(spacing: 6) {
            // 头部：标题 + 折叠 + 新建
            HStack(spacing: 6) {
                Text("会话")
                    .font((typography?.sidebarTitle ?? .system(size: 10)).weight(.semibold))
                SessionTrashEntryButton(chat: chat, title: "回收站")
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { toggleCollapse() }
                } label: {
                    MinisIconView(.sidebarLeft, size: 12)
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(shortcutHint("折叠会话侧栏", .toggleSessionSidebar))
                .accessibilityLabel("折叠会话侧栏")
                if let handler = chat.projectSessionHandler {
                    let projects = handler.grants.list()
                    let authorizationIcon = MinisIconView(
                        .folderAdd, size: 12,
                        accessibilityLabel: projects.isEmpty ? "授权一个任务项目目录" : nil
                    )
                    Group {
                        if projects.isEmpty {
                            Button(action: authorizeProjectFolder) {
                                authorizationIcon
                            }
                        } else {
                            Menu {
                                Button("授权项目目录…", action: authorizeProjectFolder)
                                ForEach(projects, id: \.projectID) { project in
                                    Button("撤销「\(project.displayName)」授权") {
                                        projectAuthorizationNeedsRoot = false
                                        do {
                                            let revokedPath = try handler.revokeProject(id: project.projectID)
                                            // 同时把该文件夹从"可访问目录"移除，不再占用上限。
                                            if let revokedPath, let settings = SettingsCenter.active {
                                                settings.unmountFolder(revokedPath)
                                                if let canonical = ProjectFolderAutoMount.eligiblePath(
                                                    for: URL(fileURLWithPath: revokedPath)), canonical != revokedPath {
                                                    settings.unmountFolder(canonical)
                                                }
                                            }
                                            projectAuthorizationFeedback = "项目授权已撤销，该文件夹也已从可访问目录移除。"
                                        } catch {
                                            projectAuthorizationFeedback = "撤销失败，请重试。"
                                        }
                                    }
                                }
                            } label: {
                                authorizationIcon
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("授权一个任务项目目录")
                    .accessibilityLabel("授权一个任务项目目录")
                    .accessibilityIdentifier("chat.projectSession.authorizeFolder")
                }
                Button {
                    chat.newSession()
                } label: {
                    MinisIconView(.add, size: 13)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .help(shortcutHint("新建会话", .newSession))
                .accessibilityLabel("新建会话")
                // AJ-59：新建自定义组
                Button {
                    newGroupText = ""
                    newGroupPresented = true
                } label: {
                    MinisIconView(.folderAdd, size: 12)
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新建组")
                .accessibilityLabel("新建组")
            }
            // 搜索已有会话与消息：结果命中消息时携带 exact locator；
            // 没有消息命中时继续显示原有标题/日期会话过滤结果。
            SessionSearchInput(model: sessionSearchModel)
                .font(typography?.sidebarItem ?? .system(size: 11))
            // 列表（按项目分组 + 归档分组）
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    if !chat.searchText.isEmpty && !sessionSearchModel.results.isEmpty {
                        if sessionSearchModel.isUpdating {
                            Text("正在更新结果…")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("session-search.updating")
                        }
                        ForEach(sessionSearchModel.results) { result in
                            SessionSearchResultRow(
                                result: result,
                                isSelected: sessionSearchModel.selectedResultID == result.id,
                                onSelect: { _ = sessionSearchModel.select(result) },
                                isUpdating: sessionSearchModel.isUpdating
                            )
                        }
                    } else {
                        // P3-SESSION-02：置顶会话跨组收敛到顶部单一「置顶」区。
                        let sessionGroups = chat.sessionGroups
                        let pinnedItems = SessionSidebarPinnedSection.pinnedItems(from: sessionGroups)
                        if !pinnedItems.isEmpty {
                            pinnedSectionHeader(count: pinnedItems.count)
                            ForEach(pinnedItems.map { SessionSidebarScopedRow(item: $0, scope: .pinned) }) { row in
                                sessionRow(row.item)
                            }
                        }
                        // AJ-30/AJ-59：自定义组 + 项目分组显示（未归属项目组在后）；
                        // 组头按真实成员计数，组行剔除已进全局置顶区的会话。
                        ForEach(sessionGroups.filter { !$0.items.isEmpty }) { group in
                            groupHeader(group)
                            ForEach(SessionSidebarPinnedSection.visibleItems(in: group).map {
                                SessionSidebarScopedRow(item: $0, scope: .group(group.id))
                            }) { row in
                                sessionRow(row.item)
                            }
                        }
                        let emptyGroups = sessionGroups.filter { $0.items.isEmpty }
                        if !emptyGroups.isEmpty {
                            DisclosureGroup(isExpanded: $showEmptySessionGroups) {
                                ForEach(emptyGroups) { group in
                                    groupHeader(group)
                                }
                            } label: {
                                Text("空分组（\(emptyGroups.count)）")
                                    .font(typography?.caption ?? .system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("chat.session.empty-groups")
                        }
                        // AJ-73：归档从主列表隐藏——仅「已归档（N）」入口展开时显示（搜索态同步隐藏）
                        if showArchived && chat.searchText.isEmpty {
                            archivedHeader
                            ForEach(visibleArchivedList.map { SessionSidebarScopedRow(item: $0, scope: .archived) }) { row in
                                archivedRow(row.item)
                            }
                        }
                        if !chat.searchText.isEmpty && chat.sessionList.isEmpty {
                            Text("无匹配会话")
                                .font(typography?.caption ?? .system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .focusSection()
            // AJ-73：底部「已归档（N）」入口按钮（点击展开/收起归档列表；搜索态隐藏保持专注）
            if chat.searchText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showArchived.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        MinisIconView(.archive, size: 12)
                            .font(.system(size: 10))
                        Text("已归档（\(visibleArchivedList.count)）")
                            .font((typography?.sidebarMeta ?? .system(size: 10)).weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        MinisIconView(showArchived ? .caretDown : .caretRight, size: 12)
                            .foregroundPalette(.tertiary)
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(showArchived
                        ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                        : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(showArchived
                                ? (theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.18)
                                : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.sidebar.archived.toggle")
                .accessibilityValue(showArchived ? "已展开" : "已收起")
                .help("显示 / 隐藏归档会话；活动列表超过\(ChatStore.maxSessionListCount)条时，较早会话会自动归档（当前会话和置顶会话保留）。")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 活动会话行：图标 + 标题 + 置顶 + 时间（紧凑单行，Codex 风格）
    private func sessionRow(_ item: ChatStore.SessionListItem) -> some View {
        let isActive = item.session.id == chat.activeSessionID
        let indicator = item.indicator
        let projection = ChatStore.projectSessionBadge(
            for: item, source: indicator, store: sessionBadgeStore,
            liveUnread: badgeDiagnosticsEnabled
                ? chat.sessions.first(where: { $0.id == item.session.id })?.unread : nil,
            diagnosticsEnabled: badgeDiagnosticsEnabled
        )
        let badge = projection.presentation
        let row = HStack(spacing: 6) {
            MinisIconView(.message, size: 12)
                .foregroundPalette(isActive ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : .secondary)
                .font(.system(size: 10))
                .frame(width: 14)
            Text(item.session.title)
                .font(typography?.sidebarItem ?? .system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .accessibilityIdentifier(
                    "typography.session.title.\(item.session.id.uuidString)"
                )
            // AJ-29：置顶图标
            if item.session.pinned {
                MinisIconView(.pin, size: 12)
                    .foregroundPalette(.secondary)
                    .font(.system(size: 8))
            }
            // 目标状态（含后台会话的续跑、暂停、受阻、完成）
            if chat.backgroundRunSessionIDs.contains(item.session.id) {
                Text("后台运行")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("chat.session.background-run.\(item.session.id.uuidString)")
            }
            if let goalStatus = chat.conversationGoalSidebarStatuses[item.session.id] {
                Text(goalStatus.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("chat.session.goal-status.\(item.session.id.uuidString)")
            }
            Spacer(minLength: 4)
            // P3-UI-020：所有会话状态经过同一个固定槽位投影，失败图标同时是重试入口，
            // 其余状态只读，避免切换会话时行尾内容跳动。
            let center = bridge?.approvalCenter
            let runtime = chat.sessionRuntimeStatus(for: item.session.id, approvalCenter: center)
            let reviewReason = center.flatMap { chat.sessionRuntimeReviewReason(for: item.session.id, approvalCenter: $0) }
            let runtimeHelp = reviewReason ?? runtime?.helpText
            Group {
                if let runtime {
                    MinisIconView(
                        runtimeIndicatorIcon(runtime),
                        size: MinisIconTokens.smallSize,
                        accessibilityLabel: runtime.title
                    )
                        .foregroundPalette(runtimeIndicatorColor(runtime))
                } else {
                    conversationIndicatorSlot(item, presentation: projection, isActive: isActive)
                }
            }
            .foregroundStyle(conversationIndicatorColor(badge, fallback: indicator, isActive: isActive))
            .frame(width: Self.conversationIndicatorSlotWidth, height: Self.conversationIndicatorSlotHeight)
            .help(runtimeHelp ?? badge.helpText)
            .accessibilityLabel(runtime?.title ?? badge.accessibilityLabel)
            .accessibilityValue(runtimeHelp ?? badge.helpText)
            .accessibilityHint(runtimeHelp ?? badge.helpText)
            .accessibilityIdentifier("chat.session.indicator.\(item.session.id.uuidString)")
            // AJ-73：hover 时行尾显示置顶/归档快捷图标（不依赖右键菜单）。
            // 图标用内层 onTapGesture：SwiftUI 手势内层优先，点图标不会触发行切换。
            if hoveredSessionID == item.session.id {
                HStack(spacing: 2) {
                    MinisIconView(.pin, size: 12)
                        .foregroundPalette(item.session.pinned
                            ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                            : Color.secondary)
                        .font(.system(size: 10))
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            chat.setPinned(!item.session.pinned, sessionID: item.session.id)
                        }
                        .help(item.session.pinned ? "取消置顶" : "置顶")
                    MinisIconView(.archive, size: 12)
                        .foregroundPalette(.secondary)
                        .font(.system(size: 10))
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            archiveSession(item.session.id)
                        }
                        .help("归档")
                }
                .transition(.opacity)
            } else {
                // Keep only visible idle-row labels current. A transcript or
                // session mutation is not required for relative time to pass.
                SessionSidebarRelativeTime(date: item.lastActivityAt, sessionID: item.session.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(sessionRowFill(isActive: isActive, isHovered: hoveredSessionID == item.session.id))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(sessionRowEdge(isActive: isActive), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        return sessionRowInteraction(
            row,
            focusedSessionID: $focusedSessionID,
            sessionID: item.session.id,
            title: item.session.title,
            isActive: isActive,
            badgeDiagnostic: projection.diagnostic,
            onActivate: { activateSessionRow(item.session.id) }
        )
        .onTapGesture {
            activateSessionRow(item.session.id)
        }
        // AJ-73：行 hover 态（驱动快捷图标显隐）
        .onHover { hovering in
            hoveredSessionID = hovering ? item.session.id : nil
        }
        // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(sessionMenuItems(item.session), at: windowPoint)
        })
        .help(item.session.preview)
    }

    /// Keep the row's focus and keyboard/accessibility contract in a separate
    /// generic view expression. The visual row above intentionally keeps its
    /// existing layout and modifier order; this boundary only gives SwiftUI's
    /// type checker a smaller expression to solve.
    private func sessionRowInteraction<Content: View>(
        _ content: Content,
        focusedSessionID: FocusState<UUID?>.Binding,
        sessionID: UUID,
        title: String,
        isActive: Bool,
        badgeDiagnostic: ChatStore.SessionBadgeProjectionDiagnostic?,
        onActivate: @escaping () -> Void
    ) -> some View {
        content
            .accessibilityElement(children: .contain)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .focusable(true)
            .focused(focusedSessionID, equals: sessionID)
            .accessibilityIdentifier("chat.session.row.\(sessionID.uuidString)")
            .accessibilityLabel(title)
            .accessibilityValue(Self.sessionRowAccessibilityValue(
                isActive: isActive, diagnostic: badgeDiagnostic
            ))
            .accessibilityHint("按回车或空格切换到此会话")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onActivate)
            .onKeyPress(.return) {
                onActivate()
                return .handled
            }
            .onKeyPress(.space) {
                onActivate()
                return .handled
            }
    }

    @ViewBuilder
    private func conversationIndicatorSlot(
        _ item: ChatStore.SessionListItem,
        presentation: ChatStore.SessionBadgeProjection,
        isActive: Bool
    ) -> some View {
        if presentation.isRetryable, let retryIdentity = item.retryIdentity {
            Button {
                // Capture the row's immutable retry snapshot at render time.
                // The action never reconstructs identity from title or task state.
                _ = chat.retryFailedSession(retryIdentity)
            } label: {
                conversationIndicatorGlyph(presentation, isActive: isActive)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.helpText)
            .accessibilityHint(presentation.helpText)
            .accessibilityIdentifier("chat.session.retry.\(item.session.id.uuidString)")
        } else {
            conversationIndicatorGlyph(presentation, isActive: isActive)
        }
    }

    @ViewBuilder
    private func conversationIndicatorGlyph(_ presentation: ChatStore.SessionBadgeProjection, isActive: Bool) -> some View {
        switch presentation.presentation.status {
        case .failed:
            // 失败标记：温和的带色圆形信息图标（不再是三角警告）。选中与非选中行都用危险色，
            // 形状仍不同于运行中（虚线圈）、未读（实心点）、空闲（空心圈），不靠颜色也能分辨。
            MinisIconView(presentation.budgetPauseReason == nil ? .info : .pause, state: .danger, size: 12)
        case .running:
            ProgressView().controlSize(.small).frame(width: 12, height: 12)
        case .idle:
            MinisIconView(.status, size: 12)
                .foregroundPalette(.secondary)
        case .unread:
            // Keep the filled unread mark until its exact Keyline asset is available.
            // An outline status circle would erase the distinction from idle.
            Image(systemName: presentation.systemImageName)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func runtimeIndicatorIcon(_ status: SessionRuntimeStatus) -> MinisIcon {
        switch status {
        case .running: .play
        case .waitingApproval: .pause
        case .needsReview: .warning
        case .interrupted: .stop
        }
    }

    private func runtimeIndicatorColor(_ status: SessionRuntimeStatus) -> Color {
        switch status {
        case .running: theme?.statusRunning ?? .secondary
        case .waitingApproval: theme?.statusWarning ?? .secondary
        case .needsReview, .interrupted: theme?.statusMuted ?? .secondary
        }
    }

    private func conversationIndicatorColor(
        _ presentation: SessionBadgeStore.Presentation,
        fallback indicator: ChatStore.ConversationListIndicator,
        isActive: Bool
    ) -> Color {
        switch presentation.status {
        case .failed:
            return theme?.statusDanger ?? .red
        case .running:
            return theme?.statusWarning ?? AppStatusColor.warning
        case .unread:
            return theme?.aj38.accent.swiftUIColor ?? Color.accentColor
        case .idle:
            _ = indicator
            return .secondary
        }
    }

    /// Project the exact row identity into the persistent production source.
    /// No active-session or title lookup is allowed at this boundary.
    static func sessionBadgePresentation(
        for item: ChatStore.SessionListItem,
        source indicator: ChatStore.ConversationListIndicator,
        store: SessionBadgeStore
    ) -> SessionBadgeStore.Presentation {
        ChatStore.projectSessionBadge(for: item, source: indicator, store: store).presentation
    }

    nonisolated static func badgeDiagnosticsRequested(arguments: [String]) -> Bool {
        arguments.contains("--miniscanvas-session-badge-diagnostic")
    }

    static func sessionRowAccessibilityValue(
        isActive: Bool,
        diagnostic: ChatStore.SessionBadgeProjectionDiagnostic?
    ) -> String {
        let ordinary = isActive ? "当前会话" : "会话"
        guard let diagnostic else { return ordinary }
        return ordinary + " | badgeDiag=" + diagnostic.accessibilityValue
    }

    /// 活动会话右键菜单（AJ-29 对照 Codex 10 项）：
    /// 重命名 / 复制（fork）/ 在新聊天中继续 / 置顶 / 未读 / Finder / 复制ID / 复制深链 / 归档 / 删除
    private func sessionMenuItems(_ session: ChatThread) -> [FloatingMenuItem] {
        var items: [FloatingMenuItem] = [
            FloatingMenuItem(kind: .button(title: "重命名…", icon: "pencil", role: nil, help: nil) { beginRename(session) }, catalogIcon: .edit),
            FloatingMenuItem(kind: .button(title: "复制会话（fork）", icon: "doc.on.doc", role: nil, help: nil) {
                if chat.duplicateSession(id: session.id) == nil,
                   let notice = chat.duplicateRefusalNotice(sessionID: session.id) {
                    deletionFeedback = notice
                }
            }, catalogIcon: .copy),
            FloatingMenuItem(kind: .button(title: "在新聊天中继续", icon: "plus.bubble", role: nil, help: "生成交接摘要，审阅后带着摘要进入新会话") { chat.continueInNewChat(sessionID: session.id) }),
            FloatingMenuItem(kind: .divider),
        ]
        if session.pinned {
            items.append(FloatingMenuItem(kind: .button(title: "取消置顶", icon: "pin.slash", role: nil, help: nil) { chat.setPinned(false, sessionID: session.id) }))
        } else {
            items.append(FloatingMenuItem(kind: .button(title: "置顶", icon: "pin", role: nil, help: nil) { chat.setPinned(true, sessionID: session.id) }, catalogIcon: .pin))
        }
        if session.unread {
            items.append(FloatingMenuItem(kind: .button(title: "标记为已读", icon: "envelope.open", role: nil, help: nil) { chat.setUnread(false, sessionID: session.id) }))
        } else {
            items.append(FloatingMenuItem(kind: .button(title: "标记为未读", icon: "envelope.badge", role: nil, help: nil) { chat.setUnread(true, sessionID: session.id) }))
        }
        items.append(FloatingMenuItem(kind: .divider))
        // AJ-30：归入项目（Codex 对话项目）
        items.append(FloatingMenuItem(kind: .button(title: "归入项目…", icon: "folder.badge.plus", role: nil, help: nil) { beginProject(session) }, catalogIcon: .folderAdd))
        if session.projectID != nil {
            items.append(FloatingMenuItem(kind: .button(title: "移出项目", icon: "folder.badge.minus", role: nil, help: nil) { chat.setProject(nil, forSession: session.id) }))
        }
        // AJ-59：移动到自定义组（真实组实体；当前组打勾）
        var groupChildren: [FloatingMenuItem] = chat.groups.map { group in
            FloatingMenuItem(kind: .button(title: group.name, icon: session.groupID == group.id ? "checkmark" : nil, role: nil, help: nil) {
                chat.moveSession(session.id, toGroup: group.id)
            }, catalogIcon: session.groupID == group.id ? .check : nil)
        }
        if !chat.groups.isEmpty {
            groupChildren.append(FloatingMenuItem(kind: .divider))
        }
        groupChildren.append(FloatingMenuItem(kind: .button(title: "不分组", icon: session.groupID == nil ? "checkmark" : nil, role: nil, help: nil) {
            chat.moveSession(session.id, toGroup: nil)
        }, catalogIcon: session.groupID == nil ? .check : nil))
        groupChildren.append(FloatingMenuItem(kind: .divider))
        groupChildren.append(FloatingMenuItem(kind: .button(title: "新建组…", icon: "folder.badge.plus", role: nil, help: nil) {
            newGroupText = ""
            newGroupPresented = true
        }, catalogIcon: .folderAdd))
        items.append(FloatingMenuItem(kind: .submenu(title: "移动到组", icon: "folder", items: groupChildren), catalogIcon: .folder))
        items.append(FloatingMenuItem(kind: .divider))
        items.append(FloatingMenuItem(kind: .button(title: "在 Finder 中显示", icon: "folder", role: nil, help: nil) { chat.revealSessionInFinder(session.id) }, catalogIcon: .folder))
        items.append(FloatingMenuItem(kind: .button(title: "复制会话 ID", icon: "number", role: nil, help: nil) { chat.copySessionID(session.id) }))
        // 有可预填目标（项目会话且已有回合）时带着目标打开；否则打开编辑器，由用户在列表里选择会话。
        let schedulerPrefill = chat.schedulerTaskTargetPrefill(forSessionID: session.id)
        items.append(FloatingMenuItem(kind: .button(title: "为此会话创建定时任务", icon: "clock.badge.plus", role: nil, help: nil) {
            if let schedulerPrefill {
                SchedulerTaskPrefillInbox.shared.pending = schedulerPrefill
            }
            openSettingsPage("定时任务")
        }))
        items.append(FloatingMenuItem(kind: .button(title: "复制深度链接", icon: "link", role: nil, help: nil) { chat.copySessionDeepLink(session.id) }, catalogIcon: .link))
        items.append(FloatingMenuItem(kind: .divider))
        items.append(FloatingMenuItem(kind: .button(title: "归档", icon: "archivebox", role: nil, help: nil) { archiveSession(session.id) }, catalogIcon: .archive))
        items.append(FloatingMenuItem(kind: .button(title: "删除", icon: "trash", role: .destructive, help: nil) {
            beginDeletion(id: session.id, archived: false)
        }, catalogIcon: .delete))
        items.append(FloatingMenuItem(kind: .button(title: "永久删除…", icon: "trash.fill", role: .destructive, help: nil) {
            beginPermanentDeletion(id: session.id)
        }, catalogIcon: .delete))
        return items
    }

    private func beginRename(_ session: ChatThread) {
        renameTargetID = session.id
        renameText = session.title
    }

    /// AJ-30：打开「归入项目」弹窗，预填当前项目名称/工作目录
    private func beginProject(_ session: ChatThread) {
        projectTargetID = session.id
        projectNameText = session.projectName ?? ""
        projectDirText = session.workingDirectory ?? ""
    }

    private func beginDeletion(id: UUID, archived _: Bool) {
        do {
            let preview = try chat.previewCurrentDeletion(id: id)
            pendingDeletion = PendingSessionDeletion(
                sessionID: id,
                archived: preview.archived,
                intent: preview.intent
            )
            deletionFeedback = nil
        } catch {
            deletionFeedback = deletionErrorMessage(error)
        }
    }

    private func beginPermanentDeletion(id: UUID) {
        do {
            let intent = try chat.previewPermanentDeletion(id: id)
            pendingDeletion = PendingSessionDeletion(
                sessionID: id,
                archived: false,
                intent: intent
            )
            deletionFeedback = nil
        } catch {
            deletionFeedback = deletionErrorMessage(error)
        }
    }

    private func cancelDeletion(_ request: PendingSessionDeletion) {
        do {
            try DeletionGate.cancel(request.intent)
            deletionFeedback = "已取消删除「\(request.intent.targetName)」。"
        } catch {
            deletionFeedback = deletionErrorMessage(error)
        }
        pendingDeletion = nil
    }

    private func executeDeletion(
        _ request: PendingSessionDeletion,
        confirmedIntent: OperationIntent
    ) {
        do {
            let receipt: DeletionReceipt
            if request.intent.operationType == .permanentDelete {
                receipt = try chat.permanentlyDeleteSession(
                    id: request.sessionID,
                    intent: confirmedIntent
                )
            } else if request.archived {
                receipt = try chat.deleteArchivedSession(
                    id: request.sessionID,
                    intent: confirmedIntent
                )
            } else {
                receipt = try chat.deleteSession(
                    id: request.sessionID,
                    intent: confirmedIntent
                )
            }
            lastDeletionReceipt = receipt
            deletionFeedback = "\(request.intent.reversible ? "已移入回收站" : "已永久删除")「\(request.intent.targetName)」。"
            pendingDeletion = nil
        } catch {
            deletionFeedback = deletionErrorMessage(error)
            pendingDeletion = nil
        }
    }

    private func deletionErrorMessage(_ error: Error) -> String {
        if let gateError = error as? DeletionGateError {
            switch gateError {
            case .firstConfirmationRequired:
                return "删除未执行：需要第一步确认。"
            case .secondConfirmationRequired:
                return "删除未执行：需要第二步确认。"
            case .targetChanged:
                return "删除未执行：会话内容已变化，请重新打开删除确认。"
            case .irreversibleRequiresPhrase:
                return "删除未执行：第二确认必须输入 永久删除。"
            case .invalidScope, .invalidIntent:
                return "删除未执行：删除预览无效，请重新开始。"
            case .expired:
                return "删除未执行：删除确认已过期，请重新打开删除确认。"
            case .cancelled:
                return "删除未执行：删除确认已取消。"
            case .alreadyExecuting:
                return "删除未执行：该删除操作正在执行。"
            case .alreadyConsumed:
                return "删除未执行：该删除确认已使用，不能重放。"
            }
        }
        if let chatError = error as? ChatStoreDeletionError {
            switch chatError {
            case .sessionNotFound:
                return "删除未执行：会话已不存在。"
            case .cannotDeleteLastSession:
                return "删除未执行：至少要保留一个活动会话。"
            case .sessionBusy:
                return "永久删除未执行：请先停止该会话正在生成的回复，再重新打开预览。"
            case .backgroundChildrenRunning:
                return "删除未执行：这个会话还有后台运行的子任务。请先在任务中心停止它们，或等它们完成后再删除。"
            }
        }
        return "删除未执行：\(UserFacingErrorText.describe(error))"
    }

    /// 归档分组标题
    private var archivedHeader: some View {
        HStack(spacing: 4) {
            MinisIconView(.archive, size: 12)
                .font(.system(size: 9))
            Text("已归档（\(visibleArchivedList.count)）")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// 分组标题：自定义组（AJ-59）/ 项目分组（AJ-30）统一渲染。
    /// 自定义组带右键菜单（重命名 / 删除）；空自定义组保留显示（组是真实实体）。
    /// P3-SESSION-02：全局置顶区区头（纯展示：置顶是会话属性，不是组实体，
    /// 因此不提供新建/改名/删除等组操作，避免发明新语义）。
    private func pinnedSectionHeader(count: Int) -> some View {
        HStack(spacing: 4) {
            MinisIconView(.pin, size: 12, accessibilityLabel: "置顶")
                .foregroundPalette((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.8))
            Text("已置顶")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityIdentifier("chat.sidebar.pinnedSection")
    }

    /// Ordinary custom-group menu producer consumed by groupHeader's catcher.
    static func customGroupMenuItems(
        rename: @escaping () -> Void, delete: @escaping () -> Void
    ) -> [FloatingMenuItem] {
        [
            FloatingMenuItem(kind: .button(title: "重命名组…", icon: "pencil", role: nil,
                                          help: nil, action: rename), catalogIcon: .edit),
            FloatingMenuItem(kind: .button(title: "删除组", icon: "trash", role: .destructive,
                                          help: nil, action: delete), catalogIcon: .delete),
        ]
    }

    /// The restore glyph shares the retry catalog; deletion admission is unchanged.
    static func archivedSessionMenuItems(
        restore: @escaping () -> Void, delete: @escaping () -> Void
    ) -> [FloatingMenuItem] {
        [
            FloatingMenuItem(kind: .button(title: "恢复", icon: "arrow.uturn.backward", role: nil,
                                          help: nil, action: restore), catalogIcon: .retry),
            FloatingMenuItem(kind: .button(title: "删除", icon: "trash", role: .destructive,
                                          help: nil, action: delete), catalogIcon: .delete),
        ]
    }

    private func groupHeader(_ group: ChatStore.SessionGroup) -> some View {
        let icon: MinisIcon
        switch group.kind {
        case .custom: icon = .folder
        case .project(nil): icon = .database
        case .project: icon = .folder
        }
        return HStack(spacing: 4) {
            MinisIconView(icon, size: 12, accessibilityLabel: group.name)
                .foregroundPalette(group.isCustomGroup
                    ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.8)
                    : Color.secondary)
            Text({ if case .project(nil) = group.kind { return "未分组" }; return group.name }())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if !group.items.isEmpty {
                Text("\(group.items.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            // B11：分组头部「在该组下新建会话」（项目组按 projectID；自定义组按 groupID）
            switch group.kind {
            case .project(let pid) where (pid ?? "").isEmpty:
                EmptyView()
            case .project(let pid):
                Button {
                    chat.newSession(
                        projectID: pid,
                        projectName: group.name,
                        workingDirectory: group.items.first?.session.workingDirectory
                    )
                } label: {
                    MinisIconView(.add, size: 12)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .help("在该项目下新建会话")
                .accessibilityLabel("在该项目下新建会话")
            case .custom(let gid):
                Button {
                    chat.newSession(
                        projectName: group.name,
                        workingDirectory: group.items.first?.session.workingDirectory,
                        groupID: gid
                    )
                } label: {
                    MinisIconView(.add, size: 12)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .help("在该组下新建会话")
                .accessibilityLabel("在该组下新建会话")
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
        .background(RightClickCatcher { windowPoint, _ in
            if group.isCustomGroup, case .custom(let gid) = group.kind {
                FloatingMenuHost.shared.present(Self.customGroupMenuItems(rename: {
                    renameGroupID = gid
                    renameGroupText = group.name
                }, delete: {
                    chat.deleteGroup(id: gid)
                }), at: windowPoint)
            }
        })
    }

    /// 归档会话行：统计 + 恢复按钮 + 右键菜单（恢复 / 删除）
    private func archivedRow(_ item: ChatStore.SessionListItem) -> some View {
        HStack(spacing: 6) {
            MinisIconView(.archive, size: 12)
                .foregroundPalette(.tertiary)
                .font(.system(size: 10))
            Text(item.session.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                restoreArchivedSession(item.session.id)
            } label: {
                MinisIconView(.retry, size: 12)
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chat.sidebar.archive.restore.\(item.session.id.uuidString)")
            .help("恢复会话")
            .accessibilityLabel("恢复会话")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(Self.archivedSessionMenuItems(restore: {
                restoreArchivedSession(item.session.id)
            }, delete: {
                beginDeletion(id: item.session.id, archived: true)
            }), at: windowPoint)
        })
        .help(item.session.preview)
    }

    private func relativeTime(_ date: Date, relativeTo now: Date) -> String {
        SessionSidebarPresentation.relativeTime(date, relativeTo: now)
    }
}

private struct PendingSessionDeletion: Identifiable {
    let id: UUID
    let sessionID: UUID
    let archived: Bool
    let intent: OperationIntent

    init(sessionID: UUID, archived: Bool, intent: OperationIntent) {
        self.id = intent.operationID
        self.sessionID = sessionID
        self.archived = archived
        self.intent = intent
    }
}

/// The canonical intent binds the target and reversibility. This notice also
/// describes App-owned draft and in-flight state without changing that intent.
enum SessionDeletionImpactNotice {
    static func ancillaryEffects(archived: Bool, reversible: Bool) -> String {
        if !reversible {
            return archived
                ? "此归档会话及其中消息将不可恢复；本次删除不影响其他会话。"
                : "此会话及其中消息将不可恢复；未发送草稿、待发附件和生成中回复（如有）也将不再可用。"
        }
        if archived {
            return "恢复后仍回到归档区；该回执仅恢复此会话文件，不包含其他会话或未发送草稿。"
        }
        return "移入回收站时，该会话里正在运行的后台命令会立即终止（恢复后不会自动重新运行）；工具输出文件保留，恢复会话后仍可查看，永久删除时才一并清除。回收站恢复会话文件及其中已发送消息；未发送草稿、待发附件和生成中回复（如有）不随该回执恢复。"
    }
}

private struct SessionDeletionPrompt: View {
    @Environment(\.themeTokens) private var theme
    enum Step {
        case first
        case second
    }

    let request: PendingSessionDeletion
    let onCancel: () -> Void
    let onConfirm: (OperationIntent) -> Void

    private enum ConfirmationField: Hashable {
        case first
        case second
    }

    @State private var step: Step = .first
    @State private var firstConfirmation = ""
    @State private var secondConfirmation = ""
    @Environment(\.typographyTokens) private var typography
    @FocusState private var focusedField: ConfirmationField?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                MinisIconView(.delete, size: 12)
                    .foregroundPalette(theme?.statusDanger ?? AppStatusColor.danger)
                Text("删除会话")
                    .font((typography?.headline ?? .title3).weight(.semibold))
                Spacer()
            }

            Text(request.intent.targetName)
                .font(typography?.headline ?? .headline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(request.intent.impactSummary)
                .foregroundStyle(.secondary)
            Text(SessionDeletionImpactNotice.ancillaryEffects(
                archived: request.archived,
                reversible: request.intent.reversible
            ))
                .foregroundStyle(.secondary)
            Text(request.intent.reversible ? "本次操作会移入回收站。" : "本次操作不可恢复。")
                .foregroundStyle(request.intent.reversible ? Color.secondary : (theme?.statusDangerText ?? AppStatusColor.danger))

            if !request.intent.reversible {
                switch step {
                case .first:
                    Text("第一步：请核对上面的会话和影响范围，然后完整输入会话名。")
                        .foregroundStyle(.secondary)
                    TextField("输入上面的会话名", text: $firstConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .first)
                        .accessibilityLabel("第一确认")
                        .accessibilityHint("完整输入上面的会话名后进入第二步")
                        .accessibilityIdentifier("chat.deletion.firstConfirmation")
                case .second:
                    Text("第二步：输入 永久删除 才会永久删除。")
                        .foregroundStyle(.secondary)
                    TextField("永久删除", text: $secondConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .second)
                        .accessibilityLabel("第二确认")
                        .accessibilityHint("必须完整输入 永久删除")
                        .accessibilityIdentifier("chat.deletion.secondConfirmation")
                }
            }

            HStack {
                Text("确认预览有时效，过期后需要重新开始。")
                    .font(typography?.caption ?? .footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("chat.deletion.cancel")
                if request.intent.reversible {
                    Button("移入回收站", role: .destructive) {
                        onConfirm(request.intent
                            .withFirstConfirmation(request.intent.targetName)
                            .withSecondConfirmation("移入回收站"))
                    }
                    .accessibilityIdentifier("chat.deletion.confirm")
                } else {
                    switch step {
                    case .first:
                        Button("下一步") {
                            guard firstConfirmation == request.intent.targetName else { return }
                            step = .second
                            focusedField = .second
                            ChatTranscriptAccessibility.announce("已进入第二步确认")
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(firstConfirmation != request.intent.targetName)
                        .accessibilityIdentifier("chat.deletion.next")
                    case .second:
                        Button("永久删除", role: .destructive) {
                            guard self.firstConfirmation == request.intent.targetName else { return }
                            let firstConfirmation = self.firstConfirmation
                            let secondConfirmation = self.secondConfirmation
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let confirmedIntent = request.intent
                                .withFirstConfirmation(firstConfirmation)
                                .withSecondConfirmation(secondConfirmation)
                            onConfirm(confirmedIntent)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(firstConfirmation != request.intent.targetName || secondConfirmation.trimmingCharacters(in: .whitespacesAndNewlines) != ("永久删除"))
                        .accessibilityIdentifier("chat.deletion.confirm")
                    }
                }
            }
        }
        .modifier(TypedDeletionDialogLayout())
        .accessibilityIdentifier("chat.deletion.prompt")
        .onAppear { if !request.intent.reversible { focusedField = .first } }
    }
}

// MARK: - 侧栏折叠切换通知（ContentView 监听；工具栏按钮与侧栏内按钮共用）

extension Notification.Name {
    static let minisCanvasToggleSessionSidebar = Notification.Name("minisCanvasToggleSessionSidebar")
    // 2026-08-06：minisCanvasSwitchToChat（文档工作区「返回聊天」）随工作板块移除
}

// MARK: - 中栏：聊天主视图（消息流 + 输入区 + token 状态行）

/// 聊天区的布局契约：消息区可以滚动收缩，但输入区必须始终保留可见高度。
enum ChatLayoutMetrics {
    static let composerMinimumHeight: CGFloat = 56
    static let messageListLayoutPriority: Double = 0
    static let composerLayoutPriority: Double = 1
}

struct ChatMainView: View {
    @Bindable var chat: ChatStore
    let documentStore: SessionDocumentStore?
    var transcriptEnvStore: EnvVarStore? = nil

    @Environment(BridgeStore.self) private var bridge: BridgeStore?
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var exportFeedback: String?
    /// 会话内文档 Tab 面板开关；不改变主布局，也不创建独立 workspace。
    @State private var showSessionDocuments = false
    @State private var showTranscriptPrivacyWarning = false
    /// The transcript itself is recreated for each session. Keep its reading
    /// positions in this stable owner so A -> B -> A can restore A's viewport.
    @State private var transcriptScrollState = ChatTranscriptScrollState()
    @State private var pendingMessageEdit: ComposerMessageEditRequest?
    /// 聊天附件统一交给 ContentView 路由到右侧应用内预览面板。
    var onOpenAttachment: ((ChatAttachment) -> Void)? = nil

    /// S2：转录面脱敏源 —— 复用 MinisCore EnvVarRedactor，对所有已配置的
    /// secret 值（含 Keychain 托管、已惰性载入的值）做内容级脱敏。
    private var transcriptRedactor: ChatTranscriptRedactor? {
        transcriptEnvStore.map { ChatTranscriptRedactor(store: $0) }
    }

    /// The copy button and the UI reconstruction consumer share this path.
    func transcriptPlainTextForCopy() -> String {
        guard let transcriptRedactor else { return "" }
        return ChatTranscriptFormatter.plainText(chat.messages, redactor: transcriptRedactor)
    }

    private func currentToolEvents() -> [MinisCore.ConversationEvent] {
        guard let sessionID = chat.activeSessionID?.uuidString else { return [] }
        return chat.conversationEventProjection.events.filter {
            $0.identity.sessionID == sessionID && ($0.kind == .tool || $0.kind == .approval)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChatToolLifecycleView(readEvents: currentToolEvents)
            .padding(.horizontal, 12)
            if showSessionDocuments, let documentStore {
                SessionDocumentWorkspaceView(
                    store: documentStore,
                    sessionID: chat.activeSessionID,
                    chat: chat
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messageList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(ChatLayoutMetrics.messageListLayoutPriority)
            }
        }
        .background(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
        .font(typography?.body ?? .body)
        .task { await prewarmRecentSessions() }
    }

    /// 首开预热：启动后空闲时，为最近更新的 3 个非活跃会话预先填充转录格式化缓存。
    /// 只在无流式、输入框为空时推进；每批约 8ms 让出主线程。字号、调色板、脱敏值、图标修订
    /// 与真实视图取值一致（见 ChatTranscriptPrewarmer 说明）。
    private func prewarmRecentSessions() async {
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled, let redactor = transcriptRedactor else { return }
        await ChatTranscriptStatusIconProjection.preload()
        guard !Task.isCancelled else { return }
        let active = chat.activeSessionID
        let targets = chat.sessions
            .filter { $0.id != active && !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(3)
            .map { thread in
                ChatTranscriptPrewarmer.Target(
                    messages: thread.messages,
                    projectRoot: thread.workingDirectory.flatMap {
                        $0.isEmpty ? nil : URL(fileURLWithPath: $0)
                    })
            }
        guard !targets.isEmpty else { return }
        await ChatTranscriptPrewarmer.prewarm(
            targets: targets,
            baseSize: ChatTranscriptView.transcriptBaseSize(
                typography: typography, dynamicTypeSize: dynamicTypeSize),
            redactor: redactor, palette: theme?.aj38,
            iconRevision: ChatTranscriptStatusIconProjection.resourceRevision,
            shouldContinue: { !chat.isStreaming && chat.draftText.isEmpty })
    }

    // MARK: 头部：标题 + 只读 Provider 状态

    private var header: some View {
        HStack(spacing: 8) {
            MinisIconView(.messages, size: 12)
                .foregroundPalette(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .font(.system(size: 12))
            Text(chat.activeSessionTitle ?? "会话")
                .font((typography?.headline ?? .system(size: 13)).weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button {
                guard let redactor = transcriptRedactor else {
                    showTranscriptPrivacyWarning = true
                    return
                }
                let title = chat.sessions.first { $0.id == chat.activeSessionID }?.title ?? "会话"
                exportFeedback = SessionMarkdownExport.chooseDestination(title: title, messages: chat.messages,
                    redactor: redactor, events: chat.conversationEvents.filter {
                        $0.identity.sessionID == chat.activeSessionID?.uuidString
                    })
            } label: { MinisIconView(.download, size: MinisIconTokens.smallSize) }
            .buttonStyle(.plain)
            .help(exportFeedback ?? "导出整个会话为 Markdown")
            .accessibilityLabel("导出会话为 Markdown")
            .accessibilityIdentifier("chat.session.export-markdown")
            // B14：复制全部对话内容；与全文选择模式共用格式化边界。
            Button {
                guard transcriptEnvStore != nil else {
                    showTranscriptPrivacyWarning = true
                    return
                }
                let text = transcriptPlainTextForCopy()
                if !text.isEmpty {
                    copyTextToClipboard(text)
                }
            } label: {
                MinisIconView(.copy, size: 12)
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("复制全部对话内容")
            .accessibilityLabel("复制全部对话内容")
            .disabled(chat.messages.isEmpty)
            .alert("无法复制对话", isPresented: $showTranscriptPrivacyWarning) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("脱敏设置尚未就绪。请重新打开对话后再复制。")
            }
            if documentStore != nil {
                Button {
                    showSessionDocuments.toggle()
                } label: {
                    MinisIconView(showSessionDocuments ? .message : .document, size: 12)
                        .foregroundPalette(showSessionDocuments
                            ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                            : Color.secondary)
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showSessionDocuments ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.secondary)
                .help(showSessionDocuments ? "返回当前会话" : "打开会话内文档")
                .accessibilityLabel(showSessionDocuments ? "返回当前会话" : "打开会话内文档")
                .accessibilityIdentifier("chat.sessionDocuments")
            }
            // AJ-58：输出模式切换从输入框旁移入头部（去输入行拥挤）；
            // 模型选择器在顶栏工具栏（ChatModelMenu）已有，头部不再重复放置。
            Picker("回答风格", selection: Binding(
                get: { chat.outputMode },
                set: { chat.setOutputMode($0) }
            )) {
                Text("默认").tag(ChatOutputMode.normal)
                ForEach(ChatOutputMode.presets, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("回答风格：简洁 / 详细 / 讲解；默认保持原回答行为")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 消息流

    /// 当前会话最近一次回合失败且可重试时，给对话末尾的"重试"按钮；与会话列表失败行同一条重试通道。
    private var failedRetryAction: (() -> Void)? {
        guard !chat.isStreaming, !chat.isActiveSessionGenerating,
              let sessionID = chat.activeSessionID,
              let snapshot = chat.executionSnapshot(forSessionID: sessionID),
              snapshot.state == .failed, snapshot.failureKind != .iterationLimit,
              snapshot.failureKind != .authorization
                || chat.providerFailureRecoveredByCheck(sessionID: sessionID) else { return nil }
        let identity = snapshot.retryIdentity
        return { [weak chat] in _ = chat?.retryFailedSession(identity) }
    }

    /// 上下文超出模型窗口的失败：对话末尾多一个“压缩后重试”（先压缩再重发上一条消息）。
    /// 授权类失败或额度不足：对话末尾显示“检查 API Key”，直接打开供应商连接设置。
    private var failedCheckAPIKeyAction: (() -> Void)? {
        guard chat.failedProviderCheckNotice != nil, let bridge else { return nil }
        let failedProviderID = chat.failedProviderCheckProviderID
        return {
            // 直接打开失败的那个供应商，而不是按“哪个没通过”去猜。
            ProviderConnectionRoute.preferredProviderID = failedProviderID
            bridge.deepLinkHandler.handle(.openSettings(id: ProviderConnectionRoute.id))
        }
    }

    private var failedCompactAndRetryAction: (() -> Void)? {
        guard chat.canCompactAndRetryFailedSession else { return nil }
        return { [weak chat] in _ = chat?.compactAndRetryFailedSession() }
    }

    private var activeProjectRoot: URL? {
        guard let sessionID = chat.activeSessionID,
              let directory = chat.sessions.first(where: { $0.id == sessionID })?.workingDirectory,
              !directory.isEmpty else { return nil }
        return URL(fileURLWithPath: directory)
    }

    private var messageList: some View {
        ChatTranscriptView(
            sessionID: chat.activeSessionID,
            messages: chat.messages,
            readToolEvents: currentToolEvents,
            transcriptEnvStore: transcriptEnvStore,
            scrollStateBinding: $transcriptScrollState,
            currentSessionID: { chat.activeSessionID },
            padding: 12,
            scrollTarget: chat.searchScrollTarget,
            retryExhaustionCard: chat.activeProviderRetryExhaustion.map {
                ChatProviderRetryExhaustionCard(chat: chat, identity: $0.identity, messageID: $0.messageID)
            },
            onContinueAfterIterationLimit: chat.activeSessionID.flatMap { sessionID in
                chat.canContinueAfterIterationLimit(sessionID: sessionID)
                    ? { _ = chat.continueAfterIterationLimit(sessionID: sessionID) } : nil
            },
            onOpenAttachment: onOpenAttachment,
            onSendPrompt: { prompt in
                // 只预填输入框，不替用户发送（未连接模型时发出去会得到一条假回复）。
                chat.draftText = prompt
            },
            onToggleReferenceCard: { messageID, expanded in
                _ = chat.setPastedTextReferenceExpanded(
                    messageID: messageID,
                    expanded: expanded,
                    sessionID: chat.activeSessionID
                )
            },
            onOpenSessionCard: { card in _ = chat.openSourceCard(card) },
            canOpenSessionCard: { card in chat.canOpenSourceCard(card) },
            onEditMessage: { messageID in
                pendingMessageEdit = ComposerMessageEditRequest.prepare(chat: chat, messageID: messageID)
            },
            onPrepareFailedMedia: { messageID, attachmentID, asFileReference in
                _ = chat.prepareFailedMediaDraft(
                    messageID: messageID, attachmentID: attachmentID,
                    asFileReference: asFileReference
                )
            },
            markdownCopyPasteboard: NSPasteboard.general,
            onRegenerateMessage: { [weak chat, viewer = chat.activeSessionID,
                revision = chat.transcriptRevision(forSession: chat.activeSessionID)] messageID in
                guard let chat, let viewer, let revision else { return }
                Task { @MainActor in
                    _ = await chat.regenerateAnswer(sessionID: viewer, messageID: messageID, expectedRevision: revision)
                }
            },
            onForkMessage: { [weak chat] messageID in
                guard let chat, let sessionID = chat.activeSessionID else { return }
                _ = chat.forkSession(id: sessionID, atMessageID: messageID, inclusive: true)
            },
            regenerationDisabledReason: { [weak chat] messageID in
                guard let chat else { return "会话不可用" }
                return chat.regenerationDisabledReason(messageID: messageID)
            },
            onRetryFailed: failedRetryAction,
            onCompactAndRetryFailed: failedCompactAndRetryAction,
            onCheckAPIKey: failedCheckAPIKeyAction,
            checkAPIKeyNotice: chat.failedProviderCheckNotice?.text,
            projectRoot: activeProjectRoot
        )
        .modifier(ComposerMessageEditConfirmation(chat: chat, request: $pendingMessageEdit))
        .id(ChatTranscriptSessionBoundary.viewIdentity(for: chat.activeSessionID))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // E11 拖放：文件拖到消息区 → 自动添加为待发送附件
        .dropDestination(for: ComposerDropItem.self) { items, _ in
            chat.addDroppedItems(items)
        } isTargeted: { _ in }
    }
}

// MARK: - 模型选择器（Composer 使用 ModelMenuButton）

// E24：模型面板由 Composer 的 ModelMenuButton 统一承载，状态栏只读展示 Provider。

// MARK: - 消息气泡

private enum ChatMessageMetadata {
    static func roleLabel(for role: ChatRole) -> String {
        switch role {
        case .user: return "用户"
        case .assistant: return "助手"
        case .tool: return "工具"
        case .system: return "系统"
        }
    }

    static func elapsedText(since timestamp: Date, now: Date = Date()) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(timestamp)))
        if elapsedSeconds < 60 {
            return "已过 \(elapsedSeconds) 秒"
        }
        let elapsedMinutes = elapsedSeconds / 60
        if elapsedMinutes < 60 {
            return "已过 \(elapsedMinutes) 分钟"
        }
        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            return "已过 \(elapsedHours) 小时"
        }
        return "已过 \(elapsedHours / 24) 天"
    }
}

private struct ChatMessageMetadataView: View {
    let message: ChatMessageUI
    @Environment(\.typographyTokens) private var typography

    private var roleLabel: String {
        ChatMessageMetadata.roleLabel(for: message.role)
    }

    private var elapsedText: String {
        ChatMessageMetadata.elapsedText(since: message.timestamp)
    }

    /// D-CHAT-18：回合时长/阶段耗时 + Provider/模型标识（无计时的历史消息为 nil）。
    private var turnTimingText: String? {
        message.modelTimingDisplayText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(roleLabel)
                Text("·")
                    .accessibilityHidden(true)
                Text(elapsedText)
            }
            .font((typography?.caption2 ?? .system(size: 9)).weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(roleLabel)消息")
            .accessibilityValue(elapsedText)
            .accessibilityIdentifier("chat.message.metadata.\(message.id.uuidString)")

            if let interruption = message.interruptionStatusText {
                Text(interruption + " · 输入「继续」接着生成")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.message.interrupted.\(message.id.uuidString)")
            }
            if let turnTimingText {
                Text(turnTimingText)
                    .font(typography?.caption2 ?? .system(size: 9))
                    .foregroundStyle(.tertiary)
                    // 一行、尾部截断；完整文案在悬停提示里，不让统计行抢正文的视线。
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat.message.turnTiming.\(message.id.uuidString)")
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessageUI
    /// C4-2：气泡「编辑」回调（nil = 不显示编辑按钮）。用户消息 hover 显示，
    /// 点击 → ChatStore.beginEdit（内容填回输入框，回车作为新消息重发，
    /// 原历史不覆盖）。注意：本气泡未接入生产转录链；生产编辑入口见
    /// ChatTranscriptView 的用户消息锚点（chat.transcript.editMessage）。
    var onEdit: ((UUID) -> Void)? = nil
    var onOpenAttachment: ((ChatAttachment) -> Void)? = nil

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @State private var isHovered = false

    var body: some View {
        Group {
            switch message.role {
        case .system:
            // 画布事件提示：居中小字
            VStack(spacing: 4) {
                ChatMessageMetadataView(message: message)
                Text(message.content)
                    .font(typography?.transcriptBody ?? .system(size: 11))
                    .foregroundStyle(.secondary)
            }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor).opacity(0.18))
                )
                .textSelection(.enabled)
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    ChatMessageMetadataView(message: message)
                    // E11 已发送附件（图片缩略图 / 文件 chip）
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.attachments.enumerated().map {
                                ChatAttachmentRenderItem(messageID: message.id, slot: $0.offset, attachment: $0.element)
                            }) { item in
                                sentAttachmentChip(item.attachment)
                            }
                        }
                    }
                    // AJ-71/72：正文用 displayContent（剥离附件注入段，附件已由 chip 展示）；
                    // 非流式切只读 NSTextView（原生 ⌘A 全选 + 跨段拖选），流式中保持 SwiftUI 渲染
                    if !message.displayContent.isEmpty {
                        if message.isStreaming {
                            MarkdownTextView(
                                text: message.displayContent,
                                baseSize: typography?.transcriptBodySize ?? 13,
                                wrapsCodeLines: true
                            )
                                .font(.system(size: typography?.transcriptBodySize ?? 13))
                        } else {
                            bubbleAttributedBody(message.displayContent, baseColor: .white)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.map { ThemeContrast.fillMeetingWhiteText($0.aj38.accent).swiftUIColor }
                              ?? Color.accentColor)
                )
                .foregroundStyle(.white)
                // AJ-71/72：复制按钮常驻（右上角常显可点，复制整条 content）；
                // C4-2：编辑按钮保持 hover 显示（填回输入框重发）
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if isHovered, let onEdit {
                            BubbleActionButton(title: "编辑", systemImage: "pencil", catalogIcon: .edit, help: "编辑此消息并重新发送") {
                                onEdit(message.id)
                            }
                        }
                        // AJ-27：复制整条消息内容（与 NodeChatBubble 共用组件）
                        // 按需显示（hover 才出现，与编辑按钮一致）——不常驻，避免「狗皮膏药」
                        if isHovered {
                            BubbleCopyButton(content: message.content, catalogIcon: .copy)
                        }
                    }
                    .offset(x: 6, y: -8)
                }
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
                }
            }
        case .tool:
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    ChatMessageMetadataView(message: message)
                    Label { Text("工具结果") } icon: { MinisIconView(.task, size: 14).foregroundPalette(.secondary) }
                        .font((typography?.caption ?? .system(size: 10)).weight(.semibold))
                        .foregroundStyle(.secondary)

                    if !message.visibleToolContent.isEmpty {
                        if message.isStreaming {
                            MarkdownTextView(
                                text: message.visibleToolContent,
                                baseSize: typography?.transcriptBodySize ?? 13,
                                wrapsCodeLines: true
                            )
                                .font(.system(size: typography?.transcriptBodySize ?? 13))
                        } else {
                            bubbleAttributedBody(message.visibleToolContent, baseColor: .textColor)
                        }
                    }

                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.attachments.enumerated().map {
                                ChatAttachmentRenderItem(messageID: message.id, slot: $0.offset, attachment: $0.element)
                            }) { item in
                                sentAttachmentChip(item.attachment)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor))
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("工具结果")
                Spacer(minLength: 30)
            }
        case .assistant:
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    ChatMessageMetadataView(message: message)
                    if message.isStreaming && message.content.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在思考…")
                                .font(typography?.transcriptBody ?? .system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(8)
                    } else if message.isStreaming {
                        // 流式中保持 SwiftUI 渲染（打字机增量重渲染），流式结束后切 NSTextView
                        MarkdownTextView(
                            text: message.content,
                            baseSize: typography?.transcriptBodySize ?? 13,
                            wrapsCodeLines: true
                        )
                            .font(.system(size: typography?.transcriptBodySize ?? 13))
                            .overlay(alignment: .bottomTrailing) {
                                // 打字机光标
                                Text("▍")
                                    .font(.system(size: typography?.transcriptBodySize ?? 13))
                                    .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                                    .offset(x: 4, y: 2)
                            }
                    } else {
                        // AJ-71/72：流式结束 → 只读 NSTextView（原生 ⌘A 全选 + 跨段拖选）
                        bubbleAttributedBody(message.content, baseColor: .textColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor))
                )
                // AJ-71/72：复制按钮按需显示（hover 才出现，非流式时可用）
                .overlay(alignment: .topTrailing) {
                    if isHovered && !message.isStreaming {
                        BubbleCopyButton(content: message.content, catalogIcon: .copy)
                            .offset(x: 6, y: -8)
                    }
                }
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
                }
                Spacer(minLength: 30)
            }
            }
        }
    }

    /// E11 已发送附件 chip（图片缩略图 / 图标 + 文件名）
    private func sentAttachmentChip(_ att: ChatAttachment) -> some View {
        ChatAttachmentOpenButton(
            attachment: att,
            onOpen: onOpenAttachment,
            surface: .bubble
        )
    }

    // MARK: AJ-71/72 气泡正文只读富文本

    /// 正文只读 NSTextView（原生 ⌘A 全选 + 跨段拖选）：复用 ReadOnlyAttributedTextView +
    /// MarkdownAttributedTextBuilder（DocumentView 同款方案）。高度由组件 sizeThatFits
    /// 按实际宽度布局得出（NSScrollView 无 intrinsic size），外层撑满父容器宽度。
    /// baseColor 按气泡背景传（user 白字 → .white；assistant 浅底 → .textColor）。
    private func bubbleAttributedBody(_ text: String, baseColor: NSColor) -> some View {
        ReadOnlyAttributedTextView(
            attributedString: AttributedCache.build(
                content: text,
                isMarkdown: true,
                baseSize: typography?.transcriptBodySize ?? 13,
                baseColor: baseColor
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 聊天消息统一文本区中的附件入口；预览目标由外层 ContentView 路由到右侧面板。
enum ChatAttachmentButtonSurface: Equatable {
    case transcript
    case bubble
}

struct ChatAttachmentOpenButton: View {
    let attachment: ChatAttachment
    let onOpen: ((ChatAttachment) -> Void)?
    var surface: ChatAttachmentButtonSurface = .transcript
    var sessionID: UUID? = nil
    var sourceStateReader: @Sendable (ChatAttachment) -> ChatAttachmentSourceState = {
        ChatAttachmentOpenTarget.sourceState(for: $0)
    }

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        AttachmentPreviewRenderView(attachment: attachment, sessionID: sessionID, requiresReady: false, sourceStateReader: sourceStateReader) { thumbnail, sourceState in
            let canOpen = sourceState?.isOpenable == true
            let statusText = sourceState?.statusText ?? "正在检查附件来源"
            Button {
                guard ChatAttachmentOpenTarget.canOpen(attachment) else { return }
                onOpen?(attachment)
            } label: {
                HStack(spacing: 5) {
                    if let nsImage = thumbnail {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: attachment.kind == .image ? 64 : 24,
                                   height: attachment.kind == .image ? 64 : 24)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        let icon: MinisIcon = switch attachment.kind {
                        case .image: .image
                        case .audio: .volume
                        case .text: .document
                        case .file: .file
                        }
                        MinisIconView(icon, size: 12)
                            .foregroundPalette(surface == .transcript
                                ? (theme?.aj38.textPrimary.swiftUIColor ?? Color.primary)
                                : Color.white)
                            .font(.system(size: 11))
                            .accessibilityHidden(true)
                    }
                    Text(attachment.fileName)
                        .font(typography?.caption ?? .system(size: 10))
                        .lineLimit(1)
                    MinisIconView(.externalLink, size: 12)
                        .foregroundPalette(surface == .transcript
                            ? (theme?.aj38.textPrimary.swiftUIColor ?? Color.primary)
                            : Color.white)
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.72)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .foregroundStyle(surface == .transcript
                    ? (theme?.aj38.textPrimary.swiftUIColor ?? Color.primary)
                    : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(surface == .transcript
                            ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.08)
                            : Color.white.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            surface == .transcript
                                ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.24)
                                : Color.white.opacity(0.18),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .frame(minHeight: 28)
            .disabled(!canOpen || onOpen == nil)
            .opacity(canOpen && onOpen != nil ? 1 : 0.55)
            .help(canOpen && onOpen != nil
                ? "在右侧面板预览 \(attachment.fileName)（\(statusText)）"
                : statusText)
            .accessibilityLabel(canOpen ? "在右侧面板预览 \(attachment.fileName)" : "附件不可用 \(attachment.fileName)")
            .accessibilityValue(statusText)
            .accessibilityHint(canOpen ? "在客户端右侧文件面板打开" : "请重新选择文件后重试")
        }
    }
}

private enum ChatTranscriptScrollAnchor {
    static let bottom = "chat.transcript.bottom"
}

private enum ChatTranscriptScrollCoordinateSpace {
    static let name = "chat.transcript.scroll"
}

enum ChatTranscriptSessionBoundary {
    static func viewIdentity(for sessionID: UUID?) -> UUID? {
        sessionID
    }
}

struct ChatTranscriptMessageSignature: Equatable {
    let id: UUID
    let role: String
    let contentLength: Int
    let isStreaming: Bool
}

/// The document revision comes from the same cache that feeds NSTextView.
/// Byte length alone misses a stream replacement such as a new line replacing
/// a character; that can change layout while the reader is following bottom.
struct ChatTranscriptChangeSignature: Equatable {
    let messages: [ChatTranscriptMessageSignature]
    let documentRevision: UInt64

    init(messages: [ChatMessageUI], documentRevision: UInt64) {
        self.messages = messages.map {
            ChatTranscriptMessageSignature(
                id: $0.id, role: $0.role.rawValue,
                contentLength: $0.content.utf8.count, isStreaming: $0.isStreaming
            )
        }
        self.documentRevision = documentRevision
    }
}

/// Structural identity for the single NSTextView transcript host.
///
/// Keep the host across new messages so TextKit can append at the tail while
/// preserving selection and layout. Session switches and empty-to-content
/// transitions still get a fresh host.
struct ChatTranscriptLayoutIdentity: Hashable {
    let sessionID: UUID?
    let hasMessages: Bool

    init(sessionID: UUID?, messages: [ChatMessageUI]) {
        self.sessionID = sessionID
        hasMessages = !messages.isEmpty
    }
}

private struct ChatTranscriptMessageAnchor: Identifiable {
    let messageID: UUID
    let offset: CGFloat
    /// D-CHAT-09：仅已完结的用户消息提供「编辑重发」锚点操作。
    var isEditable: Bool = false

    var id: UUID { messageID }
}

/// D-CHAT-18：生产转录链（单 NSTextView 承载全部消息）的回合时长页脚。
/// 展示最近一个有计时回合：进行中实时给「已处理时长 + 当前阶段」，完成后固化
/// 「总耗时 + 准备/首字/生成阶段耗时 + 工具次数 + Provider/模型标识」，并附本会话
/// 累计总耗时。历史会话/无计时消息时整条不渲染——绝不补假数据。
/// 逐条工具耗时仍由工具事件卡（ConversationEventProjection）负责，不在此重复。
private struct ChatTranscriptTurnTimingStrip: View {
    let messages: [ChatMessageUI]

    @Environment(\.typographyTokens) private var typography

    /// 最近一个带回合计时的助手消息（流式中的回合也在内）。
    /// W5-080：`.appMessage` 归属行（欢迎语/命令输出）只承载归属记录、
    /// 不承载回合时长，页脚选择器跳过它们，仍锁定最近一个模型回合。
    private var latestTimedAssistantMessage: ChatMessageUI? {
        messages.last {
            $0.role == .assistant && $0.turnTiming?.representsModelTurn == true
        }
    }

    private var hasOpenTurn: Bool {
        guard let latestTimedAssistantMessage else { return false }
        return latestTimedAssistantMessage.turnTiming?.finishedAt == nil
    }

    private func line(now: Date) -> String? {
        var segments: [String?] = []
        if let message = latestTimedAssistantMessage, let timing = message.turnTiming {
            segments.append(timing.turnDisplayText(
                providerName: message.turnProviderName,
                modelID: message.turnModelID,
                providerDisplayLabel: message.turnProviderDisplayLabel,
                now: now
            ))
        }
        segments.append(ChatStore.conversationTotalDurationText(in: messages))
        let joined = segments.compactMap { $0 }
        return joined.isEmpty ? nil : joined.joined(separator: " · ")
    }

    /// 已完成回合的短写法「回合 33 秒 · 模型」；进行中或无时长时沿用完整文案。完整文案放悬停提示。
    private func compactLine(full: String?) -> String? {
        guard let message = latestTimedAssistantMessage, let timing = message.turnTiming,
              let duration = timing.durationMilliseconds else { return full }
        let time = duration < 1_000 || duration >= 60_000
            ? ChatTurnTimingMetadata.durationText(milliseconds: duration)
            : "\(Int((Double(duration) / 1_000).rounded())) 秒"
        var parts = ["回合 \(time)"]
        if let model = message.turnModelID, !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    private func caption(_ full: String?) -> some View {
        Group {
            if let full, let text = compactLine(full: full) {
                Text(text)
                    .help(full)
                    .font(typography?.caption2 ?? .system(size: 9))
                    .foregroundStyle(.tertiary)
                    // 一行、尾部截断；完整文案在悬停提示里，不让统计行抢正文的视线。
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    // 与正文同一阅读列左缘对齐（正文段落缩进 horizontalInset）。
                    .padding(.horizontal, ChatReadingLayout.horizontalInset)
                    .frame(maxWidth: ChatReadingLayout.maxContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("回合时长与模型标识")
                    .accessibilityIdentifier("chat.transcript.turnTiming")
            }
        }
    }

    var body: some View {
        // 未完成的回合按秒自刷新「已处理时长」（同 TaskCenterObservationView 的
        // 周期时钟先例）；已完结回合的数值是稳定值，不需要时钟。
        if hasOpenTurn {
            // 流畅度第五轮：每秒变化的文字只画在 overlay 里；占位行（隐藏、不随秒钟变）
            // 独自决定本行尺寸，秒钟刷新不再让外层 VStack/ScrollView 重新量一遍整页。
            caption(line(now: Date()))
                .hidden()
                .accessibilityHidden(true)
                .overlay {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        caption(line(now: Date()))
                    }
                }
        } else {
            caption(line(now: Date()))
        }
    }
}

/// D-CHAT-09：转录视图用户消息行尾的 hover「编辑」入口。
/// 生产转录链此前只存在于未接线的 ChatBubble；这里补到单 NSTextView
/// 转录的原生锚点层，点击 → ChatStore.beginEdit（内容填回输入框，
/// 回车作为新消息重发，原历史不覆盖）。
/// 消息操作行的统一外观：点击区域不小于 24×24pt，次级文字色，悬停有淡底色（全部取自主题 token，深浅色通用）。
private struct ChatActionChip: ViewModifier {
    @Environment(\.themeTokens) private var theme
    let isHovered: Bool

    func body(content: Content) -> some View {
        let tint = theme?.textSecondary ?? Color.secondary
        content
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .frame(minWidth: 24, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(isHovered ? 0.14 : 0))
            )
            .contentShape(Rectangle())
    }
}

/// 自带悬停状态的操作行按钮外观（菜单、按钮标签用）。
private struct ChatActionHoverChip: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .modifier(ChatActionChip(isHovered: isHovered))
            .onHover { isHovered = $0 }
    }
}

private struct ChatTranscriptEditAffordance: View {
    @Environment(\.themeTokens) private var theme
    let messageID: UUID
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onEdit) {
            MinisIconView(
                .edit,
                state: isHovered ? .hover : .normal,
                size: 12,
                accessibilityLabel: "编辑"
            )
            .modifier(ChatActionChip(isHovered: isHovered))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("编辑此消息并重新发送（新建一轮，不覆盖原历史）")
        .accessibilityLabel("编辑用户消息并重新发送")
        .accessibilityIdentifier("chat.transcript.editMessage.\(messageID.uuidString)")
    }
}

@MainActor
private enum ChatTranscriptAccessibility {
    static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
    }
}

@MainActor
enum ChatTranscriptAXContract {
    static let identifier = "chat.transcript"

    static func fallbackRouteStatus(in messages: [ChatMessageUI]) -> String? {
        messages.contains {
            $0.role == .assistant
                && $0.content.contains(ChatStore.fallbackRouteProjectionPrefix)
        } ? "回退路由状态已显示" : nil
    }
}

/// 主聊天区与画布伴随对话共用的整段会话文本容器。
/// 一个 NSTextView 承载所有消息，因此鼠标拖选可以跨消息，⌘A/复制/粘贴遵循原生 AppKit 语义。
struct ChatTranscriptView: View {
    let sessionID: UUID?
    let messages: [ChatMessageUI]
    var readToolEvents: (() -> [MinisCore.ConversationEvent])? = nil
    var transcriptEnvStore: EnvVarStore? = nil
    /// Production owners survive the per-session `.id` boundary. Direct
    /// consumers can continue to use a locally owned state.
    var scrollStateBinding: Binding<ChatTranscriptScrollState>? = nil
    var currentSessionID: (@MainActor () -> UUID?)? = nil
    var padding: CGFloat = 12
    var scrollTarget: ChatTranscriptScrollTarget? = nil
    var retryExhaustionCard: ChatProviderRetryExhaustionCard? = nil
    var onContinueAfterIterationLimit: (() -> Void)? = nil
    var onOpenAttachment: ((ChatAttachment) -> Void)? = nil
    var onSendPrompt: ((String) -> Void)? = nil
    var onToggleReferenceCard: ((UUID, Bool) -> Void)? = nil
    var onOpenSessionCard: ((SessionReferenceCard) -> Void)? = nil
    var canOpenSessionCard: ((SessionReferenceCard) -> Bool)? = nil
    /// D-CHAT-09：用户消息「编辑重发」回调（→ ChatStore.beginEdit）。
    var onEditMessage: ((UUID) -> Void)? = nil
    /// Failed media remains in the original turn; these actions prepare an
    /// explicit replacement draft bound to that turn and attachment ID.
    var onPrepareFailedMedia: ((UUID, UUID, Bool) -> Void)? = nil
    /// Only the non-Canvas main transcript opts into this action.
    var markdownCopyPasteboard: (any PasteboardWriting)? = nil
    var onRegenerateMessage: ((UUID) -> Void)? = nil
    /// 从某条助手回复处分叉到新会话（只有主聊天转录提供）。
    var onForkMessage: ((UUID) -> Void)? = nil
    var regenerationDisabledReason: ((UUID) -> String?)? = nil
    /// 当前会话最近一次回合失败且可重试时由上层给出；在对话末尾显示"重试"按钮。
    var onRetryFailed: (() -> Void)? = nil
    var onCompactAndRetryFailed: (() -> Void)? = nil
    /// 授权类失败/额度不足：对话末尾的“检查 API Key”按钮与说明（供应商名称已写在说明里）。
    var onCheckAPIKey: (() -> Void)? = nil
    var checkAPIKeyNotice: String? = nil
    /// 项目根目录：用于把回复里的相对路径识别为可点链接。
    var projectRoot: URL? = nil

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var localScrollState = ChatTranscriptScrollState()
    @State private var didAppear = false
    @State private var documentCache = ChatTranscriptDocumentCache()
    @State private var displayProjection = ChatTranscriptDisplayProjectionCache()
    @State private var inlineToolHeights: [String: CGFloat] = [:]
    @State private var expandedInlineToolTurns = Set<AgentTurnIdentity>()
    private struct ToolOutputExpansion: Hashable {
        let viewerSessionID: UUID
        let messageID: UUID
    }
    @State private var expandedToolOutputs: Set<ToolOutputExpansion> = []
    /// 思考过程展开状态（默认折叠，仅显示层）。
    @State private var expandedThinking: Set<UUID> = []
    @State private var statusIconResourceRevision: UInt64 = 0

    private var scrollState: ChatTranscriptScrollState {
        get { scrollStateBinding?.wrappedValue ?? localScrollState }
        nonmutating set {
            if let scrollStateBinding {
                scrollStateBinding.wrappedValue = newValue
            } else {
                localScrollState = newValue
            }
        }
    }

    /// S2：转录面脱敏源 —— 复用 MinisCore EnvVarRedactor，对所有已配置的
    /// secret 值（含 Keychain 托管、已惰性载入的值）做内容级脱敏。
    private var transcriptRedactor: ChatTranscriptRedactor? {
        transcriptEnvStore.map { ChatTranscriptRedactor(store: $0) }
    }

    /// The native text view's built-in Copy command bypasses the toolbar copy
    /// action. No selectable document is produced without the canonical store.
    func transcriptDocumentForDisplay(baseSize: CGFloat, palette: Aj38Palette?,
                                      inlineTools: [UUID: [ChatInlineToolGap]] = [:])
        -> ChatTranscriptFormattedDocument? {
        let perf = PerformanceSignposts.begin(.transcriptDocumentForDisplay); defer { perf.end() }
        let _ = statusIconResourceRevision
        TranscriptPathLinkContext.shared.projectRoot = projectRoot
        guard let transcriptRedactor else { return nil }
        return documentCache.render(
            sessionID: sessionID, messages: displayProjection.project(
                messages,
                toolExpanded: { isToolOutputExpanded($0) },
                thinkingExpanded: { expandedThinking.contains($0) }),
            baseSize: baseSize, redactor: transcriptRedactor,
            palette: palette, inlineTools: inlineTools,
            expandedToolOutputIDs: Set(expandedToolOutputs.compactMap {
                $0.viewerSessionID == sessionID ? $0.messageID : nil
            })
        )
    }

    var body: some View {
        transcriptBody(toolEvents: readToolEvents?() ?? [])
            .background {
                // ⌘F：打开对话正文的查找栏。
                Button("") { _ = TranscriptFindRouter.showFindInterface() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .task {
                await ChatTranscriptStatusIconProjection.preload()
                guard !Task.isCancelled else { return }
                statusIconResourceRevision = ChatTranscriptStatusIconProjection.resourceRevision
            }
    }

    private func transcriptBody(toolEvents: [MinisCore.ConversationEvent]) -> some View {
        let allInlineRuns = ChatTranscriptInlineTools.runs(messages: messages, events: toolEvents,
            sessionID: sessionID, heights: inlineToolHeights, baseSize: transcriptBaseSize)
        let inlineRuns = ChatTranscriptInlineTools.visibleRuns(allInlineRuns, expandedTurns: expandedInlineToolTurns)
        return VStack(alignment: .leading, spacing: 8) {
            if messages.isEmpty {
                ChatEmptyStateView(
                    sessionID: sessionID,
                    onSendPrompt: { prompt in
                        onSendPrompt?(prompt)
                    }
                )
            } else if let transcriptDocument = transcriptDocumentForDisplay(
                baseSize: transcriptBaseSize, palette: theme?.aj38,
                inlineTools: ChatTranscriptInlineTools.gapsByMessage(inlineRuns)
            ) {
                let renderedToolIDs = documentCache.inlineToolMarkerIDs()
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 8) {
                                attachmentRows
                                referenceCardRows
                                sessionReferenceCardRows
                                let messagesByID = ChatTranscriptDisplayProjectionCache.index(messages)
                                let offsets = documentCache.inlineToolOffsets(
                                    contentWidth: transcriptContentWidth(viewportWidth: viewport.size.width))
                                let renderedEventIDs = ChatTranscriptInlineTools.positionedEventIDs(
                                    allInlineRuns, markerIDs: renderedToolIDs, offsetIDs: Set(offsets.keys),
                                    expandedTurns: expandedInlineToolTurns)
                                ZStack(alignment: .topLeading) {
                                    ReadOnlyAttributedTextView(
                                        transcriptDocument: transcriptDocument,
                                        update: documentCache.update,
                                        sessionID: sessionID,
                                        onViewportChange: { [capturedIdentity = scrollState.identity] nearBottom, verticalOffset in
                                            // A newly mounted transcript can render before its
                                            // session reset. Never attribute that viewport to the
                                            // preceding session retained by the stable owner.
                                            guard capturedIdentity.sessionID == sessionID,
                                                  currentSessionID.map({ $0() == sessionID }) ?? true else { return }
                                            let before = scrollState
                                            let action = scrollState.recordViewport(
                                                isNearBottom: nearBottom,
                                                verticalOffset: verticalOffset,
                                                identity: capturedIdentity
                                            )
                                            ChatTranscriptScrollDiagnostics.record("native-viewport-consumed",
                                                "near=\(nearBottom) offset=\(verticalOffset) accepted=\(capturedIdentity == before.identity) before=[\(ChatTranscriptScrollDiagnostics.state(before))] after=[\(ChatTranscriptScrollDiagnostics.state(scrollState))] action=\(action)")
                                        },
                                        restoreViewportOffset: scrollState.identity.sessionID == sessionID
                                            && scrollTarget?.sessionID != sessionID
                                            ? scrollState.restorationOffset : nil
                                    )
                                    .accessibilityLabel("全部对话内容")
                                    .accessibilityValue(transcriptAccessibilityValue)
                                    .accessibilityIdentifier(ChatTranscriptAXContract.identifier)
                                    ForEach(inlineRuns) { run in
                                        if let offset = offsets[run.id] {
                                            ChatTranscriptToolNode(group: run.group,
                                                insertionAccessibilityLabel: run.accessibilityLabel,
                                                sharedExpansion: run.turnIdentity.map { turn in
                                                    Binding(get: { expandedInlineToolTurns.contains(turn) }, set: { expanded in
                                                        if expanded { expandedInlineToolTurns.insert(turn) }
                                                        else { expandedInlineToolTurns.remove(turn) }
                                                    })
                                                },
                                                showsSummary: run.ownsSummary, summaryTitle: run.summaryTitle)
                                                .frame(width: max(1, transcriptContentWidth(viewportWidth: viewport.size.width)
                                                    - ChatReadingLayout.horizontalInset * 2), alignment: .leading)
                                                .offset(x: ChatReadingLayout.horizontalInset, y: offset)
                                        }
                                    }
                                    ForEach(messageAnchors(
                                        transcriptDocument,
                                        contentWidth: transcriptContentWidth(viewportWidth: viewport.size.width)
                                    )) { anchor in
                                        HStack(spacing: 4) {
                                            if let message = messagesByID[anchor.messageID], !message.isStreaming {
                                                if message.role == .tool {
                                                    toolOutputToggle(messageID: message.id)
                                                }
                                                if message.role == .assistant, message.thinkingText?.isEmpty == false {
                                                    thinkingToggle(messageID: message.id)
                                                }
                                                if !(message.role == .assistant && ChatStore.isWelcomeText(message.content)) {
                                                    transcriptCopyMenu(message)
                                                }
                                                if message.role == .assistant, !ChatStore.isWelcomeText(message.content),
                                                   let onForkMessage {
                                                    Menu {
                                                        Button("从这里分叉") { onForkMessage(message.id) }
                                                            .help("新开一个会话，保留到这条回复为止的历史；原会话不变")
                                                            .accessibilityIdentifier("chat.transcript.fork.\(message.id.uuidString)")
                                                    } label: {
                                                        // 同上：菜单按钮里用文字，不用自定义图标。
                                                        Text("⋯")
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .modifier(ChatActionHoverChip())
                                                    }
                                                    .menuStyle(.borderlessButton)
                                                    .menuIndicator(.hidden)
                                                    .fixedSize()
                                                    .help("更多操作")
                                                    .accessibilityLabel("\(attachmentRoleLabel(message.role))消息的更多操作")
                                                    .accessibilityIdentifier("chat.transcript.more.\(message.id.uuidString)")
                                                }
                                            }
                                            if let message = messagesByID[anchor.messageID],
                                               message.role == .assistant, message.id == latestAssistantMessageID,
                                               let onRegenerateMessage {
                                                let reason = regenerationDisabledReason?(message.id)
                                                let presentation = RegenerationButtonPresentation.make(disabledReason: reason)
                                                HStack(spacing: 4) {
                                                    Button { onRegenerateMessage(message.id) } label: {
                                                        Label { Text("重新生成") } icon: { MinisIconView(.refresh, size: 12) }
                                                            .font(typography?.caption2 ?? .system(size: 11))
                                                            .modifier(ChatActionHoverChip())
                                                    }
                                                        .buttonStyle(.plain)
                                                        .fixedSize()
                                                        .disabled(presentation.isDisabled)
                                                        .opacity(presentation.opacity)
                                                        .help(reason ?? "仅重新回答上一问题，不执行工具，保留历史")
                                                        .accessibilityIdentifier("chat.transcript.regenerate.\(message.id.uuidString)")
                                                    if let visibleReason = presentation.visibleReasonText {
                                                        Text(visibleReason)
                                                            .font(typography?.caption2 ?? .system(size: 10))
                                                            .foregroundStyle(.secondary)
                                                            .accessibilityIdentifier("chat.transcript.regenerate.reason.\(message.id.uuidString)")
                                                    }
                                                }
                                            }
                                            if let onEditMessage, anchor.isEditable {
                                                ChatTranscriptEditAffordance(messageID: anchor.messageID) {
                                                    onEditMessage(anchor.messageID)
                                                }
                                            }
                                        }
                                        // 右侧让出一小段，使操作按钮落在用户气泡内侧而不是贴着转录列边缘。
                                        .padding(.trailing, ChatReadingLayout.horizontalInset - UserBubbleTextBlock.textInset)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .offset(y: anchor.offset)
                                        .id(anchor.messageID)
                                    }
                                }
                                .onPreferenceChange(ChatInlineToolHeightPreferenceKey.self) { heights in
                                    let currentIDs = Set(inlineRuns.map(\.id))
                                    var next = inlineToolHeights
                                    for (id, height) in heights where currentIDs.contains(id) && height.isFinite && height > 0 {
                                        if abs((next[id] ?? 0) - height) >= 0.5 { next[id] = height }
                                    }
                                    if next != inlineToolHeights { inlineToolHeights = next }
                                }
                                .frame(maxWidth: ChatReadingLayout.maxContentWidth, alignment: .leading)
                                .frame(maxWidth: .infinity)
                                .id(ChatTranscriptLayoutIdentity(sessionID: sessionID, messages: messages))
                                TranscriptInlineImageStrip(messages: messages, projectRoot: projectRoot)
                                    .frame(maxWidth: ChatReadingLayout.maxContentWidth, alignment: .leading)
                                    .frame(maxWidth: .infinity)
                                let unpositioned = ChatTranscriptToolGroup.groups(
                                    events: toolEvents.filter { !renderedEventIDs.contains($0.id) },
                                    sessionID: sessionID)
                                if !unpositioned.isEmpty {
                                    DisclosureGroup("上次中断前的工具活动（已无法对应到具体消息）") {
                                        ForEach(unpositioned) { group in
                                            ChatTranscriptToolNode(group: group)
                                        }
                                    }
                                    .font(.caption)
                                    .accessibilityIdentifier("chat-tool-events-unpositioned")
                                }
                                if let retryExhaustionCard,
                                   sessionID?.uuidString == retryExhaustionCard.identity.turn.sessionID,
                                   let lastMessage = messages.last(where: { $0.role != .system }),
                                   lastMessage.role == .assistant,
                                   lastMessage.id == retryExhaustionCard.messageID {
                                    retryExhaustionCard
                                }
                                if let onCheckAPIKey, !retryExhaustionCardIsShown {
                                    HStack(spacing: 8) {
                                        Button(action: onCheckAPIKey) {
                                            Text("检查 API Key")
                                        }
                                        .buttonStyle(.bordered)
                                        .help("打开供应商连接设置，检查或更换 API Key")
                                        .accessibilityIdentifier("chat.transcript.check-api-key")
                                        if let checkAPIKeyNotice {
                                            Text(checkAPIKeyNotice)
                                                .font(typography?.caption2 ?? .system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, ChatReadingLayout.horizontalInset)
                                }
                                if let onRetryFailed, !retryExhaustionCardIsShown {
                                    HStack(spacing: 8) {
                                        Button(action: onRetryFailed) {
                                            Label {
                                                Text("重试")
                                            } icon: {
                                                MinisIconView(.retry, size: 12)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .help("重新回答上一条消息，不重复你的提问")
                                        .accessibilityIdentifier("chat.transcript.retry-failed")
                                        if let onCompactAndRetryFailed {
                                            Button(action: onCompactAndRetryFailed) {
                                                Text(ChatGenerationRecoveryAction.compactAndRetry.title)
                                            }
                                            .buttonStyle(.bordered)
                                            .help(ChatGenerationRecoveryAction.compactAndRetry.accessibilityHint)
                                            .accessibilityIdentifier("chat.transcript.compact-and-retry")
                                        }
                                        Text("上一次回复没有成功")
                                            .font(typography?.caption2 ?? .system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, ChatReadingLayout.horizontalInset)
                                }
                                // D-CHAT-18：回合时长/阶段耗时/累计总耗时 + Provider/模型标识。
                                ChatTranscriptTurnTimingStrip(messages: messages)
                                if let onContinueAfterIterationLimit {
                                    Button("继续", action: onContinueAfterIterationLimit)
                                        .help("已达到本轮循环上限。保留当前历史并开始下一轮，审批规则继续生效。")
                                        .accessibilityIdentifier("chat.transcript.continue-iteration-limit")
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(ChatTranscriptScrollAnchor.bottom)
                            }
                            .padding(padding)
                        }
                        .coordinateSpace(name: ChatTranscriptScrollCoordinateSpace.name)
                        .accessibilityLabel("聊天消息列表")
                        .accessibilityValue(transcriptAccessibilityValue)
                        .overlay(alignment: .bottom) {
                            newMessagesButton(proxy: proxy)
                        }
                        .onChange(of: messageSignature) { [capturedIdentity = scrollState.identity] previous, current in
                            handleMessageChange(
                                from: previous,
                                to: current,
                                identity: capturedIdentity,
                                proxy: proxy
                            )
                        }
                        .onChange(of: viewport.size) { [capturedIdentity = scrollState.identity] previous, current in
                            ChatTranscriptScrollDiagnostics.record("viewport-size",
                                "previous=\(previous) current=\(current) state=[\(ChatTranscriptScrollDiagnostics.state(scrollState))]")
                            guard previous != current, scrollState.isFollowing else { return }
                            followBottom(using: proxy, identity: capturedIdentity)
                        }
                        .onChange(of: sessionID) { _, currentSessionID in
                            inlineToolHeights = [:]
                            expandedInlineToolTurns = []
                            if scrollState.identity.sessionID != currentSessionID {
                                scrollState.resetForSession(currentSessionID)
                            }
                            didAppear = false
                            guard scrollTarget?.sessionID != currentSessionID,
                                  scrollState.restorationOffset == nil else { return }
                            followBottom(using: proxy, identity: scrollState.identity)
                        }
                        .task(id: scrollTarget?.id) {
                            guard let target = scrollTarget, target.sessionID == sessionID else { return }
                            // Let the newly rebuilt anchor stack enter the outer scroll view.
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            scrollToMessage(target, using: proxy)
                        }
                        .onAppear {
                            ChatTranscriptScrollDiagnostics.record("appear",
                                "didAppear=\(didAppear) sessionMatches=\(scrollState.identity.sessionID == sessionID) state=[\(ChatTranscriptScrollDiagnostics.state(scrollState))]")
                            guard !didAppear else { return }
                            if scrollState.identity.sessionID != sessionID {
                                scrollState.resetForSession(sessionID)
                            }
                            didAppear = true
                            if let target = scrollTarget, target.sessionID == sessionID {
                                scrollToMessage(target, using: proxy)
                            } else if scrollState.restorationOffset == nil {
                                followBottom(using: proxy, identity: scrollState.identity)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    MinisIconView(.lock, size: 14)
                        .accessibilityHidden(true)
                    Text("对话暂不可显示：脱敏设置尚未就绪。请重新打开对话。")
                }
                    .foregroundStyle(.secondary)
                    .padding(padding)
                    .accessibilityIdentifier("chat.transcript.privacyUnavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sessionID) { _, currentSessionID in
            expandedToolOutputs.removeAll()
            expandedThinking.removeAll()
            if scrollState.identity.sessionID != currentSessionID {
                scrollState.resetForSession(currentSessionID)
            }
            didAppear = false
        }
    }

    private func isToolOutputExpanded(_ messageID: UUID) -> Bool {
        guard let sessionID else { return false }
        return expandedToolOutputs.contains(ToolOutputExpansion(
            viewerSessionID: sessionID, messageID: messageID))
    }

    private func toolOutputToggle(messageID: UUID) -> some View {
        let expanded = isToolOutputExpanded(messageID)
        let viewerSessionID = sessionID
        return Button(expanded ? "收起工具输出" : "展开工具输出") {
            guard let viewerSessionID, viewerSessionID == sessionID,
                  currentSessionID.map({ $0() == viewerSessionID }) ?? true,
                  messages.contains(where: { $0.id == messageID && $0.role == .tool }) else { return }
            let identity = ToolOutputExpansion(viewerSessionID: viewerSessionID, messageID: messageID)
            let perf = PerformanceSignposts.begin(.toolOutputToggle); defer { perf.end() }
            if expandedToolOutputs.contains(identity) {
                expandedToolOutputs.remove(identity)
            } else {
                expandedToolOutputs.insert(identity)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .accessibilityIdentifier("chat.tool-output.\(messageID.uuidString).toggle")
        .accessibilityValue(expanded ? "已展开" : "已折叠")
        .help("结果正文未在此展示：该工具已真实执行并返回结果；正文按上下文策略未保留，需要时重新调用读取")
    }

    private func thinkingToggle(messageID: UUID) -> some View {
        let expanded = expandedThinking.contains(messageID)
        return Button(expanded ? "收起思考" : "展开思考") {
            guard messages.contains(where: { $0.id == messageID && $0.role == .assistant }) else { return }
            if expandedThinking.contains(messageID) {
                expandedThinking.remove(messageID)
            } else {
                expandedThinking.insert(messageID)
            }
        }
        .buttonStyle(.borderless)
        .font(typography?.caption2 ?? .system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityIdentifier("chat.thinking.\(messageID.uuidString).toggle")
        .accessibilityValue(expanded ? "已展开" : "已折叠")
    }

    private var messageSignature: ChatTranscriptChangeSignature {
        ChatTranscriptChangeSignature(
            messages: messages, documentRevision: documentCache.update.revision
        )
    }

    private var transcriptAccessibilityValue: String {
        let position = scrollState.isFollowing ? "跟随最新消息" : "正在阅读历史"
        let pending = scrollState.pendingNewMessageCount > 0
            ? "，有 \(scrollState.pendingNewMessageCount) 条新消息"
            : ""
        let route = documentCache.fallbackRouteStatus {
            ChatTranscriptAXContract.fallbackRouteStatus(in: messages)
        }
            .map { "。\($0)" } ?? ""
        return documentCache.accessibilityValue(
            status: "。滚动位置：\(position)\(pending)\(route)"
        )
    }

    private var transcriptBaseSize: CGFloat {
        Self.transcriptBaseSize(typography: typography, dynamicTypeSize: dynamicTypeSize)
    }

    /// 转录正文字号的唯一算法；预热缓存必须用与真实视图相同的字号才能命中。
    static func transcriptBaseSize(typography: TypographyTokenProvider?,
                                   dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        typography?.transcriptBodySize(for: dynamicTypeSize)
            ?? 13 * TypographyTokenProvider.dynamicTypeScale(for: dynamicTypeSize)
    }

    private func transcriptContentWidth(viewportWidth: CGFloat) -> CGFloat {
        ChatReadingLayout.columnWidth(availableWidth: viewportWidth, gutter: padding)
    }

    private func messageAnchors(
        _ document: ChatTranscriptFormattedDocument,
        contentWidth: CGFloat
    ) -> [ChatTranscriptMessageAnchor] {
        let offsets = documentCache.messageOffsets(contentWidth: contentWidth)
        guard offsets.count == document.messageStartLocations.count else { return [] }
        return messages.enumerated().compactMap { index, message in
            guard document.messageStartLocations[index] < document.attributedString.length else {
                return nil
            }
            return ChatTranscriptMessageAnchor(
                messageID: message.id,
                offset: offsets[index],
                isEditable: message.role == .user && !message.isStreaming && !message.isBackgroundCompletionNotice
            )
        }
    }

    /// Resolve redaction again at the user action boundary, retaining session
    /// identity. No copy action captures raw tool output or attachment injection.
    /// The action behind 「复制消息」/ per-code-block items / 「复制为 Markdown」 in the Copy menu.
    func copyMessage(_ messageID: UUID, codeIndex: Int? = nil,
                     pasteboard: any PasteboardWriting = NSPasteboard.general) {
        guard currentSessionID.map({ $0() == sessionID }) ?? true,
              let redactor = transcriptRedactor,
              let message = messages.first(where: { $0.id == messageID }),
              !message.isStreaming else { return }
        let body = redactedCopyBody(message, redactor: redactor)
        let projection = ChatTranscriptCopyProjection(redactedBody: body)
        if let codeIndex {
            guard projection.codeBlocks.indices.contains(codeIndex) else { return }
            copyTextToClipboard(projection.codeBlocks[codeIndex], pasteboard: pasteboard)
        } else {
            copyTextToClipboard(projection.message, pasteboard: pasteboard)
        }
    }

    private func redactedCopyBody(_ message: ChatMessageUI, redactor: ChatTranscriptRedactor) -> String {
        switch message.role {
        case .user, .assistant: return redactor.redactVisibleConversationBody(message.displayContent)
        case .tool, .system: return redactor.redact(message.displayContent)
        }
    }

    @ViewBuilder
    private func transcriptCopyMenu(_ message: ChatMessageUI) -> some View {
        let markdownPasteboard = message.role == .assistant ? markdownCopyPasteboard : nil
        if transcriptEnvStore != nil || markdownPasteboard != nil {
            let codeBlockTitles = transcriptEnvStore != nil ? codeBlockMenuTitles(for: message) : []
            Menu {
                if transcriptEnvStore != nil {
                    Button("复制消息") { copyMessage(message.id) }
                    ForEach(Array(codeBlockTitles.enumerated()), id: \.offset) { index, title in
                        Button(title) { copyMessage(message.id, codeIndex: index) }
                    }
                }
                if let markdownPasteboard {
                    Button("复制为 Markdown") {
                        copyMessage(message.id, pasteboard: markdownPasteboard)
                    }
                    .accessibilityIdentifier("chat.transcript.copyMarkdown.\(message.id.uuidString)")
                }
            } label: {
                // 下拉菜单按钮会把自定义图标压成单色剪影（包上实测成了黑方块），这里用文字标签。
                Text("复制")
                    .font(.system(size: 11))
                    .modifier(ChatActionHoverChip())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("复制")
            .accessibilityLabel("复制\(attachmentRoleLabel(message.role))消息或代码块")
            .accessibilityIdentifier("chat.transcript.copy.\(message.id.uuidString)")
        }
    }

    /// 每个代码块一项菜单：带语言和首行预览，便于在多个代码块里挑对的那个。
    private func codeBlockMenuTitles(for message: ChatMessageUI) -> [String] {
        let body = message.displayContent
        guard body.contains("```") || body.contains("~~~") else { return [] }
        let redactor = transcriptRedactor
        return displayProjection.codeBlockMenuTitles(
            messageID: message.id, content: body, secrets: redactor?.secretValues ?? []
        ) { uncachedCodeBlockMenuTitles(body: body, redactor: redactor) }
    }

    private func uncachedCodeBlockMenuTitles(body: String, redactor: ChatTranscriptRedactor?) -> [String] {
        let blocks: [(language: String?, code: String)] = MinisCore.MarkdownParser.parse(body).compactMap { block in
            if case .codeBlock(let language, let code) = block { return (language, code) }
            return nil
        }
        return blocks.enumerated().map { index, block in
            let first = block.code.split(whereSeparator: \.isNewline).first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            var preview = String(first.prefix(24))
            if first.count > 24 { preview += "…" }
            // 预览同样脱敏，菜单标题不能泄露密钥。
            preview = redactor?.redactVisibleConversationBody(preview) ?? preview
            let language = (block.language?.isEmpty == false) ? " · \(block.language!)" : ""
            return preview.isEmpty
                ? "复制代码块 \(index + 1)\(language)"
                : "复制代码块 \(index + 1)\(language)：\(preview)"
        }
    }

    /// 只有最近一条助手回复显示"重新生成"（对齐 Claude Code：历史回复不重复出现）。
    private var latestAssistantMessageID: UUID? {
        messages.last(where: { $0.role == .assistant })?.id
    }

    private var retryExhaustionCardIsShown: Bool {
        guard let retryExhaustionCard,
              sessionID?.uuidString == retryExhaustionCard.identity.turn.sessionID,
              let lastMessage = messages.last(where: { $0.role != .system }),
              lastMessage.role == .assistant,
              lastMessage.id == retryExhaustionCard.messageID else { return false }
        return true
    }

    private func scrollToMessage(
        _ target: ChatTranscriptScrollTarget,
        using proxy: ScrollViewProxy
    ) {
        guard target.sessionID == sessionID,
              messages.contains(where: { $0.id == target.messageID }) else { return }
        if reduceMotion {
            proxy.scrollTo(target.messageID, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(target.messageID, anchor: .center)
            }
        }
        ChatTranscriptAccessibility.announce("已定位到命中的确切消息")
    }

    @ViewBuilder
    private func newMessagesButton(proxy: ScrollViewProxy) -> some View {
        if scrollState.pendingNewMessageCount > 0 {
            Button {
                guard let identity = resumeNewMessagesForCurrentSession() else { return }
                followBottom(using: proxy, identity: identity)
                ChatTranscriptAccessibility.announce("已恢复跟随最新消息")
            } label: {
                Label { Text("新消息（\(scrollState.pendingNewMessageCount)）") } icon: {
                    MinisIconView(.download, size: 14, accessibilityLabel: "新消息")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("有 \(scrollState.pendingNewMessageCount) 条新消息")
            .accessibilityHint("跳转到底部并恢复跟随")
            .accessibilityIdentifier("chat.transcript.newMessages")
            .padding(.bottom, 10)
        }
    }

    /// The button belongs to this view's session. A retained scroll owner can
    /// already hold the next session while an old view action is still queued.
    @MainActor
    func resumeNewMessagesForCurrentSession() -> ChatTranscriptScrollIdentity? {
        guard let sessionID else { return nil }
        let identity = scrollState.identity
        guard identity.sessionID == sessionID else { return nil }
        if let currentSessionID, currentSessionID() != sessionID { return nil }
        guard scrollState.apply(.resumeFollowing, identity: identity) == .followBottom else {
            return nil
        }
        return identity
    }

    private func handleMessageChange(
        from previous: ChatTranscriptChangeSignature,
        to current: ChatTranscriptChangeSignature,
        identity: ChatTranscriptScrollIdentity,
        proxy: ScrollViewProxy
    ) {
        guard previous != current, let last = messages.last else { return }

        let before = scrollState
        var action: ChatTranscriptScrollAction = .none
        if current.messages.count > previous.messages.count {
            // SwiftUI can coalesce several appends into one signature change.
            // Deliver each new message to the existing reading-intent reducer,
            // then perform only the final scroll or count announcement.
            for message in messages.dropFirst(previous.messages.count) {
                if message.role == .user {
                    action = scrollState.apply(.userMessageAppended, identity: identity)
                } else if message.role == .assistant {
                    action = scrollState.apply(.assistantMessageAppended, identity: identity)
                }
            }
        } else {
            action = scrollState.apply(
                last.isStreaming ? .streamContentChanged : .retryRequested,
                identity: identity
            )
        }

        ChatTranscriptScrollDiagnostics.record("message-change",
            "previousCount=\(previous.messages.count) currentCount=\(current.messages.count) lastRole=\(last.role.rawValue) streaming=\(last.isStreaming) accepted=\(identity == before.identity) before=[\(ChatTranscriptScrollDiagnostics.state(before))] after=[\(ChatTranscriptScrollDiagnostics.state(scrollState))] action=\(action)")
        switch action {
        case .followBottom:
            followBottom(using: proxy, identity: identity)
        case let .showNewMessages(count):
            ChatTranscriptAccessibility.announce("有 \(count) 条新消息")
        case .none, .preserveHistory:
            break
        }
    }

    private func followBottom(
        using proxy: ScrollViewProxy,
        identity: ChatTranscriptScrollIdentity
    ) {
        ChatTranscriptScrollDiagnostics.record("follow-request",
            "accepted=\(scrollState.identity == identity) reduceMotion=\(reduceMotion) state=[\(ChatTranscriptScrollDiagnostics.state(scrollState))]")
        guard scrollState.identity == identity else { return }
        // Automatic following is a layout update. A queued animation can
        // outlive its measured document bounds (or the user's upward wheel)
        // and later move the native clip outside the current transcript.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(ChatTranscriptScrollAnchor.bottom, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var attachmentRows: some View {
        let messagesWithAttachments = messages.filter { !$0.attachments.isEmpty }
        if !messagesWithAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text("对话附件") } icon: { MinisIconView(.attachment, size: 14).foregroundPalette(.secondary) }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(messagesWithAttachments) { message in
                    HStack(alignment: .center, spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(message.attachments.enumerated().map {
                                    ChatAttachmentRenderItem(messageID: message.id, slot: $0.offset, attachment: $0.element)
                                }) { item in
                                    ChatAttachmentOpenButton(
                                        attachment: item.attachment,
                                        onOpen: onOpenAttachment,
                                        surface: .transcript,
                                        sessionID: sessionID
                                    )
                                    if message.role == .user,
                                       message.referenceCard == nil,
                                       item.attachment.deliveryQuarantined == true,
                                       item.attachment.hasModelMediaPayload,
                                       onPrepareFailedMedia != nil {
                                        Button("移除后重写") {
                                            onPrepareFailedMedia?(message.id, item.attachment.id, false)
                                        }
                                        .accessibilityIdentifier("chat.transcript.failedMedia.remove.\(message.id.uuidString).\(item.attachment.id.uuidString)")
                                        Button("改为文件引用") {
                                            onPrepareFailedMedia?(message.id, item.attachment.id, true)
                                        }
                                        .disabled(!ChatAttachmentOpenTarget.canOpen(item.attachment))
                                        .accessibilityIdentifier("chat.transcript.failedMedia.reference.\(message.id.uuidString).\(item.attachment.id.uuidString)")
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(attachmentRoleLabel(message.role))发送的附件")
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)).opacity(0.38), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var referenceCardRows: some View {
        let messagesWithCards = messages.filter { $0.referenceCard != nil }
        if !messagesWithCards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text("粘贴资料") } icon: { MinisIconView(.document, size: 14).foregroundPalette(.secondary) }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(messagesWithCards) { message in
                    if let card = message.referenceCard {
                        PastedTextReferenceCardView(
                            card: card,
                            isSessionCurrent: card.sessionID == sessionID,
                            onToggle: {
                                onToggleReferenceCard?(message.id, !card.isExpanded)
                            }
                        )
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .separatorColor)).opacity(0.38), lineWidth: 1)
            )
            .accessibilityIdentifier("chat.pasted-reference-card.list")
        }
    }

    @ViewBuilder
    private var sessionReferenceCardRows: some View {
        let cards = messages.compactMap(\.sessionReferenceCard)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title).font(.headline)
                        Text("\(card.projectTitle) · \(card.status.displayTitle)")
                            .font(.caption).foregroundStyle(.secondary)
                        if canOpenSessionCard?(card) != true {
                            Text("目标会话或项目授权当前不可用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("打开新任务") { onOpenSessionCard?(card) }
                                .disabled(canOpenSessionCard?(card) != true)
                            Button("复制深链") {
                                guard let link = card.deepLink else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            }
                        }
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("chat.projectSession.sourceCard")
                }
            }
        }
    }

    private func attachmentRoleLabel(_ role: ChatRole) -> String {
        switch role {
        case .user: return "用户"
        case .assistant: return "助手"
        case .tool: return "工具"
        case .system: return "系统"
        }
    }
}

// MARK: - E11 附件 UI 辅助

extension ChatAttachment {
    /// Shared display-only mapping; attachment storage and opening stay unchanged.
    var keylineIcon: MinisIcon {
        switch kind {
        case .image: return .image
        case .audio: return .volume
        case .text: return .document
        case .file: return .file
        }
    }

    /// Compatibility name for consumers outside the approved display scope.
    var iconName: String {
        switch kind {
        case .image: return "photo"
        case .audio: return "music.note"
        case .text: return "doc.text"
        case .file: return "doc"
        }
    }

    /// 预览条副标题（无大小信息时显示类型名）
    var kindLabel: String {
        switch kind {
        case .image: return "图片"
        case .audio: return "音频"
        case .text: return "文本"
        case .file: return "文件"
        }
    }
}

// MARK: - 节点上下文卡片（画布 → 上下文面板 联动展示）

/// 点击画布节点后，右侧上下文面板顶部显示的节点上下文。
struct NodeContextCard: View {
    let context: NodeContextInfo

    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                Text(context.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(context.type)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.14)))
                    .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
            }
            HStack(spacing: 10) {
                Label(context.statusLabel, systemImage: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text("输入 \(context.inputCount) · 输出 \(context.outputCount)　可在输入框用 `连线 …` 继续编排")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - U1 token 用量文案与轻量状态行（去 C: 前缀乱码）

extension ChatStore {
    /// U1：人类可读 token 用量文案（Codex 风格 C:1.2k/100k 用户看不懂 → 「已用 1.2k / 100k tokens」）。
    /// 纯函数，可单测。
    static func tokenUsageLabel(used: Int, cap: Int?) -> String {
        guard let cap else { return "已用 \(formatTokenCount(used)) tokens（无上限）" }
        return "已用 \(formatTokenCount(used)) / \(formatTokenCount(cap)) tokens"
    }
}

/// The ordinary chat status row, shared with its offscreen renderer consumer.
/// Explicit containment keeps the row identity from replacing budget children.
struct ChatStatusBar<ProviderStatus: View>: View {
    let chat: ChatStore
    @ViewBuilder var providerStatus: () -> ProviderStatus

    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            TokenUsageBar(chat: chat, compact: true, barWidth: 80)
            providerStatus()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.status-bar")
    }
}

/// U1 轻量 token 用量状态行：图标 + 「已用 x / y tokens」 + 细进度条 + 超限/接近上限提示。
/// 聊天主视图 / 伴随对话栏 / 全局状态栏共用，视觉轻量。
struct TokenUsageBar: View {
    @Bindable var chat: ChatStore
    /// true = 更紧凑（伴随对话栏 / 状态栏用；保留请求数）
    var compact: Bool = false
    /// 进度条宽度（compact 时自动收窄）
    var barWidth: CGFloat? = nil

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        // One MainActor snapshot, settled by the existing authoritative tracker.
        let budget = chat.requestBudget
        let fraction = budget.usageFraction
        let overLimit = budget.isExhausted
        let warning = !overLimit && fraction >= chat.warningFraction
        let status = overLimit ? "预算超限" : (warning ? "接近上限" : "预算可用")
        let tokenLabel = budget.maxTokensPerSession.map {
            ChatStore.tokenUsageLabel(used: budget.usedTokens, cap: $0)
        } ?? "已用 \(ChatStore.formatTokenCount(budget.usedTokens)) tokens（无上限）"
        let remaining = budget.tokensRemaining.map { "\(ChatStore.formatTokenCount($0)) tokens" } ?? "无上限"
        // C3-2：错误/警告统一走 semantic token（statusDanger / statusWarning）。
        let tint: Color = overLimit
            ? (theme?.statusDanger ?? .red)
            : (warning ? (theme?.statusWarning ?? .orange) : Color.secondary)
        HStack(spacing: 6) {
            MinisIconView(overLimit ? .warning : .status, size: 12)
                .foregroundPalette(tint)
                .font(.system(size: compact ? 9 : 10))
            Text(tokenLabel)
                .font((typography?.status ?? .system(size: compact ? 10 : 11)).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .accessibilityLabel("会话 Token 预算")
                .accessibilityValue("\(tokenLabel)，剩余 \(remaining)，\(status)")
                .accessibilityIdentifier("chat.token-usage.tokens")
            Text("请求 \(budget.usedRequests)")
                .font(typography?.caption2 ?? .system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel("请求次数")
                .accessibilityValue("\(budget.usedRequests)")
                .accessibilityIdentifier("chat.token-usage.requests")
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: barWidth ?? (compact ? 60 : 140))
            if overLimit {
                Text("预算超限")
                    .font((typography?.caption2 ?? .system(size: 10)).weight(.semibold))
                    .foregroundStyle(theme?.statusDanger ?? .red)
                    .accessibilityIdentifier("chat.token-usage.status")
            } else if warning {
                Text("接近上限")
                    .font((typography?.caption2 ?? .system(size: 10)).weight(.semibold))
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("chat.token-usage.status")
            }
        }
        .accessibilityElement(children: .contain)
        .help("本次会话 token 用量 / 预算上限（每轮 LLM 调用按响应 usage 累计）")
    }
}

// MARK: - U1 左侧伴随对话栏（画布视图：主内容 + 伴随聊天，Codex 风格）

/// 画布视图的左侧伴随对话栏：消息流 + 输入框 + 轻量 token 状态行。
/// 与底部全局对话条互斥（ContentView 在 LayoutPolicy.usesCompanionChat 时隐藏全局条）。
/// 节点-对话彻底解绑（2026-08-06 用户定案）：前台不再展示选中节点上下文，
/// 不再自动把节点名注入草稿。后台接口（applySelectedNodeContext）保留供画布指令链路使用。
/// 订阅草稿逐字符变化的最小作用域：内容闭包在本视图的 body 内求值，
/// 闭包里读取 chat.draftText 只会让本视图重绘，而不是外层大视图。
struct ComposerDraftScope<Content: View>: View {
    let chat: ChatStore
    @ViewBuilder let content: () -> Content
    var body: some View {
        _ = chat.composerDraft.revision
        return content()
    }
}

struct CompanionChatView: View {
    @Bindable var chat: ChatStore
    let bridge: BridgeStore
    var transcriptEnvStore: EnvVarStore? = nil
    /// AJ-60：是否折叠（0 宽完全隐藏）。状态由 ContentView 持有（折叠前记住宽度、展开恢复、宽度持久化）；
    /// 折叠时本视图渲染 0 宽空占位，保持视图树稳定（避免 HSplitView 分隔条异常，同主侧栏 F5-ui 策略）。
    var collapsed: Bool = false
    /// AJ-60：隐藏/恢复回调（ContentView 切换记忆状态；栏内按钮触发，恢复入口为主区左上浮动按钮）
    var onToggleCollapse: () -> Void = {}
    /// 聊天附件统一交给 ContentView 路由到右侧应用内预览面板。
    var onOpenAttachment: ((ChatAttachment) -> Void)? = nil
    /// 未发送附件的“预览”按钮（与主输入框一致）；由 ContentView 路由到右侧面板。
    var onPreviewAttachment: ((ChatAttachment, UUID) -> Void)? = nil

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @State private var showInputHistorySearch = false
    @State private var isDropTargeted = false
    @State private var transcriptScrollState = ChatTranscriptScrollState()
    @State private var pendingMessageEdit: ComposerMessageEditRequest?
    /// U4：插件 / 技能选择器 popover 开关
    @State private var showPickerPopover = false
    @State private var atMentionSelectedID: String?
    @State private var atMentionDismissedDraft: String?
    @State private var pastedTextEditorState: PastedTextEditorState?

    var body: some View {
        if collapsed {
            // AJ-60：折叠 = 0 宽空占位（视图树保持稳定；外层 .frame(minWidth: 0) + .clipped() 收为 0 宽）
            Color.clear
                .frame(width: 0, height: 0)
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                messageList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(ChatLayoutMetrics.messageListLayoutPriority)
                Divider()
                tokenRow
                    .fixedSize(horizontal: false, vertical: true)
                // 输入框的逐字符重绘隔离在 ComposerDraftScope 内，不波及消息列表。
                ComposerDraftScope(chat: chat) { composer }
                    .frame(minHeight: ChatLayoutMetrics.composerMinimumHeight)
                    .layoutPriority(ChatLayoutMetrics.composerLayoutPriority)
            }
            .frame(minWidth: 220, idealWidth: 310, maxWidth: 600)
            .font(typography?.body ?? .body)
            .background(
                theme?.sidebarBackground
                    ?? Color(nsColor: .underPageBackgroundColor).opacity(0.55)
            )
        }
    }

    // MARK: 头部（标题 + 只读 Provider 状态）

    private var header: some View {
        HStack(spacing: 8) {
            MinisIconView(.messages, size: 12)
                .foregroundPalette(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .font(.system(size: 11))
            Text("伴随对话")
                .font((typography?.headline ?? .system(size: 12)).weight(.semibold))
            Label { Text(chat.providerLabel) } icon: { MinisIconView(.server, size: 14).foregroundPalette(.tertiary) }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("当前服务商：\(chat.providerLabel)")
                .accessibilityLabel("当前服务商")
                .accessibilityValue(chat.providerLabel)
                .accessibilityIdentifier("provider.status.readonly")
            Spacer()
            // AJ-52 对话输出模式切换（详细 / 正常 / 极简，三态分段）：
            // 与聊天主输入框 GlobalComposerView 共用同一 ChatStore.outputMode 状态（一处切换三处同步）。
            Picker("回答风格", selection: Binding(
                get: { chat.outputMode },
                set: { chat.setOutputMode($0) }
            )) {
                Text("默认").tag(ChatOutputMode.normal)
                ForEach(ChatOutputMode.presets, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("回答风格：简洁 / 详细 / 讲解；默认保持原回答行为")
            // AJ-60：隐藏伴随栏（折叠前宽度已记忆，可从主区左上浮动按钮恢复）
            Button {
                onToggleCollapse()
            } label: {
                MinisIconView(.sidebarLeft, size: 12)
                    .foregroundPalette(.secondary)
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("隐藏伴随对话栏（宽度已记忆，可从主区左上角浮动按钮恢复）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: 消息流

    private var messageList: some View {
        ChatTranscriptView(
            sessionID: chat.activeSessionID,
            messages: chat.messages,
            transcriptEnvStore: transcriptEnvStore,
            scrollStateBinding: $transcriptScrollState,
            currentSessionID: { chat.activeSessionID },
            padding: 10,
            scrollTarget: chat.searchScrollTarget,
            retryExhaustionCard: chat.activeProviderRetryExhaustion.map {
                ChatProviderRetryExhaustionCard(chat: chat, identity: $0.identity, messageID: $0.messageID)
            },
            onContinueAfterIterationLimit: chat.activeSessionID.flatMap { sessionID in
                chat.canContinueAfterIterationLimit(sessionID: sessionID)
                    ? { _ = chat.continueAfterIterationLimit(sessionID: sessionID) } : nil
            },
            onOpenAttachment: onOpenAttachment,
            onSendPrompt: { prompt in
                // 只预填输入框，不替用户发送（未连接模型时发出去会得到一条假回复）。
                chat.draftText = prompt
            },
            onToggleReferenceCard: { messageID, expanded in
                _ = chat.setPastedTextReferenceExpanded(
                    messageID: messageID,
                    expanded: expanded,
                    sessionID: chat.activeSessionID
                )
            },
            onOpenSessionCard: { card in _ = chat.openSourceCard(card) },
            canOpenSessionCard: { card in chat.canOpenSourceCard(card) },
            onEditMessage: { messageID in
                pendingMessageEdit = ComposerMessageEditRequest.prepare(chat: chat, messageID: messageID)
            },
            onPrepareFailedMedia: { messageID, attachmentID, asFileReference in
                _ = chat.prepareFailedMediaDraft(
                    messageID: messageID, attachmentID: attachmentID,
                    asFileReference: asFileReference
                )
            }
        )
        .modifier(ComposerMessageEditConfirmation(chat: chat, request: $pendingMessageEdit))
        .id(ChatTranscriptSessionBoundary.viewIdentity(for: chat.activeSessionID))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // E11 拖放：文件拖到消息区 → 自动添加为待发送附件
        .dropDestination(for: ComposerDropItem.self) { items, _ in
            chat.addDroppedItems(items)
        } isTargeted: { _ in }
    }

    // MARK: U1 token 状态行（轻量版）

    private var tokenRow: some View {
        HStack(spacing: 8) {
            TokenUsageBar(chat: chat, compact: true)
            Spacer(minLength: 4)
            if chat.isMockMode {
                // G10 P2-1：Mock 模式常驻醒目徽标（未配置 Provider 时防误当真实模型）
                let hasReadyModel = chat.hasReadyChatModel
                Button {
                    bridge.deepLinkHandler.handle(.openSettings(id: hasReadyModel ? "常规" : ProviderConnectionRoute.id))
                } label: {
                    Label { Text(hasReadyModel ? "演示模式 · 选择模型" : "演示模式 · 连接模型") } icon: { MinisIconView(.warning, size: 14).foregroundPalette(theme?.statusWarning ?? AppStatusColor.warning) }
                }
                .buttonStyle(.plain)
                .font((typography?.status ?? .system(size: 9)).weight(.semibold))
                .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                .help(hasReadyModel
                      ? "当前回复为本地演示。已有可用模型，会自动切换；也可点击前往设置选择默认模型。"
                      : "还没有连接模型：当前回复为本地演示。点击打开连接模型表单，保存并检查通过后自动切换到真实模型。")
            } else {
                Label { Text(chat.providerLabel) } icon: { MinisIconView(.server, size: 14).foregroundPalette(.tertiary) }
                    .font(typography?.status ?? .system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    // MARK: 输入区（权限/模式 + 模型 + 📎 附件 + 🧩 插件/技能选择器 + 输入框 + 发送/停止）

    private var composer: some View {
        // 保留控件与草稿操作的自然高度；矮伴随栏减少可见输入行，全文仍由原 NSTextView 滚动。
        ViewThatFits(in: .vertical) {
            composerContents(maxVisibleLines: 4)
            composerContents(maxVisibleLines: 2)
            composerContents(maxVisibleLines: 1)
        }
        // 高度候选共用一个预览呈现 owner 和稳定的 AX 根。
        .dropDestination(for: ComposerDropItem.self) { items, _ in
            chat.addDroppedItems(items)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.companion")
        .accessibilityLabel("伴随对话输入区")
        .sheet(item: $pastedTextEditorState) { state in
            PastedTextCapsuleEditor(chat: chat, state: state)
        }
    }

    private func composerContents(maxVisibleLines: Int) -> some View {
        VStack(spacing: ComposerLayoutMetrics.stackSpacing) {
            ComposerContextNoticeView(chat: chat, bridge: bridge)
            if !chat.pendingAttachments.isEmpty {
                attachmentPreviewBar
            }
            if let sessionID = chat.activeSessionID {
                ForEach(chat.activePastedTextDrafts) { draft in
                PastedTextCapsuleView(
                    draft: draft,
                    onPreview: {
                        pastedTextEditorState = PastedTextEditorState(sessionID: sessionID, draft: draft)
                    },
                    onRemove: {
                        _ = PastedTextComposerConsumer.remove(
                            expectedSessionID: sessionID,
                            expectedDraftID: draft.id,
                            in: chat
                        )
                    }
                )
            }
            }
            if chat.activePendingBackgroundResultCount > 0 {
                Text("有 \(chat.activePendingBackgroundResultCount) 个后台子任务已完成，结果将在你下一轮消息中回灌；完整结果可在任务中心查看。")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.background-results.pending")
            }
            ChatRateLimitWaitCard(controller: chat.rateLimitWaits, sessionID: chat.activeSessionID,
                onCancel: { chat.stopStreaming(returnQueuedToDraft: true) })
            if !chat.activeQueuedComposerMessages.isEmpty { ComposerQueuedMessagesView(chat: chat) }
            if let notice = chat.composerInvisibleCharacterNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.invisible-characters.notice")
            }
            if let feedback = chat.pastedTextActionFeedback {
                Text(feedback)
                    .font(typography?.status ?? .caption)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.pasted-text.feedback")
                    .accessibilityAddTraits(.isStaticText)
            }
            ComposerSpeechStatusLine(
                bridge: bridge,
                accessibilityID: "composer.companion.speech.status"
            )
            // U4：已选插件 / 技能 chip 行（popover 点选后挂在输入框上方，× 移除）
            if !chat.selectedPickerItems.isEmpty {
                PickerSelectionChips(chat: chat)
            }
            // C4-2：编辑模式提示条（转录「编辑」后显示；回车 = 新消息重发）
            if chat.isEditingMessage {
                editModeBar
            }
            atMentionSection
            HStack(spacing: ComposerLayoutMetrics.controlSpacing) {
                ComposerPolicyControls(chat: chat, modeShortcutBinding: bridge.shortcutStore.binding(for: .composerMode))
                    .layoutPriority(1)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.policy.companion")

                // AJ-55 伴随栏模型选择：加同款 ModelMenuButton（复用 ModelPickerPanel 三级状态机 + 记忆），
                // 与主聊天 GlobalComposerView 一致——档位图标 + 模型短名，点击弹面板，确认后下一条消息用新模型。
                ModelMenuButton(chat: chat)
                    .accessibilityIdentifier("composer.model.companion")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer.primary-row.companion")

            AdaptiveControlRowLayout(spacing: ComposerLayoutMetrics.controlSpacing) {

                Button {
                    pickFiles()
                } label: {
                    MinisIconView(.attachment, state: chat.pendingAttachments.isEmpty ? .normal : .active, size: MinisIconTokens.defaultSize)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(
                            width: ComposerLayoutMetrics.iconButtonHitSize,
                            height: ComposerLayoutMetrics.iconButtonHitSize
                        )
                }
                .buttonStyle(.plain)
                .help("添加附件（图片/文本/Markdown/JSON 等）")
                .accessibilityLabel("添加附件")
                .accessibilityHint("选择图片、文本、Markdown 或 JSON 文件")

                // U4：插件 / 技能选择器入口（点击弹出目录 popover）
                Button {
                    showPickerPopover.toggle()
                } label: {
                    MinisIconView(.plugin, state: chat.selectedPickerItems.isEmpty ? .normal : .active, size: MinisIconTokens.defaultSize)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(
                            width: ComposerLayoutMetrics.iconButtonHitSize,
                            height: ComposerLayoutMetrics.iconButtonHitSize
                        )
                }
                .buttonStyle(.plain)
                .help("选择插件 / 技能（选中后以 @技能名 插入草稿，发送时注入技能内容到系统提示）")
                .accessibilityLabel("选择插件或技能")
                .accessibilityHint("打开插件和技能选择器")
                .popover(isPresented: $showPickerPopover, arrowEdge: .top) {
                    PluginSkillPickerPopover(chat: chat)
                        .escapeShortcut(closePopover: {
                            guard showPickerPopover else { return false }
                            showPickerPopover = false
                            return true
                        })
                }

                ComposerSpeechControl(
                    bridge: bridge,
                    chat: chat,
                    accessibilityID: "composer.companion.speech"
                )

                ComposerMemoryToolbarButton(chat: chat)

                Spacer(minLength: ComposerLayoutMetrics.controlSpacing)
            }

            HStack(spacing: ComposerLayoutMetrics.controlSpacing) {
                ComposerScrollField(
                    text: $chat.draftText,
                    font: .systemFont(ofSize: typography?.composerBodySize ?? 13),
                    placeholder: "@ 引用技能或项目文件",
                    onSend: {
                        guard canSend else {
                            chat.noteComposerSendBlockedByAttachments()
                            return
                        }
                        if chat.canSubmitPresentedToolApprovalFromKeyboard {
                            chat.submitComposerFromKeyboard()
                        } else if chat.isActiveSessionGenerating {
                            if chat.newMessageInterruptsGeneration() { chat.interruptAndSend() }
                            else { _ = chat.enqueueComposer() }
                        }
                        else { chat.submitComposerFromKeyboard() }
                    },
                    onPaste: { PastedTextComposerConsumer.accept($0, in: chat) },
                    onCommandKey: { key in
                        if key == .historySearch { showInputHistorySearch = true; return true }
                        if handleAtMentionKey(key) { return true }
                        return chat.handleInputHistoryKey(key)
                    },
                    onCursorChange: { chat.noteComposerCursor($0) },
                    onInterruptAndSend: {
                        guard canSend else {
                            chat.noteComposerSendBlockedByAttachments()
                            return
                        }
                        chat.interruptAndSend()
                    },
                    onStop: {
                        guard chat.isActiveSessionGenerating else { return false }
                        chat.stopStreaming(returnQueuedToDraft: true)
                        return true
                    },
                    persistenceFeedback: chat.draftPersistenceFeedback,
                    focusSessionID: chat.activeSessionID,
                    maxVisibleLines: maxVisibleLines,
                    nativeDraft: chat.nativeComposerDraft(),
                    onRememberNativeDraft: chat.rememberFocusedNativeDraft
                )
                .help("输入指令或对话（生成中回车排队；⌘⇧⏎ 打断并发送；Esc 停止并将队列退回输入框；⇧⏎ 或 ⌥⏎ 换行；@ 引用技能或项目文件）")
                .accessibilityIdentifier("composer.companion.input")
                .onChange(of: chat.draftText) { _, _ in
                    chat.updateFileMentionSuggestions()
                }
                .onChange(of: chat.activeSessionID) { _, _ in
                    atMentionSelectedID = nil
                    atMentionDismissedDraft = nil
                }
                .sheet(isPresented: $showInputHistorySearch) {
                    ComposerInputHistorySearch(chat: chat)
                }

                if chat.isActiveSessionStreaming {
                    if let stopCommand = AppCommandMenuBuilder.command(
                        id: "ui.chat.stop", registry: bridge.commandRegistry,
                        display: bridge.paletteDisplay
                    ) {
                        Button {
                            bridge.runCommand(id: stopCommand.id, args: [
                                "session_id": chat.activeSessionID?.uuidString ?? "",
                                "return_queued_to_draft": "true"
                            ])
                        } label: {
                            MinisIconView(.stop, state: .danger, size: MinisIconTokens.largeSize)
                                .foregroundPalette(theme?.statusDanger ?? .red)
                                .font(.system(size: 18))
                                .frame(
                                    width: ComposerLayoutMetrics.iconButtonHitSize,
                                    height: ComposerLayoutMetrics.iconButtonHitSize
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!stopCommand.isEnabled)
                        .help(stopCommand.disabledReason ?? "\(stopCommand.title)（\(bridge.shortcutStore.binding(for: .stopGeneration).displayString)）")
                        .accessibilityLabel(stopCommand.title)
                        .accessibilityHint(stopCommand.disabledReason ?? "停止当前回复生成；也可使用 \(bridge.shortcutStore.binding(for: .stopGeneration).displayString)")
                    }
                } else {
                    Button {
                        send()
                    } label: {
                        MinisIconView(.send, state: canSend ? .active : .disabled, size: MinisIconTokens.largeSize)
                            .foregroundPalette(canSend ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.secondary)
                            .font(.system(size: 18))
                            .frame(
                                width: ComposerLayoutMetrics.iconButtonHitSize,
                                height: ComposerLayoutMetrics.iconButtonHitSize
                            )
                    }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("composer.send")
                .help(chat.composerAttachmentBlockReason ?? "发送（⌘⏎）")
                .accessibilityLabel("发送")
                .accessibilityHint(chat.composerAttachmentBlockReason ?? "发送当前消息；也可使用 ⌘⏎")
                }
            }
        }
        .padding(ComposerLayoutMetrics.outerPadding)
        .background(
            RoundedRectangle(cornerRadius: ComposerLayoutMetrics.cornerRadius, style: .continuous)
                .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor).opacity(isDropTargeted ? 0.55 : 0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ComposerLayoutMetrics.cornerRadius, style: .continuous)
                .stroke(isDropTargeted ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.clear, lineWidth: 1.5)
        )
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: @ 引用（技能 + 当前项目文件）

    private struct AtMentionItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let skill: PickerCatalogItem?
        let path: String?
        var referencesDirectory = false
    }

    /// 草稿末尾是 @ 词时的候选：先技能（目录里按名称包含匹配，至多 5 个），再项目文件。
    private var atMentionItems: [AtMentionItem] {
        let draft = chat.draftText
        guard !draft.hasPrefix("/"), atMentionDismissedDraft != draft,
              let query = chat.activeAtMentionQuery else { return [] }
        let needle = query.lowercased()
        let skills = chat.pickerCatalog.filter { item in
            item.isEnabled
                && !chat.selectedPickerItems.contains(where: { $0.id == item.id })
                && (needle.isEmpty || item.name.lowercased().contains(needle))
        }.prefix(5).map {
            AtMentionItem(id: "skill:\($0.id)", title: "@\($0.name)", subtitle: "技能 · \($0.detail)",
                          skill: $0, path: nil)
        }
        let files = chat.fileMentionSuggestions.flatMap { path -> [AtMentionItem] in
            let item = AtMentionItem(id: "file:\(path)", title: ChatStore.fileMentionTitle(path),
                          subtitle: (path.hasSuffix("/") ? "目录（回车进入）· " : "文件 · ") + path, skill: nil, path: path)
            guard path.hasSuffix("/") else { return [item] }
            let reference = AtMentionItem(id: "dir-ref:\(path)", title: ChatStore.fileMentionTitle(path),
                          subtitle: "引用此目录 · " + path, skill: nil, path: path, referencesDirectory: true)
            return [item, reference]
        }
        return Array(skills) + files
    }

    @ViewBuilder
    private var atMentionSection: some View {
        let items = atMentionItems
        if !items.isEmpty {
            let selected = items.firstIndex { $0.id == atMentionSelectedID } ?? 0
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { acceptAtMention(item) } label: {
                            HStack(spacing: 8) {
                                Text(item.title).font(.system(.body, design: .monospaced)).lineLimit(1)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == selected ? Color.accentColor.opacity(0.12) : Color.clear)
                        .accessibilityIdentifier("composer.companion.at-mention.\(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
            .accessibilityIdentifier("composer.companion.at-mention-completions")
        }
    }

    private func acceptAtMention(_ item: AtMentionItem) {
        atMentionSelectedID = nil
        if let skill = item.skill {
            chat.acceptSkillMention(skill)
        } else if let path = item.path {
            if item.referencesDirectory {
                _ = chat.acceptDirectoryMention(path)
            } else {
                _ = chat.acceptFileMention(path)
            }
        }
    }

    /// ↑↓ 选择、Tab 或回车确认、Esc 关闭；没有 @ 候选时返回 false，按键照常处理。
    private func handleAtMentionKey(_ key: ComposerNativeKey) -> Bool {
        let items = atMentionItems
        guard !items.isEmpty else { return false }
        let index = items.firstIndex { $0.id == atMentionSelectedID } ?? 0
        switch key {
        case .up:
            atMentionSelectedID = items[max(0, index - 1)].id
            return true
        case .down:
            atMentionSelectedID = items[min(items.count - 1, index + 1)].id
            return true
        case .tab:
            acceptAtMention(items[index])
            return true
        case .returnKey(let option):
            guard !option, !chat.canSubmitPresentedToolApprovalFromKeyboard else { return false }
            acceptAtMention(items[index])
            return true
        case .escape:
            atMentionDismissedDraft = chat.draftText
            return true
        case .shiftTab, .historySearch:
            return false
        }
    }

    /// 有文本或待发送附件时才允许发送
    private var canSend: Bool {
        GlobalComposer.canSend(
            draftText: chat.draftText,
            pendingAttachmentCount: chat.pendingAttachments.count,
            hasPastedText: chat.activePastedTextDraft != nil,
            attachmentsReady: chat.canSubmitComposerAttachments
        )
    }

    /// 发送：直接走原链路（节点-对话已彻底解绑：不再自动补节点名进草稿）
    private func send() {
        guard canSend else {
            chat.noteComposerSendBlockedByAttachments()
            return
        }
        chat.submitInteractiveComposer()
    }

    // MARK: C4-2 编辑模式提示条（转录「编辑」后显示；回车 = 新消息重发，原历史保留）

    private var editModeBar: some View {
        ComposerEditModeBar(chat: chat, accessibilityID: "composer.edit-mode.companion")
    }

    // MARK: 附件预览条（与全局对话条一致）

    private var attachmentPreviewBar: some View {
        let mediaReadiness = chat.composerMediaReadinessSnapshot
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.pendingAttachments) { att in
                    pendingAttachmentChip(att, mediaReadiness: mediaReadiness)
                }
            }
        }
        .onAppear { chat.autoTranscribeAudioDraftsIfNeeded() }
        .onChange(of: mediaReadiness) { _, _ in chat.autoTranscribeAudioDraftsIfNeeded() }
    }

    private func pendingAttachmentChip(
        _ att: ChatAttachment,
        mediaReadiness: ComposerMediaReadinessSnapshot
    ) -> some View {
        let info = SessionSidebarAttachmentChipInfo(att)
        let sourceSessionID = chat.activeSessionID
        return AttachmentPreviewRenderView(attachment: att, sessionID: sourceSessionID, isCurrent: {
            chat.activeSessionID == sourceSessionID && chat.pendingAttachments.contains(att)
        }) { thumbnail, _ in
            HStack(spacing: 5) {
                if let nsImage = thumbnail {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    let icon: MinisIcon = switch att.kind {
                    case .image: .image
                    case .audio: .volume
                    case .text: .document
                    case .file: .file
                    }
                    MinisIconView(icon, size: 12)
                        .foregroundPalette(HierarchicalShapeStyle.secondary)
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.fileName)
                        .font(typography?.caption2 ?? .system(size: 9))
                        .lineLimit(1)
                    Text(info.typeLabel)
                        .font(typography?.caption2 ?? .system(size: 9))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("composer.companion.attachment.type.\(att.id.uuidString)")
                    if let status = ComposerAttachmentPresentation.truncationNotice(for: att, sent: false) ?? info.statusText {
                        Text(status)
                            .font(typography?.caption2 ?? .system(size: 9))
                            .foregroundStyle(theme?.statusWarning ?? Color.orange)
                            .accessibilityIdentifier("composer.companion.attachment.status.\(att.id.uuidString)")
                    }
                    Text(ComposerAttachmentPresentation.mediaReadinessText(for: att, in: mediaReadiness))
                        .font(typography?.caption2 ?? .system(size: 9))
                        .foregroundStyle(
                            mediaReadiness.attachment(id: att.id)?.blocksSend == false
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(theme?.statusWarning ?? Color.orange)
                        )
                        .lineLimit(2)
                        .accessibilityIdentifier("composer.companion.attachment.media-readiness.\(att.id.uuidString)")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ComposerAttachmentPresentation.accessibilityValue(
                    for: att, mediaReadiness: mediaReadiness
                ))
                if att.fileURL != nil,
                   ChatStore.canConvertToPathReference(att) {
                    Button("改为路径引用") {
                        chat.convertPendingAttachmentToPathReference(id: att.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme?.statusWarning ?? Color.orange)
                    .help("不读取内容，只把文件路径发给模型，由模型用 file_read 读取")
                    .accessibilityIdentifier("composer.companion.attachment.convert-to-reference.\(att.id.uuidString)")
                }
                AudioTranscriptionChipControls(chat: chat, attachment: att)
                // 与主输入框一致：附件就绪后可在右侧面板预览。
                let canPreview = onPreviewAttachment != nil && GlobalComposer.canRenderPendingAttachmentPreview(
                    att, expectedSessionID: sourceSessionID, activeSessionID: chat.activeSessionID,
                    pendingAttachments: chat.pendingAttachments)
                Button("预览") {
                    GlobalComposer.previewPendingAttachment(
                        att, expectedSessionID: sourceSessionID,
                        activeSessionID: chat.activeSessionID,
                        pendingAttachments: chat.pendingAttachments,
                        onUnavailable: { attachment, sessionID in
                            onPreviewAttachment?(attachment, sessionID)
                        }
                    ) { attachment, sessionID in
                        onPreviewAttachment?(attachment, sessionID)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canPreview)
                .help(canPreview ? "在右侧面板预览 \(att.fileName)" : "附件就绪且文件来源可用后才能预览")
                .accessibilityIdentifier("composer.companion.attachment.preview.\(att.id.uuidString)")
                Button {
                    chat.removePendingAttachment(id: att.id)
                } label: {
                    MinisIconView(.close, size: MinisIconTokens.smallSize)
                }
                .buttonStyle(.plain)
                .help(att.status == .failed ? "移除读取失败的附件；重新选择后可重试" : "移除附件")
                .accessibilityIdentifier("composer.companion.attachment.remove.\(att.id.uuidString)")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor).opacity(0.15))
            )
        }
    }

    /// E11：📎 打开系统文件面板（多选，任意类型）
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        if panel.runModal() == .OK {
            chat.addAttachments(urls: panel.urls)
        }
    }
}

/// Keeps periodic relative-time refreshes local to one row. The parent sidebar
/// remains driven by session/task projections and is not rebuilt by the clock.
private struct SessionSidebarRelativeTime: View {
    let date: Date
    let sessionID: UUID
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            Text(SessionSidebarPresentation.relativeTime(date, relativeTo: timeline.date))
                .font(typography?.sidebarMeta ?? .system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("typography.session.metadata.\(sessionID.uuidString)")
        }
    }
}

/// Presentation and input validation only; a directory is not an access grant.
enum SessionSidebarPresentation {
    static func relativeTime(_ date: Date, relativeTo now: Date, locale: Locale = .current) -> String {
        let clamped = min(date, now)
        if now.timeIntervalSince(clamped) < 5 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: clamped, relativeTo: now)
    }

    static func projectDirectory(_ text: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if trimmed == "~" { url = homeDirectory }
        else if trimmed.hasPrefix("~/") { url = homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))) }
        else {
            guard trimmed.hasPrefix("/") else { return nil }
            url = URL(fileURLWithPath: trimmed)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }
}

/// 重新生成按钮的呈现：禁用时变淡并直接显示原因短文。
struct RegenerationButtonPresentation: Equatable {
    let isDisabled: Bool
    let opacity: Double
    let visibleReasonText: String?

    static func make(disabledReason: String?) -> RegenerationButtonPresentation {
        guard let disabledReason else {
            return RegenerationButtonPresentation(isDisabled: false, opacity: 1.0, visibleReasonText: nil)
        }
        return RegenerationButtonPresentation(isDisabled: true, opacity: 0.5, visibleReasonText: disabledReason)
    }
}
