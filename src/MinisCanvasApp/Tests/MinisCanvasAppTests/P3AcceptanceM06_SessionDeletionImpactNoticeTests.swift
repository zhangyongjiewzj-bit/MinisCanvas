import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SESSION-15 deletion impact preview")
@MainActor
struct P3AcceptanceM06_SessionDeletionImpactNoticeTests {
    @Test("active and archived previews describe their distinct restore scopes")
    func noticeFollowsCanonicalLocationWithoutPromisingDraftRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSESSION15-impact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: root)))
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("合成已发送消息")
        chat.draftText = "尚未发送的草稿"

        let active = try chat.previewCurrentDeletion(id: targetID)
        #expect(!active.archived)
        #expect(active.intent.affectedCount == 1)
        #expect(active.intent.reversible)
        #expect(active.intent.scopeID == "session:\(targetID.uuidString):active")
        let activeNotice = SessionDeletionImpactNotice.ancillaryEffects(
            archived: active.archived, reversible: active.intent.reversible
        )
        #expect(activeNotice.contains("未发送草稿"))
        #expect(activeNotice.contains("待发附件"))
        #expect(activeNotice.contains("不随该回执恢复"))
        // FC-09 / C-05：如实披露后台命令会终止、工具输出文件保留到永久删除。
        #expect(activeNotice.contains("后台命令"))
        #expect(activeNotice.contains("工具输出文件保留"))

        chat.newSession()
        chat.archiveSession(id: targetID)
        let archived = try chat.previewCurrentDeletion(id: targetID)
        #expect(archived.archived)
        #expect(archived.intent.affectedCount == 1)
        #expect(archived.intent.reversible)
        #expect(archived.intent.scopeID == "session:\(targetID.uuidString):archive")
        let archivedNotice = SessionDeletionImpactNotice.ancillaryEffects(
            archived: archived.archived, reversible: archived.intent.reversible
        )
        #expect(archivedNotice.contains("回到归档区"))
        #expect(!archivedNotice.contains("草稿将被清除"))
    }

    @Test("unpersisted previews never promise a recoverable session file")
    func irreversiblePreviewDoesNotMentionRestore() throws {
        let chat = ChatStore()
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("合成未装配会话")
        chat.newSession()

        let preview = try chat.previewCurrentDeletion(id: targetID)
        #expect(!preview.archived)
        #expect(!preview.intent.reversible)
        let notice = SessionDeletionImpactNotice.ancillaryEffects(
            archived: preview.archived, reversible: preview.intent.reversible
        )
        #expect(notice.contains("不可恢复"))
        #expect(!notice.contains("回收站恢复"))

        chat.archiveSession(id: targetID)
        let archived = try chat.previewCurrentDeletion(id: targetID)
        #expect(archived.archived)
        #expect(!archived.intent.reversible)
        let archivedNotice = SessionDeletionImpactNotice.ancillaryEffects(
            archived: archived.archived, reversible: archived.intent.reversible
        )
        #expect(archivedNotice.contains("不可恢复"))
        #expect(!archivedNotice.contains("恢复后仍回到归档区"))
    }
}
