import SwiftUI
import MinisCore

/// Desktop actions entered only through the existing Composer adjudicator.
/// Navigation dependencies are mandatory and bind to the existing UI consumers;
/// this object owns no permission rules, model selection or plan approval state.
@MainActor
@Observable
final class N05DesktopCommandConsumer {
    enum Presentation: String, Identifiable {
        case rename, resume, rewind, diff, memory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .memory: "记忆"
            case .rename: "重命名会话"
            case .resume: "恢复会话"
            case .rewind: "回退检查点"
            case .diff: "工作区改动"
            }
        }
    }

    let chat: ChatStore
    var presentation: Presentation?
    private(set) var sourceSessionID: UUID?
    var renameText = ""
    var resumeQuery = ""
    var preselectLatestCheckpoint = false
    var feedback: String?
    /// 当前会话的工作目录（/diff 用）。
    var workspaceDirectory: String? {
        chat.sessions.first { $0.id == chat.activeSessionID }?.workingDirectory
    }
    private let openSettings: (String) -> Void
    private let openModelPicker: () -> Void
    private let openContext: () -> Void
    private let openDoctor: () -> Void
    private let enterPlanMode: (String?) -> Bool
    fileprivate let redactor: () -> ChatTranscriptRedactor
    /// /reject: bound by the App root to the card's Deny entry (see `denyPresentedToolApproval`).
    var rejectToolApproval: ((ComposerSubmissionSnapshot) throws -> String)?

    init(chat: ChatStore, openSettings: @escaping (String) -> Void,
         openModelPicker: @escaping () -> Void, openContext: @escaping () -> Void,
         openDoctor: @escaping () -> Void, enterPlanMode: @escaping (String?) -> Bool,
         redactor: @escaping () -> ChatTranscriptRedactor) {
        self.chat = chat
        self.openSettings = openSettings
        self.openModelPicker = openModelPicker
        self.openContext = openContext
        self.openDoctor = openDoctor
        self.enterPlanMode = enterPlanMode
        self.redactor = redactor
    }

    func execute(_ request: PendingCommandRequest, snapshot: ComposerSubmissionSnapshot) throws -> String {
        // A delayed/queued command cannot act on the newly selected session.
        guard snapshot.sessionID == chat.activeSessionID?.uuidString else {
            throw CommandExecutionError.disabled(commandID: request.commandID, reason: "命令所属会话已切换，请重新提交")
        }
        switch request.commandID {
        case "model": openModelPicker(); return "已打开模型选择器。"
        case "shortcuts":
            guard request.args["action"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
                throw CommandExecutionError.disabled(commandID: "shortcuts", reason: "此入口不支持附加操作；请用 /shortcuts 打开快捷键设置。")
            }
            openSettings("快捷键"); return "已打开快捷键设置。"
        case "permissions": openSettings("权限"); return "已打开权限管理；允许、拒绝、每次询问规则在“规则管理”一节，可手动增改或导入 .claude/settings.json。新增目录仍需明确授权。"
        case "memory": present(.memory); return "已打开记忆面板；完整管理在 设置 › 记忆。"
        case "mcp": openSettings("MCP"); return "已打开 MCP 管理。"
        case "usage":
            // 对话里直接给出本会话汇总；全部会话与单价设置仍在 设置 › 用量。
            guard let center = SettingsCenter.active else { openSettings("用量"); return "已打开用量记录。" }
            let records = UsageFilteredSettingsView.sessionRecords(
                from: center.usageStore, sessionID: chat.activeSessionID?.uuidString)
            guard !records.isEmpty else {
                openSettings("用量")
                return "本会话还没有用量记录，已打开 设置 › 用量 查看全部会话。"
            }
            let input = records.reduce(0) { $0.addingReportingOverflow($1.totalInputTokens).partialValue }
            let output = records.reduce(0) { $0.addingReportingOverflow($1.outputTokens).partialValue }
            let cost = UsageModelPricing.display(records: records, prices: center.usageStore.modelPricing)
            return "本会话用量：\(records.count) 次调用，输入 \(ChatStore.formatTokenCount(input))、输出 \(ChatStore.formatTokenCount(output)) tokens（输入含缓存）。估算费用：\(cost)（按你在 设置 › 用量 里填写的单价估算，仅供参考；没填单价的模型不计）。"
        case "skills": openSettings("技能"); return "已打开技能管理；新增技能仍需导入审核。"
        case "context": openContext(); return "已打开上下文面板。"
        case "doctor": openDoctor(); return "已打开环境诊断。"
        case "plan":
            guard enterPlanMode(request.args["description"]) else {
                throw CommandExecutionError.disabled(commandID: "plan", reason: "当前无法进入计划模式")
            }
            return "已进入计划模式；执行仍需计划批准。"
        case "clear":
            let previous = chat.activeSessionID
            let source = chat.sessions.first { $0.id == previous }
            chat.newSession(projectID: source?.projectID, projectName: source?.projectName,
                            workingDirectory: source?.workingDirectory, groupID: source?.groupID)
            return "已新建会话；旧会话保留，可用 /resume 恢复。"
        case "export":
            let redactor = redactor()
            let title = chat.sessions.first { $0.id == chat.activeSessionID }?.title ?? "会话"
            return SessionMarkdownExport.chooseDestination(title: title, messages: chat.messages, redactor: redactor,
                events: chat.conversationEvents.filter { $0.identity.sessionID == chat.activeSessionID?.uuidString })
        case "rename":
            if let title = request.args["title"], let sessionID = chat.activeSessionID {
                chat.renameSession(id: sessionID, title: title)
                return "会话已重命名。"
            }
            present(.rename)
            return "请输入新的会话名称。"
        case "stop":
            try rejectTaskID(request)
            guard chat.isActiveSessionGenerating else {
                throw CommandExecutionError.disabled(commandID: "stop", reason: "当前没有进行中的生成")
            }
            // Same call as the Composer Stop button (ui.chat.stop with return_queued_to_draft).
            chat.stopStreaming(returnQueuedToDraft: true)
            return "已停止当前生成。"
        case "retry":
            try rejectTaskID(request)
            guard let sessionID = chat.activeSessionID,
                  let identity = chat.sessionList.first(where: { $0.session.id == sessionID })?.retryIdentity else {
                throw CommandExecutionError.disabled(commandID: "retry", reason: "当前会话没有可重试的失败任务")
            }
            // Same call as the failed-row Retry button in the session sidebar.
            guard chat.retryFailedSession(identity) else {
                throw CommandExecutionError.disabled(commandID: "retry", reason: "失败记录已变化，未重试")
            }
            return "已重试上一个失败任务。"
        case "reject":
            try rejectTaskID(request)
            guard let rejectToolApproval else {
                throw CommandExecutionError.disabled(commandID: "reject", reason: "审批拒绝入口未接线")
            }
            return try rejectToolApproval(snapshot)
        case "resume": present(.resume); return "请选择要恢复的会话。"
        case "rewind": preselectLatestCheckpoint = false; present(.rewind); return "请选择检查点并确认恢复范围。"
        case "diff":
            // 只读：git status + git diff HEAD，与改动面板“工作区改动”页是同一个视图。
            present(.diff)
            return "已打开工作区改动（只读）。"
        case "undo":
            // /undo 是 /rewind 的别名：同一个面板，预选最新检查点，仍需确认。
            preselectLatestCheckpoint = true; present(.rewind)
            return "已选中最新检查点，请确认恢复范围。"
        default:
            throw CommandExecutionError.disabled(commandID: request.commandID, reason: "不属于桌面命令入口")
        }
    }

    /// stop/retry/reject act on the current session only; an explicit task id is not supported.
    private func rejectTaskID(_ request: PendingCommandRequest) throws {
        guard request.args["task_id"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            throw CommandExecutionError.disabled(commandID: request.commandID,
                reason: "此入口只作用于当前会话，不支持 task id")
        }
    }

    /// Same action as the approval card's Deny button: the card's own rendered action.
    static func denyPresentedToolApproval(
        _ center: ApprovalPromptCenter, snapshot: ComposerSubmissionSnapshot
    ) throws -> String {
        guard let target = center.pendingRequest, target.sessionID == snapshot.sessionID else {
            throw CommandExecutionError.disabled(commandID: "reject", reason: "当前会话没有待审批的工具请求")
        }
        center.actionsForPresentedRequest().deny()
        return "已拒绝当前工具请求。"
    }

    private func present(_ value: Presentation) {
        sourceSessionID = chat.activeSessionID
        renameText = chat.sessions.first { $0.id == sourceSessionID }?.title ?? ""
        feedback = nil
        resumeQuery = ""
        presentation = value
    }

    func rename() {
        guard sourceSessionID == chat.activeSessionID, let id = sourceSessionID,
              !chat.isActiveSessionGenerating else { feedback = "会话已切换或正在运行，请重新提交命令。"; return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { feedback = "名称不能为空。"; return }
        chat.renameSession(id: id, title: title)
        presentation = nil
    }

    // MARK: /memory 轻量面板

    var memoryInput = ""

    /// 面板里列出的记忆：项目会话 = 本项目已生效的记忆；普通会话 = 个人记忆里“我的记忆”段。
    func memoryEntries() -> [String] {
        _ = memoryPanelRevision
        guard let center = SettingsCenter.active else { return [] }
        if let scope = chat.activeMemoryScope {
            return center.memoryFacts
                .filter { $0.lifecycleState == .active && $0.memoryScope?.projectID == scope.projectID }
                .map(\.text)
        }
        guard let owner = center.memoryTrustedPrincipalProvider?()?.userID else { return [] }
        return center.memoryFacts
            .filter { $0.lifecycleState == .active && $0.visibility == .personal && $0.ownerUserID == owner }
            .map(\.text)
    }

    /// 面板打开时由界面的 .task 调用一次：把旧版写在 GLOBAL.md 里的个人记忆迁走，
    /// 完成后刷新列表。不在界面渲染过程中读写文件。
    func prepareMemoryPanel() {
        guard chat.activeMemoryScope == nil, let center = SettingsCenter.active else { return }
        center.migratePersonalMemorySectionFromGlobal()
        memoryPanelRevision += 1
    }

    private(set) var memoryPanelRevision = 0

    var memoryScopeDescription: String {
        chat.activeMemoryScope != nil ? "项目记忆（本项目的所有会话可用）" : "个人记忆（所有会话可用）"
    }

    func addMemoryFromPanel() {
        guard sourceSessionID == chat.activeSessionID, let center = SettingsCenter.active else {
            feedback = "会话已切换，请重新打开 /memory。"; return
        }
        switch center.addUserTypedMemory(memoryInput, within: chat.activeMemoryScope,
                                         sessionID: chat.activeSessionID?.uuidString) {
        case .project, .personal:
            memoryInput = ""
            feedback = center.memoryEnabled ? "已记住。" : "已记住，但“记忆”开关目前是关闭的，打开后才会在对话里生效。"
        case .credentialLike: feedback = "这段内容像密钥或密码，没有保存。"
        case .personalFull: feedback = "个人记忆已接近上限，请到 设置 › 记忆 精简后再记。"
        case .failed: feedback = "记忆未能保存，请检查输入或存储后重试。"
        }
    }

    func openFullMemorySettings() {
        presentation = nil
        openSettings("记忆")
    }

    func resume(_ id: UUID) {
        // 生成中也可以切换（与侧栏一致）：旧会话的回复继续写回它自己。
        guard sourceSessionID == chat.activeSessionID else {
            feedback = "会话已切换，请重新打开会话选择。"; return
        }
        chat.resumeSession(id: id)
        presentation = nil
    }


}

/// The existing recovery view owns both restore scopes and their disclosure.
/// N05 owns only the rename/resume selection UI, not another restore state machine.
struct N05DesktopCommandPanel: View {
    @Bindable var consumer: N05DesktopCommandConsumer
    let presentation: N05DesktopCommandConsumer.Presentation
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        if presentation == .rewind {
            FileCheckpointRecoveryView(chat: consumer.chat, redactor: consumer.redactor(),
                                       preselectLatest: consumer.preselectLatestCheckpoint)
        } else if presentation == .diff {
            VStack(alignment: .leading, spacing: 10) {
                WorkspaceChangesView(directory: consumer.workspaceDirectory)
                Button("关闭") { consumer.presentation = nil }
            }
            .padding(20).frame(minWidth: 520, idealWidth: 720, minHeight: 320, idealHeight: 520)
        } else {
            selectionBody
        }
    }

    private var selectionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.title).font(typography?.headline ?? .headline)
            if presentation == .rename {
                TextField("会话名称", text: $consumer.renameText)
                    .onSubmit { consumer.rename() }
                Button("保存") { consumer.rename() }.buttonStyle(.borderedProminent)
            } else if presentation == .memory {
                Text(consumer.memoryScopeDescription)
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                TextField("输入要记住的内容，回车添加", text: $consumer.memoryInput)
                    .onSubmit { consumer.addMemoryFromPanel() }
                    .accessibilityIdentifier("n05.memory-input")
                Button("添加") { consumer.addMemoryFromPanel() }
                    .disabled(consumer.memoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        let entries = consumer.memoryEntries()
                        if entries.isEmpty {
                            Text("还没有记忆。对话里直接输入“请记住……”或以“# ”开头也能添加。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, text in
                            Text("• " + text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Button("打开完整记忆设置") { consumer.openFullMemorySettings() }
                    .task { consumer.prepareMemoryPanel() }
            } else {
                TextField("搜索标题、内容或日期（含已归档）", text: $consumer.resumeQuery)
                    .accessibilityIdentifier("n05.resume-search")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        let candidates = consumer.chat.resumeCandidates(matching: consumer.resumeQuery)
                        if candidates.isEmpty {
                            Text("没有匹配的会话").foregroundStyle(.secondary)
                        }
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, entry in
                            Button { consumer.resume(entry.session.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.isArchived ? "\(entry.session.title)（已归档）" : entry.session.title)
                                    Text(entry.session.updatedAt, style: .date)
                                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            if let feedback = consumer.feedback { Text(feedback).font(typography?.caption ?? .caption) }
            Button("关闭") { consumer.presentation = nil }
        }
        .font(typography?.body ?? .body)
        .padding(20).frame(minWidth: 360, idealWidth: 460, minHeight: 180, idealHeight: 380)
    }
}
