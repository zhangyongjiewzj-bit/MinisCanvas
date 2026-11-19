import SwiftUI
import MinisCore

/// 独立的聊天正文空状态。
///
/// 该视图只描述空 session 的内容和发送回调，不读取或修改 ChatStore。
/// 主控接线时应由 composer/ChatStore 负责把回调转换为真实发送动作。
struct ChatEmptyStateView: View {
    @Environment(\.themeTokens) private var theme
    struct Content: Equatable {
        let sessionID: UUID

        var title: String { "开始新的对话" }
        var prompt: String { "输入消息开始与 Minis 助手协作" }
        var identity: String { "chat.emptyState.\(sessionID.uuidString)" }
        var accessibilityLabel: String { "空会话" }
    }

    struct LayoutMetrics: Equatable {
        let minimumWidth: CGFloat
        let contentWidth: CGFloat
        let usesVerticalStack: Bool
        let promptLineLimit: Int
    }

    /// The empty-state contract for a failed turn. It contains only the typed
    /// recovery action and bounded user-facing text; no provider payload or
    /// automatic retry is carried into the view.
    struct FailureContent: Equatable {
        let status: MinisCore.ConversationEventStatus
        let title: String
        let message: String
        let action: ChatGenerationRecoveryAction

        var isTerminal: Bool { status.isTerminal && action == .none }
        var isActionable: Bool { action != .none }
        var recoveryAction: ChatGenerationRecoveryAction { action }
        var actionTitle: String { action.title }
        var actionHint: String { action.accessibilityHint }
        var accessibilityLabel: String {
            action == .none ? "\(title)：\(message)" : "\(title)：\(message)，可执行动作：\(actionTitle)"
        }
    }

    static let accessibilityIdentifier = "chat.emptyState"
    static let sendPromptText = "你好，帮我开始一个新任务"

    let sessionID: UUID?
    let failure: ChatGenerationFailureProjection?
    private let onSendPrompt: (String) -> Void
    private let onRecoveryAction: (ChatGenerationRecoveryAction) -> Void

    init(
        sessionID: UUID?,
        failure: ChatGenerationFailureProjection? = nil,
        onSendPrompt: @escaping (String) -> Void,
        onRecoveryAction: @escaping (ChatGenerationRecoveryAction) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.failure = failure
        self.onSendPrompt = onSendPrompt
        self.onRecoveryAction = onRecoveryAction
    }

    static func content(for sessionID: UUID) -> Content {
        Content(sessionID: sessionID)
    }

    static func failureContent(for projection: ChatGenerationFailureProjection) -> FailureContent {
        let title: String
        switch projection.status {
        case .cancelled:
            title = "请求已取消"
        case .failed where projection.isRecoverable:
            title = "对话需要恢复"
        default:
            title = "请求未完成"
        }
        return FailureContent(
            status: projection.status,
            title: title,
            message: projection.userFacingMessage,
            action: projection.actionableRecoveryAction
        )
    }

    static func layoutMetrics(for availableWidth: CGFloat) -> LayoutMetrics {
        let width = max(availableWidth, 180)
        return LayoutMetrics(
            minimumWidth: width,
            contentWidth: max(width - 32, 148),
            usesVerticalStack: true,
            promptLineLimit: 2
        )
    }

    func sendPrompt() {
        onSendPrompt(Self.sendPromptText)
    }

    func recover() {
        guard let failure else { return }
        let action = failure.actionableRecoveryAction
        guard action != .none else { return }
        onRecoveryAction(action)
    }

    var body: some View {
        Group {
            if let failure {
                let content = Self.failureContent(for: failure)
                GeometryReader { geometry in
                    let metrics = Self.layoutMetrics(for: geometry.size.width)
                    VStack(spacing: 14) {
                        Group {
                            if content.isTerminal {
                                MinisIconView(.warning, size: 28)
                                    .foregroundPalette(theme?.statusWarning ?? AppStatusColor.warning)
                            } else {
                                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                            }
                        }
                        .accessibilityHidden(true)

                        VStack(spacing: 6) {
                            Text(content.title)
                                .font(.system(size: 20, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.emptyState.failure.title")

                            Text(content.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(metrics.promptLineLimit)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.emptyState.failure.message")
                        }

                        if content.action != .none {
                            Button {
                                recover()
                            } label: {
                                Label {
                                    Text(content.actionTitle)
                                } icon: {
                                    MinisIconView(.refresh, size: 14)
                                        .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("chat.emptyState.failure.action")
                            .accessibilityHint(content.actionHint)
                        }
                    }
                    .frame(maxWidth: min(420, metrics.contentWidth))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(content.accessibilityLabel)
                .accessibilityIdentifier("chat.emptyState.failure")
            } else if let sessionID {
                let content = Self.content(for: sessionID)
                GeometryReader { geometry in
                    let metrics = Self.layoutMetrics(for: geometry.size.width)
                    VStack(spacing: 14) {
                        MinisIconView(.messages, size: 28)
                            .accessibilityHidden(true)

                        VStack(spacing: 6) {
                            Text(content.title)
                                .font(.system(size: 20, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.emptyState.title")

                            Text(content.prompt)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(metrics.promptLineLimit)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.emptyState.prompt")
                        }

                        Button {
                            sendPrompt()
                        } label: {
                            Label {
                                Text("填入示例提示")
                            } icon: {
                                MinisIconView(.send, size: 14)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("chat.emptyState.sendPrompt")
                        .accessibilityHint("把一条示例提示填入输入框，确认后再发送")
                    }
                    .frame(maxWidth: min(420, metrics.contentWidth))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .id(content.identity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(content.accessibilityLabel)
                .accessibilityIdentifier(Self.accessibilityIdentifier)
            } else {
                Text("请选择一个会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("chat.emptyState.noSession")
            }
        }
        .frame(minWidth: 180)
    }
}
