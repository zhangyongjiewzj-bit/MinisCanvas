import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinisCore

// MARK: - E21 全局对话条（三栏底部通栏，所有主区视图可用）
//
// 输入框从 ChatMainView 移出，固定在 ContentView 底部（聊天 / 画布 / 文档视图共用）。
// 节点-对话已彻底解绑（2026-08-06 用户定案）：前台不再显示选中节点徽标、
// 不再自动补全节点名；applySelectedNodeContext 保留为后台接口供画布指令链路使用。

/// 选中节点上下文指令补全（纯函数，可单测）
enum GlobalComposer {
    /// Q8-r5（Q8-r4 P2-3）：快捷键单一事实来源。
    /// 注册（下方发送按钮 .keyboardShortcut）与标注（.help 文案）共用，
    /// 防止再次出现「help 宣称 ⌘⏎/⌘. 但按钮未注册」的漂移。
    static let sendShortcutDisplay = "⌘⏎"
    static let stopShortcutDisplay = "⌘."

    /// Q8-r5：发送可用性（纯函数，可单测）——有非空文本或待发送附件才可发送。
    static func canSend(
        draftText: String,
        pendingAttachmentCount: Int,
        hasPastedText: Bool = false,
        attachmentsReady: Bool = true
    ) -> Bool {
        let whitespace = CharacterSet.whitespacesAndNewlines
        return attachmentsReady && (draftText.unicodeScalars.contains { !whitespace.contains($0) }
            || pendingAttachmentCount > 0
            || hasPastedText)
    }

    /// A pending chip may open only while its original session and ready
    /// attachment are still the active draft. Recheck at the click boundary:
    /// a stale SwiftUI button must not preview an attachment in a new chat.
    static func canPreviewPendingAttachment(
        _ attachment: ChatAttachment,
        expectedSessionID: UUID?,
        activeSessionID: UUID?,
        pendingAttachments: [ChatAttachment],
        fileManager: FileManager = .default
    ) -> Bool {
        guard isCurrentPendingAttachment(attachment, expectedSessionID: expectedSessionID,
            activeSessionID: activeSessionID, pendingAttachments: pendingAttachments) else { return false }
        return ChatAttachmentOpenTarget.canOpen(attachment, fileManager: fileManager)
    }

    /// Routing identity only: source availability is checked separately before
    /// opening. A current but missing source must still reach the error route.
    static func isCurrentPendingAttachment(
        _ attachment: ChatAttachment, expectedSessionID: UUID?, activeSessionID: UUID?,
        pendingAttachments: [ChatAttachment]
    ) -> Bool {
        guard let expectedSessionID, expectedSessionID == activeSessionID,
              attachment.status == .ready else { return false }
        return pendingAttachments.contains(attachment)
    }

    /// Display eligibility uses only a background-validated hint. The actual
    /// preview action below rechecks the live source at the click boundary.
    @MainActor
    static func canRenderPendingAttachmentPreview(
        _ attachment: ChatAttachment,
        expectedSessionID: UUID?, activeSessionID: UUID?,
        pendingAttachments: [ChatAttachment]
    ) -> Bool {
        guard let expectedSessionID, expectedSessionID == activeSessionID,
              attachment.status == .ready,
              pendingAttachments.contains(attachment) else { return false }
        return AttachmentThumbnailer.cachedSourceState(for: attachment)?.isOpenable == true
    }

    @MainActor
    static func previewPendingAttachment(
        _ attachment: ChatAttachment,
        expectedSessionID: UUID?, activeSessionID: UUID?,
        pendingAttachments: [ChatAttachment], fileManager: FileManager = .default,
        onUnavailable: ((ChatAttachment, UUID) -> Void)? = nil,
        onPreview: (ChatAttachment, UUID) -> Void
    ) {
        guard isCurrentPendingAttachment(attachment, expectedSessionID: expectedSessionID,
                                         activeSessionID: activeSessionID,
                                         pendingAttachments: pendingAttachments),
              let expectedSessionID else { return }
        guard ChatAttachmentOpenTarget.canOpen(attachment, fileManager: fileManager) else {
            onUnavailable?(attachment, expectedSessionID)
            return
        }
        onPreview(attachment, expectedSessionID)
    }

    /// Slash completion is a projection of the shared command registry plus
    /// the Phase 3 slash vocabulary (ComposerSlashCommandMenu). Completion
    /// never executes a command; selection writes a canonical `/<id>` back
    /// into the draft and reuses the normal send boundary.
    static func slashSuggestions(
        for input: String,
        registry: CommandRegistry,
        sessionState: ComposerSlashSessionState = .neutral
    ) -> [CommandDefinition] {
        ComposerSlashCommandMenu.entries(
            matching: input,
            registry: registry,
            sessionState: sessionState
        ).map(\.completionCommand)
    }

    /// Completion never discards arguments the user has already typed.
    /// A bare required-argument row completes into an editable draft; an
    /// exact parsed invocation may send through the usual Composer boundary.
    static func acceptedSlashDraft(
        current: String, entry: ComposerSlashMenuEntry, registry: CommandRegistry
    ) -> (text: String, shouldSend: Bool) {
        if let custom = entry.customCommand {
            // 自定义命令：用户已经在命令名后面写了参数就原样保留并发送，否则补全成 "/名称"。
            let typed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = typed.lowercased()
            let hasTypedArguments = lowered.hasPrefix("/\(entry.id) ")
                && !typed.dropFirst(entry.id.count + 1).trimmingCharacters(in: .whitespaces).isEmpty
            if hasTypedArguments { return (typed, entry.state == .available) }
            // 需要参数的命令只补全并留一个尾随空格，等用户接着写参数。
            return entry.shouldSendOnAccept ? ("/\(custom.name)", true) : ("/\(custom.name) ", false)
        }
        let parsed = MinisCore.CommandParser().parse(current, registry: registry)
        let exact = parsed.matchScore == 100 && parsed.command?.id == entry.id
        let text = exact ? current : "/\(entry.id)"
        let hasRequiredArguments = entry.routedCommand?.argumentSpecs
            .filter(\.required).allSatisfy { parsed.args[$0.name]?.isEmpty == false } ?? true
        let canDispatch = entry.state == .available || entry.state == .requiresApproval
        return (text, canDispatch && (entry.shouldSendOnAccept || (exact && hasRequiredArguments)))
    }

    /// The Phase 3 Chat lane never offers a Canvas completion. Direct/stale
    /// slash submissions still pass through the production executor gate.
    static func visibleSlashEntries(
        for input: String,
        registry: CommandRegistry,
        sessionState: ComposerSlashSessionState,
        canvasAvailable: Bool,
        customCommands: [CustomSlashCommand] = []
    ) -> [ComposerSlashMenuEntry] {
        ComposerSlashCommandMenu.entries(
            matching: input,
            registry: registry,
            sessionState: sessionState,
            customCommands: customCommands
        ).filter { entry in
            if canvasAvailable { return true }
            if AppCommandCatalog.phase3DisabledCanvasSlashIDs.contains(entry.id),
               let command = entry.routedCommand,
               case .disabled = command.currentAvailability { return true }
            return entry.completionCommand.category != .canvas
                && entry.completionCommand.id != "ui.pipeline"
        }
    }

    /// Keep the view's common prose path ahead of dismissal-key creation and
    /// command-state projection. Deferred inputs are evaluated only for slash
    /// drafts, so long ordinary drafts do not materialize a context key.
    @MainActor
    static func slashMenuEntries(
        for input: String,
        dismissedContextKey: String?,
        contextKey: () -> String,
        registry: () -> CommandRegistry,
        sessionState: () -> ComposerSlashSessionState,
        canvasAvailable: () -> Bool,
        customCommands: () -> [CustomSlashCommand] = { [] }
    ) -> [ComposerSlashMenuEntry] {
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard input.unicodeScalars.first(where: { !whitespace.contains($0) })?.value == 47 else {
            return []
        }
        guard dismissedContextKey != contextKey() else { return [] }
        return visibleSlashEntries(
            for: input,
            registry: registry(),
            sessionState: sessionState(),
            canvasAvailable: canvasAvailable(),
            customCommands: customCommands()
        )
    }

    /// Project only the executor blockers owned by the production command
    /// adjudication consumer. An absent reason makes no broader claim about
    /// configuration, permission, or readiness.
    @MainActor
    static func missingExecutorReasons(registry: CommandRegistry) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            ComposerSlashCommandMenu.descriptors(registry: registry).compactMap { descriptor in
                ComposerCommandAdjudicationCenter.missingExecutorReason(for: descriptor.id)
                    .map { (descriptor.id, $0) }
            }
        )
    }

    /// Keep one menu reason map. The adjudicator's missing-executor verdict
    /// takes precedence; Bridge contributes only other observed blockers.
    /// Unknown facts and the absence of a known blocker grant no execution.
    @MainActor
    static func commandReadinessReasons(
        registry: CommandRegistry,
        bridge: BridgeStore
    ) -> [String: String] {
        var reasons = missingExecutorReasons(registry: registry)
        for descriptor in ComposerSlashCommandMenu.descriptors(registry: registry) {
            // Preset and App IDs share this registry but execute through the
            // registered non-Composer slash route. The Composer adjudicator's
            // `.unregistered` verdict applies only to its own command IDs.
            guard CommandRegistry.composerCommandIDs.contains(descriptor.id) else { continue }
            guard reasons[descriptor.id] == nil else { continue }
            if let reason = bridge.composerCommandReadinessObservation(
                for: descriptor.id
            ).knownBlockerReason {
                reasons[descriptor.id] = reason
            }
        }
        return reasons
    }

    struct PasteState: Equatable, Sendable {
        let body: String
        let pastedText: PastedTextDraft
    }

    static func pasteState(from event: ComposerPasteEvent) -> PasteState {
        PasteState(body: event.bodyBefore, pastedText: event.draft)
    }

    /// 画布选中节点时，为节点编辑类指令自动补全节点名：
    /// - 「调整 更紧凑」→「调整 <节点名>：更紧凑」
    /// - 「总结」→「总结 <节点名>」；「改 更紧凑」→「改 <节点名> 的内容：更紧凑」
    /// - 已带节点名（CommandParser 能解析为完整节点指令）或非节点编辑指令
    ///   （建节点 / 连线 / 执行 / 普通对话）→ 原样返回
    static func applySelectedNodeContext(text: String, nodeTitle: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let title = nodeTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return text
        }
        // 已是完整节点指令（已带节点名）→ 不补全
        if CommandParser.parse(trimmed) != nil { return text }
        // 「调整 <指令>」（无节点名、无冒号结构）→「调整 <节点名>：<指令>」
        if trimmed.hasPrefix("调整 "), !trimmed.contains("："), !trimmed.contains(":") {
            let body = String(trimmed.dropFirst("调整 ".count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return "调整 \(title)：\(body)" }
        }
        // 「总结」（无节点名）→「总结 <节点名>」
        if trimmed == "总结" { return "总结 \(title)" }
        // 「改 <内容>」（无节点名）→「改 <节点名> 的内容：<内容>」
        if trimmed.hasPrefix("改 ") {
            let body = String(trimmed.dropFirst("改 ".count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return "改 \(title) 的内容：\(body)" }
        }
        // 「设置 <内容>」（无节点名）→「设置 <节点名>：<内容>」
        if trimmed.hasPrefix("设置 ") {
            let body = String(trimmed.dropFirst("设置 ".count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return "设置 \(title)：\(body)" }
        }
        return text
    }
}

/// P3-UI-03「Composer 按宽度折叠」的唯一折叠裁决（纯函数，可单测）。
///
/// 输入框面板自身的可用宽度（面板宽度扣两侧内边距）决定折叠，不再拿它去套
/// 主窗口宽度类（窗口 800/1100 的断点与面板宽度不是一回事：两侧栏展开时窗口很宽、
/// 面板却很窄）。
///
/// 阈值依据（原生宿主实测）：默认字号下内联主控件行实际约 622pt 宽，取 660 留余量；
/// 字号放大时控件行同比变宽，阈值乘以排版内容缩放（不低于 1 倍）。
/// 低于阈值就收进溢出弹层，折叠只改变呈现位置，不改变任何控件行为。
enum GlobalComposerWidthPolicy {
    static let inlineMinimumUsableWidth: CGFloat = 660

    static func collapsesPolicyControls(usableWidth: CGFloat, contentScale: CGFloat = 1) -> Bool {
        usableWidth < inlineMinimumUsableWidth * max(1, contentScale)
    }
}

struct ConversationGoalBudgetDraft {
    enum InvalidInput: LocalizedError {
        case turns, tokens, duration

        var errorDescription: String? {
            switch self {
            case .turns: "回合上限须为正整数。"
            case .tokens: "Token 上限须为正整数，或留空表示不限。"
            case .duration: "时长上限须为大于零的分钟数，或留空表示不限。"
            }
        }
    }

    var turns: String
    var tokens: String
    var minutes: String
    private let originalDurationSeconds: Double?
    private let initialMinutes: String

    static func goalBudgetMinutesText(_ minutes: Double, locale: Locale = .current) -> String {
        minutes.formatted(.number.grouping(.never).precision(.fractionLength(0...1)).locale(locale))
    }

    init(_ budget: ConversationGoalState.Budget) {
        turns = String(budget.turnLimit)
        tokens = budget.tokenLimit.map { String($0) } ?? ""
        originalDurationSeconds = budget.durationLimitSeconds
        initialMinutes = budget.durationLimitSeconds.map {
            Self.goalBudgetMinutesText($0 / 60, locale: Locale(identifier: "en_US_POSIX"))
        } ?? ""
        minutes = initialMinutes
    }

    func limits() throws -> (turns: Int, tokens: Int?, durationSeconds: Double?) {
        guard let turnLimit = Int(turns.trimmingCharacters(in: .whitespacesAndNewlines)),
              turnLimit > 0 else { throw InvalidInput.turns }
        let tokenText = tokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenLimit = Int(tokenText)
        guard tokenText.isEmpty || (tokenLimit ?? 0) > 0 else { throw InvalidInput.tokens }
        let minuteText = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        if minuteText == initialMinutes {
            return (turnLimit, tokenLimit, originalDurationSeconds)
        }
        let seconds = Double(minuteText).map { $0 * 60 }
        if !minuteText.isEmpty {
            guard let seconds, seconds.isFinite, seconds > 0 else { throw InvalidInput.duration }
        }
        return (turnLimit, tokenLimit, seconds)
    }
}

private struct ConversationGoalBudgetButton: View {
    let budget: ConversationGoalState.Budget
    let save: (ConversationGoalBudgetDraft) throws -> Void

    @State private var draft: ConversationGoalBudgetDraft
    @State private var showing = false
    @State private var errorMessage: String?

    init(budget: ConversationGoalState.Budget, save: @escaping (ConversationGoalBudgetDraft) throws -> Void) {
        self.budget = budget
        self.save = save
        _draft = State(initialValue: ConversationGoalBudgetDraft(budget))
    }

    var body: some View {
        Button("预算") {
            draft = ConversationGoalBudgetDraft(budget)
            errorMessage = nil
            showing = true
        }
        .accessibilityIdentifier("composer.goal-budget")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("回合上限") {
                    TextField("正整数", text: $draft.turns)
                        .accessibilityIdentifier("composer.goal-budget.turns")
                }
                LabeledContent("Token 上限") {
                    TextField("不限", text: $draft.tokens)
                        .accessibilityIdentifier("composer.goal-budget.tokens")
                }
                LabeledContent("时长上限（分钟）") {
                    TextField("不限", text: $draft.minutes)
                        .accessibilityIdentifier("composer.goal-budget.minutes")
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("取消") { showing = false }
                    Button("保存") {
                        do {
                            try save(draft)
                            showing = false
                        } catch let error as ConversationGoalBudgetDraft.InvalidInput {
                            errorMessage = error.errorDescription
                        } catch {
                            errorMessage = "未能保存预算。请确认当前会话目标后重试。"
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("composer.goal-budget.save")
                }
            }
            .textFieldStyle(.roundedBorder)
            .buttonStyle(.bordered)
            .frame(width: 300)
            .padding()
        }
    }
}

/// 全局底部对话条：输入框 + 📎 附件 + 🎯 选中节点徽标 + 发送/停止。
/// 位于 ContentView 三栏之下通栏，聊天 / 画布 / 文档视图都能看到并使用。
/// 无障碍值依赖“能否发送”（读草稿）：在修饰器自己的 body 里订阅草稿，
/// 按键只重算这个修饰器，不让 GlobalComposerView 外壳失效。
private struct ComposerDraftAccessibilityValue: ViewModifier {
    let chat: ChatStore
    let value: () -> String
    func body(content: Content) -> some View {
        _ = chat.composerDraft.revision
        return content.accessibilityValue(value())
    }
}

struct GlobalComposerView: View {
    @Bindable var bridge: BridgeStore
    @Bindable var chat: ChatStore
    @FocusedValue(\.chatStopAction) private var focusedStopAction
    var onPreviewAttachment: ((ChatAttachment, UUID) -> Void)? = nil
    /// 当前主区视图（ContentView 持有；画布视图 + 选中节点 → 节点上下文）
    let mainPane: MainPane
    /// E11 文件拖放悬停（输入区高亮提示）
    @State private var showInputHistorySearch = false
    @State private var isDropTargeted = false
    /// G-10：原生输入框是否持有焦点（由 NSTextView 的 first responder 变化回调），只驱动外框描边。
    @State private var isInputFocused = false
    @State private var goalObjective = ""
    @State private var showsGoalInput = false
    /// 11/19 用户：目标卡片的预算、续跑状态、复核与证据默认收起，只留一行标题和操作按钮，
    /// 免得输入框上方占掉半屏；"待你处理"和"先调高预算"这类要你动手的提示照常显示。
    @State private var goalDetailsExpanded = false
    @State private var goalActionFailed = false
    @State private var goalActionFailureText = "未能更新会话目标。"
    @State private var pendingGoalSessionBudgetReset: SessionBudgetResetTarget?
    /// AJ-1 插件 / 技能选择器 popover（复用 U4 PluginSkillPickerPopover）
    @State private var showPickerPopover = false
    @State private var pastedTextEditorState: PastedTextEditorState?
    @State private var slashCompletionSelectedCommandID: String?
    @State private var slashCompletionDismissedContextKey: String?
    @State private var atMentionSelectedID: String?
    @State private var atMentionDismissedDraft: String?
    /// P3-UI-03：容器实测的控件行可用宽度（pt）。nil 表示首帧测量尚未完成，
    /// 测量完成前保持内联呈现，策略控件在任何时刻都不会闪失。
    @State private var composerUsableWidth: CGFloat?
    /// P3-UI-03：折叠态下策略控件溢出弹层的开合。
    @State private var showPolicyOverflowPopover = false
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    /// 当前主区是否为画布（三栏主区切到画布，或画布独占布局）
    private var isCanvasActive: Bool {
        bridge.layoutMode == .canvas || (bridge.layoutMode == .split && mainPane == .canvas)
    }

    private func goalStatusTitle(_ status: ConversationGoalState.Status) -> String {
        switch status {
        case .active: "进行中"
        case .awaitingReview: "正在核对完成证据"
        case .blocked: "受阻"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case .completed: "已完成"
        }
    }

    /// The review keeps the served provider identity for usage accounting;
    /// the goal bar shows only its safe display label, never the raw route.
    static func goalReviewProviderText(_ identity: String, records: [EnvVarEntry] = []) -> String {
        ChatStore.presentationProviderLabel(for: identity, records: records)
    }

    private func goalReviewOutcomeTitle(_ outcome: ConversationGoalState.ReviewRecord.Outcome) -> String {
        switch outcome {
        case .passed: "复核通过"
        case .rejected: "复核未通过"
        case .invalidResponse: "复核结果格式无效"
        case .unavailable: "复核暂不可用"
        case .cancelled: "复核已取消"
        case .timedOut: "复核超时"
        }
    }

    private func goalStatusColor(_ status: ConversationGoalState.Status) -> Color {
        switch status {
        case .active: theme?.statusRunning ?? .blue
        case .paused: theme?.statusWarningText ?? .orange
        default: .primary
        }
    }

    @ViewBuilder
    private func conversationGoalBar(sessionID: UUID) -> some View {
        let goal = chat.conversationGoal(for: sessionID)
        VStack(alignment: .leading, spacing: 6) {
            if let goal {
                let goalBudgetExhausted = goal.budget.usedTurns >= goal.budget.turnLimit
                    || goal.budget.tokenLimit.map { goal.budget.usedTokens >= $0 } == true
                    || goal.budget.durationLimitSeconds.map { goal.budget.usedDurationSeconds >= $0 } == true
                HStack(spacing: 8) {
                    Button {
                        goalDetailsExpanded.toggle()
                    } label: {
                        MinisIconView(goalDetailsExpanded ? .caretDown : .caretRight, size: 10)
                            .frame(width: 12)
                    }
                    .help(goalDetailsExpanded ? "收起目标详情" : "展开目标详情（预算、续跑状态、复核与证据）")
                    .accessibilityLabel(goalDetailsExpanded ? "收起目标详情" : "展开目标详情")
                    .accessibilityIdentifier("composer.goal-details-toggle")
                    MinisIconView(.target, size: MinisIconTokens.smallSize)
                        .accessibilityHidden(true)
                    Text(goal.reviewNeedsAttention ? "目标复核待处理"
                         : (goal.allRemainingWorkBlocked ? "全部等你" : goalStatusTitle(goal.status)))
                        .foregroundStyle(goalStatusColor(goal.status))
                        .font((typography?.status ?? .caption).weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        .fixedSize()
                    Text(goal.objective)
                        .font(typography?.status ?? .caption)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help(goal.objective)
                    Spacer(minLength: 0)
                    if goal.status != .completed && goal.status != .stopped {
                        ConversationGoalBudgetButton(budget: goal.budget) { draft in
                            try chat.updateConversationGoalBudget(sessionID: sessionID, goalID: goal.id, draft: draft)
                        }
                        .id(goal.id)
                        .disabled(goal.status == .awaitingReview)
                    }
                    if goal.status != .completed && goal.status != .stopped {
                        Button(goal.autoContinueEnabled ? "关闭自动续跑" : "开启自动续跑") {
                            performGoalAction {
                                try chat.setConversationGoalAutoContinue(
                                    sessionID: goal.sessionID, goalID: goal.id,
                                    enabled: !goal.autoContinueEnabled)
                            }
                        }
                        .accessibilityIdentifier("composer.goal-auto-continue")
                    }
                    if goal.status == .active || goal.status == .awaitingReview {
                        Button("暂停") { controlGoal(.pause, goal: goal) }
                    }
                    if goal.status == .paused || goal.status == .blocked {
                        Button("恢复") { controlGoal(.resume, goal: goal) }
                            .disabled(goalBudgetExhausted || chat.budgetIsOverLimit)
                    }
                    if goal.status != .stopped && goal.status != .completed {
                        Button("停止", role: .destructive) { controlGoal(.stop, goal: goal) }
                            .foregroundStyle(theme?.statusDangerText ?? .red)
                    }
                }
                .font(typography?.status ?? .caption)
                // 预算用尽、要重置本会话预算时，按钮在摘要里，收起状态下也照常显示。
                if goalDetailsExpanded
                    || chat.sessionBudgetResetTarget?.sessionID == goal.sessionID
                    || goal.budgetPauseReason != nil
                    || goal.isPausedForSessionTokenLimit == true {
                    goalBudgetSummary(goal)
                }
                if (goal.status == .paused || goal.status == .blocked) && goalBudgetExhausted {
                    Text("先调高预算，再点恢复。")
                        .font(typography?.status ?? .caption)
                        .foregroundStyle(.secondary)
                }
                if goalDetailsExpanded || goal.reviewNeedsAttention, let review = goal.lastReview {
                    VStack(alignment: .leading, spacing: 2) {
                        let title = "上次复核 · " + goalReviewOutcomeTitle(review.outcome)
                        let message = review.reason.map { Text(title + "：") + Text(verbatim: $0) } ?? Text(title)
                        if review.outcome == .rejected {
                            message.foregroundStyle(theme?.statusWarningText ?? .orange)
                        } else {
                            message
                        }
                        if let provider = review.provider {
                            Text("供应商：") + Text(verbatim: chat.presentationProviderLabel(for: provider))
                        }
                        if let modelID = review.modelID { Text("模型：") + Text(verbatim: modelID) }
                        if goal.reviewNeedsAttention {
                            Text("可回复一句，让模型补充证据后重新提交完成报告。")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if goalDetailsExpanded, let reason = goal.blockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if !goal.blockers.isEmpty {
                    let title = goal.hasUnacknowledgedBlockerReminder
                        ? "待你处理（\(goal.blockers.count)） · 待办提醒"
                        : "待你处理（\(goal.blockers.count)）"
                    DisclosureGroup(title) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(goal.blockers, id: \.self) { blocker in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(blocker.summary).fontWeight(.semibold)
                                    Text(blocker.reason)
                                    Text("需要你做：\(blocker.userAction)")
                                    ForEach(blocker.options.keys.sorted(), id: \.self) { option in
                                        Text("\(option)：\(blocker.options[option, default: ""])")
                                    }
                                    Text("选好处理方式后，在下方直接回复。")
                                        .foregroundStyle(.secondary)
                                }
                                .textSelection(.enabled)
                            }
                            Button("已处理，清除待办") { controlGoal(.clearBlockers, goal: goal) }
                                .accessibilityIdentifier("composer.goal-clear-blockers")
                        }
                    }
                    .font(.caption)
                }
                if goalDetailsExpanded, !goal.evidence.isEmpty {
                    DisclosureGroup("完成证据") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(goal.evidence.indices, id: \.self) { index in
                                Text(goal.evidence[index])
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            if goal == nil || goal?.status == .stopped || goal?.status == .completed {
                if showsGoalInput {
                    HStack {
                        TextField("输入会话目标", text: $goalObjective)
                        Button("开始") {
                            performGoalAction {
                                try chat.startConversationGoal(sessionID: sessionID, objective: goalObjective)
                                goalObjective = ""
                                showsGoalInput = false
                            }
                        }
                        .disabled(goalObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("取消") {
                            goalObjective = ""
                            showsGoalInput = false
                            goalActionFailed = false
                        }
                    }
                } else {
                    Button("设定目标") { showsGoalInput = true }
                }
            }
            if goalActionFailed {
                Text(goalActionFailureText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("composer.conversation-goal")
        .onChange(of: sessionID) {
            goalObjective = ""
            showsGoalInput = false
            goalActionFailed = false
            pendingGoalSessionBudgetReset = nil
        }
        .sessionBudgetResetConfirmation($pendingGoalSessionBudgetReset) { target in
            Task { @MainActor in
                await chat.resetConfirmedSessionBudget(target) {
                    bridge.approvalCenter.pendingRequest != nil
                }
            }
        }
    }

    private func goalBudgetSummary(_ goal: ConversationGoalState) -> some View {
        let budget = goal.budget
        let tokenLimit = budget.tokenLimit.map { $0.formatted() } ?? "不限"
        let minuteLimit = budget.durationLimitSeconds.map { ConversationGoalBudgetDraft.goalBudgetMinutesText($0 / 60) } ?? "不限"
        let minutesUsed = ConversationGoalBudgetDraft.goalBudgetMinutesText(budget.usedDurationSeconds / 60)
        let sessionLimit = chat.budgetCapTokens.map { $0.formatted() } ?? "不限"
        let loopLimit = (chat.agentEngine as? AgentLoopChatEngine)?.loop.maxIterations
        let resetBlockedReason = bridge.approvalCenter.pendingRequest == nil
            ? chat.sessionBudgetResetBlockedReason : "有任务待审批，请处理后重置。"
        return VStack(alignment: .leading, spacing: 4) {
            Text("目标回合 \(budget.usedTurns.formatted()) / \(budget.turnLimit.formatted()) · 目标 Token \(budget.usedTokens.formatted()) / \(tokenLimit) · 目标时长 \(minutesUsed) / \(minuteLimit) 分钟")
                .accessibilityIdentifier("composer.goal-budget.usage")
            Text("会话累计 Token \(chat.budgetUsedTokens.formatted()) / \(sessionLimit)")
                .accessibilityIdentifier("composer.goal-session-budget.usage")
            if let loopLimit {
                Text(loopLimit >= AgentLoop.unlimitedIterations
                     ? "每回合循环上限（基础配置）不限"
                     : "每回合循环上限（基础配置）\(loopLimit.formatted())")
            }
            Text("受运行安全上限约束")
            if !goal.autoContinueEnabled {
                Text("自动续跑已关闭")
            } else if !chat.composerPolicySelection.mode.supportsConversationGoal {
                Text("仅计划模式下不自动续跑")
            } else if chat.pendingGoalContinuationSessions.contains(goal.sessionID) {
                Text("自动续跑：等待当前输入、队列或任务完成后继续")
            } else {
                Text("自动续跑已开启：每回合正常结束后继续")
            }
            if let target = chat.sessionBudgetResetTarget, target.sessionID == goal.sessionID {
                Text("已达到会话累计 Token 上限。")
                Button("重置本会话预算") { pendingGoalSessionBudgetReset = target }
                    .disabled(resetBlockedReason != nil)
                    .accessibilityIdentifier("composer.goal-session-budget.reset")
                if let resetBlockedReason {
                    Text(resetBlockedReason)
                }
            }
            if let reason = goal.budgetRecoveryReason {
                Text(reason)
            }
            if goal.isPausedForSessionTokenLimit == true {
                if chat.budgetIsOverLimit {
                    Text("暂停：会话累计 Token 上限")
                } else {
                    Text("会话预算已可用，请手动恢复")
                }
            }
            if let reason = goal.turnPauseReason {
                switch reason {
                case .cancelled: Text("暂停：目标回合已停止或取消")
                case .unsettledFailure: Text("暂停：目标回合未能完成结算")
                case .emptyTurn: Text("暂停：续跑回合没有调用任何工具（空回合）")
                case .approvalDenied: Text("暂停：你在续跑回合里拒绝了一项操作，不再自动续跑")
                }
            }
            if let dimension = goal.budgetPauseReason {
                switch dimension {
                case .turns: Text("已达到回合上限。")
                case .tokens: Text("已达到 Token 上限。")
                case .duration: Text("已达到时长上限。")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func controlGoal(_ action: SessionStore.ConversationGoalControl, goal: ConversationGoalState) {
        performGoalAction {
            try chat.controlConversationGoal(sessionID: goal.sessionID, goalID: goal.id, action: action)
        }
    }

    private func performGoalAction(_ action: () throws -> Void) {
        do {
            try action()
            goalActionFailed = false
        } catch {
            goalActionFailed = true
            goalActionFailureText = Self.goalActionFailureMessage(for: error)
        }
    }

    /// 目标栏操作失败时给出原因，而不是只说"未能更新"。
    static func goalActionFailureMessage(for error: Error) -> String {
        switch error as? SessionStore.ConversationGoalError {
        case .unavailable:
            "未能更新会话目标：当前会话暂时不能操作目标（会话刚切换或存储不可用），请稍后重试。"
        case .invalidTransition:
            "未能更新会话目标：目标当前的状态不允许这个操作（例如已有进行中的目标，或预算已用尽需先调高）。"
        case nil:
            "未能更新会话目标：输入的内容或预算不合法，请检查后重试。"
        }
    }

    var body: some View {
        let credentialSheetBinding = Binding<Bool>(
            get: {
                chat.credentialBroker.pending?.sessionID == chat.activeSessionID
                    && chat.credentialBroker.pending != nil
            },
            set: { isPresented in
                if !isPresented {
                    chat.credentialBroker.cancel()
                }
            }
        )

        VStack(spacing: ComposerLayoutMetrics.stackSpacing) {
            InlineInteractionHost(chat: chat)
            if chat.providerReadinessStore != nil, chat.chatModelPickerItems.isEmpty,
               chat.shouldShowModelConnectionCard {
                ProviderConnectionCard(repairProviderName: chat.providerNeedingRepairName) {
                    bridge.deepLinkHandler.handle(.openSettings(id: ProviderConnectionRoute.id))
                }
            }
            if chat.providerReadinessStore != nil, chat.chatModelPickerItems.isEmpty,
               chat.shouldShowUncheckedProviderHint {
                Text("模型服务商还没检查过连接，首次发送前会自动检查。")
                    .font(typography?.status ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("composer.provider.unchecked-hint")
            }
            ComposerContextNoticeView(chat: chat, bridge: bridge)
            if let sessionID = chat.activeSessionID, chat.isPersistenceReady {
                conversationGoalBar(sessionID: sessionID)
            }
            // E11 附件预览条（待发送）
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
            if let notice = chat.composerInvisibleCharacterNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.invisible-characters.notice")
            }
            ChatRateLimitWaitCard(controller: chat.rateLimitWaits, sessionID: chat.activeSessionID,
                onCancel: { chat.stopStreaming(returnQueuedToDraft: true) })
            if !chat.activeQueuedComposerMessages.isEmpty {
                ComposerQueuedMessagesView(chat: chat)
            }
            if chat.isComposerAttachmentPreflightPending {
                HStack {
                    Text("正在准备附件，消息尚未发送。")
                        .font(typography?.status ?? .caption)
                        .accessibilityIdentifier("composer.attachment.waiting")
                    Button("取消本次发送") { chat.cancelComposerAttachmentPreflight() }
                        .escapeShortcut(denyPending: {
                            guard chat.isComposerAttachmentPreflightPending else { return false }
                            chat.cancelComposerAttachmentPreflight()
                            return true
                        })
                        .accessibilityIdentifier("composer.attachment.cancel-send")
                }
            } else if chat.isComposerCredentialPreflightPending {
                HStack {
                    Text(chat.isComposerProviderPreparationPending
                         ? "正在准备模型请求，消息尚未发送。"
                         : "正在等待系统凭据确认，消息尚未发送。")
                        .font(typography?.status ?? .caption)
                        .accessibilityIdentifier(chat.isComposerProviderPreparationPending
                            ? "composer.provider.waiting" : "composer.credential.waiting")
                    Button("取消本次发送") {
                        chat.cancelComposerCredentialPreflight()
                    }
                    .escapeShortcut(denyPending: {
                        guard chat.isComposerCredentialPreflightPending else { return false }
                        chat.cancelComposerCredentialPreflight()
                        return true
                    })
                    .accessibilityIdentifier(chat.isComposerProviderPreparationPending
                        ? "composer.provider.cancel-send" : "composer.credential.cancel-send")
                }
            } else if let feedback = chat.pastedTextActionFeedback {
                HStack(spacing: 8) {
                    Text(feedback)
                        .font(typography?.status ?? .caption)
                        .foregroundStyle(theme?.statusWarning ?? .orange)
                        .accessibilityIdentifier("composer.pasted-text.feedback")
                        .accessibilityAddTraits(.isStaticText)
                    if let repair = chat.readinessFailureRepair, repair.feedback == feedback {
                        Button("去修复") {
                            ProviderConnectionRoute.preferredProviderID = repair.providerID
                            bridge.deepLinkHandler.handle(.openSettings(id: ProviderConnectionRoute.id))
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("composer.readiness.repair")
                    }
                }
            }
            if let failure = chat.composerCommandValidationFailure,
               failure.sessionID == chat.activeSessionID {
                Text(failure.message)
                    .font(typography?.status ?? .caption)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.command.validation-error")
                    .accessibilityAddTraits(.isStaticText)
            }
            ComposerSpeechStatusLine(
                bridge: bridge,
                accessibilityID: "composer.global.speech.status"
            )
            // AJ-1：已选插件 / 技能 chip 行（popover 点选后挂在输入框上方，× 移除；复用 U4 PickerSelectionChips）
            if !chat.selectedPickerItems.isEmpty {
                PickerSelectionChips(chat: chat)
            }
            // 斜杠菜单与 @ 菜单读逐字符草稿：隔离在 ComposerDraftScope 内，按键不再重算整个输入区外壳。
            ComposerDraftScope(chat: chat) {
                Group {
                    slashCompletionSection
                    atMentionSection
                }
            }
            // AJ-67：两行布局（原单行 HStack 中按钮左右挤压输入框，918px 宽时占位符已被截断）。
            // ① 上方主控件行：权限/模式 + 模型 + 📎 附件 + 🧩 插件（左对齐小图标按钮）；
            //    🎯 选中节点徽标并入工具行右侧——徽标宽度不再挤占输入行，窄窗口（≤600px）下
            //    徽标文案 lineLimit(1) 自动截断、按钮不溢出，输入框始终独占下方整行可用宽度。
            HStack(spacing: ComposerLayoutMetrics.controlSpacing) {
                // P3-UI-03：窄宽度（compact/medium，由 AdaptiveLayoutPolicy 唯一策略源裁决）
                // 下策略控件收进溢出弹层，不再占用控件/输入行的横向空间；regular/wide
                // 保持原内联呈现。折叠只改呈现位置：三个策略菜单、bypass 确认开关、
                // 冻结快照与推理摘要在弹层内全部可达，composer.policy 容器标识符两种
                // 状态下都保持在主控件行内。
                Group {
                    if collapsesPolicyControls {
                        Button {
                            showPolicyOverflowPopover.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                MinisIconView(
                                    .settings,
                                    state: showPolicyOverflowPopover ? .active : .normal,
                                    size: MinisIconTokens.defaultSize
                                )
                                Text(ComposerPolicyPresentation.modeLabel(chat.composerPolicySelection.mode))
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(
                                minWidth: ComposerLayoutMetrics.iconButtonHitSize,
                                minHeight: ComposerLayoutMetrics.iconButtonHitSize
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("输入设置已按宽度收起（点按展开任务模式、工作量和思考强度）")
                        .accessibilityLabel("输入设置（已收起）")
                        .accessibilityValue(ComposerPolicyPresentation.modeLabel(chat.composerPolicySelection.mode))
                        .accessibilityIdentifier("composer.policy.overflow")
                        .popover(isPresented: $showPolicyOverflowPopover, arrowEdge: .top) {
                            ComposerPolicyControls(chat: chat, modeShortcutBinding: bridge.shortcutStore.binding(for: .composerMode))
                                .hidingBypassIndicator()
                                // A sheet cannot be presented from the popover;
                                // show the bypass risk confirmation inside it.
                                .inlineBypassRiskConfirmation()
                                .escapeShortcut(closePopover: {
                                    guard showPolicyOverflowPopover else { return false }
                                    showPolicyOverflowPopover = false
                                    return true
                                })
                        }
                    } else {
                        ComposerPolicyControls(chat: chat, modeShortcutBinding: bridge.shortcutStore.binding(for: .composerMode))
                    }
                }
                .layoutPriority(1)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer.policy")

                // E24 模型按钮（Codex/Hermes 风格）：档位图标 + 模型短名，点击弹 Popover 模型选择面板，
                // 与侧栏 ChatModelMenu 共用 ModelPickerPanel（F9-ui 三级状态机 ① Provider → ② 模型 → ③ 速度档位确认），
                // 确认后下一条消息用新模型
                ModelMenuButton(chat: chat)
                    .accessibilityIdentifier("composer.model")

                // E11 📎 附件按钮（F9-ui：与左侧模型按钮统一 frame，图标不再一边大一边小）
                Button {
                    pickFiles()
                } label: {
                    MinisIconView(
                        .attachment,
                        state: chat.pendingAttachments.isEmpty ? .normal : .active,
                        size: MinisIconTokens.defaultSize
                    )
                    .frame(
                        width: ComposerLayoutMetrics.iconButtonHitSize,
                        height: ComposerLayoutMetrics.iconButtonHitSize
                    )
                }
                .buttonStyle(.plain)
                .help("添加附件（图片/文本/Markdown/JSON 等）")
                .accessibilityLabel("添加附件")
                .accessibilityIdentifier("composer.attachments")

                // AJ-1 🧩 插件 / 技能选择器入口（点击弹出目录 popover；复用 U4 PluginSkillPickerPopover）
                Button {
                    showPickerPopover.toggle()
                } label: {
                    MinisIconView(
                        .plugin,
                        state: chat.selectedPickerItems.isEmpty ? .normal : .active,
                        size: MinisIconTokens.defaultSize
                    )
                    .frame(
                        width: ComposerLayoutMetrics.iconButtonHitSize,
                        height: ComposerLayoutMetrics.iconButtonHitSize
                    )
                }
                .buttonStyle(.plain)
                .help("选择插件 / 技能（选中后以 @技能名 插入草稿，发送时注入技能内容到系统提示）")
                .accessibilityLabel("选择插件或技能")
                .accessibilityIdentifier("composer.plugins")
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
                    accessibilityID: "composer.global.speech"
                )

                ComposerMemoryToolbarButton(chat: chat)
                if mainPane == .chat {
                    Button("输入历史") { showInputHistorySearch = true }
                        .buttonStyle(.borderless)
                        .help("输入历史（\(bridge.shortcutStore.binding(for: .inputHistorySearch).displayString)）；在输入框中使用，不会自动发送")
                        .accessibilityIdentifier("composer.history.open")
                }

                Spacer(minLength: 8)

                // 安全输入凭据入口放在控件行最右，与审批模式按钮隔开，避免误点。
                Button {
                    if let sessionID = chat.activeSessionID {
                        chat.credentialBroker.beginSecureEntry(sessionID: sessionID)
                    }
                } label: {
                    MinisIconView(.lock, size: MinisIconTokens.defaultSize)
                        .frame(
                            width: ComposerLayoutMetrics.iconButtonHitSize,
                            height: ComposerLayoutMetrics.iconButtonHitSize
                        )
                }
                .buttonStyle(.plain)
                .help("安全输入凭据")
                .accessibilityLabel("安全输入凭据")
                .accessibilityIdentifier("composer.credential.secure-entry")
                .padding(.leading, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer.primary-row.global")

            // The warning stays visible while the compact policy controls are collapsed.
            if collapsesPolicyControls,
               chat.composerPolicySelection.mode == .bypassPermission,
               chat.composerPolicySelection.bypassModeConfirmed {
                ComposerBypassIndicator()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if chat.isEditingMessage {
                ComposerEditModeBar(chat: chat, accessibilityID: "composer.edit-mode.global")
            }

            // ② 下方输入行：输入框独占剩余宽度（ComposerScrollField 内部 .frame(maxWidth: .infinity) 撑满），
            //    右侧仅发送/停止按钮，无其他控件挤压输入区。
            // 输入行读逐字符草稿（draftText 绑定、发送可用态）：隔离在 ComposerDraftScope 内，
            // 与伴随栏一致；外层 body 只在非草稿状态变化时重算。
            ComposerDraftScope(chat: chat) {
            HStack(spacing: ComposerLayoutMetrics.controlSpacing) {
                ComposerScrollField(
                    text: $chat.draftText,
                    font: .systemFont(ofSize: typography?.composerBodySize ?? 13),
                    placeholder: "输入消息，/ 查看命令，@ 引用技能或项目文件",
                    onSend: {
                        guard canSend else {
                            chat.noteComposerSendBlockedByAttachments()
                            return
                        }
                        if chat.canSubmitPresentedToolApprovalFromKeyboard {
                            send(fromKeyboard: true)
                        } else if chat.isActiveSessionGenerating {
                            if chat.newMessageInterruptsGeneration() { chat.interruptAndSend() }
                            else { _ = chat.enqueueComposer() }
                        }
                        else { send(fromKeyboard: true) }
                    },
                    onPaste: { chat.interceptCredentialPaste($0) || PastedTextComposerConsumer.accept($0, in: chat) },
                    onCommandKey: { handleNativeComposerKey($0) },
                    onCursorChange: { chat.noteComposerCursor($0) },
                    historySearchBinding: mainPane == .chat ? bridge.shortcutStore.binding(for: .inputHistorySearch) : nil,
                    onCommandReturn: {
                        let canFlushQueue = chat.isActiveSessionGenerating
                            && !chat.activeQueuedComposerMessages.isEmpty
                            && chat.draftText.isEmpty && chat.pendingAttachments.isEmpty
                            && chat.activePastedTextDrafts.isEmpty
                            && !chat.isComposerAttachmentPreflightPending
                            && !chat.blocksComposerStreamingActions
                            && chat.canSubmitComposerAttachments
                        guard canSend || canFlushQueue else {
                            chat.noteComposerSendBlockedByAttachments()
                            return
                        }
                        if chat.isActiveSessionGenerating && !chat.canSubmitPresentedToolApprovalFromKeyboard {
                            chat.interruptAndSend(flushingQueued: true)
                        } else { send(fromKeyboard: true) }
                    },
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
                    focusShortcutBinding: bridge.shortcutStore.binding(for: .focusComposer),
                    focusSessionID: chat.activeSessionID,
                    inputAccessibilityIdentifier: "composer.global.input",
                    nativeDraft: chat.nativeComposerDraft(),
                    onRememberNativeDraft: chat.rememberFocusedNativeDraft,
                    onFocusChange: { focused in
                        if isInputFocused != focused { isInputFocused = focused }
                    }
                )
                .help("输入指令或对话（生成中回车排队；⌘⇧⏎ 打断并发送；Esc 停止并将队列退回输入框；⇧⏎ 或 ⌥⏎ 换行）")
                .sheet(isPresented: $showInputHistorySearch) {
                    if mainPane == .chat {
                        ComposerInputHistorySearch(chat: chat, redactor: bridge.productionTranscriptRedactor)
                    } else { ComposerInputHistorySearch(chat: chat) }
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
                                .frame(
                                    width: ComposerLayoutMetrics.iconButtonHitSize,
                                    height: ComposerLayoutMetrics.iconButtonHitSize
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!stopCommand.isEnabled)
                        .accessibilityLabel(stopCommand.title)
                        .accessibilityIdentifier("composer.stop")
                        .help(stopCommand.disabledReason ?? "\(stopCommand.title)（\(bridge.shortcutStore.binding(for: .stopGeneration).displayString)）")
                    }
                } else {
                    Button {
                        if let lane = chat.mm01FieldLane, lane.requiresOwnedOutboundAudit {
                            do { send(ownedTicket: try lane.beginOwnedUIAction(.composerSendButton)) }
                            catch { return } // no substitute caller on a refusal
                        } else {
                        send()
                        }
                    } label: {
                        MinisIconView(
                            .send,
                            state: canSend ? .active : .disabled,
                            size: MinisIconTokens.largeSize
                        )
                        .frame(
                            width: ComposerLayoutMetrics.iconButtonHitSize,
                            height: ComposerLayoutMetrics.iconButtonHitSize
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("composer.send")
                    .shortcutKey(bridge.shortcutStore.binding(for: .sendMessage)) // AJ-57：绑定读 Store
                    .help(chat.composerAttachmentBlockReason
                          ?? "发送（\(bridge.shortcutStore.binding(for: .sendMessage).displayString)）")
                }
            }
            .onChange(of: chat.draftText) { old, new in
                // 输入框刚进入斜杠状态（菜单即将打开）时重读自定义命令，改了命令文件马上生效。
                if new.hasPrefix("/"), !old.hasPrefix("/") { chat.refreshCustomSlashCommands() }
                chat.updateFileMentionSuggestions()
            }
            }
        }
        .background {
            Button("") { stopFocusedObject() }
                .shortcutKey(bridge.shortcutStore.binding(for: .stopGeneration))
                .disabled(focusedStopAction == nil && !chat.isActiveSessionGenerating)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(ComposerLayoutMetrics.outerPadding)
        .background(
            RoundedRectangle(cornerRadius: ComposerLayoutMetrics.cornerRadius, style: .continuous)
                .fill(composerSurfaceFill)
                // 轻阴影让卡片与外层同色底带分层；静态参数，不随输入重算。
                .shadow(color: composerShadowColor, radius: 6, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ComposerLayoutMetrics.cornerRadius, style: .continuous)
                .stroke(composerSurfaceStroke, lineWidth: composerSurfaceStrokeWidth)
        )
        .background(
            // P3-UI-03：只读测量面板宽度并驱动唯一策略源裁决；背景 GeometryReader
            // 不参与父布局，也不引入第二套断点。
            GeometryReader { proxy in
                Color.clear
                    .onAppear { applyComposerPanelWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newValue in
                        applyComposerPanelWidth(newValue)
                    }
            }
        )
        .frame(maxWidth: composerColumnMaxWidth)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        // 输入区外框与对话区同一底色（主背景）：窗口放大后左右两侧不再露出一条
        // 不同色的横带；上缘加一段很短的渐隐，正文滚到输入区时淡出而不是被一刀切断。
        // 渐隐是静态图层，不随内容重算。
        .padding(.top, 8)
        .padding(.bottom, 0)
        .background(composerBandColor)
        .overlay(alignment: .top) {
            LinearGradient(colors: [composerBandColor.opacity(0), composerBandColor],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
                .offset(y: -14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .font(typography?.composerControl ?? .body)
        // E11 拖放：文件拖到输入区 → 自动添加为附件
        .dropDestination(for: ComposerDropItem.self) { items, _ in
            // 本地文件与浏览器拖来的图片数据都走统一落地函数；网页链接提示先保存到本地。
            chat.addDroppedItems(items)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.global")
        .accessibilityLabel("全局对话输入区")
        .modifier(ComposerDraftAccessibilityValue(chat: chat) { composerAccessibilityValue })
        .onChange(of: chat.activeSessionID) { _, _ in
            resetSlashCompletionSelection()
            atMentionSelectedID = nil
            atMentionDismissedDraft = nil
        }
        .sheet(isPresented: credentialSheetBinding) {
            ChatCredentialCardView(chat: chat)
        }
        .sheet(item: $pastedTextEditorState) { state in
            PastedTextCapsuleEditor(chat: chat, state: state)
        }
    }

    /// 输入卡片外观；聚焦态来自原生输入框的 first responder 回调。
    private var composerSurface: ComposerSurfaceStyle? {
        theme.map { ComposerSurfaceStyle.resolve(palette: $0.aj38, isFocused: isInputFocused, isDropTargeted: isDropTargeted) }
    }

    private var composerSurfaceFill: Color {
        if let surface = composerSurface { return surface.fill.swiftUIColor }
        return Color(nsColor: .underPageBackgroundColor).opacity(isDropTargeted ? 0.55 : 0.35)
    }

    private var composerSurfaceStroke: Color {
        if let surface = composerSurface { return surface.stroke.swiftUIColor }
        return isDropTargeted ? Color.accentColor : Color.clear
    }

    private var composerSurfaceStrokeWidth: CGFloat {
        composerSurface?.strokeWidth ?? 1.5
    }

    /// 阴影色：按主题底色明暗取黑色的不同浓度（深色底上需更浓才看得出）。
    private var composerShadowColor: Color {
        guard let background = theme?.aj38.backgroundPrimary else { return Color.black.opacity(0.10) }
        let luminance = 0.299 * background.r + 0.587 * background.g + 0.114 * background.b
        return Color.black.opacity(luminance < 0.5 ? 0.40 : 0.09)
    }

    private var composerBandColor: Color {
        theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor)
    }

    private var composerColumnMaxWidth: CGFloat {
        ChatReadingLayout.composerColumnWidth(availableWidth: .infinity, gutter: 0)
    }

    private func stopFocusedObject() {
        if let focusedStopAction { focusedStopAction(); return }
        guard let command = AppCommandMenuBuilder.command(id: "ui.chat.stop", registry: bridge.commandRegistry,
                                                          display: bridge.paletteDisplay), command.isEnabled else { return }
        bridge.runCommand(id: command.id, args: ["session_id": chat.activeSessionID?.uuidString ?? "", "return_queued_to_draft": "true"])
    }

    /// 有文本或待发送附件时才允许发送（Q8-r5：委托 GlobalComposer.canSend 纯函数，可单测）
    private var canSend: Bool {
        !chat.isComposerAttachmentPreflightPending && !chat.blocksComposerStreamingActions && GlobalComposer.canSend(
            draftText: chat.draftText,
            pendingAttachmentCount: chat.pendingAttachments.count,
            hasPastedText: chat.activePastedTextDraft != nil,
            attachmentsReady: chat.canSubmitComposerAttachments
        )
    }

    /// P3-UI-03：当前实测宽度下是否把策略控件折叠进溢出呈现。
    /// 首帧测量前（nil）保持内联，控件不闪失；裁决委托
    /// GlobalComposerWidthPolicy，按面板自身可用宽度判断。
    private var collapsesPolicyControls: Bool {
        guard let composerUsableWidth else { return false }
        return GlobalComposerWidthPolicy.collapsesPolicyControls(
            usableWidth: composerUsableWidth, contentScale: CGFloat(typography?.contentScale ?? 1))
    }

    /// 面板实测宽度扣除两侧 `ComposerLayoutMetrics.outerPadding` 后即控件/输入行
    /// 的真实可用宽度，交给 GlobalComposerWidthPolicy 的面板级阈值裁决。
    private func applyComposerPanelWidth(_ panelWidth: CGFloat) {
        let usable = max(0, panelWidth - 2 * ComposerLayoutMetrics.outerPadding)
        guard composerUsableWidth != usable else { return }
        composerUsableWidth = usable
    }

    private var composerAccessibilityValue: String {
        if chat.isComposerAttachmentPreflightPending { return "正在准备附件，消息尚未发送，可取消" }
        if chat.isComposerProviderPreparationPending { return "正在准备模型请求，消息尚未发送，可取消" }
        if chat.isComposerCredentialPreflightPending { return "等待系统凭据确认，消息尚未发送，可取消" }
        if chat.isActiveSessionStreaming { return "生成中，可停止" }
        if let reason = chat.composerAttachmentBlockReason { return reason }
        if canSend { return "已准备发送" }
        return "等待输入"
    }

    private var slashSessionState: ComposerSlashSessionState {
        var reasons = GlobalComposer.commandReadinessReasons(
            registry: chat.registeredComposerCommandRegistry,
            bridge: bridge
        )
        if !chat.activeSessionHasProjectRoot {
            reasons["init"] = "普通会话没有项目目录，/init 不知道把 CLAUDE.md 写到哪里；请在项目会话里使用"
        }
        return ComposerSlashSessionState(
            isStreaming: chat.isActiveSessionStreaming,
            hasPendingComposerCommand: chat.pendingComposerCommand != nil,
            hasActiveSession: chat.activeSessionID != nil,
            unavailableReasonsByCommandID: reasons
        )
    }

    private var slashMenuEntries: [ComposerSlashMenuEntry] {
        GlobalComposer.slashMenuEntries(
            for: chat.draftText,
            dismissedContextKey: slashCompletionDismissedContextKey,
            contextKey: { slashCompletionContextKey },
            registry: { chat.registeredComposerCommandRegistry },
            sessionState: { slashSessionState },
            canvasAvailable: { bridge.canvasIfAvailable != nil },
            customCommands: { chat.slashMenuCustomCommands }
        )
    }

    /// One evaluation of the slash projection per body pass. The entries are
    /// passed down to the menu instead of being recomputed by each row.
    @ViewBuilder
    private var slashCompletionSection: some View {
        let entries = slashMenuEntries
        if !entries.isEmpty {
            slashCompletionMenu(entries: entries)
        }
    }

    /// Highlighted row, resolved from the bound command identity so a
    /// narrowed list cannot move the selection onto a different command.
    private var slashCompletionSelectedIndex: Int? {
        ComposerSlashCommandMenu.selectedIndex(
            for: slashCompletionSelectedCommandID,
            in: slashMenuEntries
        )
    }

    private var slashCompletionContextKey: String {
        "\(chat.activeSessionID?.uuidString ?? "none")\u{001F}\(chat.draftText)"
    }

    private func resetSlashCompletionSelection() {
        slashCompletionSelectedCommandID = nil
        slashCompletionDismissedContextKey = nil
    }

    /// Handle native key commands while the canonical registry owns a visible
    /// slash completion menu. Returning false preserves normal text editing,
    /// including ⌥⏎, and lets the text view move focus for bare Tab keys.
    private func handleNativeComposerKey(_ key: ComposerNativeKey) -> Bool {
        if key == .historySearch { showInputHistorySearch = true; return true }
        if chat.handleInputHistoryKey(key) { return true }
        let entries = slashMenuEntries
        guard !entries.isEmpty else { return handleAtMentionKey(key) }
        let suggestions = entries.map(\.completionCommand)

        if case .shiftTab = key {
            slashCompletionSelectedCommandID = nil
            slashCompletionDismissedContextKey = slashCompletionContextKey
            return false
        }

        let completionKey: CommandCompletionKey
        switch key {
        case .up:
            completionKey = .up
        case .down:
            completionKey = .down
        case .tab:
            completionKey = .tab
        case .escape:
            completionKey = .escape
        case .returnKey(let option):
            guard !option else { return false }
            if chat.canSubmitPresentedToolApprovalFromKeyboard { return false }
            // The user typed the complete unavailable command. Let the normal
            // submit boundary show its rejection while the menu row stays blocked.
            let text = chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = MinisCore.CommandParser().parse(text, registry: chat.registeredComposerCommandRegistry)
            if parsed.disposition == .command, parsed.matchScore == 100,
               let id = parsed.command?.id, id == "boundary.set" || id == "canvas.run" {
                return false
            }
            completionKey = .enter
        case .shiftTab, .historySearch:
            return false
        }

        let selectedIndex = min(
            max(slashCompletionSelectedIndex ?? 0, 0),
            suggestions.count - 1
        )
        var state = CommandCompletionState(
            suggestions: suggestions,
            selectedIndex: selectedIndex
        )
        let action = state.handle(completionKey)
        slashCompletionSelectedCommandID = state.selectedIndex.flatMap {
            suggestions.indices.contains($0) ? suggestions[$0].id : nil
        }

        switch action {
        case .moveSelection:
            return true
        case .accept(let commandID):
            guard let entry = entries.first(where: { $0.id == commandID }) else {
                return false
            }
            // Tab completes only. Return completes then follows the existing
            // submitComposer boundary, and only when the row is dispatchable
            // under the current session state (阻断 rows complete text but
            // never dispatch).
            let accepted = GlobalComposer.acceptedSlashDraft(
                current: chat.draftText, entry: entry,
                registry: chat.registeredComposerCommandRegistry
            )
            let wasTyped = accepted.text == chat.draftText
            chat.draftText = accepted.text
            if case .returnKey = key, accepted.shouldSend {
                send(fromKeyboard: wasTyped)
            }
            return true
        case .dismiss:
            return GlobalComposer.dismissSlashCompletion(
                entries: entries, contextKey: slashCompletionContextKey,
                selectedCommandID: &slashCompletionSelectedCommandID,
                dismissedContextKey: &slashCompletionDismissedContextKey
            )
        case .noop:
            return false
        }
    }

    // MARK: @ 引用（技能 + 当前项目文件）

    private struct AtMentionItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let skill: PickerCatalogItem?
        let path: String?
        var mcpResource: MCPResourceItem? = nil
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
            let item = AtMentionItem(id: "file:\(path)",
                          title: ChatStore.fileMentionTitle(path),
                          subtitle: (path.hasSuffix("/") ? "目录（回车进入）· " : "文件 · ") + path, skill: nil, path: path)
            guard path.hasSuffix("/") else { return [item] }
            let reference = AtMentionItem(id: "dir-ref:\(path)",
                          title: ChatStore.fileMentionTitle(path),
                          subtitle: "引用此目录 · " + path, skill: nil, path: path, referencesDirectory: true)
            return [item, reference]
        }
        let mcpResources = chat.mcpResourceSuggestions.map {
            AtMentionItem(id: "mcp:\($0.id)", title: $0.title,
                          subtitle: "MCP 资源 · \($0.serverName) · \($0.uri)",
                          skill: nil, path: nil, mcpResource: $0)
        }
        return Array(skills) + files + mcpResources
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
                        .accessibilityIdentifier("composer.at-mention.\(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
            .accessibilityIdentifier("composer.at-mention-completions")
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
        } else if let resource = item.mcpResource {
            chat.acceptMCPResourceMention(resource)
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

    private func slashCompletionMenu(entries: [ComposerSlashMenuEntry]) -> some View {
        let selectedIndex = ComposerSlashCommandMenu.selectedIndex(
            for: slashCompletionSelectedCommandID,
            in: entries
        ) ?? 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, command in
                    Button {
                        let accepted = GlobalComposer.acceptedSlashDraft(
                            current: chat.draftText, entry: command,
                            registry: chat.registeredComposerCommandRegistry
                        )
                        chat.draftText = accepted.text
                        if accepted.shouldSend {
                            send()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("/\(command.id)")
                                    .font(.system(.body, design: .monospaced))
                                Text(command.customCommand?.argumentHint ?? command.descriptor.zhTitle)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Text(command.state.label)
                                    .font(.caption2)
                                    .foregroundStyle(slashStateColor(command.state))
                                    .accessibilityIdentifier("composer.slash.state.\(command.id)")
                            }
                            Text(command.descriptor.zhSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            let detail = command.customCommand.map { "\($0.source.displayName)命令" }
                                ?? command.descriptor.risk?.displayLabel ?? "注册命令"
                            let trailing = command.stateReason
                                ?? "\(command.descriptor.argumentSummary) · \(detail)"
                            Text([command.executionSummary, trailing].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        index == selectedIndex
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                    .accessibilityIdentifier("composer.slash.\(command.id)")
                    .accessibilityLabel("/\(command.id) \(command.descriptor.zhTitle) \(command.descriptor.enTitle) \(command.descriptor.zhSummary)")
                    .accessibilityValue(command.accessibilityValue(
                        isSelected: index == selectedIndex
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 280)
        .accessibilityIdentifier("composer.slash-completions")
        .escapeShortcut(closePopover: { handleNativeComposerKey(.escape) })
    }

    private func slashStateColor(_ state: ComposerSlashCommandState) -> Color {
        switch state {
        case .available: .secondary
        case .requiresApproval: theme?.statusWarningText ?? AppStatusColor.warning
        case .blocked: theme?.statusDangerText ?? AppStatusColor.danger
        }
    }

    /// 发送：直接走原链路（节点-对话已彻底解绑：不再自动补节点名进草稿）
    private func send(ownedTicket: OwnedMMActionTicket? = nil, fromKeyboard: Bool = false) {
        let ready = canSend
        chat.recordComposerSendInvocation(canSend: ready)
        guard ready else {
            chat.noteComposerSendBlockedByAttachments()
            return
        }
        if let ownedTicket {
            OwnedMMOutboundContext.$action.withValue(ownedTicket) { chat.submitComposer() }
        } else if fromKeyboard {
            chat.submitComposerFromKeyboard()
        } else {
            chat.submitInteractiveComposer()
        }
    }

    // MARK: E11 附件预览条

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
        let sourceSessionID = chat.activeSessionID
        return AttachmentPreviewRenderView(attachment: att, sessionID: sourceSessionID, isCurrent: {
            chat.activeSessionID == sourceSessionID && chat.pendingAttachments.contains(att)
        }) { thumbnail, _ in
            let canPreview = onPreviewAttachment != nil && GlobalComposer.canRenderPendingAttachmentPreview(
                att,
                expectedSessionID: sourceSessionID,
                activeSessionID: chat.activeSessionID,
                pendingAttachments: chat.pendingAttachments
            )
            // 音频转写控件另起一行，避免撑出输入框宽度、把"预览/移除"挤出可见区。
            VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let nsImage = thumbnail {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    MinisIconView(att.keylineIcon, size: 12)
                        .foregroundPalette(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(att.fileName)
                        .font(typography?.caption ?? .system(size: 10))
                        .lineLimit(1)
                    // 两阶段状态可见（P3-COMP-04）：pending/failed 行内显示状态文案；
                    // ready 时副标题为"大小 · 类型名"，kindLabel 不再被 size 抑制。
                    // 失败原因只在下方的就绪说明行显示一次（警告色），这里不再重复。
                    if att.status == .failed {
                        EmptyView()
                    } else if let statusText = att.statusText {
                        Text(statusText)
                            .font(typography?.caption2 ?? .system(size: 9))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(ComposerAttachmentPresentation.subtitle(for: att))
                            .font(typography?.caption2 ?? .system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    // D-COMPOSER-04：状态如实投影（读取中/降级不冒充成功，COMPOSER-08）。
                    Text(ComposerAttachmentPresentation.statusLabel(for: att, in: mediaReadiness))
                        .font(typography?.caption2 ?? .system(size: 9))
                        .foregroundStyle(
                            ComposerAttachmentPresentation.status(for: att).claimsSuccess
                                && mediaReadiness.attachment(id: att.id)?.blocksSend != true
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(theme?.statusWarning ?? Color.orange)
                        )
                        .lineLimit(1)
                        .accessibilityIdentifier("composer.attachment.status.\(att.id.uuidString)")
                    Text(ComposerAttachmentPresentation.mediaReadinessText(for: att, in: mediaReadiness))
                        .font(typography?.caption2 ?? .system(size: 9))
                        .foregroundStyle(
                            mediaReadiness.attachment(id: att.id)?.blocksSend == false
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(theme?.statusWarning ?? Color.orange)
                        )
                        .lineLimit(2)
                        .accessibilityIdentifier("composer.attachment.media-readiness.\(att.id.uuidString)")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ComposerAttachmentPresentation.accessibilityValue(
                    for: att, mediaReadiness: mediaReadiness
                ))
                .accessibilityIdentifier("composer.attachment.info.\(att.id.uuidString)")
                if att.fileURL != nil,
                   ChatStore.canConvertToPathReference(att) {
                    Button("改为路径引用") {
                        chat.convertPendingAttachmentToPathReference(id: att.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme?.statusWarning ?? Color.orange)
                    .help("不读取内容，只把文件路径发给模型，由模型用 file_read 读取")
                    .accessibilityIdentifier("composer.attachment.convert-to-reference.\(att.id.uuidString)")
                }
                Button("预览") {
                    GlobalComposer.previewPendingAttachment(
                        att, expectedSessionID: sourceSessionID,
                        activeSessionID: chat.activeSessionID,
                        pendingAttachments: chat.pendingAttachments,
                        onUnavailable: { attachment, sessionID in
                            // The existing root route reports the live source
                            // error before resolution or file-content reads.
                            onPreviewAttachment?(attachment, sessionID)
                        }
                    ) { attachment, sessionID in
                        onPreviewAttachment?(attachment, sessionID)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canPreview)
                .help(canPreview ? "在右侧面板预览 \(att.fileName)" : "附件就绪且文件来源可用后才能预览")
                .accessibilityLabel("在右侧面板预览 \(att.fileName)")
                .accessibilityValue(canPreview ? "可预览" : "暂不可预览")
                .accessibilityIdentifier("composer.attachment.preview.\(att.id.uuidString)")
                Button {
                    chat.removePendingAttachment(id: att.id)
                } label: {
                    MinisIconView(.remove, size: MinisIconTokens.smallSize, accessibilityLabel: "移除附件")
                }
                .buttonStyle(.plain)
                .help("移除附件")
            }
            if att.kind == .audio {
                AudioTranscriptionChipControls(chat: chat, attachment: att)
            }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
