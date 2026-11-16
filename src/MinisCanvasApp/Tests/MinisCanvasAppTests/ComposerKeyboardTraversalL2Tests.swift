import AppKit
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// D-AX-03: exercise the shared native delegate with actual, distinct key views.
/// The companion consumer has no command callback; the global consumer does.
@Suite("L2 Composer native keyboard traversal", .serialized)
@MainActor
struct ComposerKeyboardTraversalL2Tests {
    @Test(arguments: [false, true], ["insertTab:", "insertBacktab:"])
    func unhandledTabMovesToTheCorrectResponder(
        hasCommandCallback: Bool, selector: String
    ) throws {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        var received: [ComposerNativeKey] = []
        if hasCommandCallback {
            fixture.coordinator.onCommandKey = { received.append($0); return false }
        }
        #expect(fixture.window.makeFirstResponder(fixture.input))

        let handled = fixture.coordinator.textView(
            fixture.input, doCommandBy: NSSelectorFromString(selector)
        )

        #expect(handled)
        let forward = selector == "insertTab:"
        #expect(fixture.window.firstResponder === (forward ? fixture.next : fixture.previous))
        #expect(fixture.input.string == "保留草稿")
        #expect(received == (hasCommandCallback ? [forward ? .tab : .shiftTab] : []))
    }

    @Test(arguments: ["insertTab:", "insertBacktab:"])
    func consumedCompletionCommandDoesNotMoveFocus(selector: String) {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        var received: [ComposerNativeKey] = []
        fixture.coordinator.onCommandKey = { received.append($0); return true }
        #expect(fixture.window.makeFirstResponder(fixture.input))

        #expect(fixture.coordinator.textView(
            fixture.input, doCommandBy: NSSelectorFromString(selector)
        ))

        #expect(fixture.window.firstResponder === fixture.input)
        #expect(received == [selector == "insertTab:" ? .tab : .shiftTab])
        #expect(fixture.input.string == "保留草稿")
    }

    @Test(arguments: [false, true])
    func markedTextRetainsFocusAndDoesNotDispatch(hasCommandCallback: Bool) {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        var received: [ComposerNativeKey] = []
        if hasCommandCallback {
            fixture.coordinator.onCommandKey = { received.append($0); return true }
        }
        #expect(fixture.window.makeFirstResponder(fixture.input))
        fixture.input.setMarkedText(
            "拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(fixture.input.hasMarkedText())
        for selector in ["insertTab:", "insertBacktab:", "insertNewline:"] {
            #expect(!fixture.coordinator.textView(
                fixture.input, doCommandBy: NSSelectorFromString(selector)
            ))
            #expect(fixture.window.firstResponder === fixture.input)
        }
        #expect(received.isEmpty)
        #expect(fixture.sentCount() == 0)
        fixture.input.unmarkText()
    }

    @Test(arguments: ["insertTab:", "insertBacktab:"])
    func detachedInputDoesNotClaimFocusTraversal(selector: String) {
        let input = ComposerPasteAwareTextView(frame: .zero)
        let field = ScrollableComposerTextView(
            text: .constant("草稿"), font: .systemFont(ofSize: 13), onSend: {}
        )
        let coordinator = ScrollableComposerTextView.Coordinator(field)
        #expect(input.window == nil)
        #expect(!coordinator.textView(input, doCommandBy: NSSelectorFromString(selector)))
    }

    @Test
    func ordinaryReturnStillSendsOnceWithoutChangingFocusOrDraft() {
        let fixture = makeFixture()
        defer { fixture.window.close() }
        #expect(fixture.window.makeFirstResponder(fixture.input))
        #expect(fixture.coordinator.textView(
            fixture.input, doCommandBy: NSSelectorFromString("insertNewline:")
        ))
        #expect(fixture.sentCount() == 1)
        #expect(fixture.input.string == "保留草稿")
        #expect(fixture.window.firstResponder === fixture.input)
    }

    private func makeFixture() -> (
        window: NSWindow, input: ComposerPasteAwareTextView,
        previous: NSTextView, next: NSTextView,
        coordinator: ScrollableComposerTextView.Coordinator, sentCount: () -> Int
    ) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView!.bounds)
        let previous = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        let input = ComposerPasteAwareTextView(frame: NSRect(x: 200, y: 0, width: 180, height: 100))
        let next = NSTextView(frame: NSRect(x: 400, y: 0, width: 180, height: 100))
        for view in [previous, input, next] { container.addSubview(view) }
        window.contentView = container
        previous.nextKeyView = input
        input.nextKeyView = next
        next.nextKeyView = previous
        input.string = "保留草稿"
        var sent = 0
        let field = ScrollableComposerTextView(
            text: .constant(input.string), font: .systemFont(ofSize: 13),
            onSend: { sent += 1 }
        )
        let coordinator = ScrollableComposerTextView.Coordinator(field)
        return (window, input, previous, next, coordinator, { sent })
    }
}
