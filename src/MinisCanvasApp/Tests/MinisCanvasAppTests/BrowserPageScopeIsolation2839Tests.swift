import Foundation
import Testing
import WebKit
@testable import MinisCanvasApp
@testable import MinisCore

@MainActor
@Suite("D-BROWSER-05 owned page storage isolation", .serialized)
struct BrowserPageScopeIsolation2839Tests {
    @Test("local page cookie and storage remain inside the four-part scope across reopen")
    func localPageStateFollowsOnlyItsOwningScope() async throws {
        let fixture = try BrowserLocalHTTPFixture()
        defer { fixture.stop() }
        try await fixture.waitUntilReady()
        let page = fixture.url(path: "/scope2839")
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profile = "profile2839" + suffix
        let conversation = "conversation2839" + suffix
        let workspace = "workspace2839" + suffix
        let scope = BrowserSessionScope(
            surface: .userBrowser, profile: profile,
            session: conversation, workspace: workspace
        )
        let policy = BrowserNavigationPolicy(allowedDomains: ["127.0.0.1"])
        let owner = BrowserSession(scope: scope, idleTimeoutMinutes: 1, navigationPolicy: policy)
        defer { owner.close() }
        let ownerStore = owner.webView.configuration.websiteDataStore
        try await owner.navigate(to: page)

        // This synthetic page runs the real WebKit cookie and localStorage APIs.
        let setPageState = """
        localStorage.setItem('scope2839', '\(suffix)');
        document.cookie = 'scope2839=\(suffix); path=/';
        localStorage.getItem('scope2839') === '\(suffix)' &&
            document.cookie.includes('scope2839=\(suffix)') ? 'written' : 'missing'
        """
        #expect(try await owner.executeJavaScript(setPageState) == "written")

        func pageState(_ session: BrowserSession) async throws -> String {
            try await session.navigate(to: page)
            return try await session.executeJavaScript(
                "String(localStorage.getItem('scope2839') === '\(suffix)') + '|' + " +
                "String(document.cookie.includes('scope2839=\(suffix)'))"
            )
        }

        let same = BrowserSession(scope: scope, navigationPolicy: policy)
        defer { same.close() }
        #expect(same.webView.configuration.websiteDataStore === ownerStore)
        #expect(try await pageState(same) == "true|true")

        let foreignScopes: [BrowserSessionScope] = [
            .init(surface: .agentBrowser, profile: profile,
                  session: conversation, workspace: workspace),
            .init(surface: .userBrowser, profile: profile + "other",
                  session: conversation, workspace: workspace),
            .init(surface: .userBrowser, profile: profile,
                  session: conversation + "other", workspace: workspace),
            .init(surface: .userBrowser, profile: profile,
                  session: conversation, workspace: workspace + "other")
        ]
        for foreignScope in foreignScopes {
            let foreign = BrowserSession(scope: foreignScope, navigationPolicy: policy)
            #expect(foreign.webView.configuration.websiteDataStore !== ownerStore)
            #expect(try await pageState(foreign) == "false|false")
            foreign.close()
        }

        // Idle reclaim changes WebView identity but retains this scoped store.
        let previousView = owner.webView
        owner.setUserVisible(false)
        #expect(owner.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        #expect(owner.reopenResource())
        #expect(owner.webView !== previousView)
        #expect(owner.webView.configuration.websiteDataStore === ownerStore)
        #expect(try await pageState(owner) == "true|true")

        owner.close()
        same.close()
        let nextLifetime = BrowserSession(scope: scope, navigationPolicy: policy)
        defer { nextLifetime.close() }
        #expect(nextLifetime.webView.configuration.websiteDataStore !== ownerStore)
        #expect(try await pageState(nextLifetime) == "false|false")
        #expect(fixture.requestPaths.contains("/scope2839"))
    }
}
