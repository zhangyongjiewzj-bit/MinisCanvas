import AppKit
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("R35 Slot I2 new-session transcript body visibility")
struct R35SlotI2NewSessionBodyVisibilityTests {
    @Test("content height comes from the current document rect, not a stale session frame")
    @MainActor
    func measuredHeightIgnoresStaleFrameHeight() {
        let measured = ReadOnlyAttributedTextView.measuredContentHeight(
            usedRect: NSRect(x: 0, y: 0, width: 320, height: 42),
            inset: NSSize(width: 0, height: 0)
        )

        #expect(measured == 43)
    }

    @Test("new-session projection keeps the first body across switch and stream completion")
    @MainActor
    func newSessionProjectionKeepsFirstBodyAcrossSwitchAndCompletion() async throws {
        let chat = ChatStore()
        let oldSessionID = try #require(chat.activeSessionID)
        chat.appendUser("old user")
        chat.appendAssistant("old assistant")

        chat.newSession()
        let newSessionID = try #require(chat.activeSessionID)
        chat.appendUser("new user")
        chat.appendAssistant("new assistant", toSession: newSessionID, isStreaming: true)

        #expect(chat.messages.last?.content == "new assistant")
        #expect(
            ChatTranscriptFormatter.attributedString(chat.messages).string.contains("new assistant")
        )

        chat.switchSession(id: oldSessionID)
        #expect(ChatTranscriptFormatter.attributedString(chat.messages).string.contains("old assistant"))

        chat.switchSession(id: newSessionID)
        #expect(ChatTranscriptFormatter.attributedString(chat.messages).string.contains("new assistant"))
        #expect(
            chat.finalizeStreamingMessage(
                sessionID: newSessionID,
                at: chat.messages.count - 1
            )
        )
        #expect(chat.messages.last?.isStreaming == false)
        #expect(ChatTranscriptFormatter.attributedString(chat.messages).string.contains("new assistant"))
    }

    @Test("persisted transcript projects body after a fresh ChatStore load")
    @MainActor
    func persistedTranscriptProjectsBodyAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-chat-body-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let chat = ChatStore()
        let sessionID = try #require(chat.activeSessionID)
        chat.attachPersistence(store)
        chat.appendUser("persisted user")
        chat.appendAssistant("persisted assistant")

        let reloaded = ChatStore()
        reloaded.attachPersistence(store)
        reloaded.switchSession(id: sessionID)

        #expect(reloaded.messages.contains { $0.content == "persisted assistant" })
        #expect(
            ChatTranscriptFormatter.attributedString(reloaded.messages).string.contains("persisted assistant")
        )
    }

    @Test("a first assistant body in a new session follows after old-session history reading")
    func firstAssistantBodyIsVisibleAfterSessionSwitch() {
        let body = ChatMessageUI(role: .assistant, content: "new-session assistant body")
        #expect(!ChatTranscriptFormatter.attributedString([body]).string.isEmpty)

        var oldState = ChatTranscriptScrollState()
        _ = oldState.apply(.viewport(isNearBottom: false))
        _ = oldState.apply(.assistantMessageAppended)
        #expect(!oldState.isFollowing)
        #expect(oldState.pendingNewMessageCount == 1)

        let oldSessionIdentity = ChatTranscriptSessionBoundary.viewIdentity(for: UUID())
        let newSessionIdentity = ChatTranscriptSessionBoundary.viewIdentity(for: UUID())
        #expect(oldSessionIdentity != newSessionIdentity)

        var state = ChatTranscriptScrollState()
        let action = state.apply(.assistantMessageAppended)

        #expect(action == .followBottom)
        #expect(state.apply(.streamContentChanged) == .followBottom)
        #expect(state.isFollowing)
        #expect(state.pendingNewMessageCount == 0)
    }

    @Test("streaming and history-following behavior stays session-local")
    func streamingAndHistoryFollowingStaySessionLocal() {
        var state = ChatTranscriptScrollState()
        _ = state.apply(.viewport(isNearBottom: false))

        #expect(state.apply(.streamContentChanged) == .preserveHistory)
        #expect(state.apply(.assistantMessageAppended) == .showNewMessages(count: 1))

        let sessionID = UUID()
        #expect(
            ChatTranscriptSessionBoundary.viewIdentity(for: sessionID)
                == ChatTranscriptSessionBoundary.viewIdentity(for: sessionID)
        )
        var newSessionState = state
        #expect(newSessionState.apply(.streamContentChanged) == .preserveHistory)

        #expect(
            ChatTranscriptSessionBoundary.viewIdentity(for: sessionID)
                != ChatTranscriptSessionBoundary.viewIdentity(for: UUID())
        )
        newSessionState = ChatTranscriptScrollState()
        #expect(newSessionState.apply(.userMessageAppended) == .followBottom)
        #expect(newSessionState.apply(.streamContentChanged) == .followBottom)
        #expect(newSessionState.isFollowing)
        #expect(newSessionState.pendingNewMessageCount == 0)
    }

    @Test("adjacent sessions do not inherit hidden-body state")
    func adjacentSessionsDoNotInheritHiddenBodyState() {
        var historicallyScrolledState = ChatTranscriptScrollState()
        _ = historicallyScrolledState.apply(.viewport(isNearBottom: false))
        _ = historicallyScrolledState.apply(.assistantMessageAppended)
        #expect(historicallyScrolledState.pendingNewMessageCount == 1)

        let firstSessionID = UUID()
        #expect(
            ChatTranscriptSessionBoundary.viewIdentity(for: firstSessionID)
                != ChatTranscriptSessionBoundary.viewIdentity(for: UUID())
        )
        var adjacentSessionState = ChatTranscriptScrollState()
        #expect(adjacentSessionState.apply(.assistantMessageAppended) == .followBottom)
        #expect(adjacentSessionState.isFollowing)
        #expect(adjacentSessionState.pendingNewMessageCount == 0)
    }
}
