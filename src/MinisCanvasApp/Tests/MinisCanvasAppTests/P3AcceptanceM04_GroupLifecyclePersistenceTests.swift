import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("P3-SESSION-01 自定义会话组重挂载")
@MainActor
struct P3AcceptanceM04_GroupLifecyclePersistenceTests {
    @Test("两个成员随组名跨重挂载存活，删组后成员回到未分组")
    func twoMembersSurviveRenameAndReturnUngroupedAfterDeletion() throws {
        let identifier = "P3AcceptanceM04.GroupLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)

        let first = ChatStore(preferencesDefaults: defaults)
        #expect(first.attachPersistence(store))
        let firstID = try #require(first.activeSessionID)
        first.appendUser("第一会话内容")
        first.newSession()
        let secondID = try #require(first.activeSessionID)
        first.appendUser("第二会话内容")
        #expect(firstID != secondID)

        let group = try #require(first.createGroup(named: "工作组"))
        first.moveSession(firstID, toGroup: group.id)
        first.moveSession(secondID, toGroup: group.id)
        first.renameGroup(id: group.id, to: "已改名工作组")

        let reopened = ChatStore(preferencesDefaults: defaults)
        #expect(reopened.attachPersistence(store))
        #expect(reopened.groups.first(where: { $0.id == group.id })?.name == "已改名工作组")
        #expect(try #require(reopened.sessions.first(where: { $0.id == firstID })).groupID == group.id)
        #expect(try #require(reopened.sessions.first(where: { $0.id == secondID })).groupID == group.id)
        let grouped = try #require(reopened.sessionGroups.first(where: { $0.kind == .custom(group.id) }))
        #expect(Set(grouped.items.map(\.session.id)) == Set([firstID, secondID]))

        reopened.deleteGroup(id: group.id)
        let afterDeletion = ChatStore(preferencesDefaults: defaults)
        #expect(afterDeletion.attachPersistence(store))
        #expect(!afterDeletion.groups.contains(where: { $0.id == group.id }))
        #expect(try #require(afterDeletion.sessions.first(where: { $0.id == firstID })).groupID == nil)
        #expect(try #require(afterDeletion.sessions.first(where: { $0.id == secondID })).groupID == nil)
        let ungrouped = try #require(afterDeletion.sessionGroups.first(where: { $0.kind == .project(nil) }))
        #expect(Set(ungrouped.items.map(\.session.id)).isSuperset(of: [firstID, secondID]))
    }
}
