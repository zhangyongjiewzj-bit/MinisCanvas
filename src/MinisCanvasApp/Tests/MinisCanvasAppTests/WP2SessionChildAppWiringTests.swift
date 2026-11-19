import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("WP-2 App session and child wiring")
@MainActor
struct WP2SessionChildAppWiringTests {
    @Test
    func structuredSessionActionFreezesIdentityAndPublishesTaskReceipt() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let sourceSessionID = try #require(bridge.chat.activeSessionID)

        let observation = try bridge.performSessionAction(
            .new(
                title: "会话 A",
                projectID: "project-a",
                workingDirectory: "/tmp/project-a"
            )
        )

        #expect(observation.action.action == .new)
        #expect(observation.source.sessionID == sourceSessionID.uuidString)
        #expect(observation.source.taskID != observation.taskID)
        #expect(observation.receipt.sessionID == bridge.chat.activeSessionID?.uuidString)
        #expect(bridge.chat.sessions.last?.title == "会话 A")
        #expect(store.snapshot(taskID: observation.taskID, parentID: sourceSessionID.uuidString)?.status == .succeeded)
        #expect(store.allReceipts().contains { $0.runID == observation.runID })
        #expect(bridge.taskCenterObservation.taskSnapshots.contains { $0.taskID == observation.taskID })
    }

    @Test
    func structuredActionsKeepABSessionsSeparateAndForkIsObservable() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let sessionA = try #require(bridge.chat.activeSessionID)
        bridge.chat.appendUser("A 的消息")

        let newObservation = try bridge.performSessionAction(.new(title: "会话 B"))
        let sessionB = try #require(bridge.chat.activeSessionID)
        #expect(sessionB != sessionA)
        bridge.chat.appendUser("B 的消息")

        _ = try bridge.performSessionAction(.rename(sessionID: sessionB.uuidString, title: "会话 B 已改名"))
        _ = try bridge.performSessionAction(.switch(sessionID: sessionA.uuidString))
        #expect(bridge.chat.activeSessionID == sessionA)
        #expect(bridge.chat.messages.contains { $0.content == "A 的消息" })
        #expect(!bridge.chat.messages.contains { $0.content == "B 的消息" })

        let forkObservation = try bridge.performSessionAction(.fork(sessionID: sessionA.uuidString))
        let forkedID = try #require(bridge.chat.activeSessionID)
        #expect(forkedID != sessionA && forkedID != sessionB)
        #expect(bridge.chat.messages.contains { $0.content == "A 的消息" })
        #expect(forkObservation.receipt.action == .fork)
        #expect(store.taskCenterSnapshots().filter { $0.status == .succeeded }.count == 4)
        #expect(newObservation.receipt.action == .new)
    }

    @Test
    func productionForkPersistsSourceAndChildSeparatelyAcrossReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP2-fork-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionStore = MinisCore.SessionStore(directory: root)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        #expect(bridge.chat.attachPersistence(sessionStore))
        let sourceSessionID = try #require(bridge.chat.activeSessionID)
        let attachment = ChatAttachment(
            kind: .text,
            fileName: "fork.md",
            fileType: .markdown,
            data: Data("fork-owned".utf8)
        )
        let childAttachment = ChatAttachment(
            kind: .text,
            fileName: "child.md",
            fileType: .markdown,
            data: Data("child-owned".utf8)
        )
        let sourceAttachment = ChatAttachment(
            kind: .text,
            fileName: "source.md",
            fileType: .markdown,
            data: Data("source-owned".utf8)
        )

        bridge.chat.appendUser("源会话初始", attachments: [attachment])
        let forkObservation = try bridge.performSessionAction(
            .fork(sessionID: sourceSessionID.uuidString)
        )
        let childSessionID = try #require(bridge.chat.activeSessionID)
        #expect(forkObservation.receipt.action == .fork)
        #expect(childSessionID != sourceSessionID)
        #expect(forkObservation.receipt.sessionID == childSessionID.uuidString)

        bridge.chat.appendUser("子会话后续", attachments: [childAttachment])
        _ = try bridge.performSessionAction(
            .switch(sessionID: sourceSessionID.uuidString)
        )
        bridge.chat.appendUser("源会话后续", attachments: [sourceAttachment])

        let reopened = ChatStore()
        #expect(reopened.attachPersistence(sessionStore))
        let source = try #require(
            reopened.sessions.first(where: { $0.id == sourceSessionID })
        )
        let child = try #require(
            reopened.sessions.first(where: { $0.id == childSessionID })
        )
        let sourceUsers = source.messages.filter { $0.role == .user }
        let childUsers = child.messages.filter { $0.role == .user }

        #expect(sourceUsers.map(\.content) == ["源会话初始", "源会话后续"])
        #expect(childUsers.map(\.content) == ["源会话初始", "子会话后续"])
        #expect(sourceUsers.first?.attachments == [attachment])
        #expect(childUsers.first?.attachments == [attachment])
        #expect(sourceUsers.last?.attachments == [sourceAttachment])
        #expect(childUsers.last?.attachments == [childAttachment])
        #expect(!sourceUsers.contains { $0.content == "子会话后续" })
        #expect(!childUsers.contains { $0.content == "源会话后续" })
    }

    @Test
    func invalidTargetFailsClosedWithoutChangingActiveSessionOrLedger() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let active = try #require(bridge.chat.activeSessionID)
        let beforeTasks = store.taskCenterSnapshots()

        #expect(throws: SessionActionError.invalidTarget) {
            try bridge.performSessionAction(.switch(sessionID: UUID().uuidString))
        }

        #expect(bridge.chat.activeSessionID == active)
        #expect(store.taskCenterSnapshots() == beforeTasks)
    }

    @Test
    func directChatSessionMutationsUseTheBridgeConsumer() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let first = try #require(bridge.chat.activeSessionID)

        bridge.chat.newSession()
        let second = try #require(bridge.chat.activeSessionID)
        bridge.chat.renameSession(id: second, title: "来自 ChatStore")
        bridge.chat.switchSession(id: first)
        let forked = try #require(bridge.chat.duplicateSession(id: first))

        #expect(forked != first && forked != second)
        #expect(store.taskCenterSnapshots().filter { $0.status == .succeeded }.count == 4)
        #expect(bridge.chat.sessions.first(where: { $0.id == second })?.title == "来自 ChatStore")
    }

    @Test
    func forkingNonActiveSessionDoesNotStopTheActiveSessionStream() async throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let engine = F3SessionSwitchTests.HangingEngine()
        bridge.chat.agentEngine = engine

        var stoppedBTurn: Task<Void, Never>?
        var originalError: (any Error)?
        do {
            // A is idle history: forking a session that is still generating is refused (D-3),
            // so the fork source here has a settled message, while B keeps streaming.
            bridge.chat.appendUser("会话 A")
            let sessionA = try #require(bridge.chat.activeSessionID)

            _ = try bridge.performSessionAction(.new(title: "会话 B"))
            let sessionB = try #require(bridge.chat.activeSessionID)
            bridge.chat.draftText = "会话 B"
            bridge.chat.sendDraft()
            try await Task.sleep(for: .milliseconds(50))
            #expect(bridge.chat.isActiveSessionStreaming)

            _ = try bridge.performSessionAction(.fork(sessionID: sessionA.uuidString))

            #expect(bridge.chat.activeSessionID != sessionB)
            bridge.chat.switchSession(id: sessionB)
            #expect(bridge.chat.isActiveSessionStreaming)
            // Retain B's exact turn before the original stop removes its handle.
            stoppedBTurn = bridge.chat.turnTaskForTests(sessionID: sessionB)
            bridge.chat.stopStreaming()
        } catch {
            originalError = error
        }
        // All business checks have completed or thrown. Retire only this
        // fixture's remaining streams (including A), then join their consumers.
        let remainingTurns = bridge.chat.cancelStreamingForApplicationExit()
        if let stoppedBTurn { await stoppedBTurn.value }
        for turn in remainingTurns { await turn.value }
        if let originalError { throw originalError }
    }
}
