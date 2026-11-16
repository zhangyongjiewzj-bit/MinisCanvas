import Foundation
import Testing
import WebKit
@testable import MinisCore

/// Lifecycle tests deliberately use the deterministic `reclaimIfIdle(at:)`
/// seam. They do not start a network load or require a GUI WebKit process.
@MainActor
struct BrowserIdleLifecycleTests {

    @Test
    func idleEligibleReclaimsAndReopensOneScopedResource() throws {
        let session = BrowserSession(
            scopeID: "idle-lifecycle-scope",
            userAgent: "Lifecycle-UA/1.0",
            idleTimeoutMinutes: 1
        )
        let original = session.webView
        let originalGeneration = session.resourceGeneration

        session.setUserVisible(false)
        #expect(session.resourceState == .idleEligible)
        #expect(!session.reclaimIfIdle(at: Date().addingTimeInterval(59)))
        #expect(session.resourceState == .idleEligible)
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        #expect(session.resourceState == .reclaimed)
        #expect(session.resourceGeneration > originalGeneration)
        #expect(session.webView !== original)
        #expect(
            session.webView.configuration.websiteDataStore
                === original.configuration.websiteDataStore
        )

        #expect(session.reopenResource())
        #expect(session.resourceState == .live)
        #expect(session.webView !== original)
        #expect(session.webView.configuration.websiteDataStore
                === original.configuration.websiteDataStore)
        #expect(session.webView.customUserAgent == "Lifecycle-UA/1.0")
        session.close()
    }

    @Test
    func activeLeaseAndUserVisibleTabCannotBeReclaimed() throws {
        let session = BrowserSession(scopeID: "lease-scope", idleTimeoutMinutes: 1)
        let lease = try session.acquireOperationLease()
        session.setUserVisible(false)
        #expect(session.resourceState == .live)
        #expect(!session.reclaimIfIdle(at: Date().addingTimeInterval(3_600)))
        #expect(session.activeOperationCount == 1)

        session.releaseOperationLease(lease)
        #expect(session.resourceState == .idleEligible)

        session.setUserVisible(true)
        #expect(session.resourceState == .live)
        #expect(!session.reclaimIfIdle(at: Date().addingTimeInterval(3_600)))
        #expect(session.resourceState == .live)
        session.close()
    }

    @Test
    func repeatedAcquireAfterReclaimSharesOneReplacement() throws {
        let session = BrowserSession(scopeID: "single-reopen-scope", idleTimeoutMinutes: 1)
        session.setUserVisible(false)
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        let generationBeforeAcquire = session.resourceGeneration

        let first = try session.acquireOperationLease()
        let reopenedView = session.webView
        let second = try session.acquireOperationLease()
        #expect(session.resourceState == .live)
        #expect(session.resourceGeneration == generationBeforeAcquire + 1)
        #expect(session.webView === reopenedView)
        #expect(first.generation == second.generation)
        #expect(session.activeOperationCount == 2)

        session.releaseOperationLease(first)
        session.releaseOperationLease(second)
        #expect(session.activeOperationCount == 0)
        #expect(session.resourceState == .idleEligible)
        session.close()
    }

    @Test
    func staleIdentityAndLateLeaseCannotReviveReclaimedResource() throws {
        let session = BrowserSession(scopeID: "generation-scope", idleTimeoutMinutes: 1)
        let oldIdentity = session.identity
        let oldView = session.webView
        let oldLease = try session.acquireOperationLease()
        session.releaseOperationLease(oldLease)
        session.setUserVisible(false)
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        #expect(!session.accepts(oldIdentity))
        #expect(session.resourceState == .reclaimed)
        // Even if a queued callback reaches the old delegate, the detached
        // WebView identity cannot complete or resurrect the current resource.
        session.webView(oldView, didFinish: nil)
        #expect(session.resourceState == .reclaimed)

        let newLease = try session.acquireOperationLease()
        #expect(session.accepts(session.identity))
        #expect(!session.accepts(oldIdentity))
        #expect(session.activeOperationCount == 1)
        // A late release from the old generation is ignored and cannot
        // release the new operation.
        session.releaseOperationLease(oldLease)
        #expect(session.activeOperationCount == 1)
        session.releaseOperationLease(newLease)
        session.close()
    }

    @Test
    func settingsRefreshSurvivesReopenWithoutChangingScopeStore() throws {
        var settings = BrowserSettings(
            userAgentPreset: .custom,
            customUserAgent: "Custom-Lifecycle-UA/2.0",
            viewportMode: .custom,
            customViewportWidth: 640,
            customViewportHeight: 480,
            idleTabTimeoutMinutes: 2
        )
        let session = BrowserSession(scopeID: "settings-scope")
        session.apply(settings: settings)
        #expect(session.idleTimeoutMinutes == 2)
        #expect(session.webView.customUserAgent == "Custom-Lifecycle-UA/2.0")
        #expect(session.webView.frame.size.width == 640)
        #expect(session.webView.frame.size.height == 480)
        let dataStore = session.webView.configuration.websiteDataStore

        session.setUserVisible(false)
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(121)))
        #expect(session.reopenResource())
        #expect(session.webView.configuration.websiteDataStore === dataStore)
        #expect(session.webView.customUserAgent == "Custom-Lifecycle-UA/2.0")
        #expect(session.webView.frame.size.width == 640)
        #expect(session.webView.frame.size.height == 480)

        settings.idleTabTimeoutMinutes = 3
        session.apply(settings: settings)
        #expect(session.idleTimeoutMinutes == 3)
        session.close()
    }

    @Test
    func lateActivityCannotMoveIdleDeadlineBackward() {
        let session = BrowserSession(scopeID: "monotonic-activity-scope", idleTimeoutMinutes: 1)
        let anchor = Date()
        let newerActivity = anchor.addingTimeInterval(120)

        session.recordActivity(at: newerActivity)
        // A queued callback from before the newer activity must not shorten
        // the protection window and make the resource reclaimable early.
        session.recordActivity(at: anchor)
        session.setUserVisible(false)

        #expect(!session.reclaimIfIdle(at: anchor.addingTimeInterval(179)))
        #expect(session.reclaimIfIdle(at: anchor.addingTimeInterval(181)))
        session.close()
    }

    @Test
    func closeInvalidatesLeasesAndRefusesReopen() throws {
        let session = BrowserSession(scopeID: "closed-scope")
        let lease = try session.acquireOperationLease()
        session.close()
        #expect(session.resourceState == .closed)
        #expect(session.activeOperationCount == 0)
        #expect(!session.reopenResource())
        #expect(throws: BrowserError.resourceClosed) {
            _ = try session.acquireOperationLease()
        }
        // A late release is ignored and cannot alter the closed state.
        session.releaseOperationLease(lease)
        #expect(session.resourceState == .closed)
    }
}
