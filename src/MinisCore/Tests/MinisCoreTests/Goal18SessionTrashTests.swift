import Foundation
import Testing
@testable import MinisCore

@Suite("Goal18 thirty-day native session trash")
struct Goal18SessionTrashTests {
    @Test func nativeReceiptSurvivesRestartAndRestoresOriginalPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Trash-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: root))
        let service = SessionDeletionService(manager: manager)
        let session = try store.createSession(title: "待撤销会话")
        try store.saveMessage(LLMMessage(role: .user, content: "原消息"), sessionID: session.id)
        let before = try Data(contentsOf: store.sessionsDirectory.appendingPathComponent(session.id + ".json"))
        let now = Date()
        let intent = try service.preview(sessionID: session.id)
            .withFirstConfirmation("我已核对这份预览").withSecondConfirmation("移入回收站")
        let receipt = try service.delete(intent, now: now)
        #expect(store.loadSession(id: session.id) == nil)
        let reopened = SessionDeletionService(manager: SessionManager(store: SessionStore(directory: root), badgeStore: SessionBadgeStore(directory: root)))
        let entry = try #require(reopened.trashEntries(now: now.addingTimeInterval(29 * 86400)).first)
        #expect(entry.receipt == receipt)
        try reopened.restore(entry.receipt, now: now.addingTimeInterval(29 * 86400))
        #expect(try Data(contentsOf: store.sessionsDirectory.appendingPathComponent(session.id + ".json")) == before)
        #expect(try reopened.trashEntries(now: now.addingTimeInterval(29 * 86400)).isEmpty)
    }
    @Test func exactThirtyDayBoundaryPurgesOnlyIndexedMatchingPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Goal18Trash-" + UUID().uuidString).resolvingSymlinksInPath()
        try #require(root.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: root))
        let service = SessionDeletionService(manager: manager)
        let target = try store.createSession(title: "到期会话")
        let sibling = try store.createSession(title: "仍在用")
        let now = Date()
        let intent = try service.preview(sessionID: target.id)
            .withFirstConfirmation("我已核对这份预览").withSecondConfirmation("移入回收站")
        let receipt = try service.delete(intent, now: now)
        let unknown = store.sessionsDirectory.appendingPathComponent("_trash/legacy-unknown.json")
        try Data("legacy".utf8).write(to: unknown)
        #expect(try service.purgeExpiredTrash(now: now.addingTimeInterval(30 * 86400 - 1)) == 0)
        #expect(throws: SessionDeletionError.self) { try service.restore(receipt, now: now.addingTimeInterval(30 * 86400)) }
        #expect(try service.purgeExpiredTrash(now: now.addingTimeInterval(30 * 86400)) == 1)
        #expect(try Data(contentsOf: unknown) == Data("legacy".utf8))
        #expect(store.loadSession(id: sibling.id) != nil)
        #expect(try service.trashEntries(now: now.addingTimeInterval(30 * 86400)).isEmpty)
    }
}
