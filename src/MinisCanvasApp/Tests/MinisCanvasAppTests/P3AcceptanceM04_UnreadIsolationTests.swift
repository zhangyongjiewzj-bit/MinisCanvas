import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SESSION-05 unread isolation")
@MainActor
struct P3AcceptanceM04_UnreadIsolationTests {
    @Test func openingOneUnreadSessionPreservesTheOtherAcrossRemount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3AcceptanceM04-unread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MinisCore.SessionStore(directory: directory)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let sessionA = try #require(chat.activeSessionID)
        chat.appendUser("A 的消息")
        chat.newSession()
        let sessionB = try #require(chat.activeSessionID)
        chat.appendUser("B 的消息")
        chat.setUnread(true, sessionID: sessionA)
        chat.setUnread(true, sessionID: sessionB)

        chat.switchSession(id: sessionA)
        #expect(chat.sessions.first { $0.id == sessionA }?.unread == false)
        #expect(chat.sessions.first { $0.id == sessionB }?.unread == true)
        #expect(chat.sessionList.first { $0.session.id == sessionB }?.indicator == .unread)

        let reopened = ChatStore()
        #expect(reopened.attachPersistence(store))
        #expect(reopened.sessions.first { $0.id == sessionA }?.unread == false)
        #expect(reopened.sessions.first { $0.id == sessionB }?.unread == true)
        #expect(reopened.sessionList.first { $0.session.id == sessionB }?.indicator == .unread)
        #expect(reopened.sessions.first { $0.id == sessionA }?.messages.contains {
            $0.content == "A 的消息"
        } == true)
        #expect(reopened.sessions.first { $0.id == sessionB }?.messages.contains {
            $0.content == "B 的消息"
        } == true)
    }
}
