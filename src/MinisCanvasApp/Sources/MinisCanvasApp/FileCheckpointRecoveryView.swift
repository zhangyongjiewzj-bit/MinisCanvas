import SwiftUI
import MinisCore

@MainActor
struct FileCheckpointRecoveryView: View {
    @Bindable var chat: ChatStore
    var redactor: ChatTranscriptRedactor? = nil
    /// 只显示这个文件的检查点（来自改动列表的"请求查看恢复"）；按物理规范化路径比较。
    var focusPath: String? = nil
    /// /undo 入口：预选最新检查点。
    var preselectLatest = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var isRestoring = false
    @State private var conversationAnchors: [SessionTranscriptRewindAnchor] = []
    @State private var pendingConversationAnchor: SessionTranscriptRewindAnchor?
    @State private var conversationReadFailed = false
    @State private var includeFilesForConversationRewind = false
    @State private var pendingBeforeCheckpointID: UUID?
    @State private var selectedCheckpointID: UUID?
    @State private var pendingOverwriteCheckpointID: UUID?

    private static func physicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return PolicyRuntimePathBoundary.canonicalPath(standardized) ?? standardized
    }

    private var visibleCheckpoints: [FileCheckpointStore.Summary] {
        guard let focusPath else { return chat.fileCheckpoints }
        let target = Self.physicalPath(focusPath)
        return chat.fileCheckpoints.filter { Self.physicalPath($0.path) == target }
    }

    /// 列表行的说明：操作、到秒的时间、所在目录（同一文件同一天的多条也能区分）。
    private static func rowDetail(for item: FileCheckpointStore.Summary) -> String {
        let operation: String
        switch item.operation {
        case .write: operation = "写入"
        case .edit: operation = "编辑"
        case .delete: operation = "删除"
        case nil: operation = "改动"
        }
        let time = item.createdAt.formatted(
            .dateTime.year().month().day().hour().minute().second())
        let directory = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        return "\(operation) · \(time) · \(directory)"
    }

    /// “恢复到此之前”会撤销的文件名（该检查点及其之后的所有记录）。
    private func filesAffected(byRewindingBefore id: UUID) -> String {
        guard let target = chat.fileCheckpoints.first(where: { $0.id == id }) else { return "" }
        let names = Array(Set(chat.fileCheckpoints.filter { $0.createdAt >= target.createdAt }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent })).sorted()
        let shown = names.prefix(6).joined(separator: "、")
        return names.count > 6 ? "\(shown) 等 \(names.count) 个文件" : shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("恢复文件与会话历史").font(typography?.headline ?? .headline)
            Text("会话锚点 · 仅回退会话")
                .font(typography?.contextBody ?? .body)
            Text("保留所选消息及此前历史，移除其后消息；不恢复文件，草稿与模式保持不变。回退不可撤销。")
                .font(typography?.caption ?? .caption)
            if conversationReadFailed {
                Text("会话锚点暂不可用，请等待当前回合结束或重新打开恢复窗口。")
            } else if conversationAnchors.isEmpty {
                Text("暂无可回退的会话位置：需要先有一条已完成的助手回复（不含工具调用的那种）。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
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
                            HStack {
                                Button("仅回退会话至此消息…") {
                                    includeFilesForConversationRewind = false
                                    pendingConversationAnchor = display.anchor
                                }
                                .accessibilityIdentifier("checkpoints.conversation.\(anchor.id)")
                                Button("回退会话并恢复其后的文件…") {
                                    includeFilesForConversationRewind = true
                                    pendingConversationAnchor = display.anchor
                                }
                                .accessibilityIdentifier("checkpoints.conversation-files.\(anchor.id)")
                            }
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
            Text("检查点总占用上限 \(FileCheckpointStore.totalQuotaBytes / (1024 * 1024)) MB；超出后先清理对话快照，再清理最旧的文件记录，被清理的部分无法再恢复。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if chat.isActiveSessionGenerating {
                        Button("停止并回退本轮文件改动") {
                            guard !isRestoring else { return }
                            isRestoring = true
                            Task { @MainActor in
                                _ = await chat.stopAndRevertTurnFiles()
                                isRestoring = false
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("checkpoints.stop-and-revert")
                    }
                    if visibleCheckpoints.isEmpty {
                        Text(focusPath == nil ? "暂无文件检查点。" : "这个文件暂无可恢复的检查点。")
                            .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    }
                    ForEach(visibleCheckpoints) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                .font(typography?.contextBody ?? .body)
                            Text(Self.rowDetail(for: item))
                                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            if !item.hasConversation {
                                Text("对话快照不可用（过大或已清理），只能恢复文件。")
                                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            }
                            AdaptiveControlRowLayout(spacing: 6) {
                                Button("仅恢复文件") { restore(item.id, includeConversation: false) }
                                Button("恢复文件和对话") { restore(item.id, includeConversation: true) }
                                    .disabled(!item.hasConversation)
                                Button("恢复到此之前…") { pendingBeforeCheckpointID = item.id }
                                    .accessibilityIdentifier("checkpoints.before.\(item.id.uuidString)")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(isRestoring || chat.isActiveSessionGenerating)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(selectedCheckpointID == item.id ? 0.2 : 0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("checkpoints.item.\(item.id.uuidString)")
                    }
                }
            }
            if let feedback = chat.checkpointFeedback {
                Text(feedback).font(typography?.caption ?? .caption)
                    .accessibilityIdentifier("checkpoints.feedback")
            }
            if let conflictID = chat.rewindConflictOfferCheckpointID {
                Button("先把当前版本存为检查点再覆盖…") { pendingOverwriteCheckpointID = conflictID }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isRestoring || chat.isActiveSessionGenerating)
                    .accessibilityIdentifier("checkpoints.before.overwrite")
            }
            Button("关闭") { dismiss() }.disabled(isRestoring)
        }
        .padding(20).frame(minWidth: 480, minHeight: 360)
        .onAppear {
            readConversationAnchors()
            if preselectLatest { selectedCheckpointID = visibleCheckpoints.first?.id }
        }
        .confirmationDialog("确认恢复到此检查点之前？", isPresented: Binding(
            get: { pendingBeforeCheckpointID != nil },
            set: { if !$0 { pendingBeforeCheckpointID = nil } }
        )) {
            Button("确认恢复", role: .destructive) {
                guard let id = pendingBeforeCheckpointID, !isRestoring else { return }
                pendingBeforeCheckpointID = nil
                isRestoring = true
                Task { @MainActor in
                    _ = await chat.restoreFileCheckpointsBefore(id)
                    isRestoring = false
                }
            }
            .accessibilityIdentifier("checkpoints.before.confirm")
            Button("取消", role: .cancel) { pendingBeforeCheckpointID = nil }
        } message: {
            Text("将撤销该检查点及其之后的所有文件改动（从新到旧），涉及：\(pendingBeforeCheckpointID.map(filesAffected(byRewindingBefore:)) ?? "")。任一文件已被改动或不在授权范围内时，所有文件都不会被修改，并会告诉你是哪些文件；对话不变。")
        }
        .confirmationDialog("先保存当前版本，再覆盖？", isPresented: Binding(
            get: { pendingOverwriteCheckpointID != nil },
            set: { if !$0 { pendingOverwriteCheckpointID = nil } }
        )) {
            Button("保存当前版本并覆盖", role: .destructive) {
                guard let id = pendingOverwriteCheckpointID, !isRestoring else { return }
                pendingOverwriteCheckpointID = nil
                isRestoring = true
                Task { @MainActor in
                    _ = await chat.restoreFileCheckpointsBefore(id, overwriteConflicts: true)
                    isRestoring = false
                }
            }
            .accessibilityIdentifier("checkpoints.before.overwrite.confirm")
            Button("取消", role: .cancel) { pendingOverwriteCheckpointID = nil }
        } message: {
            Text("已被改动的文件会先把当前内容存成一个新的检查点（之后还能恢复回来），再恢复到旧版本；其余文件照常恢复。")
        }
        .confirmationDialog("确认仅回退会话？", isPresented: Binding(
            get: { pendingConversationAnchor != nil },
            set: { if !$0 { pendingConversationAnchor = nil } }
        )) {
            Button("确认回退并移除后续消息", role: .destructive) {
                guard let anchor = pendingConversationAnchor, !isRestoring else { return }
                isRestoring = true
                pendingConversationAnchor = nil
                let withFiles = includeFilesForConversationRewind
                Task { @MainActor in
                    if withFiles {
                        _ = await chat.restoreConversationAndFiles(anchor)
                    } else {
                        _ = chat.restoreConversationHistory(anchor)
                    }
                    isRestoring = false
                    readConversationAnchors()
                }
            }
            .accessibilityIdentifier("checkpoints.conversation.confirm")
            Button("取消", role: .cancel) { pendingConversationAnchor = nil }
        } message: {
            Text(includeFilesForConversationRewind
                 ? "此操作不可撤销。保留该消息及此前历史，移除后续消息，并恢复其后改动的文件；任一文件无法恢复时会话也不回退。"
                 : "此操作不可撤销。仅保留该消息及此前历史，移除后续消息；不修改文件、未发送草稿或模式。")
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
