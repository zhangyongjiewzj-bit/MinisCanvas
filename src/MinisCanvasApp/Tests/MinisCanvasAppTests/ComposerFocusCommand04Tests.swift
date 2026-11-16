import AppKit
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 Composer 原生焦点消费者", .serialized)
@MainActor
struct ComposerFocusCommand04Tests {
    @Test func currentRequestFocusesMountedEditorOnceAndDetachedRequestIsNotConsumed() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let container = NSView(frame: window.contentView!.bounds)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 210, height: 120))
        let editor = ComposerPasteAwareTextView(frame: scroll.bounds)
        scroll.documentView = editor
        let other = NSTextView(frame: NSRect(x: 220, y: 0, width: 180, height: 100))
        container.addSubview(scroll)
        container.addSubview(other)
        window.contentView = container

        let field = ScrollableComposerTextView(
            text: .constant("synthetic draft"), font: .systemFont(ofSize: 13), onSend: {}
        )
        let coordinator = ScrollableComposerTextView.Coordinator(field)
        let firstRequest = UUID()
        #expect(window.makeFirstResponder(other))
        coordinator.applyFocusRequest(firstRequest, in: scroll)
        #expect(window.firstResponder === editor)
        #expect(coordinator.lastAppliedFocusRequestID == firstRequest)

        #expect(window.makeFirstResponder(other))
        coordinator.applyFocusRequest(firstRequest, in: scroll)
        #expect(window.firstResponder === other, "same request must not steal focus again")

        let detached = NSScrollView(frame: scroll.frame)
        detached.documentView = ComposerPasteAwareTextView(frame: detached.bounds)
        let secondRequest = UUID()
        coordinator.applyFocusRequest(secondRequest, in: detached)
        #expect(coordinator.lastAppliedFocusRequestID == firstRequest)
        coordinator.applyFocusRequest(secondRequest, in: scroll)
        #expect(window.firstResponder === editor)
        #expect(coordinator.lastAppliedFocusRequestID == secondRequest)
    }
}
