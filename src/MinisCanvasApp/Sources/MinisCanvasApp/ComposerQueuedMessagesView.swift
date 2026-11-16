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
                    .disabled(chat.isActiveSessionGenerating || !chat.draftText.isEmpty
                        || !chat.pendingAttachments.isEmpty || !chat.activePastedTextDrafts.isEmpty)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            DisclosureGroup("管理排队消息") {
                ComposerQueueManagementList(
                    items: chat.activeQueuedComposerMessages,
                    canEdit: !chat.isEditingMessage && chat.draftText.isEmpty
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
    @State private var presentsCheckpoints = false
    @State private var presentsContextSources = false
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
            if let reason = chat.contextLimitReason {
                HStack {
                    Text(reason)
                    Button("新会话继续") { chat.continueAfterContextLimit() }
                        .disabled(!chat.canContinueAfterContextLimit)
                }
                .accessibilityIdentifier("composer.context-limit")
            }
            Button("恢复文件检查点…") { presentsCheckpoints = true }
                .disabled(chat.isActiveSessionGenerating || chat.fileCheckpoints.isEmpty)
                .help(FileCheckpointStore.scopeDisclosure)
                .accessibilityIdentifier("composer.file-checkpoints")
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
        if fraction > 0.9 { return theme?.statusDangerText ?? .red }
        if fraction >= 0.7 { return theme?.statusWarningText ?? .orange }
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

            Button("压缩上下文") {
                guard let sessionID, chat.activeSessionID == sessionID,
                      let command = AppCommandMenuBuilder.command(
                        id: "ui.chat.compact", registry: bridge.commandRegistry, display: bridge.paletteDisplay
                      ), command.isEnabled else { return }
                presentsContextSources = false
                bridge.runCommand(id: command.id)
            }
            .disabled(sessionID == nil || compact?.isEnabled != true)
        }
        .frame(width: 320)
        .padding(10)
    }
}

/// Shared by the main and companion composer toolbars; reads the same
/// session-scoped injection result as the former context-notice disclosure.
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
