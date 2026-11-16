import SwiftUI

// MARK: - 命令面板（Cmd+K 唤起）

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let shortcut: String?
}

extension PaletteCommand {
    static let all: [PaletteCommand] = [
        PaletteCommand(id: "new", title: "新建会话", subtitle: "开启一个新的对话", icon: "square.and.pencil", shortcut: "⌘N"),
        PaletteCommand(id: "toggleMock", title: "切换模型", subtitle: "在 Mock / 已注册 Provider 间切换", icon: "cpu", shortcut: nil),
        PaletteCommand(id: "toggleMessages", title: "切换消息列表栏", subtitle: "显示 / 隐藏三栏中间的消息列表", icon: "sidebar.right", shortcut: nil),
        PaletteCommand(id: "settings", title: "打开设置", subtitle: "Provider 配置与模型选择", icon: "gearshape", shortcut: nil),
        PaletteCommand(id: "canvas", title: "打开画布", subtitle: "无限画布（A2 CanvasApp 后续接入）", icon: "square.grid.2x2", shortcut: nil),
    ]
}

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return PaletteCommand.all }
        return PaletteCommand.all.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            // 半透明遮罩，点击关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { appState.palettePresented = false }

            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 8) {
                    Image(systemName: "command")
                        .foregroundStyle(.secondary)
                    TextField("输入命令或搜索…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($queryFocused)
                        .accessibilityLabel("命令搜索")
                        .accessibilityHint("输入关键词筛选命令；上下方向键选择，Return 执行，Escape 关闭")
                        .onKeyPress(.downArrow) {
                            if !filtered.isEmpty { selectedIndex = min(selectedIndex + 1, filtered.count - 1) }
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            selectedIndex = max(selectedIndex - 1, 0)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            appState.palettePresented = false
                            return .handled
                        }
                        .onSubmit {
                            execute(filtered[safe: selectedIndex] ?? filtered.first)
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(12)

                Divider()

                // 命令列表
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            Button {
                                execute(command)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: command.icon)
                                        .frame(width: 22)
                                        .foregroundStyle(index == selectedIndex ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(command.title)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(command.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let shortcut = command.shortcut {
                                        Text(shortcut)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(index == selectedIndex ? Color.accentColor.opacity(0.18) : .clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(command.title)
                            .accessibilityValue(command.subtitle + (command.shortcut.map { "，快捷键 \($0)" } ?? ""))
                            .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
        }
        .onAppear {
            queryFocused = true
            query = ""
            selectedIndex = 0
        }
    }

    private func execute(_ command: PaletteCommand?) {
        guard let command else { return }
        appState.runCommand(command)
    }
}

extension Collection {
    /// 越界安全下标。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
