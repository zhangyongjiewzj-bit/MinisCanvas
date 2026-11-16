import SwiftUI

// MARK: - 聊天主区（消息流式列表 + 输入框）

struct ChatView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            if let session = appState.selectedSession {
                MessageList(session: session)
                    .id(session.id)
                Divider()
                InputBar(
                    text: $appState.draftText,
                    isStreaming: appState.streamingSessionID == session.id,
                    onSend: { appState.sendDraft() },
                    onStop: { appState.stopStreaming() }
                )
            } else {
                ContentUnavailableView(
                    "无会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从侧栏选择一个会话，或新建一个。")
                )
            }
        }
    }
}

// MARK: - 消息列表

private struct MessageList: View {
    @Environment(AppState.self) private var appState
    let session: ChatSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(session.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: session.messages.last?.id) { _, newID in
                if let newID {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.messages.last?.content.count) { _, _ in
                if let last = session.messages.last, last.isStreaming {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: appState.scrollTargetID) { _, target in
                guard let target, let _ = session.messages.first(where: { $0.id == target }) else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                appState.scrollTargetID = nil
            }
        }
    }
}

// MARK: - 消息气泡

struct MessageBubbleView: View {
    let message: ChatMessageUI

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if message.isStreaming && message.content.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("正在思考…").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                } else {
                    bubbleContent
                }
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            MarkdownRenderer.inline(message.content)
                .textSelection(.enabled)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                )
                .foregroundStyle(.white)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(MarkdownRenderer.blocks(from: message.content).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .textSelection(.enabled)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            MarkdownRenderer.inline(text)
        case .heading(let text):
            MarkdownRenderer.inline(text)
                .font(.system(size: 15, weight: .semibold))
        case .listItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                MarkdownRenderer.inline(text)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.35))
            )
        }
    }
}

// MARK: - 输入栏（Enter 发送 / Shift+Enter 换行）

private struct InputBar: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 120)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
                .focused($focused)
                .accessibilityLabel("消息输入")
                .accessibilityHint("输入消息；按 Return 发送，按 Shift 加 Return 换行")
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("输入消息，Enter 发送，Shift+Enter 换行")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 12)
                            .padding(.leading, 11)
                            .allowsHitTesting(false)
                    }
                }

            Button(action: isStreaming ? onStop : onSend) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isStreaming ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel(isStreaming ? "停止生成" : "发送消息")
            .accessibilityHint(isStreaming ? "停止当前回复生成" : "发送当前消息")
            .help(isStreaming ? "停止生成" : "发送")
        }
        .padding(10)
    }
}
