import Foundation
import Testing
@testable import MinisCanvasApp

/// A reference record is shared by the escaping product callback and the
/// post-call assertion. Reading its snapshot through a separate function
/// avoids folding a captured local Optional into its initial nil value in
/// optimized, cross-module consumer builds.
@MainActor
private final class ChatEmptyPromptRecorder {
    private var prompts: [String] = []

    @inline(never)
    func receive(_ prompt: String) {
        prompts.append(prompt)
    }

    @inline(never)
    func snapshot() -> [String] {
        prompts
    }
}

@Suite("聊天正文空状态")
struct ChatEmptyStateViewTests {
    @Test("空 session 显示开始对话状态和发送提示")
    @MainActor
    func emptySessionContent() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
        let content = ChatEmptyStateView.content(for: sessionID)

        #expect(content.title == "开始新的对话")
        #expect(content.prompt == "输入消息开始与 Minis 助手协作")
        #expect(content.sessionID == sessionID)
    }

    @Test("发送提示回调使用稳定的示例提示")
    @MainActor
    func sendsPrompt() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
        let recorder = ChatEmptyPromptRecorder()
        let view = ChatEmptyStateView(sessionID: sessionID, onSendPrompt: { prompt in
            recorder.receive(prompt)
        })

        view.sendPrompt()

        let sentPrompts = recorder.snapshot()
        #expect(sentPrompts.count == 1)
        #expect(sentPrompts == ["你好，帮我开始一个新任务"])
    }

    @Test("session identity 和 AX label 不随渲染重排")
    @MainActor
    func stableIdentityAndAccessibility() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
        let content = ChatEmptyStateView.content(for: sessionID)

        #expect(content.identity == "chat.emptyState.\(sessionID.uuidString)")
        #expect(content.accessibilityLabel == "空会话")
        #expect(ChatEmptyStateView.accessibilityIdentifier == "chat.emptyState")
    }

    @Test("窄窗仍保留固定内容宽度和垂直布局")
    @MainActor
    func narrowWindowLayoutIsStable() {
        let metrics = ChatEmptyStateView.layoutMetrics(for: 180)

        #expect(metrics.minimumWidth == 180)
        #expect(metrics.contentWidth == 148)
        #expect(metrics.usesVerticalStack)
        #expect(metrics.promptLineLimit == 2)
    }
}
