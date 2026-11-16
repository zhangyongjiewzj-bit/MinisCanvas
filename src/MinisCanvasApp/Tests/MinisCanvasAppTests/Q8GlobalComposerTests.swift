import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - Q8-r5（Q8-r4 P2-3）：全局输入框快捷键标注与注册一致性 + 发送可用性
//
// Q8-r4 原始问题：help 文案宣称 ⌘⏎/⌘. 但按钮未注册 keyboardShortcut（标注漂移）。
// 修复：GlobalComposer 提取 sendShortcutDisplay / stopShortcutDisplay 常量作为
// 单一事实来源，GlobalComposerView 的 .keyboardShortcut 注册与 .help 标注共用，
// 结构性杜绝再次漂移。本套件钉死常量值与 canSend 纯函数行为。

@Suite("Q8 全局输入框：快捷键一致性 + 发送可用性")
struct Q8GlobalComposerTests {

    // MARK: 快捷键标注（单一事实来源）

    @Test func shortcutDisplayConstantsMatchRegisteredBindings() {
        // 与 GlobalComposerView 中实际注册一致：
        // 发送按钮 .keyboardShortcut(.return, modifiers: .command) → ⌘⏎
        // 停止按钮 .keyboardShortcut(".", modifiers: .command) → ⌘.
        #expect(GlobalComposer.sendShortcutDisplay == "⌘⏎")
        #expect(GlobalComposer.stopShortcutDisplay == "⌘.")
        // 标注不得为空或含占位残留
        #expect(!GlobalComposer.sendShortcutDisplay.isEmpty)
        #expect(!GlobalComposer.stopShortcutDisplay.isEmpty)
    }

    // MARK: canSend 纯函数（GlobalComposerView.canSend 委托于此）

    @Test func canSendRequiresTextOrAttachment() {
        #expect(!GlobalComposer.canSend(draftText: "", pendingAttachmentCount: 0))
        // Match the production submission boundary: whitespace-only text,
        // including newlines, is not a payload without a ready attachment.
        #expect(!GlobalComposer.canSend(draftText: "    ", pendingAttachmentCount: 0))
        #expect(GlobalComposer.canSend(draftText: "建节点 llm", pendingAttachmentCount: 0))
        #expect(GlobalComposer.canSend(draftText: "", pendingAttachmentCount: 1))
        #expect(GlobalComposer.canSend(draftText: "带附件", pendingAttachmentCount: 2))
    }

    @Test(arguments: ["", "    ", "\t", "\n", "\r\n", " \t\n \n\t ",
                      "\u{00A0}", "\u{2003}", " \u{00A0}\n\u{2003} "])
    func whitespaceOnlyTextCannotEnableSend378(_ draft: String) {
        #expect(!GlobalComposer.canSend(draftText: draft, pendingAttachmentCount: 0))
    }

    @Test(arguments: ["你好", " \t你好\n", "第一行\n第二行", " \n/commands\t ",
                      "\u{2003}\u{00A0}你好"])
    func actualTextIncludingMultilineRemainsSendable378(_ draft: String) {
        #expect(GlobalComposer.canSend(draftText: draft, pendingAttachmentCount: 0))
    }

    @Test func readyAttachmentsAndPastedTextKeepTheirExistingReadinessGate378() {
        #expect(GlobalComposer.canSend(draftText: "\n", pendingAttachmentCount: 1))
        #expect(GlobalComposer.canSend(
            draftText: "\u{00A0}\u{2003}", pendingAttachmentCount: 1
        ))
        #expect(GlobalComposer.canSend(
            draftText: " \t\n ", pendingAttachmentCount: 0, hasPastedText: true
        ))
        #expect(!GlobalComposer.canSend(
            draftText: "带附件", pendingAttachmentCount: 1, attachmentsReady: false
        ))
        #expect(!GlobalComposer.canSend(
            draftText: "\u{00A0}\u{2003}", pendingAttachmentCount: 1, attachmentsReady: false
        ))
        #expect(!GlobalComposer.canSend(
            draftText: "\n", pendingAttachmentCount: 0,
            hasPastedText: true, attachmentsReady: false
        ))
    }
}
