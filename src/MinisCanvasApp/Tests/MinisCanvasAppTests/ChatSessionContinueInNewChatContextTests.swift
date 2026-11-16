import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - D-SESSION-12 「在新聊天中继续」保留必要上下文，不覆盖原会话
// D-SESSION-11 的兄弟补充：donor b18c2308（WP2SessionChildAppWiringTests）已钉住
// 源/子消息与附件在重开后的互不影响；本文件只补它未覆盖的必要上下文维度——
// 引用卡（session 围栏重绑）、草稿归属、兄弟会话独立，全部经真实持久化重开。

@Suite("D-SESSION-12 新聊天继续上下文")
@MainActor
struct ChatSessionContinueInNewChatContextTests {

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSESSION12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 「在新聊天中继续」= ChatStore.duplicateSession（ChatSidebarView 同一入口）。
    /// 合同：子会话携带源的全部必要上下文（正文、附件、引用卡材料），引用卡
    /// 重新围栏到子会话；源会话的草稿、标题、消息一字不改；重开后两侧依旧。
    @Test("continueInNewChat carries content attachments and reference card without touching the source")
    func continueInNewChatCarriesContextAndRefencesChild() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let sourceID = try #require(chat.activeSessionID)

        let material = " \n" + String(repeating: "上下文材料", count: 200) + "\n "
        let draft = PastedTextDraft(id: UUID(), text: material, source: .pasteboard, kind: .reference)
        let submission = PastedTextSubmissionSnapshot(
            capsuleID: draft.id, sessionID: sourceID, body: " 解释材料 ", pastedText: draft)
        let attachment = ChatAttachment(
            kind: .text, fileName: "context.md", fileType: .markdown,
            data: Data("附件全文".utf8))
        // Use the ordinary Composer submission, including the actual
        // attachment suffix producer, instead of appendUser's already-composed seam.
        chat.streamingProviderOverride = MockProvider()
        #expect(chat.setPastedTextDraft(draft))
        chat.draftText = " 解释材料 "
        chat.addComposerDraftAttachment(attachment)
        chat.sendDraft()
        let sent = try #require(chat.messages.first(where: { $0.role == .user }))
        let expectedContent = submission.fullText + "\n\n"
            + ChatStore.composeUserContent(text: "", attachments: [attachment])
        #expect(sent.content == expectedContent)
        let sentCard = try #require(sent.referenceCard)
        #expect(sentCard.material == material)
        #expect(sentCard.sessionID == sourceID)
        // Await the owned offline turn before duplicating its closed transcript.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while chat.isStreaming && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!chat.isStreaming)
        #expect(chat.messages.filter { $0.content != ChatStore.welcomeText }.count == 2)
        let sourceContent = sent.content
        chat.draftText = "源会话未发送草稿"
        let sourceUserMessageID = try #require(
            chat.messages.first(where: { $0.role == .user })).id
        let sourceTitle = try #require(
            chat.sessions.first(where: { $0.id == sourceID })?.title)

        // 「在新聊天中继续」
        let childID = try #require(chat.duplicateSession(id: sourceID))
        #expect(childID != sourceID)
        #expect(chat.activeSessionID == childID)

        // 必要上下文完整携带：正文、附件、引用卡材料
        let childUser = try #require(chat.messages.first(where: { $0.role == .user }))
        #expect(childUser.content == sourceContent)
        #expect(childUser.attachments == [attachment])
        #expect(childUser.referenceCard?.material == material)
        #expect(childUser.referenceCard?.instruction == "解释材料")
        // 引用卡按会话围栏：投影必须重绑到子会话，否则子会话内展开会被拒绝。
        #expect(childUser.referenceCard?.sessionID == childID)
        #expect(chat.setPastedTextReferenceExpanded(
            messageID: childUser.id, expanded: true, sessionID: childID))

        // 新 composer：子会话不携带源草稿；源草稿留在源键下。
        #expect(chat.draftText.isEmpty)
        chat.appendUser("子会话续写")

        // 切回源：未被继续动作覆盖——标题、消息、引用卡围栏、草稿全部原样。
        chat.switchSession(id: sourceID)
        #expect(chat.draftText == "源会话未发送草稿")
        let sourceUser = try #require(chat.messages.first(where: { $0.role == .user }))
        #expect(sourceUser.referenceCard?.sessionID == sourceID)
        #expect(sourceUser.id == sourceUserMessageID)
        #expect(chat.messages.filter { $0.content != ChatStore.welcomeText }.count == 2)
        #expect(chat.sessions.first(where: { $0.id == sourceID })?.title == sourceTitle)
        #expect(chat.sessions.first(where: { $0.id == childID })?.title
            .hasSuffix("（副本）") == true)
        #expect(!chat.messages.contains { $0.content == "子会话续写" })

        // 真实持久化重开：两侧在磁盘上就是两份独立 transcript，围栏各自保持。
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: root)))
        let restoredSource = try #require(
            reopened.sessions.first(where: { $0.id == sourceID }))
        let restoredChild = try #require(
            reopened.sessions.first(where: { $0.id == childID }))
        // 源 = 用户+回答；子 = 源上下文 + 子会话续写（首会话预置 .assistant 欢迎语不计）。
        #expect(restoredSource.messages.filter { $0.content != ChatStore.welcomeText }.count == 2)
        #expect(restoredChild.messages.filter { $0.content != ChatStore.welcomeText }.count == 3)
        let sourceCards = restoredSource.messages.compactMap(\.referenceCard)
        let childCards = restoredChild.messages.compactMap(\.referenceCard)
        #expect(sourceCards.count == 1)
        #expect(childCards.count == 1)
        #expect(sourceCards.allSatisfy { $0.sessionID == sourceID })
        #expect(childCards.allSatisfy { $0.sessionID == childID })
        #expect(restoredChild.messages.contains { $0.content == "子会话续写" })
        #expect(!restoredSource.messages.contains { $0.content == "子会话续写" })
        let restoredSourceUser = try #require(restoredSource.messages.first(where: { $0.role == .user }))
        let restoredChildUser = try #require(restoredChild.messages.first(where: { $0.role == .user }))
        #expect(restoredSourceUser.attachments == [attachment])
        #expect(restoredChildUser.attachments == [attachment])
        #expect(restoredSourceUser.content == expectedContent)
        #expect(restoredChildUser.content == expectedContent)
        let sourceCard = try #require(restoredSourceUser.referenceCard)
        let childCard = try #require(restoredChildUser.referenceCard)
        #expect(sourceCard.id == draft.id)
        #expect(childCard.id == draft.id)
        #expect(sourceCard.material == material)
        #expect(childCard.material == material)
        #expect(sourceCard.instruction == "解释材料")
        #expect(childCard.instruction == "解释材料")
        #expect(sourceCard.sessionID == sourceID)
        #expect(childCard.sessionID == childID)
        reopened.switchSession(id: childID)
        #expect(!reopened.setPastedTextReferenceExpanded(
            messageID: restoredChildUser.id, expanded: true, sessionID: sourceID))
        #expect(reopened.setPastedTextReferenceExpanded(
            messageID: restoredChildUser.id, expanded: true, sessionID: childID))
        let expandedChild = try #require(reopened.messages.first(where: { $0.id == restoredChildUser.id })?.referenceCard)
        #expect(expandedChild.renderedMaterial == material)
    }

    /// 同一源连续两次 fork：兄弟会话互不影响，且不改动源（SESSION-11 的兄弟维度）。
    @Test("two forks of one source stay independent from each other and the source")
    func siblingForksStayIndependent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let sourceID = try #require(chat.activeSessionID)
        chat.appendUser("共同历史")
        chat.appendAssistant("共同回答")

        let first = try #require(chat.duplicateSession(id: sourceID))
        chat.appendUser("只属于第一个副本")
        let second = try #require(chat.duplicateSession(id: sourceID))
        // 第二次 fork 从源复制：不得继承第一个副本的后续消息。
        #expect(second != first)
        #expect(chat.messages.filter { $0.content != ChatStore.welcomeText }.count == 2)
        chat.appendUser("只属于第二个副本")

        chat.switchSession(id: sourceID)
        #expect(chat.messages.filter { $0.content != ChatStore.welcomeText }.map(\.content)
            == ["共同历史", "共同回答"])
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: root)))
        let rFirst = try #require(reopened.sessions.first(where: { $0.id == first }))
        let rSecond = try #require(reopened.sessions.first(where: { $0.id == second }))
        #expect(rFirst.messages.contains { $0.content == "只属于第一个副本" })
        #expect(!rFirst.messages.contains { $0.content == "只属于第二个副本" })
        #expect(!rSecond.messages.contains { $0.content == "只属于第一个副本" })
        #expect(rSecond.messages.contains { $0.content == "只属于第二个副本" })
        let rSource = try #require(reopened.sessions.first(where: { $0.id == sourceID }))
        #expect(rSource.messages.filter { $0.content != ChatStore.welcomeText }.map(\.content)
            == ["共同历史", "共同回答"])
    }
}
