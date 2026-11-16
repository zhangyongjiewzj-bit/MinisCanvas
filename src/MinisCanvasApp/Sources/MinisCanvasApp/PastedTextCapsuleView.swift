import SwiftUI
import MinisCore

@MainActor
enum PastedTextComposerConsumer {
    /// Returns true only when the long paste was accepted into ChatStore.
    /// Short text remains owned by NSTextView's native paste path.
    @discardableResult
    static func accept(_ event: ComposerPasteEvent, in chat: ChatStore) -> Bool {
        guard PastedTextPolicy.shouldCollapse(event.draft) else { return false }
        // Accepting a separate reference is not an edit or clear of an
        // unchanged body. Real body changes retain the draft persistence path.
        if chat.draftText != event.bodyBefore {
            chat.draftText = event.bodyBefore
        }
        return chat.setPastedTextDraft(event.draft)
    }

    @discardableResult
    static func save(
        _ draft: PastedTextDraft,
        expectedSessionID: UUID,
        expectedDraftID: UUID,
        in chat: ChatStore
    ) -> Bool {
        chat.updatePastedTextDraft(
            draft,
            expectedSessionID: expectedSessionID,
            expectedDraftID: expectedDraftID
        )
    }

    @discardableResult
    static func remove(
        expectedSessionID: UUID,
        expectedDraftID: UUID,
        in chat: ChatStore
    ) -> Bool {
        chat.removePastedTextDraft(
            expectedSessionID: expectedSessionID,
            expectedDraftID: expectedDraftID
        )
    }

    static func intentInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        sessionReadIntentInput(body: body, pastedText: pastedText)
    }

    /// Reference material is never an authorization signal. Only the typed
    /// body and an explicit instruction capsule may enter intent matching.
    static func sessionReadIntentInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        PastedTextPolicy.sessionReadIntentInput(body: body, pastedText: pastedText)
    }

    static func commandInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        PastedTextPolicy.commandInput(body: body, pastedText: pastedText)
    }

    static func submissionSnapshot(
        capsuleID: UUID,
        sessionID: UUID,
        body: String,
        pastedText: PastedTextDraft
    ) -> PastedTextSubmissionSnapshot {
        PastedTextSubmissionSnapshot(
            capsuleID: capsuleID,
            sessionID: sessionID,
            body: body,
            pastedText: pastedText
        )
    }
}

/// Bounded summary for long pasted text; the full payload remains outside the view.
struct PastedTextCapsuleView: View {
    static let accessibilityIdentifier = "composer.pasted-text.capsule"

    let draft: PastedTextDraft
    @Environment(\.themeTokens) private var theme
    let onPreview: () -> Void
    let onRemove: () -> Void

    init(
        draft: PastedTextDraft,
        onPreview: @escaping () -> Void = {},
        onRemove: @escaping () -> Void = {}
    ) {
        self.draft = draft
        self.onPreview = onPreview
        self.onRemove = onRemove
    }

    private var summary: PastedTextSummary {
        PastedTextPolicy.summary(for: draft.text)
    }

    var body: some View {
        HStack(spacing: 6) {
            MinisIconView(.document, size: MinisIconTokens.defaultSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(draft.kind == .instruction ? "粘贴指令" : "粘贴参考")
                    .font(.caption.weight(.medium))
                Text("\(summary.characterCount) 字符 · \(summary.lineCount) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !summary.preview.isEmpty {
                    Text(InvisibleCharacterPolicy.visible(summary.preview).replacingOccurrences(of: "\n", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onPreview) {
                MinisIconView(.eye, size: MinisIconTokens.smallSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑粘贴文本")
            .accessibilityIdentifier("composer.pasted-text.preview")
            .help("预览并编辑粘贴文本")

            Button(action: onRemove) {
                MinisIconView(.remove, size: MinisIconTokens.smallSize, accessibilityLabel: "删除粘贴文本")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除粘贴文本")
            .accessibilityIdentifier("composer.pasted-text.remove")
            .help("删除粘贴文本")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(draft.kind == .instruction ? "粘贴指令摘要" : "粘贴参考摘要")
        .accessibilityValue("\(summary.characterCount) 字符，\(summary.lineCount) 行")
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

struct PastedTextEditorState: Identifiable {
    let id: UUID
    let sessionID: UUID
    let draft: PastedTextDraft

    init(sessionID: UUID, draft: PastedTextDraft) {
        self.id = draft.id
        self.sessionID = sessionID
        self.draft = draft
    }
}

struct PastedTextCapsuleEditor: View {
    @Bindable var chat: ChatStore
    let state: PastedTextEditorState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeTokens) private var theme
    @State private var text: String

    init(chat: ChatStore, state: PastedTextEditorState) {
        self.chat = chat
        self.state = state
        _text = State(initialValue: state.draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑粘贴文本")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 460, minHeight: 260)
                .accessibilityIdentifier("composer.pasted-text.editor")
                .accessibilityLabel("粘贴文本编辑器")

            if let notice = InvisibleCharacterPolicy.notice(in: [text]) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.pasted-text.invisible-characters")
            }

            if let feedback = chat.pastedTextActionFeedback {
                Text(feedback)
                    .font(.caption)
                    .modifier(ReadableStatusForeground(status: .warning))
                    .accessibilityIdentifier("composer.pasted-text.feedback")
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                Button("删除", role: .destructive) {
                    delete()
                }
                .accessibilityIdentifier("composer.pasted-text.delete")

                Spacer()

                Button("取消") {
                    chat.clearPastedTextActionFeedback()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("composer.pasted-text.cancel")

                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("composer.pasted-text.save")
            }
        }
        .padding(16)
        .onAppear {
            chat.clearPastedTextActionFeedback()
        }
    }

    private func save() {
        let updated = PastedTextDraft(
            id: state.draft.id,
            text: text,
            source: state.draft.source,
            kind: state.draft.kind
        )
        guard PastedTextComposerConsumer.save(
            updated,
            expectedSessionID: state.sessionID,
            expectedDraftID: state.draft.id,
            in: chat
        ) else { return }
        dismiss()
    }

    private func delete() {
        guard PastedTextComposerConsumer.remove(
            expectedSessionID: state.sessionID,
            expectedDraftID: state.draft.id,
            in: chat
        ) else { return }
        dismiss()
    }
}

/// Transcript projection for sent pasted material. Expansion is explicit and
/// the owning session is responsible for accepting the toggle.
struct PastedTextReferenceCardView: View {
    let card: PastedTextReferenceCard
    let isSessionCurrent: Bool
    let onToggle: () -> Void

    private var cardKindLabel: String {
        card.kind == .instruction ? "指令" : "参考"
    }

    /// Keep transcript elements unique across sessions and capsules while
    /// retaining a stable prefix for focused automation selectors.
    private var cardIdentity: String {
        "\(card.sessionID.uuidString).\(card.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                MinisIconView(.document, size: 14)
                    .accessibilityHidden(true)
                Text("粘贴\(cardKindLabel)")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(card.characterCount) 字符 · \(card.lineCount) 行")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(card.isExpanded ? "收起\(cardKindLabel)" : "展开\(cardKindLabel)", action: onToggle)
                    .buttonStyle(.link)
                    .font(.system(size: 10, weight: .medium))
                    .disabled(!isSessionCurrent)
                    .accessibilityLabel(card.isExpanded ? "收起粘贴\(cardKindLabel)" : "展开粘贴\(cardKindLabel)")
                    .accessibilityValue(isSessionCurrent ? "当前会话" : "会话已切换，已锁定")
                    .accessibilityIdentifier("chat.pasted-reference-card.toggle.\(cardIdentity)")
                    .help(card.isExpanded ? "收起粘贴\(cardKindLabel)" : "展开粘贴\(cardKindLabel)")
            }
            if !card.instruction.isEmpty {
                Text(card.instruction)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
            }
            Text(card.renderedMaterial)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(card.isExpanded ? nil : 4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "粘贴\(cardKindLabel)，\(card.stateLabel)，\(card.characterCount) 字符"
        )
        .accessibilityValue(isSessionCurrent ? "当前会话" : "会话已切换，已锁定")
        .accessibilityIdentifier("chat.pasted-reference-card.\(cardIdentity)")
    }
}
