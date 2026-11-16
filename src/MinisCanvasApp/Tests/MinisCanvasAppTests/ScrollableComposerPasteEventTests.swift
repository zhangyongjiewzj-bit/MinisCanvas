import Foundation
import AppKit
import Testing
@testable import MinisCanvasApp

@Suite("Scrollable composer paste events")
struct ScrollableComposerPasteEventTests {
    @Test("real paste event routes a long payload without inserting the full text")
    @MainActor
    func realPasteEventRoutesLongPayload() {
        let pastedText = String(repeating: "长", count: 2_001)
        let textView = ComposerPasteAwareTextView(frame: .zero)
        textView.string = "正文"
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.pasteboardStringProvider = { pastedText }

        var receivedEvent: ComposerPasteEvent?
        textView.onPasteEvent = { event in
            receivedEvent = event
            return true
        }

        textView.paste(nil)

        #expect(receivedEvent?.text == pastedText)
        #expect(receivedEvent?.bodyBefore == "正文")
        #expect(textView.string == "正文")
    }

    @Test("paste event creates a pasteboard draft without collapsing typing semantics")
    func pasteEventCreatesDraft() {
        let event = ComposerPasteEvent(text: "长文本")

        #expect(event.text == "长文本")
        #expect(event.draft.source == .pasteboard)
        #expect(event.draft.text == "长文本")
    }

    @Test("return binding remains independent from paste event metadata")
    func returnBindingRemainsStable() {
        #expect(ComposerReturnBinding.shouldSendOnReturn(optionKey: false))
        #expect(!ComposerReturnBinding.shouldSendOnReturn(optionKey: true))
    }

    @Test("long paste replaces the selected body range instead of duplicating it")
    func selectedRangeBecomesEditableBody() {
        let body = "前缀旧内容后缀"
        let selected = body.index(body.startIndex, offsetBy: 2)..<body.index(body.startIndex, offsetBy: 5)

        #expect(
            ComposerPasteEvent.editableBody(
                replacing: selected,
                in: body
            ) == "前缀后缀"
        )
    }

    @Test("coordinator initialization avoids actor capture and view updates synchronize paste callbacks")
    func pasteCallbackIsCoordinatorOwned() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/ScrollableComposerTextView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("var onPaste: ((ComposerPasteEvent) -> Bool)?"))
        #expect(source.contains("self.onPaste = nil"))
        #expect(!source.contains("self.onPaste = parent.onPaste"))
        #expect(source.components(separatedBy: "context.coordinator.onPaste = onPaste").count - 1 == 2)
        #expect(source.contains("[weak coordinator]"))
    }
}
