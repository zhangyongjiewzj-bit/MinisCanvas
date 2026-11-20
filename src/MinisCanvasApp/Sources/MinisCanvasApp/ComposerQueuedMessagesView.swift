import SwiftUI
import MinisCore

@MainActor
struct ComposerQueuedMessagesView: View {
    @Bindable var chat: ChatStore
    @Environment(\.typographyTokens) private var typography
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("排队消息 \(chat.activeQueuedComposerMessages.count) 条")
                Spacer(minLength: 4)
                Button("发送下一条") { _ = chat.sendNextQueuedComposer() }
                    .disabled(chat.isActiveSessionGenerating || chat.hasDraft
                        || !chat.pendingAttachments.isEmpty || !chat.activePastedTextDrafts.isEmpty)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            DisclosureGroup("管理排队消息") {
                ComposerQueueManagementList(
                    items: chat.activeQueuedComposerMessages,
                    canEdit: !chat.isEditingMessage && !chat.hasDraft
                        && chat.pendingAttachments.isEmpty && chat.activePastedTextDrafts.isEmpty,
                    edit: { _ = chat.editQueuedComposer(id: $0) },
                    delete: { _ = chat.deleteQueuedComposer(id: $0) }
                )
                .frame(minHeight: 80, maxHeight: 220)
            }
        }
        .font(typography?.caption ?? .caption)
        .accessibilityIdentifier("composer.queued-messages")
        .help("自然完成后自动发送排队消息；停止生成会把排队消息退回输入框，不自动发送。")
    }
}

@MainActor
struct ComposerContextNoticeView: View {
    @Bindable var chat: ChatStore
    let bridge: BridgeStore
    @State private var permissionRulesNoticeDismissed = false
    @State private var presentsCheckpoints = false
    @State private var presentsContextSources = false
    @State private var compactionHint = ""
    @State private var pendingBudgetReset: SessionBudgetResetTarget?
    @Environment(\.minisOpenSettingsPage) private var openSettingsPage
    @Environment(\.typographyTokens) private var typography
    @Environment(\.themeTokens) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = chat.sessionPersistenceNotice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("composer.persistence-unsaved")
            }
            if let notice = chat.queuePersistenceNotice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("composer.queue-persistence-notice")
            }
            if let notice = chat.sessionContinuationNotice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("composer.continuation-notice")
            }
            // 11/19 用户：上下文占用和"恢复文件检查点"并排一行，少占输入框上方一行。
            HStack(spacing: 8) {
                Button {
                    presentsContextSources.toggle()
                } label: {
                    Label {
                        Text("上下文 \(chat.contextOccupancy?.display ?? "—")")
                    } icon: {
                        MinisIconView(.analytics, size: 12)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(contextOccupancyColor)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(chat.contextOccupancyHelp)
                .accessibilityIdentifier("composer.context-occupancy")
                .popover(isPresented: $presentsContextSources, arrowEdge: .top) {
                    contextSources
                }
                .onChange(of: chat.activeSessionID) { _, _ in
                    presentsContextSources = false
                }
                if !chat.fileCheckpoints.isEmpty {
                    Button("恢复文件检查点…") { presentsCheckpoints = true }
                        .disabled(chat.isActiveSessionGenerating)
                        .help(FileCheckpointStore.scopeDisclosure)
                        .accessibilityIdentifier("composer.file-checkpoints")
                }
            }
            if let reason = chat.contextLimitReason {
                HStack {
                    Text(reason)
                    Button("新会话继续") { chat.continueAfterContextLimit() }
                        .disabled(!chat.canContinueAfterContextLimit)
                    if chat.sessionBudgetResetTarget != nil {
                        Button("去设置调高上限") { openSettingsPage(SettingsPage.agent.rawValue) }
                            .accessibilityIdentifier("composer.context-limit.open-settings")
                    }
                    if let target = chat.sessionBudgetResetTarget {
                        Button("重置预算") { pendingBudgetReset = target }
                            .disabled(chat.sessionBudgetResetBlockedReason != nil
                                || bridge.approvalCenter.pendingRequest != nil)
                            .help(chat.sessionBudgetResetBlockedReason ?? "清零本会话的累计用量计数后继续")
                            .accessibilityIdentifier("composer.context-limit.budget-reset")
                    }
                }
                .sessionBudgetResetConfirmation($pendingBudgetReset) { target in
                    Task { @MainActor in
                        await chat.resetConfirmedSessionBudget(target) {
                            bridge.approvalCenter.pendingRequest != nil
                        }
                    }
                }
                .accessibilityIdentifier("composer.context-limit")
            }
            MemoryProposalInlineCards(chat: chat)
            // A-4：权限规则文件损坏、版本不符或写入失败时，对话页给出可见提示（原来只记日志，
            // 用户看不到，以为“始终允许”还在生效）。只读内存里的诊断列表，无文件读写。
            if !permissionRulesNoticeDismissed,
               bridge.approvalCenter.persistentRules?.diagnostics().contains(where: { $0.hasPrefix("规则文件") }) == true {
                HStack(spacing: 8) {
                    Text("权限规则文件出了问题，部分“始终允许”规则可能没有生效；拒绝和每次询问规则仍然有效。")
                    Button("查看详情") { openSettingsPage(SettingsPage.permissions.rawValue) }
                        .accessibilityIdentifier("composer.permission-rules-notice.open")
                    Button("知道了") { permissionRulesNoticeDismissed = true }
                        .accessibilityIdentifier("composer.permission-rules-notice.dismiss")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer.permission-rules-notice")
            }
        }
        .font(typography?.caption ?? .caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $presentsCheckpoints) { FileCheckpointRecoveryView(chat: chat) }
        .sheet(item: $chat.sessionContinuationDraft) { draft in
            SessionContinuationPreview(
                draft: draft,
                confirm: { chat.confirmSessionContinuation() },
                cancel: { chat.cancelSessionContinuation() }
            )
        }
    }
    private var contextOccupancyColor: Color {
        guard let fraction = chat.contextOccupancy?.fraction else { return .secondary }
        // 颜色跟随自动压缩阈值：到阈值变黄（未设阈值按 70%），到 95%（发送被拒的线）变红。
        let warn = chat.configuredAutoCompactThreshold ?? 0.7
        if fraction >= ContextWindowPolicy.hardBlockFraction { return theme?.statusDangerText ?? .red }
        if fraction >= min(warn, ContextWindowPolicy.hardBlockFraction) { return theme?.statusWarningText ?? .orange }
        return .secondary
    }

    private var contextSources: some View {
        let sessionID = chat.activeSessionID
        let sample = chat.contextOccupancy
        let compact = AppCommandMenuBuilder.command(
            id: "ui.chat.compact", registry: bridge.commandRegistry, display: bridge.paletteDisplay
        )

        return VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                InspectorSection(identifier: "composer.context-sources", title: "最近占用回报所属请求的来源",
                                 icon: "doc.text", catalogIcon: .document) {
                    if let sources = sample?.sources {
                        InspectorValueRow("系统提示", sources.system.detail)
                        InspectorValueRow("记忆", sources.memory.detail)
                        InspectorValueRow("技能", sources.skills.detail)
                        InspectorValueRow("MCP 工具", sources.mcpTools.detail)
                        InspectorValueRow("消息", sources.messages.detail)
                        InspectorValueRow("附件", sources.attachments.detail)
                    } else if sample == nil {
                        InspectorEmptyState(text: "尚无模型占用回报")
                    } else {
                        InspectorEmptyState(text: "该请求没有提供来源分类")
                    }
                }
            }
            .frame(maxHeight: 280)

            TextField("压缩指引（可选），例如：保留关于数据库迁移的决定", text: $compactionHint)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composer.compaction-hint")
            Button("压缩上下文") {
                guard let sessionID, chat.activeSessionID == sessionID,
                      let command = AppCommandMenuBuilder.command(
                        id: "ui.chat.compact", registry: bridge.commandRegistry, display: bridge.paletteDisplay
                      ), command.isEnabled else { return }
                presentsContextSources = false
                let hint = compactionHint.trimmingCharacters(in: .whitespacesAndNewlines)
                compactionHint = ""
                if hint.isEmpty {
                    bridge.runCommand(id: command.id)
                } else {
                    chat.compactContext(hint: hint)
                }
            }
            .disabled(sessionID == nil || compact?.isEnabled != true)
        }
        .frame(width: 320)
        .padding(10)
    }
}

/// Shared by the main and companion composer toolbars; reads the same
/// session-scoped injection result as the former context-notice disclosure.
/// 模型自己提议的记忆：在对话里给批准卡，用户点“批准并记住”才写入。
/// 只列本会话范围内、来自对话提议的待审项；其余来源的待审项仍在 设置 › 记忆。
@MainActor
struct MemoryProposalInlineCards: View {
    @Bindable var chat: ChatStore
    @State private var proposals: [MemoryProposalEnvelope] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(proposals, id: \.proposal.proposalID) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型提议记住：" + proposal.text)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("批准并记住") { approve(proposal) }
                            .accessibilityIdentifier("composer.memory-proposal.approve")
                        Button("拒绝") { reject(proposal) }
                            .accessibilityIdentifier("composer.memory-proposal.reject")
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("composer.memory-proposals")
        .task(id: chat.activeSessionID) { refresh() }
        .onChange(of: chat.isActiveSessionGenerating) { _, generating in
            if !generating { refresh() }
        }
    }

    private func refresh() {
        let pending = (try? SettingsCenter.active?.pendingMemoryProposals()) ?? []
        proposals = pending.filter { $0.sourceID == MemoryProposalConsumer.chatProjectSourceID }
    }

    private func approve(_ proposal: MemoryProposalEnvelope) {
        do {
            try SettingsCenter.active?.approveDisplayedMemoryProposal(proposal)
            message = "已记住。"
        } catch {
            message = "没能记住这条，请到 设置 › 记忆 重新检查。"
        }
        refresh()
    }

    private func reject(_ proposal: MemoryProposalEnvelope) {
        do {
            try SettingsCenter.active?.rejectDisplayedMemoryProposal(proposal)
            message = "已拒绝，未写入记忆。"
        } catch {
            message = "没能拒绝这条，请到 设置 › 记忆 处理。"
        }
        refresh()
    }
}

@MainActor
struct ComposerMemoryToolbarButton: View {
    @Bindable var chat: ChatStore
    @State private var presentsMemory = false
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        Button {
            presentsMemory.toggle()
        } label: {
            MinisIconView(
                .library,
                state: presentsMemory ? .active : .normal,
                size: MinisIconTokens.defaultSize
            )
                .frame(
                    width: ComposerLayoutMetrics.iconButtonHitSize,
                    height: ComposerLayoutMetrics.iconButtonHitSize
                )
        }
        .buttonStyle(.plain)
        .help("查看本轮使用或检索的持久记忆：\(chat.memoryInjectionStatusText)")
        .accessibilityLabel("查看本轮记忆")
        .accessibilityValue(chat.memoryInjectionStatusText)
        .accessibilityIdentifier("composer.injected-memory.toolbar")
        .popover(isPresented: $presentsMemory, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text(chat.memoryInjectionStatusText)
                    .font(.headline)
                if let bytes = chat.injectedGlobalMemoryByteCount {
                    Text("GLOBAL.md · 已加载 \(bytes) B（只读全局指令）")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if chat.lastInjectedMemoryFactIDs.isEmpty {
                            Text(chat.injectedGlobalMemoryByteCount == nil ? "本轮未注入记忆" : "本轮使用只读全局指令")
                        } else {
                            ForEach(Array(zip(chat.lastInjectedMemoryFactIDs, chat.lastInjectedMemoryFactLabels)), id: \.0) { row in
                                Text(row.1).help(row.0)
                            }
                        }
                        Text("注入总上限 \(chat.memoryInjectionLimitCharacters) 字符")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }
            .font(typography?.caption ?? .caption)
            .padding(16)
            .frame(width: 320)
            .accessibilityIdentifier("composer.injected-memory")
            .escapeShortcut(closePopover: {
                guard presentsMemory else { return false }
                presentsMemory = false
                return true
            })
        }
    }
}
