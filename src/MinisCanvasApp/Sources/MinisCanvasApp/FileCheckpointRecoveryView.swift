import SwiftUI
import MinisCore

@MainActor
struct FileCheckpointRecoveryView: View {
    @Bindable var chat: ChatStore
    var redactor: ChatTranscriptRedactor? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var isRestoring = false
    @State private var conversationAnchors: [SessionTranscriptRewindAnchor] = []
    @State private var pendingConversationAnchor: SessionTranscriptRewindAnchor?
    @State private var conversationReadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("恢复文件与会话历史").font(typography?.headline ?? .headline)
            Text("会话锚点 · 仅回退会话")
                .font(typography?.contextBody ?? .body)
            Text("保留所选消息及此前历史，移除其后消息；不恢复文件，草稿与模式保持不变。回退不可撤销。")
                .font(typography?.caption ?? .caption)
            if conversationReadFailed {
                Text("会话锚点暂不可用，请等待当前回合结束或重新打开恢复窗口。")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(conversationAnchors) { anchor in
                        let display = chat.conversationRewindDisplay(for: anchor, redactor: redactor)
                        VStack(alignment: .leading, spacing: 4) {
                            if let preview = display.preview {
                                Text(verbatim: preview).lineLimit(1)
                                if let timestamp = display.timestamp {
                                    HStack {
                                        Text("助手消息")
                                        Text(timestamp, style: .time)
                                    }
                                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("技术详情") {
                                    Text("消息 \(anchor.messageIndex + 1) · 版本 \(anchor.expectedSession.transcriptRevision)")
                                }
                            } else {
                                Text("消息 \(anchor.messageIndex + 1) · 助手消息／可回退边界 · 版本 \(anchor.expectedSession.transcriptRevision)")
                            }
                            Button("仅回退会话至此消息…") { pendingConversationAnchor = display.anchor }
                                .accessibilityIdentifier("checkpoints.conversation.\(anchor.id)")
                                .disabled(isRestoring || chat.isActiveSessionGenerating)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            Divider()
            Text("文件检查点").font(typography?.contextBody ?? .body)
            Text(FileCheckpointStore.scopeDisclosure)
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("checkpoints.scope-disclosure")
            Text("文件检查点有效期为 \(FileCheckpointStore.retentionDays) 天；超期记录不能恢复，启用期间会在启动或打开恢复列表时清理。")
                .font(typography?.body ?? .body).foregroundStyle(.secondary)
                .accessibilityIdentifier("checkpoints.retention-disclosure")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.fileCheckpoints) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                .font(typography?.contextBody ?? .body)
                            Text(item.createdAt, style: .date).font(typography?.caption ?? .caption)
                            AdaptiveControlRowLayout(spacing: 6) {
                                Button("仅恢复文件") { restore(item.id, includeConversation: false) }
                                Button("恢复文件和对话") { restore(item.id, includeConversation: true) }
                                    .disabled(!item.hasConversation)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(isRestoring || chat.isActiveSessionGenerating)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("checkpoints.item.\(item.id.uuidString)")
                    }
                }
            }
            if let feedback = chat.checkpointFeedback {
                Text(feedback).font(typography?.caption ?? .caption)
                    .accessibilityIdentifier("checkpoints.feedback")
            }
            Button("关闭") { dismiss() }.disabled(isRestoring)
        }
        .padding(20).frame(minWidth: 480, minHeight: 360)
        .onAppear { readConversationAnchors() }
        .confirmationDialog("确认仅回退会话？", isPresented: Binding(
            get: { pendingConversationAnchor != nil },
            set: { if !$0 { pendingConversationAnchor = nil } }
        )) {
            Button("确认回退并移除后续消息", role: .destructive) {
                guard let anchor = pendingConversationAnchor, !isRestoring else { return }
                isRestoring = true
                _ = chat.restoreConversationHistory(anchor)
                pendingConversationAnchor = nil
                isRestoring = false
                readConversationAnchors()
            }
            .accessibilityIdentifier("checkpoints.conversation.confirm")
            Button("取消", role: .cancel) { pendingConversationAnchor = nil }
        } message: {
            Text("此操作不可撤销。仅保留该消息及此前历史，移除后续消息；不修改文件、未发送草稿或模式。")
        }
        .onChange(of: chat.activeSessionID) { _, _ in dismiss() }
    }

    private func readConversationAnchors() {
        do {
            conversationAnchors = try chat.conversationRewindAnchors()
            conversationReadFailed = false
        } catch {
            conversationAnchors = []
            conversationReadFailed = true
        }
    }

    private func restore(_ id: UUID, includeConversation: Bool) {
        guard !isRestoring, !chat.isActiveSessionGenerating else { return }
        isRestoring = true
        Task { @MainActor in
            _ = await chat.restoreFileCheckpoint(id, includeConversation: includeConversation)
            isRestoring = false
        }
    }
}
