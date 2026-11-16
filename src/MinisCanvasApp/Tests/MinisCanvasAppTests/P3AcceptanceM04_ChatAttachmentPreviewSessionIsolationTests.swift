import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("S02 / D-COMPOSER-07 聊天附件预览归属")
@MainActor
struct P3AcceptanceM04_ChatAttachmentPreviewSessionIsolationTests {
    @Test("A 附件预览切到 B 后失效，返回 A 不自动恢复旧预览或改写草稿消息")
    func chatPreviewExpiresAcrossSessionSwitch() throws {
        let chat = ChatStore()
        let sessionA = try #require(chat.activeSessionID)
        chat.appendUser("A 的合成消息")
        chat.draftText = "A 的合成草稿"

        let syntheticRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("s02-\(UUID().uuidString)", isDirectory: true)
        let attachmentURL = syntheticRoot.appendingPathComponent("A-attachment.txt")
        var selection: ChatAttachmentPreviewSelection? = ChatAttachmentPreviewSelection(
            sessionID: sessionA,
            url: attachmentURL
        )
        #expect(selection?.visible(in: chat.activeSessionID)?.url == attachmentURL)
        let panel = ContextPanelView(
            chat: chat,
            canvas: nil,
            nodeContext: nil,
            onCollapse: {},
            attachmentPreviewSelection: selection
        )
        #expect(panel.visibleAttachmentPreview?.url == attachmentURL)

        let fileTree = FileTreeStore(rootURL: syntheticRoot)
        fileTree.selectAttachment(try #require(selection))
        #expect(fileTree.selectedURL == attachmentURL)

        let sessionB = chat.applyNewSession(title: "B")
        #expect(chat.activeSessionID == sessionB)
        #expect(chat.messages.isEmpty)
        #expect(chat.draftText.isEmpty)
        #expect(panel.visibleAttachmentPreview == nil)
        selection = selection?.visible(in: chat.activeSessionID)
        fileTree.clearChatAttachmentSelection()
        #expect(selection == nil)
        #expect(fileTree.selectedURL == nil)
        #expect(fileTree.preview.map { _ in true } == nil)

        chat.appendUser("B 的合成消息")
        chat.draftText = "B 的合成草稿"
        chat.switchSession(id: sessionA)
        #expect(selection?.visible(in: chat.activeSessionID) == nil)
        let returnedPanel = ContextPanelView(
            chat: chat,
            canvas: nil,
            nodeContext: nil,
            onCollapse: {},
            attachmentPreviewSelection: selection
        )
        #expect(returnedPanel.visibleAttachmentPreview == nil)
        #expect(fileTree.selectedURL == nil)
        #expect(chat.messages.contains { $0.content == "A 的合成消息" })
        #expect(!chat.messages.contains { $0.content == "B 的合成消息" })
        #expect(chat.draftText == "A 的合成草稿")

        chat.switchSession(id: sessionB)
        #expect(chat.messages.contains { $0.content == "B 的合成消息" })
        #expect(chat.draftText == "B 的合成草稿")
    }

    @Test("手动工作区文件即使 URL 与聊天附件相同，也不被聊天来源失效清除")
    func manualWorkspaceSelectionSurvivesChatPreviewExpiry() {
        let sessionA = UUID()
        let syntheticRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("s02-\(UUID().uuidString)", isDirectory: true)
        let sameURL = syntheticRoot.appendingPathComponent("workspace-file.txt")
        let fileTree = FileTreeStore(rootURL: syntheticRoot)
        let attachment = ChatAttachmentPreviewSelection(sessionID: sessionA, url: sameURL)

        fileTree.selectAttachment(attachment)
        #expect(fileTree.selectedURL == sameURL)
        fileTree.select(sameURL) // 用户从文件树手动选择同一文件，来源已经变成 workspace。
        fileTree.clearChatAttachmentSelection()
        #expect(fileTree.selectedURL == sameURL)

        let repeatedClick = ChatAttachmentPreviewSelection(sessionID: sessionA, url: sameURL)
        #expect(repeatedClick != attachment)
        fileTree.selectAttachment(repeatedClick)
        fileTree.clearChatAttachmentSelection()
        #expect(fileTree.selectedURL == nil)
    }
}
