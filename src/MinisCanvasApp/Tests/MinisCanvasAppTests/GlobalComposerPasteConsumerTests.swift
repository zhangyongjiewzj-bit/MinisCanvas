import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Global Composer paste consumer")
@MainActor
struct GlobalComposerPasteConsumerTests {
    @Test("paste consumer keeps the editable body separate from the payload")
    func separatesBodyAndPastedPayload() {
        let event = ComposerPasteEvent(text: "长粘贴内容", bodyBefore: "正文")
        let state = GlobalComposer.pasteState(from: event)
        let store = ChatStore()

        store.draftText = state.body
        #expect(store.setPastedTextDraft(state.pastedText))
        #expect(store.draftText == "正文")
        #expect(store.composeDraftPayload() == "正文\n\n[Pasted text]\n长粘贴内容")
    }

    @Test("paste consumer preserves an empty body without manufacturing a separator")
    func preservesEmptyBody() {
        let event = ComposerPasteEvent(text: "只有粘贴内容", bodyBefore: "")
        let state = GlobalComposer.pasteState(from: event)
        let store = ChatStore()

        store.draftText = state.body
        #expect(store.setPastedTextDraft(state.pastedText))
        #expect(store.composeDraftPayload() == "只有粘贴内容")
    }
}
