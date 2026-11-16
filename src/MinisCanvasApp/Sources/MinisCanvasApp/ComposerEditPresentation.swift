import SwiftUI
import MinisCore

struct ComposerEditDraftIdentity: Equatable {
    let sessionID: UUID?
    let text: String
    let attachments: [ChatAttachment]
    let pastedDrafts: [PastedTextDraft]
    let editingMessageID: UUID?

    var needsConfirmation: Bool { !text.isEmpty || !attachments.isEmpty || !pastedDrafts.isEmpty }

    @MainActor static func capture(_ chat: ChatStore) -> Self {
        Self(sessionID: chat.activeSessionID, text: chat.draftText,
             attachments: chat.pendingAttachments, pastedDrafts: chat.activePastedTextDrafts,
             editingMessageID: chat.editingMessageID)
    }
}

struct ComposerMessageEditRequest: Identifiable {
    let messageID: UUID
    let draft: ComposerEditDraftIdentity
    var id: UUID { messageID }

    @MainActor static func prepare(chat: ChatStore, messageID: UUID) -> Self? {
        guard chat.messages.contains(where: { $0.id == messageID && $0.role == .user }) else { return nil }
        let draft = ComposerEditDraftIdentity.capture(chat)
        guard draft.needsConfirmation else { chat.beginEdit(messageID: messageID); return nil }
        return Self(messageID: messageID, draft: draft)
    }
}

@MainActor
struct ComposerMessageEditConfirmation: ViewModifier {
    @Bindable var chat: ChatStore
    @Binding var request: ComposerMessageEditRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { expected in
            let current = ComposerEditDraftIdentity.capture(chat)
            let stillCurrent = expected.draft == current
                && chat.messages.contains { $0.id == expected.messageID && $0.role == .user }
            VStack(alignment: .leading, spacing: 12) {
                Text("替换当前草稿？").font(.headline)
                Text("编辑消息会填回原消息并停止当前生成。取消会保留当前草稿和生成状态。")
                if !stillCurrent { Text("草稿或会话已变化，请取消后重新选择消息。") }
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { request = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("替换草稿并编辑") {
                        guard expected.draft == ComposerEditDraftIdentity.capture(chat),
                              chat.messages.contains(where: { $0.id == expected.messageID && $0.role == .user }) else { return }
                        chat.beginEdit(messageID: expected.messageID)
                        request = nil
                    }
                    .disabled(!stillCurrent)
                }
            }
            .padding(20)
            .frame(minWidth: 420)
            .accessibilityIdentifier("composer.edit.confirmation")
        }
    }
}

@MainActor
struct ComposerEditModeBar: View {
    @Bindable var chat: ChatStore
    let accessibilityID: String
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    var body: some View {
        HStack(spacing: 5) {
            MinisIconView(.edit, size: 12)
                .font(.system(size: 9, weight: .semibold))
            Text("编辑消息中…（回车作为新消息重发）")
                .font((typography?.caption2 ?? .system(size: 9)).weight(.medium))
                .lineLimit(1)
            Button { chat.cancelEdit() } label: {
                MinisIconView(.close, size: 12).font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("取消编辑")
            .accessibilityLabel("取消编辑")
            .accessibilityIdentifier(accessibilityID + ".cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.12)))
        .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
    }
}

enum ChatAuthorizationFeedbackExpiry {
    @MainActor static func waitToClear(
        expected: String,
        sleep: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(6)) },
        current: @MainActor () -> String?, clear: @MainActor () -> Void
    ) async {
        do { try await sleep() } catch { return }
        guard !Task.isCancelled, current() == expected else { return }
        clear()
    }
}
