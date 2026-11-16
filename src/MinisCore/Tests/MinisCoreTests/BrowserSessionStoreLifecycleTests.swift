import Foundation
import Testing
import WebKit
@testable import MinisCore

/// P3-BROWSER-01 store-lifecycle and settings-authority tests (lane 135).
///
/// These pin the Cookie 语义 half of the canonical row: the scoped
/// `WKWebsiteDataStore` registry is the single source of truth for a
/// 登录态/Cookie/缓存/页面存储 boundary, an identity's store survives idle
/// reclaim, is shared by exactly the live sessions of that identity, and is
/// retired deterministically when the last live session closes — plus the
/// settings consumer clause (UA、窗口大小、空闲回收 must truly drive the
/// live resource and its reclaim timing, including after a reopen).
///
/// Like the lifecycle suites in `BrowserIdleLifecycleTests`, these tests
/// use the deterministic `reclaimIfIdle(at:)` seam and never start a
/// network load or require a GUI WebKit process.
@MainActor
struct BrowserSessionStoreLifecycleTests {

    private func structuredKey(_ marker: String, surface: BrowserSessionSurface = .userBrowser) -> BrowserScopeIsolationKey {
        BrowserScopeIsolationKey(
            surface: surface,
            profile: "profile-\(marker)",
            session: "session-\(marker)",
            workspace: "workspace-\(marker)"
        )
    }

    private func store(of session: BrowserSession) -> WKWebsiteDataStore {
        session.webView.configuration.websiteDataStore
    }

    /// While at least one live session of an identity remains, closing
    /// another session of the same identity must not disturb the shared
    /// store: a fresh session of that identity still joins the same slot.
    @Test
    func registrySlotSurvivesCloseOfAllButTheLastLiveSession() {
        let key = structuredKey("slot-survives")
        let first = BrowserSession(scope: BrowserSessionScope(key: key))
        let second = BrowserSession(scope: BrowserSessionScope(key: key))
        let sharedStore = store(of: first)
        #expect(store(of: second) === sharedStore)

        first.close()
        let third = BrowserSession(scope: BrowserSessionScope(key: key))
        #expect(store(of: third) === sharedStore)
        #expect(store(of: second) === sharedStore)
        second.close()
        third.close()
    }

    /// Closing the last live session of an identity retires the registry
    /// slot: a later session claiming the same identity starts from a fresh
    /// private store and cannot resurrect the closed generation's state.
    /// The next two sessions of the identity then share the new slot.
    @Test
    func closingLastLiveSessionRetiresTheIdentityStore() {
        let key = structuredKey("retire-slot")
        let first = BrowserSession(scope: BrowserSessionScope(key: key))
        let firstStore = store(of: first)
        first.close()

        let second = BrowserSession(scope: BrowserSessionScope(key: key))
        let third = BrowserSession(scope: BrowserSessionScope(key: key))
        #expect(store(of: second) !== firstStore)
        #expect(store(of: second) === store(of: third))
        second.close()
        third.close()
    }

    /// The count a session owns is released exactly once. Two closes of the
    /// same session must not consume the reference that a still-live
    /// sibling holds, so the identity's slot stays intact for it.
    @Test
    func repeatedCloseReleasesExactlyOneRegistryReference() {
        let key = structuredKey("double-close")
        let first = BrowserSession(scope: BrowserSessionScope(key: key))
        let second = BrowserSession(scope: BrowserSessionScope(key: key))
        let third = BrowserSession(scope: BrowserSessionScope(key: key))
        let sharedStore = store(of: first)

        first.close()
        first.close()
        second.close()

        // `third` is still live, so a new session of the same identity must
        // join `third`'s store. An over-decrement would have evicted the
        // slot when `second` closed and handed out a fresh store instead.
        let fourth = BrowserSession(scope: BrowserSessionScope(key: key))
        #expect(store(of: third) === sharedStore)
        #expect(store(of: fourth) === sharedStore)
        third.close()
        fourth.close()
    }

    /// The lifecycle rule is shape-neutral: a string-shaped legacy identity
    /// shares its slot among live sessions and is retired with the last
    /// live session, exactly like a structured four-tuple.
    @Test
    func legacyOpaqueIdentityFollowsTheSameCloseLifecycle() {
        let first = BrowserSession(scopeID: "lane135-legacy-opaque")
        let second = BrowserSession(scopeID: "lane135-legacy-opaque")
        let legacyStore = store(of: first)
        #expect(store(of: second) === legacyStore)

        first.close()
        let third = BrowserSession(scopeID: "lane135-legacy-opaque")
        #expect(store(of: third) === legacyStore)

        second.close()
        third.close()
        let fourth = BrowserSession(scopeID: "lane135-legacy-opaque")
        #expect(store(of: fourth) !== legacyStore)
        fourth.close()
    }

    /// Idle reclaim is not a close: it never touches the registry. The one
    /// live session re-binds the identical scoped store after reclaim and
    /// reopen, and a second session of the identity still joins it.
    @Test
    func reclaimAndReopenNeverTouchTheRegistrySlot() {
        let key = structuredKey("reclaim-keeps-slot", surface: .agentBrowser)
        let session = BrowserSession(scope: BrowserSessionScope(key: key), idleTimeoutMinutes: 1)
        let scopedStore = store(of: session)

        session.setUserVisible(false)
        #expect(session.resourceState == .idleEligible)
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        #expect(session.resourceState == .reclaimed)
        #expect(store(of: session) === scopedStore)
        #expect(session.reopenResource())
        #expect(store(of: session) === scopedStore)

        let sibling = BrowserSession(scope: BrowserSessionScope(key: key))
        #expect(store(of: sibling) === scopedStore)
        session.close()
        sibling.close()
    }

    /// The two surfaces of BROWSER-05 retire independently: fully closing
    /// the 用户浏览器 identity must not disturb a live Agent 浏览器
    /// identity that happens to share the session and workspace text.
    @Test
    func userAndAgentSurfacesReleaseIndependently() {
        let marker = "surface-independence"
        let userKey = structuredKey(marker, surface: .userBrowser)
        let agentKey = structuredKey(marker, surface: .agentBrowser)
        let user = BrowserSession(scope: BrowserSessionScope(key: userKey))
        let agent = BrowserSession(scope: BrowserSessionScope(key: agentKey))
        let agentStore = store(of: agent)
        #expect(store(of: user) !== agentStore)

        user.close()
        let nextUser = BrowserSession(scope: BrowserSessionScope(key: userKey))
        let nextAgent = BrowserSession(scope: BrowserSessionScope(key: agentKey))
        // The closed user identity started fresh; the still-live agent
        // identity keeps its slot.
        #expect(store(of: nextUser) !== store(of: agent))
        #expect(store(of: nextAgent) === agentStore)
        agent.close()
        nextUser.close()
        nextAgent.close()
    }

    /// An unverified scope (a claimed structure that cannot be proven) never
    /// enters the registry at all: every resource gets a private store, and
    /// closing such a session releases nothing it does not own.
    @Test
    func unverifiedScopesNeverEnterTheRegistryAndCloseSafely() {
        let brokenKey = BrowserScopeIsolationKey(
            surface: .userBrowser,
            profile: "   ",
            session: "lane135-unverified",
            workspace: "lane135-unverified"
        )
        #expect(!brokenKey.isValid)
        let first = BrowserSession(scope: BrowserSessionScope(key: brokenKey))
        let second = BrowserSession(scope: BrowserSessionScope(key: brokenKey))
        #expect(store(of: first) !== store(of: second))

        first.close()
        first.close()
        let third = BrowserSession(scope: BrowserSessionScope(key: brokenKey))
        #expect(store(of: third) !== store(of: second))
        second.close()
        third.close()
    }

    /// The default ephemeral scope is private per session and its close
    /// path touches no shared slot (its registry key is nil).
    @Test
    func ephemeralScopesStayPrivateAcrossClose() {
        let first = BrowserSession()
        let second = BrowserSession()
        #expect(store(of: first) !== store(of: second))
        first.close()
        let third = BrowserSession()
        #expect(store(of: third) !== store(of: second))
        second.close()
        third.close()
    }

    /// BROWSER-01 settings-consumer clause at unit level: one `apply` of the
    /// saved browser settings must drive the live WebView's UA and window
    /// size AND the idle-reclaim timing itself, and the values must survive
    /// a reclaim/reopen cycle, including a settings revision in between.
    @Test
    func browserSettingsDriveUAWindowSizeAndReclaimTimingAcrossReopen() {
        var settings = BrowserSettings(
            userAgentPreset: .custom,
            customUserAgent: "Lane135-UA/1.0",
            viewportMode: .custom,
            customViewportWidth: 640,
            customViewportHeight: 480,
            idleTabTimeoutMinutes: 1
        )
        let session = BrowserSession(scopeID: "lane135-settings-authority")
        session.apply(settings: settings)

        #expect(session.webView.customUserAgent == "Lane135-UA/1.0")
        #expect(session.webView.frame.size == CGSize(width: 640, height: 480))
        let scriptsAfterFirstApply = session.webView.configuration.userContentController.userScripts
        #expect(scriptsAfterFirstApply.count == 1)
        #expect(scriptsAfterFirstApply.first?.source.contains("width=640") == true)
        #expect(session.idleTimeoutMinutes == 1)

        // The applied one-minute timeout is the value the reclaim decision
        // consumes, not the default fifteen.
        session.setUserVisible(false)
        #expect(!session.reclaimIfIdle(at: Date().addingTimeInterval(59)))
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        #expect(session.resourceState == .reclaimed)
        let scopedStore = store(of: session)
        #expect(session.reopenResource())

        // The reopened resource is configured from the applied settings.
        #expect(store(of: session) === scopedStore)
        #expect(session.webView.customUserAgent == "Lane135-UA/1.0")
        let scriptsAfterReopen = session.webView.configuration.userContentController.userScripts
        #expect(scriptsAfterReopen.count == 1)
        #expect(scriptsAfterReopen.first?.source.contains("width=640") == true)

        // A revised settings snapshot moves every consumer together.
        settings.userAgentPreset = .desktopChrome
        settings.viewportMode = .custom
        settings.customViewportWidth = 1024
        settings.customViewportHeight = 768
        settings.idleTabTimeoutMinutes = 2
        session.apply(settings: settings)
        #expect(session.idleTimeoutMinutes == 2)
        #expect(session.webView.customUserAgent != "Lane135-UA/1.0")
        #expect(session.webView.configuration.userContentController.userScripts.first?.source.contains("width=1024") == true)
        session.setUserVisible(false)
        #expect(!session.reclaimIfIdle(at: Date().addingTimeInterval(119)))
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(121)))
        #expect(session.resourceState == .reclaimed)
        session.close()
    }
}
