import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("Chat transcript scroll policy")
struct ChatTranscriptScrollTests {
    @Test("the production session boundary can recreate transcript views without losing the parent's reading offset")
    @MainActor
    func retainedOwnerSurvivesTranscriptReplacement() {
        let sessionA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sessionB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let owner = RetainedTranscriptScrollOwner()
        let binding = Binding<ChatTranscriptScrollState>(
            get: { owner.state }, set: { owner.state = $0 }
        )

        let firstA = ChatTranscriptView(sessionID: sessionA, messages: [], scrollStateBinding: binding)
        var state = firstA.scrollStateBinding!.wrappedValue
        state.resetForSession(sessionA)
        _ = state.recordViewport(isNearBottom: false, verticalOffset: 125, identity: state.identity)
        firstA.scrollStateBinding!.wrappedValue = state

        // The `.id(sessionID)` boundary discards firstA and creates fresh
        // children. Both still reach the stable production owner's Binding.
        let firstB = ChatTranscriptView(sessionID: sessionB, messages: [], scrollStateBinding: binding)
        state = firstB.scrollStateBinding!.wrappedValue
        state.resetForSession(sessionB)
        firstB.scrollStateBinding!.wrappedValue = state
        let secondA = ChatTranscriptView(sessionID: sessionA, messages: [], scrollStateBinding: binding)
        state = secondA.scrollStateBinding!.wrappedValue
        state.resetForSession(sessionA)
        secondA.scrollStateBinding!.wrappedValue = state

        #expect(owner.state.restorationOffset == 125)
        #expect(!owner.state.isFollowing)
    }

    @Test("native transcript saving and restoration select the outer scrollbar above the text wrapper")
    @MainActor
    func nativeViewportSelectsOuterScrollHost() {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        let inner = NSTextView.scrollableTextView()
        outer.documentView = document
        document.addSubview(inner)

        #expect(ChatTranscriptNativeViewport.outerScrollView(above: inner) === outer)
        #expect(outer.contentView !== inner.contentView)
    }

    @Test("history reading is protected while assistant messages arrive")
    func protectsHistoryAndCountsNewMessages() {
        var state = ChatTranscriptScrollState()

        #expect(state.apply(.viewport(isNearBottom: false)) == .preserveHistory)
        #expect(state.apply(.assistantMessageAppended) == .showNewMessages(count: 1))
        #expect(state.apply(.assistantMessageAppended) == .showNewMessages(count: 2))
        #expect(state.pendingNewMessageCount == 2)
        #expect(state.isFollowing == false)

        #expect(state.apply(.resumeFollowing) == .followBottom)
        #expect(state.pendingNewMessageCount == 0)
        #expect(state.isFollowing == true)
    }

    @Test("a session change restores the default transcript intent")
    func sessionChangeResetsTranscriptIntent() {
        var state = ChatTranscriptScrollState()
        _ = state.apply(.viewport(isNearBottom: false))
        _ = state.apply(.assistantMessageAppended)

        state.resetForSession()

        #expect(state.isNearBottom == true)
        #expect(state.isFollowing == true)
        #expect(state.pendingNewMessageCount == 0)
    }

    @Test("stale session events cannot change the current viewport intent")
    func staleSessionIdentityIsRejectedAfterReset() {
        let oldSessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let newSessionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var state = ChatTranscriptScrollState()

        state.resetForSession(oldSessionID)
        let oldIdentity = state.identity
        #expect(state.apply(.viewport(isNearBottom: false), identity: oldIdentity) == .preserveHistory)

        state.resetForSession(newSessionID)
        let newIdentity = state.identity
        #expect(newIdentity.sessionID == newSessionID)
        #expect(newIdentity.generation != oldIdentity.generation)
        #expect(state.apply(.assistantMessageAppended, identity: oldIdentity) == .none)
        #expect(state.pendingNewMessageCount == 0)
        #expect(state.isFollowing == true)
        #expect(state.apply(.viewport(isNearBottom: false), identity: newIdentity) == .preserveHistory)
    }

    @Test("an old session's new-message button cannot clear the current session's count")
    @MainActor
    func staleNewMessageButtonPreservesCurrentSession() {
        let sessionA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sessionB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let owner = RetainedTranscriptScrollOwner()
        owner.state.resetForSession(sessionB)
        let identityB = owner.state.identity
        _ = owner.state.apply(.viewport(isNearBottom: false), identity: identityB)
        _ = owner.state.apply(.assistantMessageAppended, identity: identityB)
        _ = owner.state.apply(.assistantMessageAppended, identity: identityB)
        let binding = Binding<ChatTranscriptScrollState>(
            get: { owner.state }, set: { owner.state = $0 }
        )

        // An A action still queued after the retained owner advances to B
        // must not borrow B's identity and consume B's unread count.
        let staleA = ChatTranscriptView(
            sessionID: sessionA, messages: [], scrollStateBinding: binding,
            currentSessionID: { sessionB }
        )
        #expect(staleA.resumeNewMessagesForCurrentSession() == nil)
        #expect(owner.state.pendingNewMessageCount == 2)
        #expect(!owner.state.isFollowing)

        // A B view is also stale while the production active session is A.
        let staleB = ChatTranscriptView(
            sessionID: sessionB, messages: [], scrollStateBinding: binding,
            currentSessionID: { sessionA }
        )
        #expect(staleB.resumeNewMessagesForCurrentSession() == nil)
        #expect(owner.state.pendingNewMessageCount == 2)

        let currentB = ChatTranscriptView(
            sessionID: sessionB, messages: [], scrollStateBinding: binding,
            currentSessionID: { sessionB }
        )
        #expect(currentB.resumeNewMessagesForCurrentSession() == identityB)
        #expect(owner.state.pendingNewMessageCount == 0)
        #expect(owner.state.isFollowing)
    }

    @Test("A to B to A restores A's native history offset without borrowing B's viewport")
    func sessionRoundTripRestoresHistoryPosition() {
        let sessionA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sessionB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var state = ChatTranscriptScrollState()

        state.resetForSession(sessionA)
        let firstA = state.identity
        #expect(state.recordViewport(
            isNearBottom: false, verticalOffset: 125, identity: firstA
        ) == .preserveHistory)
        state.resetForSession(sessionB)
        let firstB = state.identity
        #expect(state.restorationOffset == nil)
        #expect(state.isFollowing)
        #expect(state.recordViewport(
            isNearBottom: true, verticalOffset: 900, identity: firstB
        ) == .followBottom)

        state.resetForSession(sessionA)
        let secondA = state.identity
        #expect(state.restorationOffset == 125)
        #expect(!state.isFollowing)
        #expect(state.apply(.assistantMessageAppended, identity: secondA) == .showNewMessages(count: 1))
        #expect(state.recordViewport(
            isNearBottom: true, verticalOffset: 900, identity: firstA
        ) == .none)
        #expect(state.restorationOffset == 125)
        #expect(state.recordViewport(
            isNearBottom: false, verticalOffset: 125, identity: secondA
        ) == .preserveHistory)

        // Once A is actually returned to its bottom, its next visit follows latest.
        #expect(state.recordViewport(
            isNearBottom: true, verticalOffset: 900, identity: secondA
        ) == .followBottom)
        state.resetForSession(sessionB)
        state.resetForSession(sessionA)
        #expect(state.restorationOffset == nil)
        #expect(state.isFollowing)
    }

    @Test("a caller-captured identity stays stale after session reset")
    func delayedCallerClosureUsesCapturedGeneration() {
        let oldSessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let newSessionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var state = ChatTranscriptScrollState()

        state.resetForSession(oldSessionID)
        let capturedIdentity = state.identity
        let delayedMessageCallback: (ChatTranscriptScrollEvent) -> ChatTranscriptScrollAction = { event in
            state.apply(event, identity: capturedIdentity)
        }

        state.resetForSession(newSessionID)

        #expect(delayedMessageCallback(.assistantMessageAppended) == .none)
        #expect(state.identity.sessionID == newSessionID)
        #expect(state.pendingNewMessageCount == 0)
    }

    @Test("a user message and a followed stream keep the bottom visible")
    func userMessageRestoresFollowAndStreamingGrowthFollows() {
        var state = ChatTranscriptScrollState()
        _ = state.apply(.viewport(isNearBottom: false))

        #expect(state.apply(.userMessageAppended) == .followBottom)
        #expect(state.apply(.streamContentChanged) == .followBottom)
        #expect(state.apply(.streamCancelled) == .followBottom)
    }

    @Test("attachment render identity survives placeholder to resolved replacement")
    func attachmentIdentityUsesMessageAndSourceSlot() {
        let messageID = UUID()
        let placeholder = ChatAttachment(
            kind: .file,
            fileName: "prompt.png",
            fileType: .image,
            fileURL: "/tmp/prompt.png"
        )
        let resolved = ChatAttachment(
            kind: .image,
            fileName: "prompt.png",
            fileType: .image,
            mimeType: "image/png",
            data: Data([0, 1, 2]),
            fileURL: "/tmp/prompt.png"
        )

        let before = ChatAttachmentRenderItem(messageID: messageID, slot: 0, attachment: placeholder)
        let after = ChatAttachmentRenderItem(messageID: messageID, slot: 0, attachment: resolved)

        #expect(before.id == after.id)
        #expect(ChatAttachmentRenderItem(messageID: messageID, slot: 1, attachment: resolved).id != before.id)
    }
}

@MainActor
private final class RetainedTranscriptScrollOwner {
    var state = ChatTranscriptScrollState()
}
