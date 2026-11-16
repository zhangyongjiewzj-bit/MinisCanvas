import SwiftUI

// MARK: - 会话侧栏（可搜索 / 固定置顶 / 新建 / 删除）

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索会话…", text: $appState.searchText)
                    .textFieldStyle(.plain)
                if !appState.searchText.isEmpty {
                    Button {
                        appState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // 新建会话
            Button {
                appState.newSession()
            } label: {
                Label("新会话", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.15))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // 会话列表（固定置顶在上）
            let matched = appState.session(matching: appState.searchText)
            let pinned = matched.filter { $0.isPinned }
            let unpinned = matched.filter { !$0.isPinned }

            List(selection: $appState.selectedSessionID) {
                if !pinned.isEmpty {
                    Section("已固定") {
                        ForEach(pinned) { session in
                            SessionRow(session: session)
                        }
                    }
                }
                Section {
                    ForEach(unpinned) { session in
                        SessionRow(session: session)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SessionRow: View {
    @Environment(AppState.self) private var appState
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(session.lastMessagePreview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(session.isPinned ? "取消固定" : "固定置顶") {
                appState.togglePin(session)
            }
            Divider()
            Button("删除会话", role: .destructive) {
                appState.deleteSession(session)
            }
        }
    }
}
