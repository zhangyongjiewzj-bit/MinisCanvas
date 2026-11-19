import SwiftUI
import MinisCore

/// 右侧检查器的“任务看板”页：当前项目（普通会话共用“个人”看板）的共享任务列表。
/// 各会话通过 `task_board` 工具读写，用户也可以在这里直接增删改、放开认领、跳到认领它的会话。
struct TaskBoardInspectorView: View {
    @Environment(\.themeTokens) private var theme
    let chat: ChatStore
    @State private var items: [TaskBoardItem] = []
    @State private var newTitle = ""
    @State private var errorText: String?
    @State private var loadError: String?
    @Environment(\.typographyTokens) private var typography

    private var boardKey: String {
        chat.sessions.first(where: { $0.id == chat.activeSessionID })?.projectID
            ?? TaskBoardStore.personalBoardKey
    }

    private var boardName: String {
        boardKey == TaskBoardStore.personalBoardKey ? "个人" : "本项目"
    }

    var body: some View {
        InspectorSection(
            identifier: "chat-inspector.task-board",
            title: "任务看板",
            icon: "checklist",
            summary: items.isEmpty ? boardName : "\(boardName) · \(items.count) 项",
            initiallyExpanded: false
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("新任务标题", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTask)
                        .accessibilityIdentifier("task-board.new-title")
                    Button("添加", action: addTask)
                        .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if items.isEmpty && loadError == nil {
                    Text("暂无任务。会话可以用 task_board 工具认领和更新任务。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in row(item) }
                if let message = loadError ?? errorText {
                    Text(message)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                }
            }
        }
        .accessibilityIdentifier("task-board")
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: TaskBoardStore.didChangeNotification)) { _ in
            reload()
        }
        .onChange(of: boardKey) { _, _ in reload() }
    }

    @ViewBuilder
    private func row(_ item: TaskBoardItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(typography?.body ?? .callout)
                    .strikethrough(item.status == .done)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu(item.status.displayName) {
                    ForEach(TaskBoardStatus.allCases, id: \.self) { status in
                        Button(status.displayName) { setStatus(item, status) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { remove(item) } label: { MinisIconView(.delete, size: 14) }
                    .buttonStyle(.borderless)
                    .help("删除任务")
            }
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let owner = item.claimedBySessionID {
                HStack(spacing: 8) {
                    Text("认领：\(item.claimedByTitle ?? "会话")")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                    if let id = UUID(uuidString: owner), chat.sessions.contains(where: { $0.id == id }) {
                        Button("打开会话") { chat.switchSession(id: id) }
                            .buttonStyle(.link)
                    }
                    Button("放开认领") { unclaim(item) }
                        .buttonStyle(.link)
                }
            }
            if !item.note.isEmpty {
                Text("备注：\(item.note)")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        do {
            items = try TaskBoardStore.shared.items(boardKey: boardKey)
            loadError = nil
        } catch {
            items = []
            loadError = (error as? LocalizedError)?.errorDescription ?? "任务看板读取失败"
        }
    }

    private func addTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        perform {
            _ = try TaskBoardStore.shared.add(
                boardKey: boardKey, title: title, creatorSessionID: nil, creatorTitle: nil)
            newTitle = ""
        }
    }

    private func setStatus(_ item: TaskBoardItem, _ status: TaskBoardStatus) {
        perform {
            _ = try TaskBoardStore.shared.setStatus(
                boardKey: boardKey, id: item.id, status: status, note: nil, requesterSessionID: nil)
        }
    }

    private func unclaim(_ item: TaskBoardItem) {
        perform { _ = try TaskBoardStore.shared.unclaim(boardKey: boardKey, id: item.id) }
    }

    private func remove(_ item: TaskBoardItem) {
        perform { try TaskBoardStore.shared.remove(boardKey: boardKey, id: item.id, requesterSessionID: nil) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "操作失败"
        }
        reload()
    }
}
