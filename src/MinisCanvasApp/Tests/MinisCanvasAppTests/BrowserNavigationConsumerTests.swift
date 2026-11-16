import Foundation
import Testing
import WebKit
@testable import MinisCanvasApp
@testable import MinisCore

/// WebKit owns every action, frame, response and window feature in these tests.
/// The custom scheme serves only memory bytes; no fixture request reaches a network.
@MainActor
private final class BrowserNavigationCallbackFixture: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
    let webView: WKWebView
    var action: ((WKNavigationAction, @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) -> Void)?
    var response: ((WKNavigationResponse, @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) -> Void)?
    var window: ((WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?)?
    var responseURL: URL?
    var dispatchCount = 0
    var finished = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Install the handler after NSObject initialization, before creating the view.
        let handler = BrowserNavigationMemoryHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: "browser-fixture")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        handler.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ path: String) {
        webView.load(URLRequest(url: URL(string: "browser-fixture://local/\(path)")!))
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        action = nil
        response = nil
        window = nil
    }

    func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "WebKit did not produce the required fixture callback within 10 seconds")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let action { action(navigationAction, decisionHandler) }
        else { decisionHandler(navigationAction.request.url?.scheme == "browser-fixture" ? .allow : .cancel) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let response { response(navigationResponse, decisionHandler) }
        else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        window?(configuration, navigationAction, windowFeatures)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        dispatchCount += 1
        let data = Data("<html><body><a id='popup' href='browser-fixture://local/popup' target='_blank'>Open</a></body></html>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: responseURL ?? urlSchemeTask.request.url!,
                                            mimeType: "text/html", expectedContentLength: data.count,
                                            textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Weak ownership avoids a configuration → handler → fixture → view cycle.
@MainActor
private final class BrowserNavigationMemoryHandler: NSObject, WKURLSchemeHandler {
    weak var owner: BrowserNavigationCallbackFixture?
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        owner?.webView(webView, start: urlSchemeTask)
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@Suite("D-BROWSER-04 App navigation consumer")
struct BrowserNavigationConsumerIncrementTests {

    @Test("the real action delegate cancels unsafe navigation exactly once before dispatch")
    @MainActor
    func actionDelegateCancelsBeforeRequestDispatch() async throws {
        let session = BrowserSession(scopeID: "delegate-action",
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["example.com"]))
        let fixture = BrowserNavigationCallbackFixture()
        defer { fixture.close(); session.close() }
        var decisions: [WKNavigationActionPolicy] = []
        fixture.action = { action, completion in
            #expect(action.targetFrame?.isMainFrame == true)
            session.webView(session.webView, decidePolicyFor: action) { policy in
                decisions.append(policy)
                completion(policy)
            }
        }
        fixture.load("blocked")
        try await fixture.wait { !decisions.isEmpty }
        #expect(decisions == [.cancel])
        #expect(decisions.count == 1)
        #expect(fixture.dispatchCount == 0)
    }

    @Test("the real response delegate cancels an unauthorized redirect exactly once")
    @MainActor
    func responseDelegateCancelsBeforeCommit() async throws {
        let session = BrowserSession(scopeID: "delegate-response",
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["example.com"]))
        let fixture = BrowserNavigationCallbackFixture()
        defer { fixture.close(); session.close() }
        let deniedURL = URL(string: "https://evil.example.net/redirect")!
        // This URL is response metadata only, supplied by the memory handler.
        fixture.responseURL = deniedURL
        var decisions: [WKNavigationResponsePolicy] = []
        fixture.response = { response, completion in
            #expect(response.response.url == deniedURL)
            #expect(response.isForMainFrame)
            session.webView(session.webView, decidePolicyFor: response) { policy in
                decisions.append(policy)
                completion(policy)
            }
        }
        fixture.load("response")
        try await fixture.wait { !decisions.isEmpty }
        #expect(decisions == [.cancel])
        #expect(decisions.count == 1)
        #expect(fixture.dispatchCount == 1)
        #expect(!fixture.finished)
    }

    @Test("the real UI delegate never creates an unauthorized new window")
    @MainActor
    func newWindowDelegateReturnsNoResource() async throws {
        let session = BrowserSession(scopeID: "delegate-window",
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["example.com"]))
        let fixture = BrowserNavigationCallbackFixture()
        defer { fixture.close(); session.close() }
        var windowCallbacks = 0
        fixture.window = { configuration, action, features in
            windowCallbacks += 1
            #expect(action.targetFrame == nil)
            let created = session.webView(session.webView, createWebViewWith: configuration,
                                          for: action, windowFeatures: features)
            #expect(created == nil)
            return created
        }
        fixture.load("page")
        try await fixture.wait { fixture.finished }
        _ = try await fixture.webView.evaluateJavaScript("document.getElementById('popup').click(); null")
        try await fixture.wait { windowCallbacks > 0 }
        #expect(windowCallbacks == 1)
        #expect(fixture.dispatchCount == 1)
    }

    @Test
    @MainActor
    func agentConsumerReceivesTheExistingDomainAllowlist() {
        let tool = BrowserTool(
            settings: .default,
            navigationPolicy: BrowserNavigationPolicy(allowedDomains: ["example.com"])
        )
        #expect(tool.session.navigationDecision(
            for: URL(string: "https://example.com/start"),
            source: .initial
        ).isAllowed)
        #expect(!tool.session.navigationDecision(
            for: URL(string: "https://evil.example.net/start"),
            source: .initial
        ).isAllowed)
        tool.session.close()
    }

    @Test("an invalid URL leaves the previous success visible")
    func invalidInputDoesNotReplaceLastPage() throws {
        var state = BrowserNavigationState()
        guard case .navigate(let requestID, let target) = state.start(rawInput: "https://example.com") else {
            Issue.record("合法地址未进入导航队列")
            return
        }
        let completed = state.complete(requestID: requestID, target: target, result: .success)
        #expect(completed)
        #expect(state.start(rawInput: "javascript:alert(1)") == .none)
        guard case .failure(let failure, let previousURL) = state.phase else {
            Issue.record("非法地址必须进入可见失败状态")
            return
        }
        #expect(previousURL == target)
        #expect(failure.retryURL == nil)
    }

    @Test("a policy denial is visible and cannot be mistaken for a load")
    func crossOriginDecisionIsExplicitlyDenied() {
        let policy = BrowserNavigationPolicy(allowedDomains: ["example.com"])
        let current = URL(string: "https://example.com/start")!
        let decision = policy.decision(
            for: URL(string: "https://evil.example.net/redirect"),
            source: .redirect,
            scopeID: "context-panel",
            expectedScopeID: "context-panel",
            generation: 4,
            expectedGeneration: 4,
            currentURL: current
        )
        #expect(decision == .deny(.crossOriginNotAuthorized))
        #expect(decision.refusalReason == "cross_origin_not_authorized")
        let denial = BrowserError.navigationDenied(.crossOriginNotAuthorized).localizedDescription
        #expect(denial.contains("地址栏"))
        #expect(denial.contains("设置 → 智能体运行 → 运行安全上限"))
        #expect(denial.contains("允许访问的网站"))
    }

    @Test("stale UI completion cannot cover a newer request")
    func staleCompletionRemainsDroppedAfterCancellation() {
        var state = BrowserNavigationState()
        guard case .navigate(let firstID, let firstTarget) = state.start(rawInput: "https://example.com/one") else {
            Issue.record("第一条导航未进入队列")
            return
        }
        guard case .navigate(let secondID, let secondTarget) = state.start(rawInput: "https://example.com/two") else {
            Issue.record("第二条导航未进入队列")
            return
        }
        let staleCompleted = state.complete(requestID: firstID, target: firstTarget, result: .success)
        #expect(!staleCompleted)
        let currentCompleted = state.complete(requestID: secondID, target: secondTarget, result: .failure("navigation denied"))
        #expect(currentCompleted)
        guard case .failure(let failure, _) = state.phase else {
            Issue.record("当前失败必须可见")
            return
        }
        #expect(failure == .failed(target: secondTarget, message: "navigation denied"))
        #expect(failure.message == "navigation denied。请检查地址或网络后重试。")
    }
}
