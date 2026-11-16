import SwiftUI
import AppKit
import CanvasCore

// MARK: - U2-r 节点级模型对话面板（右侧上下文面板内）
//
// 节点选中时展示：标题「节点「标题」· 模型名」+ 该节点独立消息历史 +
// 输入框（发送给该节点模型）+ 清空历史按钮 + 模型设置按钮。
// 与 agent 对话完全隔离：读写 NodeChatStore（nodeID 分区历史），不碰 ChatStore。
// 无 key / 无 provider：输入框禁用 + 内联提示（NodeChatConfigStatus.hint）。

struct NodeChatPanelView: View {
    let node: CanvasNode
    let canvas: CanvasStore
    @Bindable var nodeChat: NodeChatStore

    @Environment(\.themeTokens) private var theme

    /// 主题强调色（AJ-38 赭橙；未注入回退系统 accent）
    private var accent: Color { theme?.aj38.accent.swiftUIColor ?? Color.accentColor }

    init(node: CanvasNode, canvas: CanvasStore) {
        self.node = node
        self.canvas = canvas
        self._nodeChat = Bindable(canvas.nodeChat)
    }

    /// 实时后端配置（store 为 @Observable，模型面板改配置自动刷新）
    private var backend: NodeBackendConfig? {
        canvas.graph.node(id: node.id)?.backendConfig
    }

    /// 标题栏模型名：如 "bailian · qwen3.8-max-preview"；未配置 → "默认（未配置）"
    private var modelLabel: String {
        guard let config = backend, !config.providerID.isEmpty else { return "默认（未配置）" }
        return config.displayName
    }

    private var configStatus: NodeChatConfigStatus {
        nodeChat.configurationStatus(nodeID: node.id, backend: backend)
    }

    private var messages: [NodeChatMessage] {
        nodeChat.messages(for: node.id)
    }

    private var inputText: Binding<String> {
        Binding(
            get: { nodeChat.input(for: node.id) },
            set: { nodeChat.setInput($0, for: node.id) }
        )
    }

    private var canSend: Bool {
        configStatus.isReady && !nodeChat.isSending(nodeID: node.id)
    }

    /// AJ-74：节点×LLM 前台下线开关——NodeChat 面板入口整体禁用（true = 显示下线说明）。
    /// 恢复节点对话时改为 false 即可，chatContent 全部逻辑原样保留（编译不破坏）。
    private static let nodeChatRetired = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Self.nodeChatRetired {
                offlineNotice
            } else {
                chatContent
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((theme?.aj38.borderSubtle.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor)).opacity(0.10))
        )
    }

    /// AJ-74 预留：原节点对话 UI（保留不删，待恢复节点对话时替换 offlineNotice 展示）。
    @ViewBuilder
    private var chatContent: some View {
        if NodeCapability.supportsLLMChat(nodeType: node.type) {
            header
            Divider()
            messageList
            if !configStatus.isReady {
                hintRow
            }
            inputRow
            footerRow
        } else {
            // F10 P0-03：生图/生视频节点不支持 LLM 聊天（后端是生图/生视频服务，
            // 无对话能力）→ 隐藏聊天入口，只留说明 + 模型设置入口。
            mediaNodeNotice
        }
    }

    /// AJ-74：下线占位——面板入口隐藏/禁用：不渲染输入框、历史与模型设置入口，仅提示下线。
    private var offlineNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("节点对话已下线（AJ-74）")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text("节点×LLM 前台功能已下线：节点对话暂不可用，相关逻辑保留待后续恢复。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    // MARK: 媒体节点说明（F10 P0-03：隐藏 LLM 聊天选项）

    private var mediaNodeNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: NodeCapability.forNodeType(node.type) == .image ? "photo" : "video")
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                Text("节点「\(node.title)」· \(modelLabel)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    canvas.presentModelPanel(for: node.id)
                } label: {
                    Label("模型设置", systemImage: "cpu")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .help("打开模型设置面板（选择媒体后端与参数）")
            }
            Text("生图/生视频节点不支持模型聊天：请在模型设置面板选择媒体后端（生图/生视频服务）与时长、分辨率等参数。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    // MARK: 头部：节点「标题」· 模型名 + 模型设置按钮

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 10))
                .foregroundStyle(accent)
            Text("节点「\(node.title)」· \(modelLabel)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help("该节点模型对话（独立历史，与 agent 隔离）")
            Spacer(minLength: 4)
            Button {
                canvas.presentModelPanel(for: node.id)
            } label: {
                Label("模型设置", systemImage: "cpu")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .help("打开模型设置面板")
        }
    }

    // MARK: 消息列表（该节点独立历史）

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.isEmpty {
                        Text("与「\(node.title)」的模型对话从这里开始")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(messages) { message in
                            NodeChatBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 90, maxHeight: 240)
            .onChange(of: messages.last?.id) { _, newID in
                if let newID {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: 无 key / 无 provider 提示

    private var hintRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(theme?.statusWarning ?? .orange)
            Text(configStatus.hint)
                .font(.system(size: 9))
                .foregroundStyle(theme?.statusWarning ?? .orange)
                .lineLimit(2)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((theme?.statusWarning ?? .orange).opacity(0.10))
        )
    }

    // MARK: 输入行（发送给该节点模型）

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField("发送给该节点模型…", text: inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...4)
                .disabled(!configStatus.isReady)
                .onSubmit {
                    guard canSend else { return }
                    Task { await canvas.sendNodeChat(nodeID: node.id, message: inputText.wrappedValue) }
                }
            Button {
                Task { await canvas.sendNodeChat(nodeID: node.id, message: inputText.wrappedValue) }
            } label: {
                if nodeChat.isSending(nodeID: node.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? accent : Color.secondary.opacity(0.4))
            .disabled(!canSend)
            .help(canSend ? "发送给该节点模型（⏎）" : configStatus.hint)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor)).opacity(0.6))
        )
    }

    // MARK: 底部：清空历史 + 消息计数

    private var footerRow: some View {
        HStack {
            Text("\(messages.count) 条消息 · 独立于 agent 对话")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                nodeChat.clearHistory(nodeID: node.id)
            } label: {
                Label("清空历史", systemImage: "trash")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(messages.isEmpty)
            .help("清空该节点对话历史")
        }
    }
}

// MARK: - 消息气泡（user 右 / assistant 左，复用 MarkdownTextView）

private struct NodeChatBubble: View {
    let message: NodeChatMessage

    @Environment(\.themeTokens) private var theme

    /// 主题强调色（AJ-38 赭橙；未注入回退系统 accent）
    private var accent: Color { theme?.aj38.accent.swiftUIColor ?? Color.accentColor }

    @State private var isHovered = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                MarkdownTextView(text: message.content)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.opacity(0.85))
                    )
                    .foregroundStyle(.white)
                    // AJ-27：hover 复制按钮（与 ChatBubble 共用组件）
                    .overlay(alignment: .topTrailing) {
                        if isHovered {
                            BubbleCopyButton(content: message.content)
                                .offset(x: 6, y: -8)
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
                    }
            }
        case .assistant:
            HStack(alignment: .bottom, spacing: 6) {
                MarkdownTextView(text: message.content)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor))
                    )
                    // AJ-27：hover 复制按钮（与 ChatBubble 共用组件）
                    .overlay(alignment: .topTrailing) {
                        if isHovered {
                            BubbleCopyButton(content: message.content)
                                .offset(x: 6, y: -8)
                        }
                    }
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
                    }
                Spacer(minLength: 30)
            }
        }
    }
}
