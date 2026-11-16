import Foundation
import Testing
import WebKit
@testable import MinisCanvasApp
@testable import MinisCore

@MainActor
@Suite("D-BROWSER-08 owned delayed page lifecycle", .serialized)
struct BrowserOwnedDelayedLifecycle3099Tests {
    @Test("stopped A response cannot publish into B across switch, idle reopen, and restart")
    func stoppedPageCannotBecomeReplacementResult() async throws {
        let fixture = try BrowserLocalHTTPFixture(heldPath: "/held3099")
        defer { fixture.stop() }
        try await fixture.waitUntilReady()
        let policy = BrowserNavigationPolicy(allowedDomains: ["127.0.0.1"])
        let workspace = "owned3099-\(UUID().uuidString)"
        let a = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: workspace)
        let b = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: workspace)
        let owner = BrowserTabSessionOwner()
        defer { owner.retire() }
        let first = BrowserSession(
            scope: BrowserTabView.userBrowserScope(for: a.sessionID, workspaceID: workspace),
            idleTimeoutMinutes: 1, navigationPolicy: policy
        )
        owner.retain(first, for: a)
        let firstView = first.webView
        let firstIdentity = first.identity
        let heldURL = fixture.url(path: "/held3099")
        var firstResult = BrowserNavigationState()
        guard case .navigate(let firstRequest, _) = firstResult.start(rawInput: heldURL.absoluteString)
        else { Issue.record("A did not enter the real navigation path"); return }
        let pending = Task { @MainActor in try await first.navigate(to: heldURL) }
        try await fixture.waitUntilHeld(path: "/held3099")

        // The production tab hide stops the owned navigation before the
        // production owner switch retires its entire WebView generation.
        owner.hide(first)
        do {
            try await pending.value
            Issue.record("the stopped A navigation completed")
        } catch is CancellationError {
            // Expected terminal cancellation, not a successful A page.
        }
        firstResult.invalidate()
        owner.retire(ifDifferentFrom: b)
        #expect(first.resourceState == .closed)
        #expect(!first.accepts(firstIdentity))
        #expect(firstView.navigationDelegate == nil)
        #expect(owner.currentResource(for: a) == nil)
        let didCompleteRetiredA = firstResult.complete(
            requestID: firstRequest, target: heldURL, result: .success
        )
        #expect(!didCompleteRetiredA)

        let second = BrowserSession(
            scope: BrowserTabView.userBrowserScope(for: b.sessionID, workspaceID: workspace),
            idleTimeoutMinutes: 1, navigationPolicy: policy
        )
        owner.retain(second, for: b)
        let secondView = second.webView
        let secondStore = secondView.configuration.websiteDataStore
        let bURL = fixture.url(path: "/page3099-b")
        var secondResult = BrowserNavigationState()
        guard case .navigate(let bRequest, _) = secondResult.start(rawInput: bURL.absoluteString)
        else { Issue.record("B did not enter the real navigation path"); return }
        try await second.navigate(to: bURL)
        let didCompleteCurrentB = secondResult.complete(
            requestID: bRequest, target: bURL, result: .success
        )
        #expect(didCompleteCurrentB)
        #expect(second.currentURL() == bURL)
        #expect(second.webView !== firstView)
        #expect((owner.currentResource(for: b) as? BrowserSession) === second)

        // The held A HTTP response is released only after B has a real page.
        #expect(fixture.releaseHeldResponse(path: "/held3099"))
        let nextURL = fixture.url(path: "/page3099-b-next")
        try await second.navigate(to: nextURL)
        #expect(second.currentURL() == nextURL)
        #expect(firstResult.phase == .idle)
        #expect(secondResult.phase == .success(bURL))

        // Reclaim replaces only B's physical view; it retains B's scope.
        second.setUserVisible(false)
        #expect(second.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        #expect(second.reopenResource())
        #expect(second.webView !== secondView)
        #expect(second.webView.configuration.websiteDataStore === secondStore)
        let reopenedURL = fixture.url(path: "/page3099-b-reopened")
        try await second.navigate(to: reopenedURL)
        #expect(second.currentURL() == reopenedURL)

        // Closing and recreating the panel cannot resurrect B's old process
        // or A's delayed page, even when the trusted session identity repeats.
        owner.retire()
        #expect(second.resourceState == .closed)
        #expect(secondView.navigationDelegate == nil)
        let restartedOwner = BrowserTabSessionOwner()
        defer { restartedOwner.retire() }
        let restarted = BrowserSession(
            scope: BrowserTabView.userBrowserScope(for: b.sessionID, workspaceID: workspace),
            navigationPolicy: policy
        )
        restartedOwner.retain(restarted, for: b)
        #expect(restarted.webView !== secondView)
        #expect(restarted.webView.configuration.websiteDataStore !== secondStore)
        let restartedURL = fixture.url(path: "/page3099-restarted")
        try await restarted.navigate(to: restartedURL)
        #expect(restarted.currentURL() == restartedURL)
        #expect(fixture.requestPaths.contains("/held3099"))
        #expect(fixture.requestPaths.contains("/page3099-restarted"))
    }

    @Test("a held local response times out without becoming the next successful page")
    func timedOutPageCannotOverwriteRecovery() async throws {
        let fixture = try BrowserLocalHTTPFixture(heldPath: "/timeout3099")
        defer { fixture.stop() }
        try await fixture.waitUntilReady()
        let session = BrowserSession(
            scope: .init(surface: .userBrowser, profile: "synthetic3099",
                         session: UUID().uuidString, workspace: "timeout3099"),
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["127.0.0.1"])
        )
        defer { session.close() }
        // The server holds the response indefinitely. Keep this watchdog
        // above normal WebKit startup variance so only the owned hold causes it.
        session.navigationTimeout = 8
        let timeoutURL = fixture.url(path: "/timeout3099")
        let timedOut = Task { @MainActor in try await session.navigate(to: timeoutURL) }
        try await fixture.waitUntilHeld(path: "/timeout3099")
        do {
            try await timedOut.value
            Issue.record("held local page unexpectedly completed")
        } catch let error as BrowserError {
            #expect(error == .navigationTimeout(timeoutURL))
        }
        #expect(session.activeNavigation == nil)
        #expect(fixture.releaseHeldResponse(path: "/timeout3099"))
        let recoveredURL = fixture.url(path: "/recovered3099")
        try await session.navigate(to: recoveredURL)
        #expect(session.currentURL() == recoveredURL)
    }
}
