import AppKit
import Foundation
import Testing
@testable import MinisCanvasApp

/// Counts the native setter rather than a production counter or a mock font.
/// The body still calls AppKit; no window or physical keyboard claim is made.
@MainActor
private final class FontWriteCountingTextView3041: NSTextView {
    private(set) var fontWriteCount = 0

    override var font: NSFont? {
        get { super.font }
        set {
            fontWriteCount += 1
            super.font = newValue
        }
    }
}

@Suite("D-PERF-01 native Composer font refresh")
@MainActor
struct ComposerFontRefresh3041Tests {
    @Test("100k committed draft edits do not rewrite unchanged font attributes")
    func committedInputRetainsNativeFontWithoutRepeatedSetter() {
        let font = NSFont.systemFont(ofSize: 13)
        let input = FontWriteCountingTextView3041(
            frame: NSRect(x: 0, y: 0, width: 480, height: 80))
        input.isRichText = false
        input.font = font
        input.string = String(repeating: "中🙂e\u{301}a", count: 10_000)
        #expect(input.string.utf8.count >= 100_000)
        input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        var expected = input.string
        let keys = ["a", "中", "e\u{301}", "🙂"]
        for index in 0..<32 {
            let key = keys[index % keys.count]
            input.insertText(key, replacementRange: input.selectedRange())
            let writesBeforeRefresh = input.fontWriteCount
            let selection = input.selectedRange()
            let origin = input.visibleRect.origin
            ScrollableComposerTextView.updateFontIfNeeded(font, in: input)
            expected += key
            #expect(input.string == expected)
            #expect(input.selectedRange() == selection)
            #expect(input.visibleRect.origin == origin)
            #expect(input.fontWriteCount == writesBeforeRefresh)
        }

        // Positive control: this same consumer must still apply typography.
        let larger = NSFont.systemFont(ofSize: 18)
        let initialFontWrites = input.fontWriteCount
        ScrollableComposerTextView.updateFontIfNeeded(larger, in: input)
        #expect(input.fontWriteCount == initialFontWrites + 1)
        #expect(input.font == larger)
        #expect(input.string == expected)
        ScrollableComposerTextView.updateFontIfNeeded(larger, in: input)
        #expect(input.fontWriteCount == initialFontWrites + 1)
    }

    @Test("Equal font objects preserve marked text and scrolled selection on refresh")
    func equalFontRefreshPreservesCompositionAndViewport() throws {
        let font = NSFont.systemFont(ofSize: 13)
        // Equality must work across independently resolved fonts; identity
        // alone would cause redundant writes after SwiftUI reevaluation.
        let equalFont = try #require(NSFont(descriptor: font.fontDescriptor, size: font.pointSize))
        #expect(equalFont == font)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
        let input = FontWriteCountingTextView3041(
            frame: NSRect(x: 0, y: 0, width: 480, height: 1_000))
        input.isRichText = false
        input.font = font
        input.string = String(repeating: "中🙂e\u{301}\n", count: 32)
        scroll.documentView = input
        let range = (input.string as NSString).range(of: "🙂")
        input.setSelectedRange(range)
        input.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                            replacementRange: range)
        #expect(input.hasMarkedText())
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        let marked = input.markedRange()
        let selected = input.selectedRanges
        let text = input.string
        let origin = scroll.contentView.bounds.origin
        let initialFontWrites = input.fontWriteCount
        for _ in 0..<32 {
            ScrollableComposerTextView.updateFontIfNeeded(equalFont, in: input)
        }
        #expect(input.fontWriteCount == initialFontWrites)
        #expect(input.string == text)
        #expect(input.hasMarkedText() && input.markedRange() == marked)
        #expect(input.selectedRanges == selected)
        #expect(scroll.contentView.bounds.origin == origin)
        input.unmarkText()
    }
}
