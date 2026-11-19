import Testing
import Foundation
import AppKit
@testable import MinisCanvasApp

// MARK: - AJ-24 可滚动输入框：回车发送 / ⌥⏎ 换行 / 发送可用性 / 拖放附件
//
// 背景：原输入框 TextField(axis:.vertical) + .lineLimit(1...4) 超过 4 行不产生滚动视图，
// 只能方向键挪光标（用户反馈：内容多时鼠标无法滚动）。改用可滚动 NSTextView 桥接。
// 换控件是高风险改动，测试先行钉死四条行为：回车发送、⌥⏎ 换行、发送可用性、拖放附件。

// MARK: - 纯逻辑：回车键行为判定（可单测，不依赖真实 NSTextView）

@Suite("AJ-24 回车键行为：发送 vs 换行")
@MainActor
struct AJ24ComposerReturnTests {

    /// 普通回车 → 发送（不插入换行）
    @Test func plainReturnSends() {
        #expect(ComposerReturnBinding.shouldSendOnReturn(optionKey: false) == true)
    }

    /// ⌥⏎（Option+回车）→ 换行（不发送）
    @Test func optionReturnInsertsNewline() {
        #expect(ComposerReturnBinding.shouldSendOnReturn(optionKey: true) == false)
    }

    /// 发送可用性判定（GlobalComposer.canSend 委托，保持原语义）
    @Test func canSendRetained() {
        #expect(!GlobalComposer.canSend(draftText: "", pendingAttachmentCount: 0))
        // 纯空白不可发（与视图原实现同语义：trim .whitespaces）
        #expect(!GlobalComposer.canSend(draftText: "    ", pendingAttachmentCount: 0))
        #expect(GlobalComposer.canSend(draftText: "建节点 llm", pendingAttachmentCount: 0))
        // 换行视为可编辑内容（原行为保留，不做行为变更）
        #expect(GlobalComposer.canSend(draftText: "多行\n文本", pendingAttachmentCount: 0))
        #expect(GlobalComposer.canSend(draftText: "", pendingAttachmentCount: 1))
        #expect(GlobalComposer.canSend(draftText: "带附件", pendingAttachmentCount: 2))
    }

    /// 可滚动固定高度：maxLines 越大高度越高，超量内容由滚动条承载
    @Test func scrollHeightForMaxLines() {
        let font = NSFont.systemFont(ofSize: 13)
        let h4 = ScrollableComposerTextView.height(for: font, maxLines: 4)
        let h1 = ScrollableComposerTextView.height(for: font, maxLines: 1)
        #expect(h4 > h1)
        #expect(h4 > 0)
        #expect(h1 > 0)
    }
}

// MARK: - 拖放附件：容器 dropDestination 仍走 addAttachments 原链路

@Suite("AJ-24 拖放附件保留")
@MainActor
struct AJ24ComposerDragDropTests {

    /// 构造临时文件（自包含，不依赖 E11 私有 helper）
    private func makeTempFile(name: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aj24-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test func dropDestinationStillAddsAttachment() throws {
        let chat = ChatStore()
        let txtURL = try makeTempFile(name: "drop.txt", content: "dropped")
        defer { try? FileManager.default.removeItem(at: txtURL.deletingLastPathComponent()) }

        // 等价于输入区容器 .dropDestination 的拖放回调：chat.addAttachments(urls:)
        chat.addAttachments(urls: [txtURL])
        #expect(chat.pendingAttachments.isEmpty == false)
        #expect(chat.pendingAttachments.first?.fileName == "drop.txt")
    }

    @Test func dropDestinationWithAttachmentEnablesSend() throws {
        let chat = ChatStore()
        let txtURL = try makeTempFile(name: "note.md", content: "# 标题")
        defer { try? FileManager.default.removeItem(at: txtURL.deletingLastPathComponent()) }

        chat.draftText = "" // 无文本
        chat.addAttachments(urls: [txtURL])
        // 仅附件（无文本）也可发送：canSend 判定保持
        #expect(GlobalComposer.canSend(draftText: chat.draftText,
                                       pendingAttachmentCount: chat.pendingAttachments.count) == true)
    }
}

@Suite("Shift+Return newline")
struct ComposerShiftReturnRoutingTests {
    @Test func shiftReturnRoutesLikeOptionReturn() {
        let selector = NSSelectorFromString("insertNewline:")
        #expect(ComposerNativeKeyRouting.key(for: selector, modifierFlags: [.shift]) == .returnKey(option: true))
        #expect(ComposerNativeKeyRouting.key(for: selector, modifierFlags: [.option]) == .returnKey(option: true))
        #expect(ComposerNativeKeyRouting.key(for: selector, modifierFlags: []) == .returnKey(option: false))
    }
}
