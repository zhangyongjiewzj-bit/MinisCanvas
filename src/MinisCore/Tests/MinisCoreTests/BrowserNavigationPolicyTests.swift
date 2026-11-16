import Foundation
import Testing
@testable import MinisCore

@Suite("D-BROWSER-04 navigation policy")
struct BrowserNavigationPolicyTests {

    private let scopeID = "browser-policy-scope"

    private func url(_ raw: String) -> URL {
        guard let value = URL(string: raw) else {
            fatalError("fixture URL must be valid: \(raw)")
        }
        return value
    }

    private func decision(
        _ policy: BrowserNavigationPolicy,
        _ rawURL: String?,
        source: BrowserNavigationPolicy.Source = .action,
        currentURL: URL? = nil,
        scope: String? = nil,
        generation: UInt64 = 1
    ) -> BrowserNavigationPolicy.Decision {
        policy.decision(
            for: rawURL.map(url),
            source: source,
            scopeID: scope ?? scopeID,
            expectedScopeID: scopeID,
            generation: generation,
            expectedGeneration: 1,
            currentURL: currentURL
        )
    }

    private func pendingLocalHTMLDecision(
        policy: BrowserNavigationPolicy = BrowserNavigationPolicy(),
        _ rawURL: String,
        requestIsPending: Bool = true,
        pendingSource: BrowserNavigationPolicy.Source? = .initial,
        callbackSource: BrowserNavigationPolicy.Source = .response,
        boundIdentityRawURL: String? = nil
    ) -> BrowserNavigationPolicy.Decision? {
        let value = url(rawURL)
        return BrowserSession.pendingLocalHTMLDocumentDecision(
            for: value,
            baseDecision: decision(policy, rawURL, source: callbackSource),
            requestIsPending: requestIsPending,
            allowsLocalContent: policy.allowsLocalContent,
            pendingNavigationSource: pendingSource,
            callbackSource: callbackSource,
            boundIdentity: boundIdentityRawURL.map(url)
        )
    }

    private func pendingLocalHTMLTerminalDecision(
        _ rawURL: String,
        baseDecision: BrowserNavigationPolicy.Decision? = nil,
        terminalRequestID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        activeRequestID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        hasPendingContinuation: Bool = true,
        sourceIsOwner: Bool = true,
        navigationMatchesActive: Bool = true,
        requestIsPending: Bool = true,
        allowsLocalContent: Bool = true,
        pendingSource: BrowserNavigationPolicy.Source? = .initial,
        resourceIsLive: Bool = true,
        boundIdentityRawURL: String? = nil
    ) -> BrowserNavigationPolicy.Decision? {
        BrowserSession.pendingLocalHTMLTerminalDocumentDecision(
            for: url(rawURL),
            baseDecision: baseDecision ?? decision(
                BrowserNavigationPolicy(), rawURL, source: .response
            ),
            terminalRequestID: terminalRequestID,
            activeRequestID: activeRequestID,
            hasPendingContinuation: hasPendingContinuation,
            sourceIsOwner: sourceIsOwner,
            navigationMatchesActive: navigationMatchesActive,
            requestIsPending: requestIsPending,
            allowsLocalContent: allowsLocalContent,
            pendingNavigationSource: pendingSource,
            resourceIsLive: resourceIsLive,
            boundIdentity: boundIdentityRawURL.map(url)
        )
    }

    @Test("unsafe schemes and malformed URLs are denied before dispatch")
    func unsafeSchemesFailClosed() {
        let policy = BrowserNavigationPolicy(allowedDomains: ["example.com"])
        for rawURL in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>",
            "miniscanvas://open/settings",
            "https://user:password@example.com/private"
        ] {
            let result = decision(policy, rawURL, source: .initial)
            #expect(!result.isAllowed)
        }
        #expect(
            decision(policy, "https://example.com/ok", source: .initial).isAllowed
        )
    }

    @Test("authorized domain and same-origin navigation are allowed")
    func authorizedAndSameOriginAreAllowed() {
        let policy = BrowserNavigationPolicy(allowedDomains: ["example.com"])
        #expect(
            decision(policy, "https://example.com/start", source: .initial).isAllowed
        )
        #expect(
            decision(
                policy,
                "https://example.com/next",
                source: .action,
                currentURL: url("https://example.com/start")
            ).isAllowed
        )
        // The existing PolicyRuntime domain convention includes subdomains.
        #expect(
            decision(policy, "https://www.example.com/docs", source: .redirect).isAllowed
        )
    }

    @Test("unauthorized cross-origin and HTTPS downgrade are denied")
    func crossOriginRedirectsFailClosed() {
        let policy = BrowserNavigationPolicy(allowedDomains: ["example.com"])
        let current = url("https://example.com/start")
        #expect(
            decision(
                policy,
                "https://evil.example.net/redirect",
                source: .redirect,
                currentURL: current
            ) == .deny(.crossOriginNotAuthorized)
        )
        #expect(
            decision(
                policy,
                "http://example.com/downgrade",
                source: .response,
                currentURL: current
            ) == .deny(.insecureRedirect)
        )
    }

    @Test("response, back-forward, and new-window paths share the policy")
    func nonInitialNavigationUsesTheSameGate() {
        let policy = BrowserNavigationPolicy(allowedDomains: ["example.com"])
        let current = url("https://example.com/start")
        #expect(
            decision(
                policy,
                "https://evil.example.net/response",
                source: .response,
                currentURL: current
            ) == .deny(.crossOriginNotAuthorized)
        )
        #expect(
            decision(
                policy,
                "https://evil.example.net/history",
                source: .backForward,
                currentURL: current
            ) == .deny(.crossOriginNotAuthorized)
        )
        #expect(
            decision(
                policy,
                "https://example.com/popup",
                source: .newWindow,
                currentURL: current
            ) == .deny(.newWindowNotAllowed)
        )
    }

    @Test("scope and generation fences reject late decisions")
    func staleIdentityCannotAuthorizeNavigation() {
        let policy = BrowserNavigationPolicy(allowedDomains: ["example.com"])
        #expect(
            decision(policy, "https://example.com/ok", source: .initial, scope: "other-scope")
                == .deny(.invalidScope)
        )
        #expect(
            decision(policy, "https://example.com/ok", source: .initial, generation: 2)
                == .deny(.staleGeneration)
        )
        #expect(
            decision(policy, nil, source: .action) == .deny(.missingURL)
        )
    }

    @Test("explicit address authorization is one host and does not create full access")
    func explicitAuthorizationIsBounded() {
        var policy = BrowserNavigationPolicy()
        let authorized = policy.authorize(url("https://example.com/path"))
        #expect(authorized)
        #expect(policy.allowedHosts == Set(["example.com"]))
        #expect(
            decision(policy, "https://example.com/next", source: .response).isAllowed
        )
        #expect(
            decision(
                policy,
                "https://other.example.net/next",
                source: .redirect,
                currentURL: url("https://example.com/path")
            ) == .deny(.crossOriginNotAuthorized)
        )
    }

    @Test("about blank stays local while file and app links stay blocked")
    func localPreviewDoesNotWidenWebPolicy() {
        let policy = BrowserNavigationPolicy(allowedDomains: [])
        #expect(decision(policy, "about:blank", source: .initial).isAllowed)
        #expect(
            decision(policy, "about:blank?mode=preview", source: .initial)
                == .deny(.unsupportedScheme)
        )
        #expect(
            decision(policy, "about:blank#preview", source: .initial)
                == .deny(.unsupportedScheme)
        )
        #expect(!decision(policy, "file:///tmp/preview.html", source: .initial).isAllowed)
        #expect(!decision(policy, "miniscanvas://canvas/1", source: .initial).isAllowed)
    }

    @Test("pending local HTML accepts only an exact bound WebKit document identity")
    func pendingLocalHTMLDocumentIdentityIsExactAndScoped() {
        #expect(pendingLocalHTMLDecision("about:blank") == .allow)
        #expect(pendingLocalHTMLDecision("about:srcdoc") == .allow)
        // The normalized empty-path callback is terminal-only; generic policy
        // callbacks continue to reject it even while local HTML is pending.
        #expect(pendingLocalHTMLDecision("about:") == .deny(.unsupportedScheme))
        #expect(pendingLocalHTMLDecision("about:?mode=preview") == .deny(.unsupportedScheme))
        #expect(pendingLocalHTMLDecision("about:#preview") == .deny(.unsupportedScheme))
        #expect(pendingLocalHTMLDecision("about:blank?mode=preview") == .deny(.unsupportedScheme))
        #expect(pendingLocalHTMLDecision("about:blank#preview") == .deny(.unsupportedScheme))
        #expect(pendingLocalHTMLDecision("about:srcdoc?mode=preview") == .deny(.unsupportedScheme))
        #expect(pendingLocalHTMLDecision("about:srcdoc#preview") == .deny(.unsupportedScheme))
        #expect(
            pendingLocalHTMLDecision("about:blank", boundIdentityRawURL: "about:blank")
                == .allow
        )
        #expect(
            pendingLocalHTMLDecision("about:srcdoc", boundIdentityRawURL: "about:blank")
                == .deny(.unsupportedScheme)
        )

        // Non-local schemes remain governed by the ordinary navigation policy.
        for rawURL in [
            "file:///tmp/preview.html",
            "data:text/html,preview",
            "javascript:alert(1)",
            "miniscanvas://canvas/1"
        ] {
            #expect(pendingLocalHTMLDecision(rawURL) == nil)
        }

        // The exception is attached to a pending nil-baseURL load only.
        #expect(pendingLocalHTMLDecision("about:blank", requestIsPending: false) == nil)
        #expect(
            pendingLocalHTMLDecision("about:blank", pendingSource: .action)
                == .deny(.unsupportedScheme)
        )
        #expect(
            pendingLocalHTMLDecision(
                policy: BrowserNavigationPolicy(allowedDomains: [], allowsLocalContent: false),
                "about:srcdoc"
            ) == .deny(.unsupportedScheme)
        )

        // A new-window denial is preserved by the normal policy gate.
        #expect(
            pendingLocalHTMLDecision(
                "about:blank",
                requestIsPending: true,
                callbackSource: .newWindow
            ) == nil
        )
        #expect(
            decision(BrowserNavigationPolicy(), "about:blank", source: .newWindow)
                == .deny(.newWindowNotAllowed)
        )
    }

    @Test("normalized about empty path requires verified terminal ownership")
    func normalizedAboutEmptyPathRequiresVerifiedTerminalOwnership() {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let differentRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(pendingLocalHTMLTerminalDecision("about:") == .allow)

        // URL shape alone is never authority: require the current request,
        // continuation, source view, active navigation and local-load state.
        #expect(
            pendingLocalHTMLTerminalDecision(
                "about:", terminalRequestID: requestID, activeRequestID: differentRequestID
            ) == nil
        )
        #expect(pendingLocalHTMLTerminalDecision("about:", terminalRequestID: nil) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", hasPendingContinuation: false) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", sourceIsOwner: false) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", navigationMatchesActive: false) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", requestIsPending: false) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", allowsLocalContent: false) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", pendingSource: .action) == nil)
        #expect(pendingLocalHTMLTerminalDecision("about:", resourceIsLive: false) == nil)
        #expect(
            pendingLocalHTMLTerminalDecision(
                "about:", boundIdentityRawURL: "about:blank"
            ) == nil
        )
        #expect(
            pendingLocalHTMLTerminalDecision(
                "about:", baseDecision: .deny(.staleGeneration)
            ) == nil
        )
        #expect(pendingLocalHTMLTerminalDecision("about:", baseDecision: .allow) == nil)

        // Only the observed parsed identity is eligible; do not normalize or
        // strip URL components to turn other about/custom URLs into it.
        for rawURL in [
            "about:?mode=preview",
            "about:#preview",
            "about:/",
            "about://example.com/",
            "about:blank",
            "about:srcdoc",
            "about:config",
            "file:///tmp/preview.html",
            "data:text/html,preview",
            "javascript:alert(1)",
            "miniscanvas://canvas/1"
        ] {
            #expect(pendingLocalHTMLTerminalDecision(rawURL) == nil)
        }
    }

    @Test("WebKit NSURL opaque about identities retain the existing local HTML contract")
    func legacyNSURLOpaqueIdentityRetainsLocalHTMLContract() throws {
        for rawIdentity in ["about:blank", "about:srcdoc"] {
            let nsURL: NSURL = try #require(NSURL(string: rawIdentity))
            let legacy: URL = nsURL as URL
            #expect(legacy.absoluteString == rawIdentity)
            // The same Foundation representation seen in real WK action callbacks.
            #expect(legacy.path.isEmpty)
            let base = BrowserNavigationPolicy().decision(
                for: legacy, source: .action, scopeID: scopeID,
                expectedScopeID: scopeID, generation: 1, expectedGeneration: 1
            )
            #expect(base == .deny(.unsupportedScheme))
            #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
                for: legacy, baseDecision: base, requestIsPending: true,
                allowsLocalContent: true, pendingNavigationSource: .initial,
                callbackSource: .action
            ) == .allow)
        }
    }

    @Test("NSURL identity compatibility preserves pending and exact-document boundaries")
    func legacyNSURLIdentityPreservesLocalHTMLBoundaries() throws {
        let nsURL: NSURL = try #require(NSURL(string: "about:blank"))
        let legacy: URL = nsURL as URL
        #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
            for: legacy, baseDecision: .deny(.unsupportedScheme),
            requestIsPending: false, allowsLocalContent: true,
            pendingNavigationSource: .initial, callbackSource: .action
        ) == nil)
        #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
            for: legacy, baseDecision: .deny(.unsupportedScheme),
            requestIsPending: true, allowsLocalContent: false,
            pendingNavigationSource: .initial, callbackSource: .action
        ) == .deny(.unsupportedScheme))
        #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
            for: legacy, baseDecision: .deny(.unsupportedScheme),
            requestIsPending: true, allowsLocalContent: true,
            pendingNavigationSource: .action, callbackSource: .action
        ) == .deny(.unsupportedScheme))
        #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
            for: legacy, baseDecision: .deny(.newWindowNotAllowed),
            requestIsPending: true, allowsLocalContent: true,
            pendingNavigationSource: .initial, callbackSource: .newWindow
        ) == nil)
        #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
            for: legacy, baseDecision: .deny(.unsupportedScheme),
            requestIsPending: true, allowsLocalContent: true,
            pendingNavigationSource: .initial, callbackSource: .response,
            boundIdentity: url("about:srcdoc")
        ) == .deny(.unsupportedScheme))
        for rawIdentity in [
            "about:", "about:/", "about:config", "about:blank?preview=1",
            "about:blank#preview", "about:%62lank", "about://example.com/blank",
            "file:///tmp/owned-preview.html", "data:text/html,owned-preview",
            "javascript:void(0)", "miniscanvas://owned-preview"
        ] {
            let nsURL: NSURL = try #require(NSURL(string: rawIdentity))
            let value: URL = nsURL as URL
            #expect(BrowserSession.pendingLocalHTMLDocumentDecision(
                for: value, baseDecision: .deny(.unsupportedScheme),
                requestIsPending: true, allowsLocalContent: true,
                pendingNavigationSource: .initial, callbackSource: .action
            ) != .allow)
        }
    }
}
