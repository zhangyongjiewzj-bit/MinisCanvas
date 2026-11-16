import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("ChatStore pasted text state")
struct ChatStorePastedTextStateTests {
    @Test("pasted text is scoped to the active session and composes once")
    @MainActor
    func stateIsSessionScoped() {
        let store = ChatStore()
        let first = store.activeSessionID
        let draft = PastedTextDraft(id: UUID(), text: "粘贴内容", source: .pasteboard)

        #expect(store.setPastedTextDraft(draft))
        #expect(store.activePastedTextDraft == draft)
        store.draftText = "正文"
        #expect(store.composeDraftPayload().contains(ComposerPayload.pastedTextSeparator))

        store.newSession()
        #expect(store.activeSessionID != first)
        #expect(store.activePastedTextDraft == nil)
        #expect(store.clearPastedTextDraft() == false)
    }

    @Test("clearing pasted state is explicit and idempotent")
    @MainActor
    func clearIsIdempotent() {
        let store = ChatStore()
        let draft = PastedTextDraft(id: UUID(), text: "一次", source: .pasteboard)
        #expect(store.setPastedTextDraft(draft))
        #expect(store.clearPastedTextDraft())
        #expect(store.activePastedTextDraft == nil)
        #expect(store.clearPastedTextDraft() == false)
    }

    @Test("late capsule actions cannot mutate the newly active session")
    @MainActor
    func lateActionsKeepBothSessionsAndExposeFeedback() throws {
        let store = ChatStore()
        let firstID = try #require(store.activeSessionID)
        let firstDraft = PastedTextDraft(
            id: UUID(),
            text: "第一会话粘贴内容",
            source: .pasteboard
        )
        #expect(store.setPastedTextDraft(firstDraft))

        let secondID = store.applyNewSession(title: "第二会话")
        let secondDraft = PastedTextDraft(
            id: UUID(),
            text: "第二会话粘贴内容",
            source: .pasteboard
        )
        #expect(store.setPastedTextDraft(secondDraft))

        let staleUpdate = PastedTextDraft(
            id: firstDraft.id,
            text: "迟到保存不应进入第二会话",
            source: .pasteboard
        )
        #expect(!PastedTextComposerConsumer.save(
            staleUpdate,
            expectedSessionID: firstID,
            expectedDraftID: firstDraft.id,
            in: store
        ))
        #expect(store.pastedTextActionFeedback == "会话已切换，粘贴文本未保存。")
        #expect(store.activePastedTextDraft == secondDraft)

        #expect(!PastedTextComposerConsumer.remove(
            expectedSessionID: firstID,
            expectedDraftID: firstDraft.id,
            in: store
        ))
        #expect(store.pastedTextActionFeedback == "会话已切换，粘贴文本未删除。")
        #expect(store.activePastedTextDraft == secondDraft)

        store.switchSession(id: firstID)
        #expect(store.activeSessionID == firstID)
        #expect(store.activePastedTextDraft == firstDraft)
        store.switchSession(id: secondID)
        #expect(store.activeSessionID == secondID)
        #expect(store.activePastedTextDraft == secondDraft)
    }

    @Test("matching capsule actions update and remove only their owner")
    @MainActor
    func matchingActionsPreserveNormalBehavior() throws {
        let store = ChatStore()
        let sessionID = try #require(store.activeSessionID)
        let draft = PastedTextDraft(id: UUID(), text: "原始", source: .pasteboard)
        #expect(store.setPastedTextDraft(draft))

        let updated = PastedTextDraft(id: draft.id, text: "已保存", source: .pasteboard)
        #expect(PastedTextComposerConsumer.save(
            updated,
            expectedSessionID: sessionID,
            expectedDraftID: draft.id,
            in: store
        ))
        #expect(store.activePastedTextDraft == updated)
        #expect(PastedTextComposerConsumer.remove(
            expectedSessionID: sessionID,
            expectedDraftID: updated.id,
            in: store
        ))
        #expect(store.activePastedTextDraft == nil)
        #expect(store.pastedTextActionFeedback == nil)
    }

    @Test("sending freezes one capsule snapshot before clearing the session draft")
    @MainActor
    func sendFreezesCapsuleSnapshot() throws {
        let store = ChatStore()
        let draft = PastedTextDraft(id: UUID(), text: "不可变粘贴内容", source: .pasteboard)
        #expect(store.setPastedTextDraft(draft))
        store.draftText = "正文"

        store.sendDraft()
        let userMessages = store.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        let sent = try #require(userMessages.first)

        #expect(store.activePastedTextDraft == nil)
        #expect(store.lastPastedTextSubmissionSnapshot?.capsuleID == draft.id)
        #expect(store.lastPastedTextSubmissionSnapshot?.sessionID == store.activeSessionID)
        #expect(store.lastPastedTextSubmissionSnapshot?.text == "正文\n\n[Pasted text]\n不可变粘贴内容")
        #expect(store.lastPastedTextSubmissionSnapshot?.isReference == true)
        #expect(sent.referenceCard?.sessionID == store.activeSessionID)
        #expect(sent.referenceCard?.material == draft.text)
        #expect(sent.displayContent == "正文")
        #expect(store.messages.filter { $0.role == .user }.count == 1)
    }

    @Test("reference card expansion is fenced to the sending session")
    @MainActor
    func referenceCardExpansionIsSessionScoped() {
        let store = ChatStore()
        guard let sourceSessionID = store.activeSessionID else {
            Issue.record("ChatStore must start with an active session")
            return
        }
        let card = PastedTextReferenceCard(
            id: UUID(),
            sessionID: sourceSessionID,
            instruction: "总结资料",
            material: String(repeating: "资料", count: 180)
        )
        store.appendUser(
            "总结资料\n\n[Pasted text]\n\(card.material)",
            referenceCard: card
        )

        guard let sentMessageID = store.messages.last?.id else {
            Issue.record("reference card message was not appended")
            return
        }
        #expect(store.messages.last?.referenceCard?.isExpanded == false)
        #expect(store.setPastedTextReferenceExpanded(
            messageID: sentMessageID,
            expanded: true,
            sessionID: sourceSessionID
        ))
        #expect(store.messages.last?.referenceCard?.isExpanded == true)

        store.newSession()
        #expect(!store.setPastedTextReferenceExpanded(
            messageID: sentMessageID,
            expanded: false,
            sessionID: sourceSessionID
        ))
        store.switchSession(id: sourceSessionID)
        #expect(store.messages.last?.referenceCard?.isExpanded == true)
    }

}
