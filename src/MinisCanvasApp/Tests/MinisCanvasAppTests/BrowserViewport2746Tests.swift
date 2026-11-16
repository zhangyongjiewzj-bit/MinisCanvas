import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MinisCanvasApp
@testable import MinisCore

@MainActor
@Suite("D-BROWSER-01 embedded viewport consumer", .serialized)
struct BrowserViewport2746Tests {
    @Test("saved viewport reaches local HTTP page inside a narrower right panel")
    func configuredPageSizeSurvivesPanelLayout() async throws {
        let fixture = try BrowserLocalHTTPFixture()
        defer { fixture.stop() }
        try await fixture.waitUntilReady()

        let settings = BrowserSettings(
            userAgentPreset: .custom,
            customUserAgent: "Task2746-Synthetic-UA/1.0",
            viewportMode: .custom,
            customViewportWidth: 390,
            customViewportHeight: 844,
            idleTabTimeoutMinutes: 1
        )
        let session = BrowserSession(
            scopeID: "task2746-viewport",
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["127.0.0.1"])
        )
        defer { session.close() }
        session.apply(settings: settings)

        // This is the production right-panel content at the observed 300×840
        // allocation; the page's configured viewport remains 390×844.
        let hosted = NSHostingView(rootView: BrowserViewportContent(session: session, settings: settings))
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 840),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        #expect(session.webView.superview != nil, "production viewport content must host the real WKWebView")

        try await session.navigate(to: fixture.url(path: "/viewport"))
        let result = try #require(try await session.webView.evaluateJavaScript(
            "[window.innerWidth, window.innerHeight, navigator.userAgent].join('|')"
        ) as? String)
        #expect(result == "390|844|Task2746-Synthetic-UA/1.0")
        #expect(fixture.requestPaths.contains("/viewport"))
        #expect(session.idleTimeoutMinutes == 1)
    }
}
