import Foundation
import Testing
import WebKit
@testable import MinisCanvasApp
@testable import MinisCore

@MainActor
private final class BrowserPaneLifetimeFake: BrowserTabLifecycleResource {
    private(set) var hideCount = 0
    private(set) var retireCount = 0
    private(set) var isRetired = false

    func hideBrowserTab() { hideCount += 1 }

    func retireBrowserTab() {
        retireCount += 1
        isRetired = true
    }

    func canPublishLateResult() -> Bool { !isRetired }
}

@Suite("P3-BROWSER-08 浏览器面板资源归属")
@MainActor
struct P3AcceptanceM06_BrowserPaneLifetimeTests {
    private func waitForNavigation(in session: BrowserSession) async throws -> WKNavigation {
        for _ in 0..<200 {
            if let navigation = session.activeNavigation { return navigation }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try #require(session.activeNavigation,
                            "WebKit did not create the synthetic navigation handle")
    }

    @Test("a retired pane's late WebKit callback cannot settle the replacement pane")
    func lateNavigationAfterPaneSwitchCannotPublishIntoNewSession() async throws {
        let owner = BrowserTabSessionOwner()
        let workspace = "browser08-late-callback-workspace"
        let a = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: workspace)
        let b = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: workspace)
        let url = URL(string: "https://example.com/synthetic")!
        var firstState = BrowserNavigationState()
        var secondState = BrowserNavigationState()
        guard case .navigate(let firstRequest, _) = firstState.start(rawInput: url.absoluteString),
              case .navigate(let secondRequest, _) = secondState.start(rawInput: url.absoluteString)
        else {
            Issue.record("synthetic pane navigation did not enter the loading state")
            return
        }

        let first = BrowserSession(scope: BrowserTabView.userBrowserScope(
            for: a.sessionID, workspaceID: workspace))
        owner.retain(first, for: a)
        defer { owner.retire() }
        let firstView = first.webView
        let firstStore = firstView.configuration.websiteDataStore
        firstView.navigationDelegate = nil // Keep the genuine WKNavigation pending for controlled delivery.
        let firstLoad = Task { @MainActor in
            try await first.loadHTMLString("<html><body>synthetic A</body></html>")
        }
        let firstNavigation = try await waitForNavigation(in: first)

        // ContextPanelView retires on its trusted identity change; its old
        // child also invalidates the request token during onDisappear.
        owner.retire(ifDifferentFrom: b)
        firstState.invalidate()
        #expect(first.resourceState == .closed)
        #expect(firstView.navigationDelegate == nil)
        do {
            try await firstLoad.value
            Issue.record("retiring A must fail its pending navigation")
        } catch let error as BrowserError {
            #expect(error == .resourceClosed)
        } catch {
            Issue.record("unexpected retired-navigation error: \(error)")
        }

        let second = BrowserSession(scope: BrowserTabView.userBrowserScope(
            for: b.sessionID, workspaceID: workspace))
        owner.retain(second, for: b)
        #expect(second.webView !== firstView)
        #expect(second.webView.configuration.websiteDataStore !== firstStore)
        second.webView.navigationDelegate = nil
        let secondLoad = Task { @MainActor in
            try await second.loadHTMLString("<html><body>synthetic B</body></html>")
        }
        let secondNavigation = try await waitForNavigation(in: second)

        // An old terminal callback, even when misdelivered to B's delegate,
        // must not finish B's active navigation or publish A's UI result.
        first.webView(firstView, didFinish: firstNavigation)
        second.webView(firstView, didFinish: firstNavigation)
        second.webView(second.webView, didFinish: firstNavigation)
        second.webView(firstView, didFail: firstNavigation,
                       withError: NSError(domain: "synthetic-late-A", code: 1))
        #expect(second.activeNavigation === secondNavigation)
        let didCompleteFirst = firstState.complete(requestID: firstRequest, target: url,
                                                   result: .success)
        #expect(!didCompleteFirst)
        #expect(firstState.phase == .idle)
        #expect(secondState.phase == .loading(target: url, previousURL: nil))

        second.webView(second.webView, didFinish: secondNavigation)
        try await secondLoad.value
        let didCompleteSecond = secondState.complete(requestID: secondRequest, target: url,
                                                     result: .success)
        #expect(didCompleteSecond)
        #expect(secondState.phase == .success(url))
        #expect(second.activeNavigation == nil)
    }

    @Test("real WebView leases retire on pane switch and a restarted owner gets a fresh store")
    func realWebViewsRetireAcrossPaneSwitchAndOwnerRestart() throws {
        let owner = BrowserTabSessionOwner()
        let workspace = "browser08-synthetic-workspace"
        let a = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: workspace)
        let b = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: workspace)
        let scopeA = BrowserTabView.userBrowserScope(for: a.sessionID, workspaceID: workspace)
        let scopeB = BrowserTabView.userBrowserScope(for: b.sessionID, workspaceID: workspace)
        #expect(scopeA != scopeB)

        let first = BrowserSession(scope: scopeA, idleTimeoutMinutes: 1)
        let firstView = first.webView
        let firstIdentity = first.identity
        let firstStore = firstView.configuration.websiteDataStore
        let oldLease = try first.acquireOperationLease()
        owner.retain(first, for: a)
        owner.hide(first)
        #expect(first.resourceState == .live)
        #expect(first.activeOperationCount == 1)

        owner.retire(ifDifferentFrom: b)
        #expect(first.resourceState == .closed)
        #expect(first.activeOperationCount == 0)
        #expect(!first.accepts(firstIdentity))
        #expect(first.webView !== firstView)
        #expect(firstView.navigationDelegate == nil)
        #expect(firstView.uiDelegate == nil)
        #expect(owner.currentResource(for: a) == nil)

        let second = BrowserSession(scope: scopeB, idleTimeoutMinutes: 1)
        let secondView = second.webView
        let secondStore = secondView.configuration.websiteDataStore
        owner.retain(second, for: b)
        #expect(secondView !== firstView)
        #expect(secondStore !== firstStore)
        let currentLease = try second.acquireOperationLease()
        first.releaseOperationLease(oldLease)
        first.webView(firstView, didFinish: nil)
        #expect(second.activeOperationCount == 1)
        #expect(second.accepts(second.identity))
        #expect((owner.currentResource(for: b) as? BrowserSession) === second)
        second.releaseOperationLease(currentLease)

        owner.retire()
        #expect(second.resourceState == .closed)
        #expect(second.activeOperationCount == 0)
        #expect(secondView.navigationDelegate == nil)
        #expect(owner.currentResource(for: b) == nil)

        // A new panel owner after teardown must not rejoin the retired
        // WebView or cookie slot, even if the conversation identity repeats.
        let restartedOwner = BrowserTabSessionOwner()
        let restarted = BrowserSession(scope: scopeB, idleTimeoutMinutes: 1)
        restartedOwner.retain(restarted, for: b)
        #expect(restarted.webView !== secondView)
        #expect(restarted.webView.configuration.websiteDataStore !== secondStore)
        #expect((restartedOwner.currentResource(for: b) as? BrowserSession) === restarted)
        restartedOwner.retire()
        #expect(restarted.resourceState == .closed)
    }

    @Test("同会话短暂隐藏只暂停浏览器，重新显示仍持有同一资源")
    func shortTabHideRetainsCurrentSession() {
        let owner = BrowserTabSessionOwner()
        let identity = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: "workspace-a")
        let resource = BrowserPaneLifetimeFake()
        owner.retain(resource, for: identity)

        owner.hide(resource)
        owner.retire(ifDifferentFrom: identity)

        #expect(resource.hideCount == 1)
        #expect(resource.retireCount == 0)
        #expect((owner.currentResource(for: identity) as? BrowserPaneLifetimeFake) === resource)
    }

    @Test("A→B→A 与工作区变化均退休旧资源，迟到结果不能复活")
    func scopeChangesRetireOldSessionBeforeRebind() {
        let owner = BrowserTabSessionOwner()
        let sessionID = UUID()
        let a = BrowserPaneOwnerIdentity(sessionID: sessionID, workspaceID: "workspace-a")
        let b = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: "workspace-a")
        let newWorkspace = BrowserPaneOwnerIdentity(sessionID: b.sessionID, workspaceID: "workspace-b")
        let firstA = BrowserPaneLifetimeFake()
        owner.retain(firstA, for: a)

        // A queued old-pane callback cannot relabel the same resource as B.
        owner.retain(firstA, for: b)
        #expect(firstA.retireCount == 1)
        #expect(owner.currentResource(for: b) == nil)

        owner.retire(ifDifferentFrom: b)
        #expect(firstA.retireCount == 1)
        #expect(!firstA.canPublishLateResult())
        let resourceB = BrowserPaneLifetimeFake()
        owner.retain(resourceB, for: b)
        owner.hide(firstA)
        #expect(resourceB.hideCount == 0)

        owner.retire(ifDifferentFrom: newWorkspace)
        #expect(resourceB.retireCount == 1)
        let workspaceB = BrowserPaneLifetimeFake()
        owner.retain(workspaceB, for: newWorkspace)
        owner.retire(ifDifferentFrom: a)
        #expect(workspaceB.retireCount == 1)

        let secondA = BrowserPaneLifetimeFake()
        owner.retain(secondA, for: a)
        #expect(secondA !== firstA)
        #expect(firstA.retireCount == 1)
        #expect((owner.currentResource(for: a) as? BrowserPaneLifetimeFake) === secondA)
        owner.retire()
    }

    @Test("父面板退出显式关闭一次并释放唯一资源引用")
    func ownerTeardownRetiresAndReleasesResource() {
        let owner = BrowserTabSessionOwner()
        let identity = BrowserPaneOwnerIdentity(sessionID: UUID(), workspaceID: "workspace-a")
        weak var releasedResource: BrowserPaneLifetimeFake?
        do {
            let resource = BrowserPaneLifetimeFake()
            releasedResource = resource
            owner.retain(resource, for: identity)
            owner.retire()
            #expect(resource.retireCount == 1)
            owner.retire()
            #expect(resource.retireCount == 1)
        }
        #expect(owner.currentResource(for: identity) == nil)
        #expect(releasedResource == nil)
    }
}
