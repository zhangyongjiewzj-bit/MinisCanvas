import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-59 对话自定义组（真实组实体）
//
// 背景：此前侧栏「组」仅是按项目 ID 动态聚合的展示（AJ-30），用户无法新建组。
// AJ-59 引入真实组实体 ChatGroup（可新建/重命名/删除），会话可移动到任意组，
// 空组保留显示；组目录 UserDefaults 持久化，会话归属经 groupID 随磁盘会话落盘。

@Suite("AJ-59 对话自定义组", .serialized)
@MainActor
struct AJ59ChatGroupTests {

    /// Each case owns a disposable preferences suite; no standard-domain key
    /// is read, removed, or overwritten by a group test.
    private func freshChat() -> (chat: ChatStore, cleanup: () -> Void) {
        let suiteName = "com.miniscanvas.test.chat-groups.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Synthetic chat group preferences suite unavailable")
        }
        let chat = ChatStore(preferencesDefaults: defaults)
        chat.loadGroups()
        return (chat, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: 组目录 CRUD

    @Test func createGroupRejectsEmptyName() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        #expect(chat.createGroup(named: "   ") == nil)
        #expect(chat.createGroup(named: "") == nil)
        #expect(chat.groups.isEmpty)
    }

    @Test func createGroupAppendsTrimmedName() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "  工作  ")
        #expect(g != nil)
        #expect(chat.groups.count == 1)
        #expect(chat.groups.first?.name == "工作")
    }

    @Test func renameGroupUpdatesNameAndIgnoresEmpty() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "旧名")!
        chat.renameGroup(id: g.id, to: "  新名 ")
        #expect(chat.groups.first?.name == "新名")
        chat.renameGroup(id: g.id, to: "  ")
        #expect(chat.groups.first?.name == "新名")
    }

    @Test func deleteGroupClearsMemberSessions() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "临时")!
        let sessionID = chat.sessions[0].id
        chat.moveSession(sessionID, toGroup: g.id)
        #expect(chat.sessions[0].groupID == g.id)
        chat.deleteGroup(id: g.id)
        #expect(chat.groups.isEmpty)
        #expect(chat.sessions[0].groupID == nil)
    }

    // MARK: 会话归属

    @Test func moveSessionToGroupAndBack() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "工作")!
        let sessionID = chat.sessions[0].id
        chat.moveSession(sessionID, toGroup: g.id)
        #expect(chat.sessions[0].groupID == g.id)
        chat.moveSession(sessionID, toGroup: nil)
        #expect(chat.sessions[0].groupID == nil)
    }

    // MARK: 侧栏分组聚合

    @Test func emptyGroupStillAppearsInSidebar() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "空组")!
        // 无任何会话归组 → 组仍在侧栏（真实实体），且成员为空。
        // 注：不断言总组数——测试环境可能残留带项目归属的会话（项目分组）。
        let groups = chat.sessionGroups
        let custom = groups.first { $0.kind == .custom(g.id) }
        #expect(custom != nil)
        #expect(custom?.items.isEmpty == true)
        #expect(custom?.isCustomGroup == true)
    }

    @Test func customGroupsPrecedeProjectGroups() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "工作")!

        // 会话 A → 自定义组；会话 B → 项目 P；会话 C → 无归属
        let a = chat.sessions[0].id
        chat.newSession()
        let b = chat.sessions[1].id
        chat.newSession()
        let c = chat.sessions[2].id

        chat.moveSession(a, toGroup: g.id)
        chat.setProject(ChatStore.SessionProject(id: "P", name: "项目P", workingDirectory: "/p"), forSession: b)

        let groups = chat.sessionGroups
        #expect(groups.count == 3)
        // 1. 自定义组（含会话 A）
        #expect(groups[0].kind == .custom(g.id))
        #expect(groups[0].items.map(\.session.id) == [a])
        // 2. 项目分组（仅未归自定义组的会话 → 含 B）
        #expect(groups[1].kind == .project("P"))
        #expect(groups[1].items.map(\.session.id) == [b])
        // 3. 未归属项目（含 C）
        #expect(groups[2].kind == .project(nil))
        #expect(groups[2].items.map(\.session.id) == [c])
    }

    @Test func projectSessionMovesIntoCustomGroup() {
        let fixture = freshChat()
        defer { fixture.cleanup() }
        let chat = fixture.chat
        let g = chat.createGroup(named: "工作")!
        let sessionID = chat.sessions[0].id
        chat.setProject(ChatStore.SessionProject(id: "P", name: "项目P", workingDirectory: "/p"), forSession: sessionID)

        // 归组前：自定义组（空，保留显示）+ 项目分组
        #expect(chat.sessionGroups.count == 2)
        #expect(chat.sessionGroups[0].kind == .custom(g.id))
        #expect(chat.sessionGroups[1].kind == .project("P"))

        // 归组后：项目分组消失（无剩余会话），自定义组收纳
        chat.moveSession(sessionID, toGroup: g.id)
        let groups = chat.sessionGroups
        #expect(groups.count == 1)
        #expect(groups[0].kind == .custom(g.id))
        #expect(groups[0].items.map(\.session.id) == [sessionID])
    }

    // MARK: 持久化兼容

    @Test func chatThreadCodableRoundTripsGroupID() throws {
        let session = ChatThread(title: "带组会话", groupID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatThread.self, from: data)
        #expect(decoded.groupID == session.groupID)
        #expect(decoded.title == "带组会话")
    }

    @Test func chatThreadDecodesLegacyJSONWithoutGroupID() throws {
        // 旧持久化 JSON：无 groupID / pinned / unread 键 → 按 nil/false 解码
        let legacy = """
        {"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","title":"旧会话",
         "createdAt":0,"updatedAt":0,"messages":[],"projectID":"P","projectName":"旧项目","workingDirectory":"/p"}
        """
        let decoded = try JSONDecoder().decode(ChatThread.self, from: Data(legacy.utf8))
        #expect(decoded.groupID == nil)
        #expect(decoded.pinned == false)
        #expect(decoded.projectID == "P")
    }

    @Test func persistedChatSessionRoundTripsGroupID() throws {
        let persisted = MinisCore.ChatSession(
            id: "s1", title: "t",
            projectID: "P", projectName: "项目", workingDirectory: "/p",
            groupID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        )
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(MinisCore.ChatSession.self, from: data)
        #expect(decoded.groupID == "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
        // UI 转换链：asThread 还原 UUID
        let thread = decoded.asThread()
        #expect(thread.groupID == UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
    }

    @Test func persistedChatSessionDecodesLegacyJSONWithoutGroupID() throws {
        let legacy = """
        {"id":"s2","title":"旧","createdAt":0,"updatedAt":0,"messages":[],
         "projectID":"P","projectName":"旧项目","workingDirectory":"/p"}
        """
        let decoded = try JSONDecoder().decode(MinisCore.ChatSession.self, from: Data(legacy.utf8))
        #expect(decoded.groupID == nil)
        #expect(decoded.workingDirectory == "/p")
    }
}
