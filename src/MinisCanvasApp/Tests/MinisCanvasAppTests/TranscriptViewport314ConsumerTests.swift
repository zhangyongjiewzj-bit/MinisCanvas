import AppKit
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-PERF-02 native transcript measurement and placement")
@MainActor
struct TranscriptViewport314ConsumerTests {
    @Test func placementBetweenProposalsDoesNotInvalidateMeasuredHistory() throws {
        let cache = ChatTranscriptDocumentCache()
        let redactor = ChatTranscriptRedactor(secretValues: ["synthetic-hidden-token"])
        let history = ChatMessageUI(role: .user, content:
            "# Historical heading\n\n" + String(repeating: "历史 Markdown **bold** readable words 。\n", count: 400)
            + "synthetic-hidden-token")
        let document = cache.render(sessionID: UUID(), messages: [history], baseSize: 17, redactor: redactor)
        let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
        let coordinator = view.makeCoordinator()
        let host = view.makeNSView(coordinator: coordinator)
        let text = try #require(host.documentView as? NSTextView)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        let proposal = ProposedViewSize(width: 480, height: nil)
        let measured = try #require(view.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
        let prefixRange = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: 200), actualCharacterRange: nil)
        let prefixRect = manager.boundingRect(forGlyphRange: prefixRange, in: container)
        let original = NSAttributedString(attributedString: text.attributedString())
        text.selectedRanges = [NSValue(range: NSRange(location: 3, length: 7))]

        // SwiftUI can measure using a fallback width before placing the native
        // scroll view at the resolved width. Drive AppKit's real placement and
        // layout, rather than comparing two calculated height numbers.
        host.setFrameSize(NSSize(width: 600, height: measured.height))
        host.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: container)
        #expect(manager.boundingRect(forGlyphRange: prefixRange, in: container) == prefixRect)
        #expect(ReadOnlyAttributedTextView.measuredContentHeight(
            usedRect: manager.usedRect(for: container), inset: text.textContainerInset
        ) == measured.height)
        #expect(text.attributedString().isEqual(to: original))
        #expect(text.selectedRanges.first?.rangeValue == NSRange(location: 3, length: 7))
        #expect(text.accessibilityValue() == original.string)
        #expect(!text.string.contains("synthetic-hidden-token"))

        // The next actual proposal, rather than placement, owns the reflow.
        let actualProposal = ProposedViewSize(width: 600, height: nil)
        let actual = try #require(view.sizeThatFits(actualProposal, nsView: host, coordinator: coordinator))
        let controlCoordinator = view.makeCoordinator()
        let control = view.makeNSView(coordinator: controlCoordinator)
        let controlSize = try #require(view.sizeThatFits(actualProposal, nsView: control, coordinator: controlCoordinator))
        let controlText = try #require(control.documentView as? NSTextView)
        #expect(actual == controlSize)
        #expect(text.attributedString().isEqual(to: controlText.attributedString()))
        #expect(actual.height > 1)
        #expect(host.contentView.bounds.origin == .zero)
    }

    @Test func sendBatchAndCoalescedTailPreserveNativeHistoryGeometry() async throws {
        await ChatTranscriptStatusIconProjection.preload()
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: ["synthetic-hidden-token"])
        let history = ChatMessageUI(role: .user, content:
            "# Existing history\n\n" + String(repeating: "第 40 行之前的历史 **bold**。\n", count: 80))
        let initial = cache.render(sessionID: session, messages: [history], baseSize: 17, redactor: redactor)
        let first = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let coordinator = first.makeCoordinator()
        let host = first.makeNSView(coordinator: coordinator)
        let text = try #require(host.documentView as? NSTextView)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        let proposal = ProposedViewSize(width: 600, height: nil)
        let initialSize = try #require(first.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
        host.setFrameSize(initialSize)
        host.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: container)
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        outer.documentView = host
        outer.contentView.scroll(to: NSPoint(x: 0, y: 200))
        outer.reflectScrolledClipView(outer.contentView)
        let readingOrigin = outer.contentView.bounds.origin
        let prefix = NSAttributedString(attributedString: text.attributedString())
        let prefixRange = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: prefix.length), actualCharacterRange: nil)
        let prefixRect = manager.boundingRect(forGlyphRange: prefixRange, in: container)
        text.selectedRanges = [NSValue(range: NSRange(location: 5, length: 9))]
        let user = ChatMessageUI(role: .user, content: "你好")
        var assistant = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        for phase in 0..<3 {
            if phase == 1 {
                for delta in ["第 1 行", "第 1 行\n第 2 行 synthetic-hidden-token"] {
                    assistant.content = delta
                    _ = cache.render(sessionID: session, messages: [history, user, assistant], baseSize: 17, redactor: redactor)
                }
            } else if phase == 2 {
                assistant.isStreaming = false
            }
            let messages = [history, user, assistant]
            let document = cache.render(sessionID: session, messages: messages, baseSize: 17, redactor: redactor)
            let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
            view.updateNSView(host, coordinator: coordinator)
            let size = try #require(view.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            manager.ensureLayout(for: container)
            #expect(size.height >= initialSize.height)
            #expect(ReadOnlyAttributedTextView.measuredContentHeight(
                usedRect: manager.usedRect(for: container), inset: text.textContainerInset
            ) == size.height)
            #expect(outer.contentView.bounds.origin == readingOrigin)
            let visible = text.convert(outer.contentView.bounds, from: outer.contentView)
            let visibleGlyphs = manager.glyphRange(forBoundingRect: visible, in: container)
            #expect(visibleGlyphs.length > 0)
            let visibleCharacters = manager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
            #expect(visibleCharacters.location < prefix.length)
            #expect(manager.boundingRect(forGlyphRange: visibleGlyphs, in: container).intersects(visible))
            #expect(manager.boundingRect(forGlyphRange: prefixRange, in: container) == prefixRect)
            #expect(text.attributedString().attributedSubstring(from: NSRange(location: 0, length: prefix.length)).isEqual(to: prefix))
            #expect(text.selectedRanges.first?.rangeValue == NSRange(location: 5, length: 9))
            #expect(host.contentView.bounds.origin == .zero)
            #expect(text.accessibilityValue() == document.attributedString.string)
            #expect(!text.string.contains("synthetic-hidden-token"))
            let controlCoordinator = view.makeCoordinator()
            let control = view.makeNSView(coordinator: controlCoordinator)
            let controlSize = try #require(view.sizeThatFits(proposal, nsView: control, coordinator: controlCoordinator))
            #expect(size == controlSize)
            let controlText = try #require(control.documentView as? NSTextView)
            #expect(text.attributedString().isEqual(to: controlText.attributedString()))
            // Full transcript input is trusted only after one projection from
            // original messages; generic re-sanitization deliberately hides icons.
            let independentlyFormatted = ChatTranscriptFormatter.formattedDocument(
                messages, baseSize: 17, redactor: redactor).attributedString
            #expect(UX02ChatReadingTests.renderingDifference(document.attributedString, independentlyFormatted) == nil)
        }
    }
}
