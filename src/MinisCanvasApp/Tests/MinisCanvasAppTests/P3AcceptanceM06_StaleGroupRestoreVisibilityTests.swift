import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("P3-SESSION-08 分组变更后会话仍可见")
@MainActor
struct P3AcceptanceM06_StaleGroupRestoreVisibilityTests {
    @Test("归档期间删除所属组，恢复后会话及消息仍在侧栏并跨重挂载存活")
    func archivedMemberReturnsUngroupedAfterItsGroupIsDeleted() throws {
        let identifier = "P3AcceptanceM06.StaleGroupRestore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)

        let first = ChatStore(preferencesDefaults: defaults)
        #expect(first.attachPersistence(store))
        let sessionID = try #require(first.activeSessionID)
        first.appendUser("归档前保留的内容")
        let group = try #require(first.createGroup(named: "暂存组"))
        first.moveSession(sessionID, toGroup: group.id)
        first.archiveSession(id: sessionID)
        #expect(first.archivedList.contains { $0.session.id == sessionID })

        first.deleteGroup(id: group.id)
        let reopened = ChatStore(preferencesDefaults: defaults)
        #expect(reopened.attachPersistence(store))
        #expect(!reopened.groups.contains { $0.id == group.id })
        reopened.restoreSession(id: sessionID)

        let restored = try #require(reopened.sessions.first { $0.id == sessionID })
        #expect(restored.groupID == nil)
        #expect(restored.messages.contains { $0.content == "归档前保留的内容" })
        #expect(reopened.sessionGroups.flatMap(\.items).filter { $0.session.id == sessionID }.count == 1)

        let remounted = ChatStore(preferencesDefaults: defaults)
        #expect(remounted.attachPersistence(store))
        #expect(try #require(remounted.sessions.first { $0.id == sessionID }).groupID == nil)
        #expect(remounted.sessionGroups.flatMap(\.items).filter { $0.session.id == sessionID }.count == 1)
    }

    @Test("迟到的已删除组动作无效，现存组移动仍生效")
    func staleGroupMoveCannotHideAnActiveSession() throws {
        let identifier = "P3AcceptanceM06.StaleGroupMove.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        let chat = ChatStore(preferencesDefaults: defaults)
        let sessionID = try #require(chat.activeSessionID)
        let oldGroup = try #require(chat.createGroup(named: "旧组"))
        let currentGroup = try #require(chat.createGroup(named: "现存组"))
        chat.moveSession(sessionID, toGroup: currentGroup.id)
        chat.deleteGroup(id: oldGroup.id)

        chat.moveSession(sessionID, toGroup: oldGroup.id)
        #expect(try #require(chat.sessions.first { $0.id == sessionID }).groupID == currentGroup.id)
        #expect(chat.sessionGroups.flatMap(\.items).filter { $0.session.id == sessionID }.count == 1)

        chat.moveSession(sessionID, toGroup: nil)
        #expect(try #require(chat.sessions.first { $0.id == sessionID }).groupID == nil)
        chat.moveSession(sessionID, toGroup: currentGroup.id)
        #expect(try #require(chat.sessions.first { $0.id == sessionID }).groupID == currentGroup.id)
        chat.archiveSession(id: sessionID)
        chat.restoreSession(id: sessionID)
        #expect(try #require(chat.sessions.first { $0.id == sessionID }).groupID == currentGroup.id)
    }
}
