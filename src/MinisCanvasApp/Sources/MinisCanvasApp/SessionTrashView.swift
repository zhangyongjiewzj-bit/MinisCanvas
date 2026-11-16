import SwiftUI
import MinisCore

struct SessionTrashEntryButton: View {
    @Bindable var chat: ChatStore
    let title: String
    @State private var isPresented = false
    var body: some View {
        Button(title) { isPresented = true }
            .buttonStyle(.borderless).controlSize(.small)
            .sheet(isPresented: $isPresented) { SessionTrashView(chat: chat) }
            .accessibilityIdentifier("sessions.open-trash")
    }
}

@MainActor
struct SessionTrashView: View {
    @Bindable var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("回收站 · 保留30天").font(typography?.headline ?? .headline)
                Spacer()
                Button("刷新") { chat.refreshSessionTrash() }
            }
            if chat.sessionTrashEntries.isEmpty {
                Text("回收站为空").foregroundStyle(.secondary)
            } else {
                List(chat.sessionTrashEntries) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(typography?.contextBody ?? .body)
                            Text(item.deletedAt, style: .date)
                                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") { _ = chat.restoreTrashedSession(item.receipt) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("恢复会话 \(item.title)")
                            .accessibilityIdentifier("sessions.trash.restore.\(item.id.uuidString)")
                    }
                }
            }
            if let feedback = chat.sessionTrashFeedback {
                Text(feedback).font(typography?.caption ?? .caption)
                    .accessibilityIdentifier("sessions.trash.feedback")
            }
            Button("关闭") { dismiss() }
        }
        .padding(20).frame(minWidth: 420, minHeight: 320)
        .onAppear { chat.refreshSessionTrash() }
    }
}
