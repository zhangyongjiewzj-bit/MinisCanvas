import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E7 会话侧栏增强（归档 / 搜索 / 统计 / 重命名 / 复制）

@Suite("E7 会话侧栏增强")
@MainActor
struct E7SessionSidebarTests {

    /// 临时目录：所有 SessionStore 落临时目录，不碰 Application Support。
    private func makeStore() -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E7SidebarTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionStore(directory: dir), dir)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("MOVE TO TRASH")
    }

    // MARK: 统计

    @Test func sessionListCarriesStatsAndOrder() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.appendUser("第一条")
        chat.appendAssistant("回复")
        chat.appendCanvasNotice("🟢 画布新增节点") // system 不计入消息数
        chat.newSession()
        chat.appendUser("新会话")

        let list = chat.sessionList
        #expect(list.count == 2)
        // 最近更新在前
        #expect(list.first?.session.id == chat.activeSessionID)
        // 消息数口径：不含 system（欢迎语 + 用户 + 回复 = 3）
        let first = list.first { $0.session.id == firstID }
        #expect(first?.messageCount == 3)
        #expect(first?.lastActivityAt == first?.session.updatedAt)
        // 时间排序：新会话（刚 append）应排在第一个
        #expect(list[0].session.id == chat.activeSessionID)
    }

    // MARK: 搜索

    @Test func searchFiltersByTitleAndPreview() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.appendUser("闪电五连鞭教程")
        chat.newSession()
        chat.appendUser("量子纠缠入门")

        chat.searchText = "闪电"
        #expect(chat.sessionList.count == 1)
        #expect(chat.sessionList.first?.session.id == firstID)

        // 按预览（消息内容）匹配
        chat.searchText = "量子"
        #expect(chat.sessionList.count == 1)
        #expect(chat.sessionList.first?.session.id != firstID)

        // 无匹配
        chat.searchText = "不存在的会话"
        #expect(chat.sessionList.isEmpty)

        // 清空恢复全部
        chat.searchText = ""
        #expect(chat.sessionList.count == 2)
    }

    // MARK: 重命名 / 复制（fork）

    @Test func renameSessionUpdatesTitleOnly() {
        let chat = ChatStore()
        let id = chat.activeSessionID!
        let updatedAt = chat.sessions[0].updatedAt

        chat.renameSession(id: id, title: "  新的名字  ")
        #expect(chat.sessions[0].title == "新的名字")
        #expect(chat.sessions[0].updatedAt == updatedAt) // 不刷新时间，避免列表跳动

        // 空标题忽略
        chat.renameSession(id: id, title: "   ")
        #expect(chat.sessions[0].title == "新的名字")
    }

    @Test func duplicateSessionForksMessagesAndSwitches() {
        let chat = ChatStore()
        let sourceID = chat.activeSessionID!
        chat.appendUser("原始问题")
        chat.appendAssistant("原始回答")

        let copyID = chat.duplicateSession(id: sourceID)!
        #expect(copyID != sourceID)
        #expect(chat.activeSessionID == copyID)
        #expect(chat.sessions.count == 2)
        let copy = chat.sessions.first { $0.id == copyID }
        #expect(copy?.title == chat.sessions[0].title + "（副本）")
        #expect(copy?.messages.count == chat.sessions[0].messages.count)
        #expect(copy?.messages.map(\.content) == chat.sessions[0].messages.map(\.content))

        // 复制不破坏源会话
        chat.switchSession(id: sourceID)
        #expect(chat.messages.contains { $0.content == "原始回答" })

        // 不存在的会话返回 nil
        #expect(chat.duplicateSession(id: UUID()) == nil)
    }

    /// S-04：编辑带附件的旧消息后“从这里分叉到新会话”，附件跟着草稿进新会话的输入框。
    @Test func editForkCarriesTheEditedMessageAttachmentsIntoTheNewSession() throws {
        let chat = ChatStore()
        let sourceID = try #require(chat.activeSessionID)
        let attachment = ChatAttachment(kind: .image, fileName: "设计稿.png", fileType: .image,
                                        mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        chat.appendUser("看这张图", attachments: [attachment])
        chat.appendAssistant("好的")
        let messageID = try #require(chat.messages.first { $0.role == .user }?.id)
        chat.beginEdit(messageID: messageID)
        #expect(chat.pendingAttachments.count == 1)
        chat.draftText = "改过的问题"

        let forkID = try #require(chat.forkFromEditedMessage())
        #expect(forkID != sourceID)
        #expect(chat.activeSessionID == forkID)
        #expect(chat.draftText == "改过的问题")
        #expect(chat.pendingAttachments.map(\.id) == [attachment.id])
    }

    // MARK: 归档 / 恢复（内存态，未装配持久化）

    @Test func archiveAndRestoreInMemory() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID!
        chat.appendUser("要归档的内容")
        chat.newSession()
        let secondID = chat.activeSessionID!

        // 归档第一个
        chat.archiveSession(id: firstID)
        #expect(chat.sessions.count == 1)
        #expect(chat.sessions.first?.id == secondID)
        #expect(chat.archivedList.count == 1)
        #expect(chat.archivedList.first?.session.id == firstID)
        #expect(chat.activeSessionID == secondID) // 自动切到剩余会话

        // 归档当前会话 → 允许归到 0
        chat.archiveSession(id: secondID)
        #expect(chat.sessions.isEmpty)
        #expect(chat.archivedList.count == 2)
        #expect(chat.activeSessionID == nil)

        // 恢复最近归档的
        chat.restoreSession(id: firstID)
        #expect(chat.archivedList.count == 1)
        #expect(chat.sessions.count == 1)
        #expect(chat.activeSessionID == firstID)
        #expect(chat.messages.contains { $0.content == "要归档的内容" })
    }

    // MARK: 归档 / 恢复（持久化态：磁盘文件随 _archive 目录移动）

    @Test func archivePersistsToDiskAndReloads() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let id = chat.activeSessionID!
        chat.appendUser("持久化归档测试")
        chat.appendAssistant("归档回复")

        // 磁盘归档：文件从 sessions 目录移到 _archive
        chat.archiveSession(id: id)
        #expect(chat.sessionManager != nil)
        let manager = chat.sessionManager!
        #expect(!store.listSessions().contains { $0.id == id.uuidString })
        let archivedFile = manager.archiveDirectory.appendingPathComponent("\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: archivedFile.path))

        // 重新装配：归档会话从磁盘恢复进归档分组（初始欢迎会话仍在内存）
        let chat2 = ChatStore()
        chat2.attachPersistence(store)
        #expect(chat2.sessions.count == 1)
        #expect(chat2.archivedList.count == 1)
        #expect(chat2.archivedList.first?.session.id == id)

        // 恢复：文件移回 sessions 目录，UI 回活动列表
        chat2.restoreSession(id: id)
        #expect(chat2.sessions.count == 2)
        #expect(chat2.archivedList.isEmpty)
        #expect(store.listSessions().contains { $0.id == id.uuidString })
        #expect(!FileManager.default.fileExists(atPath: archivedFile.path))
        #expect(chat2.messages.contains { $0.content == "持久化归档测试" })
    }

    @Test func deleteArchivedRemovesDiskFile() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let id = chat.activeSessionID!
        chat.appendUser("待删除归档")
        chat.archiveSession(id: id)

        let manager = chat.sessionManager!
        let archivedFile = manager.archiveDirectory.appendingPathComponent("\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: archivedFile.path))

        let originalPayload = try Data(contentsOf: archivedFile)
        let intent = try chat.previewDeletion(id: id, archived: true)
        let receipt = try chat.deleteArchivedSession(id: id, intent: confirmed(intent))
        #expect(chat.archivedList.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: archivedFile.path))

        // 再次删除（已不存在）静默忽略
        chat.deleteArchivedSession(id: id)
        #expect(chat.archivedList.isEmpty)
        let trashDirectory = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let payloadName = "\(receipt.operationID.uuidString).json"
        let indexName = ".trash-receipt-\(receipt.operationID.uuidString).json"
        let entries = try FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
        #expect(Set(entries.map(\.lastPathComponent)) == [payloadName, indexName])
        #expect(try Data(contentsOf: trashDirectory.appendingPathComponent(payloadName)) == originalPayload)
        let index = try JSONDecoder().decode(SessionDeletionService.TrashEntry.self,
            from: Data(contentsOf: trashDirectory.appendingPathComponent(indexName)))
        #expect(index.receipt == receipt)
    }

    @Test func deletingChatSessionMovesTheOrphanToTrash() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let deletedID = try #require(chat.activeSessionID)
        chat.appendUser("会被删除的会话")
        chat.newSession()

        let originalPayload = try Data(contentsOf: store.sessionsDirectory.appendingPathComponent("\(deletedID.uuidString).json"))
        let intent = try chat.previewDeletion(id: deletedID)
        let receipt = try chat.deleteSession(id: deletedID, intent: confirmed(intent))

        #expect(store.loadSession(id: deletedID.uuidString) == nil)
        let trashDirectory = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let payloadName = "\(receipt.operationID.uuidString).json"
        let indexName = ".trash-receipt-\(receipt.operationID.uuidString).json"
        let entries = try FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
        #expect(Set(entries.map(\.lastPathComponent)) == [payloadName, indexName])
        #expect(try Data(contentsOf: trashDirectory.appendingPathComponent(payloadName)) == originalPayload)
        let index = try JSONDecoder().decode(SessionDeletionService.TrashEntry.self,
            from: Data(contentsOf: trashDirectory.appendingPathComponent(indexName)))
        #expect(index.receipt == receipt)
    }

    @Test func deletingActiveChatSessionUsesGateBeforeMemoryMutation() throws {
        let (store, _) = makeStore()
        let chat = ChatStore()
        chat.attachPersistence(store)
        let deletedID = try #require(chat.activeSessionID)
        chat.appendUser("活动会话 gate 删除")
        chat.newSession()

        let originalPayload = try Data(contentsOf: store.sessionsDirectory.appendingPathComponent("\(deletedID.uuidString).json"))
        let intent = try chat.previewDeletion(id: deletedID)
        let receipt = try chat.deleteSession(id: deletedID, intent: confirmed(intent))

        #expect(chat.sessions.contains { $0.id == deletedID } == false)
        #expect(store.loadSession(id: deletedID.uuidString) == nil)
        let trashDirectory = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let payloadName = "\(receipt.operationID.uuidString).json"
        let indexName = ".trash-receipt-\(receipt.operationID.uuidString).json"
        let entries = try FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
        #expect(Set(entries.map(\.lastPathComponent)) == [payloadName, indexName])
        #expect(try Data(contentsOf: trashDirectory.appendingPathComponent(payloadName)) == originalPayload)
        let index = try JSONDecoder().decode(SessionDeletionService.TrashEntry.self,
            from: Data(contentsOf: trashDirectory.appendingPathComponent(indexName)))
        #expect(index.receipt == receipt)
    }
}
