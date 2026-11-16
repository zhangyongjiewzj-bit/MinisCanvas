import SwiftUI
import MinisCore

/// Desktop actions entered only through the existing Composer adjudicator.
/// Navigation dependencies are mandatory and bind to the existing UI consumers;
/// this object owns no permission rules, model selection or plan approval state.
@MainActor
@Observable
final class N05DesktopCommandConsumer {
    enum Presentation: String, Identifiable {
        case rename, resume, rewind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rename: "重命名会话"
            case .resume: "恢复会话"
            case .rewind: "回退检查点"
            }
        }
    }

    let chat: ChatStore
    var presentation: Presentation?
    private(set) var sourceSessionID: UUID?
    var renameText = ""
    var feedback: String?
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
        case "permissions": openSettings("权限"); return "已打开权限管理；新增目录仍需明确授权。"
        case "memory": openSettings("记忆"); return "已打开记忆页。"
        case "mcp": openSettings("MCP"); return "已打开 MCP 管理。"
        case "usage": openSettings("用量"); return "已打开用量记录。"
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
        case "rewind": present(.rewind); return "请选择检查点并确认恢复范围。"
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

    func resume(_ id: UUID) {
        guard sourceSessionID == chat.activeSessionID, !chat.isActiveSessionGenerating else {
            feedback = "会话已切换或正在运行，请重新打开会话选择。"; return
        }
        chat.switchSession(id: id)
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
            FileCheckpointRecoveryView(chat: consumer.chat, redactor: consumer.redactor())
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
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(consumer.chat.sessionsSorted) { session in
                            Button { consumer.resume(session.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(session.title)
                                    Text(session.updatedAt, style: .date)
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
