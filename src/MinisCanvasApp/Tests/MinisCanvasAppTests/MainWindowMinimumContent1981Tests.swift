import AppKit
import Testing
@testable import MinisCanvasApp

// Native host consumer. The source change does not claim this suite has run.
@Suite("D-APP-21 main window content width", .serialized)
@MainActor
struct MainWindowMinimumContent1981Tests {
    @Test("the production main-window minimum admits every requested content width")
    func productionWindowAdmitsOriginalMatrix() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        WindowEdgeClamp.applyMinimumContentSize(to: window)
        #expect(window.contentMinSize.width == CGFloat(AdaptiveLayoutPolicy.minimumSupportedWidth))
        #expect(window.contentMinSize.height == 620)
        for width: CGFloat in [600, 800, 1_000, 1_280, 1_600] {
            window.setContentSize(NSSize(width: width, height: 640))
            let actual = window.contentRect(forFrameRect: window.frame).size
            #expect(abs(actual.width - width) <= 1, "requested content width \(width), actual \(actual.width)")
            #expect(actual.height >= 620)
        }
    }
}
