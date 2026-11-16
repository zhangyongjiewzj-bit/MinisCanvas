import SwiftUI

@MainActor
struct SessionContinuationPreview: View {
    @Bindable var draft: SessionContinuationDraft
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新会话交接摘要").font(.headline)
            Text("摘要可编辑；确认后作为新会话的历史背景。原会话保留。")
                .foregroundStyle(.secondary)
            if draft.isGenerating {
                ProgressView("正在生成交接摘要…")
            }
            if let failure = draft.failureMessage {
                Text(failure).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft.previewText)
                .disabled(draft.isGenerating)
                .accessibilityLabel("可编辑的交接摘要")
                .accessibilityIdentifier("continuation.summary-editor")
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.confirmedBackgroundText == nil ? "不带摘要继续" : "确认并继续", action: confirm)
                    .disabled(draft.isGenerating)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("continuation.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
    }
}

/// A queue row's edit action transfers its complete payload back to the
/// composer, where existing attachment and paste controls remain available.
@MainActor
struct ComposerQueueManagementList: View {
    let items: [PersistedComposerQueueItem]
    var canEdit = true
    let edit: (UUID) -> Void
    let delete: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text.isEmpty ? "附件消息" : item.text)
                                .lineLimit(3)
                            Text("附件 \(item.attachments.count) · 粘贴文本 \(item.pastedDrafts.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { edit(item.id) }
                            .disabled(!canEdit)
                        Button("删除", role: .destructive) { delete(item.id) }
                            .accessibilityIdentifier("composer.queue-management.delete.\(item.id.uuidString)")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.queue-management.row.\(item.id.uuidString)")
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("composer.queue-management")
    }
}
