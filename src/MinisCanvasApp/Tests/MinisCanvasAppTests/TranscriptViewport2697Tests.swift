import AppKit
import Testing
@testable import MinisCanvasApp

@Suite("D-PERF-02 deferred transcript viewport fact")
@MainActor
struct TranscriptViewport2697Tests {
    @Test("a queued bottom sample cannot overwrite a later native history position")
    func delayedBottomNotificationReadsCurrentClip() async throws {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let inner = NSTextView.scrollableTextView()
        outer.documentView = document
        document.addSubview(inner)
        let clip = outer.contentView
        clip.scroll(to: NSPoint(x: 0, y: 900))
        outer.reflectScrolledClipView(clip)
        #expect(document.bounds.maxY - clip.bounds.maxY <= 24)

        var delivered: [(nearBottom: Bool, offset: Double)] = []
        let viewport = ChatTranscriptNativeViewport(innerScrollView: inner) { nearBottom, offset in
            delivered.append((nearBottom, offset))
        }
        // Both notifications reach the production observer synchronously.
        // Its MainActor delivery is deferred until after the native clip has
        // moved from bottom to history in this same session.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        clip.scroll(to: NSPoint(x: 0, y: 100))
        outer.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        #expect(document.bounds.maxY - clip.bounds.maxY > 24)
        for _ in 0..<20 where delivered.count < 2 { await Task.yield() }

        #expect(delivered.count >= 2)
        #expect(delivered.allSatisfy { !$0.nearBottom && $0.offset > 0 })
        viewport.cancelRestoration()
    }
}
