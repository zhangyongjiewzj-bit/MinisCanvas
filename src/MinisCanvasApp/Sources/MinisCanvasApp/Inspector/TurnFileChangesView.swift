import SwiftUI

struct TurnFileChangesView: View {
    let changes: [TurnFileChange]
    let canSendComment: Bool
    let onSendComment: (String) async -> Bool
    let onReviewRecovery: (String) -> Void
    var onReviewChildRecovery: ((String, String) -> Void)? = nil
    @State private var selectedTurn: Int?
    @Environment(\.typographyTokens) private var typography

    private var turns: [Int] { Array(Set(changes.map(\.turnID))).sorted() }
    private var effectiveTurn: Int? {
        selectedTurn.flatMap { turns.contains($0) ? $0 : nil } ?? turns.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("回合", selection: Binding(get: { effectiveTurn }, set: { selectedTurn = $0 })) {
                ForEach(turns, id: \.self) { turn in
                    Text("T\(turn)").tag(Optional(turn))
                }
            }
            .accessibilityIdentifier("changes.turn-picker")
            Text("仅包含成功文件工具的账本记录；shell 命令造成的改动不在此面板。账本保留范围外的历史不显示；源载荷已截断的内容无法展开恢复。成功事实仅来自当前 engine 内存，重启后缺少匹配事实的旧记录不显示。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            if !canSendComment {
                Text("评论会通过普通输入框发送；请先处理输入草稿、附件或编辑中的消息。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(ChildTaskFileReviewGroup.capture(changes, turnID: effectiveTurn)) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title).font(typography?.contextBody ?? .body)
                            ForEach(group.changes) { change in
                                TurnFileDiffView(change: change, canSendComment: canSendComment,
                                    onSendComment: onSendComment, onReviewRecovery: onReviewRecovery,
                                    onReviewChildRecovery: onReviewChildRecovery)
                            }
                        }
                        .accessibilityIdentifier("changes.group.\(group.id)")
                    }
                    if changes.isEmpty {
                        Text("当前会话暂无可归属回合的文件改动。")
                            .font(typography?.contextBody ?? .body).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .accessibilityIdentifier("changes.panel")
    }
}

private struct TurnFileDiffView: View {
    let change: TurnFileChange
    let canSendComment: Bool
    let onSendComment: (String) async -> Bool
    let onReviewRecovery: (String) -> Void
    let onReviewChildRecovery: ((String, String) -> Void)?
    @State private var expanded = false
    @State private var expandedText = false
    @State private var selectedLine: DiffReviewLine?
    @State private var comment = ""
    @State private var feedback: String?
    @State private var pendingCommentSubmission: UUID?
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    private var visibleDiff: String {
        expandedText ? change.diff : String(change.diff.prefix(TurnFileChangesProjection.previewCharacters))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(DiffReviewLine.parse(visibleDiff)) { line in
                            Button {
                                selectedLine = line
                                feedback = nil
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(line.oldLine.map(String.init) ?? "").frame(width: 36, alignment: .trailing)
                                    Text(line.newLine.map(String.init) ?? "").frame(width: 36, alignment: .trailing)
                                    Text(line.text).fixedSize(horizontal: true, vertical: false)
                                }
                                .font((typography?.caption ?? .caption).monospaced())
                                .foregroundStyle(line.isAddition ? (theme?.statusSuccess ?? .green)
                                    : line.isDeletion ? (theme?.statusDangerText ?? .red) : Color.secondary)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .disabled(pendingCommentSubmission != nil || (line.oldLine == nil && line.newLine == nil))
                            .accessibilityLabel("旧行 \(line.oldLine.map(String.init) ?? "无")，新行 \(line.newLine.map(String.init) ?? "无")，\(line.text)")
                        }
                    }
                }
                if let notice = change.sourceTruncationNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
                if !expandedText && change.diff.count > TurnFileChangesProjection.previewCharacters {
                    Text("已截断：当前显示前 6000 字符。")
                    Button(change.expansionLabel) { expandedText = true }
                }
                if expandedText && change.exceedsExpandedLimit {
                    Text("已达到 64 KB 上限，Diff 仍不完整。")
                }
                if let line = selectedLine {
                    Text("针对 \(change.path):\(line.newLine ?? line.oldLine ?? 0)\(line.newLine == nil ? "（删除前）" : "")")
                    TextField("修改意见", text: $comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .disabled(pendingCommentSubmission != nil)
                    Button(pendingCommentSubmission == nil ? "发送评论" : "正在提交…") { send(line) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(pendingCommentSubmission != nil || !canSendComment || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let feedback { Text(feedback) }
                if let childTaskID = change.childTaskID {
                    Button("审核子任务文件恢复…") {
                        onReviewChildRecovery?(childTaskID, change.absolutePath)
                    }
                    .disabled(onReviewChildRecovery == nil)
                    Text(onReviewChildRecovery == nil
                         ? "子任务恢复审批入口尚不可用；未执行恢复。"
                         : "将按此子任务与文件筛选检查点，逐文件审核；文件已变化时不能覆盖。")
                        .foregroundStyle(.secondary)
                } else {
                    Button("还原此文件改动…") { onReviewRecovery(change.absolutePath) }
                    Text("将打开现有检查点列表，需选择快照；不会自动猜测本条改动对应的快照。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(typography?.caption ?? .caption)
        } label: {
            HStack {
                Text(change.path).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("+\(change.additions) −\(change.deletions)")
            }
            .font(typography?.contextBody ?? .body)
        }
        .onDisappear {
            // Invalidate only this view's late result; the Composer owns admission.
            pendingCommentSubmission = nil
        }
    }

    private func send(_ line: DiffReviewLine) {
        guard pendingCommentSubmission == nil, canSendComment,
              let message = TurnFileChangesProjection.comment(path: change.path, line: line, text: comment)
        else { return }
        let submittedComment = comment
        let submissionID = UUID()
        pendingCommentSubmission = submissionID
        Task { @MainActor in
            let accepted = await onSendComment(message)
            guard pendingCommentSubmission == submissionID else { return }
            pendingCommentSubmission = nil
            if accepted {
                if comment == submittedComment { comment = "" }
                feedback = "普通消息流程已受理；发送或排队状态请查看聊天区。"
            } else {
                feedback = "未受理，评论已保留。请检查会话与输入区。"
            }
        }
    }
}
