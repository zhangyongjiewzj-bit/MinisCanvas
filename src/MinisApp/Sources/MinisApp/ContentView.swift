import SwiftUI

// MARK: - 三栏主界面（会话侧栏 / 消息列表 / 聊天区）

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } content: {
            if appState.showMessageList {
                SessionMessagesView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
            } else {
                Color.clear
            }
        } detail: {
            ChatView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.newSession()
                } label: {
                    Label("新会话", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("新建会话 (⌘N)")

                ModelPickerView()

                Button {
                    appState.palettePresented = true
                } label: {
                    Label("命令面板", systemImage: "command")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("命令面板 (⌘K)")
            }
        }
        .overlay {
            if appState.palettePresented {
                CommandPaletteView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: appState.palettePresented)
        .sheet(isPresented: $appState.settingsPresented) {
            SettingsView()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 三栏中间：当前会话的消息列表（点击跳转到聊天区对应消息）

private struct SessionMessagesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = appState.selectedSession {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                Divider()

                List {
                    ForEach(session.messages) { message in
                        Button {
                            appState.scrollTargetID = message.id
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: message.role == .user ? "person.circle" : "sparkles")
                                    .font(.system(size: 11))
                                    .foregroundStyle(message.role == .user ? Color.accentColor : Color.orange)
                                Text(message.content.isEmpty ? "…" : message.content)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            } else {
                ContentUnavailableView("未选择会话", systemImage: "bubble.left")
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - 设置面板

private struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.title2.bold())

            GroupBox("Provider 与模型") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("当前：")
                        Text(appState.providerLabel)
                            .fontWeight(.medium)
                    }
                    ModelPickerView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }

            GroupBox("凭据（环境变量）") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("云端 Provider 的 API Key 从环境变量读取：")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("OPENAI_API_KEY · ANTHROPIC_API_KEY · OPENROUTER_API_KEY")
                        .font(.system(size: 12, design: .monospaced))
                    Text("本地（Ollama/ComfyUI）默认 http://127.0.0.1:11434，无需凭据。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("已注册 Provider（ProviderFactory）") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.availableProviders, id: \.self) { type in
                        Label(type.displayName, systemImage: "checkmark.circle")
                            .font(.system(size: 12))
                    }
                }
                .padding(8)
            }

            Spacer()

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}
