import Testing
import Foundation
@testable import MinisCanvasApp
@testable import MinisCore

// MARK: - AJ-34 浏览器 tab：URL 校验
// 只允许 http/https，拒绝 file://、javascript: 等协议及无主机名输入。

@Suite("AJ-34 浏览器 URL 校验")
struct BrowserURLValidationTests {

    @Test("http/https 合法输入被接受")
    func acceptsHttpAndHttps() {
        guard let url = BrowserURLValidator.validatedURL(from: "https://example.com") else {
            Issue.record("https://example.com 应被接受")
            return
        }
        #expect(url.absoluteString == "https://example.com")

        #expect(BrowserURLValidator.validatedURL(from: "http://example.com") != nil)
        #expect(BrowserURLValidator.validatedURL(from: "https://example.com/path?q=1") != nil)
    }

    @Test("无 scheme 的裸域名自动补 https://")
    func prependsHttpsForBareHost() {
        #expect(BrowserURLValidator.validatedURL(from: "example.com")?.scheme == "https")
        #expect(BrowserURLValidator.validatedURL(from: "www.example.com")?.absoluteString == "https://www.example.com")
    }

    @Test("file:// 被拒绝")
    func rejectsFileScheme() {
        #expect(BrowserURLValidator.validatedURL(from: "file:///etc/passwd") == nil)
        #expect(BrowserURLValidator.validatedURL(from: "file:///Users/alice/Desktop/report.pdf") == nil)
    }

    @Test("javascript: 与 data: 被拒绝")
    func rejectsOtherSchemes() {
        #expect(BrowserURLValidator.validatedURL(from: "javascript:alert(1)") == nil)
        #expect(BrowserURLValidator.validatedURL(from: "data:text/html,<script>") == nil)
        #expect(BrowserURLValidator.validatedURL(from: "ftp://example.com") == nil)
        #expect(BrowserURLValidator.validatedURL(from: "about:blank") == nil)
    }

    @Test("空串与纯空白被拒绝")
    func rejectsEmptyInput() {
        #expect(BrowserURLValidator.validatedURL(from: "") == nil)
        #expect(BrowserURLValidator.validatedURL(from: "   ") == nil)
    }

    @Test("无主机名输入被拒绝")
    func rejectsMissingHost() {
        #expect(BrowserURLValidator.validatedURL(from: "https://") == nil)
        #expect(BrowserURLValidator.validatedURL(from: "http:///path") == nil)
    }

    @Test("首尾空白被裁剪")
    func trimsWhitespace() {
        #expect(BrowserURLValidator.validatedURL(from: "  https://example.com  ")?.absoluteString == "https://example.com")
    }
}

// MARK: - AJ-34 浏览器生产消费者状态机

@Suite("AJ-34 浏览器导航状态")
struct BrowserNavigationConsumerTests {

    @Test("合法导航完成后显示成功页面")
    func validNavigationPublishesSuccess() {
        var state = BrowserNavigationState()
        let action = state.start(rawInput: "https://example.com")

        guard case .navigate(let requestID, let target) = action else {
            Issue.record("合法网址必须进入导航队列")
            return
        }
        #expect(state.phase == .loading(target: target, previousURL: nil))
        let transitionResult0 = state.complete(requestID: requestID, target: target, result: .success)
        #expect(transitionResult0)
        #expect(state.phase == .success(target))
        #expect(state.lastSuccessfulURL == target)
    }

    @Test("非法协议拒绝导航并保留上一合法页面")
    func invalidNavigationIsVisibleWithoutSideEffect() {
        var state = BrowserNavigationState()
        guard case .navigate(let requestID, let previous) = state.start(rawInput: "https://example.com") else {
            Issue.record("前置合法网址未进入导航")
            return
        }
        let transitionResult1 = state.complete(requestID: requestID, target: previous, result: .success)
        #expect(transitionResult1)

        let transitionResult2 = state.start(rawInput: "file:///etc/passwd") == .none
        #expect(transitionResult2)
        guard case .failure(let failure, let previousURL) = state.phase else {
            Issue.record("非法协议必须进入可见失败状态")
            return
        }
        #expect(previousURL == previous)
        #expect(failure.retryURL == nil)
        #expect(failure.message.contains("未执行导航"))
    }

    @Test("迟到的旧结果不能覆盖新导航，失败可重试")
    func staleCompletionCannotOverwriteNewRequest() {
        var state = BrowserNavigationState()
        guard case .navigate(let firstID, let firstTarget) = state.start(rawInput: "https://first.example") else {
            Issue.record("第一条导航未进入队列")
            return
        }
        guard case .navigate(let secondID, let secondTarget) = state.start(rawInput: "https://second.example") else {
            Issue.record("第二条导航未进入队列")
            return
        }

        let transitionResult3 = !state.complete(
            requestID: firstID,
            target: firstTarget,
            result: .failure("旧导航失败")
        )
        #expect(transitionResult3)
        #expect(state.phase == .loading(target: secondTarget, previousURL: nil))
        let transitionResult4 = state.complete(
            requestID: secondID,
            target: secondTarget,
            result: .failure("loopback 无法连接")
        )
        #expect(transitionResult4)
        guard case .failure(let failure, _) = state.phase else {
            Issue.record("当前失败必须可见")
            return
        }
        #expect(failure.retryURL == secondTarget)
        _ = state.retry()
        guard case .loading(let retryTarget, _) = state.phase else {
            Issue.record("真实失败必须提供可验证重试")
            return
        }
        #expect(retryTarget == secondTarget)
        #expect(state.requestID > secondID)
    }

    @Test("取消后迟到成功结果被丢弃")
    func cancellationInvalidatesPendingResult() {
        var state = BrowserNavigationState()
        guard case .navigate(let requestID, let target) = state.start(rawInput: "https://example.com") else {
            Issue.record("导航未进入队列")
            return
        }
        let transitionResult5 = state.cancel()
        #expect(transitionResult5)
        let transitionResult6 = !state.complete(requestID: requestID, target: target, result: .success)
        #expect(transitionResult6)
        guard case .failure(let failure, _) = state.phase else {
            Issue.record("取消必须留下可见状态")
            return
        }
        #expect(failure.retryURL == target)
    }
}

@MainActor
@Suite("AJ-34 浏览器资源生命周期 consumer")
struct BrowserTabResourceConsumerTests {

    @Test("ContextPanel 可见 tab 持有用户排除")
    func visibleTabIsExcludedFromIdleReclaim() throws {
        let session = BrowserSession(scopeID: "context-panel-visible", idleTimeoutMinutes: 1)
        session.setUserVisible(true)
        #expect(session.resourceState == .live)
        #expect(!session.reclaimIfIdle(at: Date().addingTimeInterval(3_600)))
        session.close()
    }

    @Test("BridgeStore 按设置快照装配 BrowserTool，并可刷新 idle policy")
    func bridgeStoreConsumesBrowserSettings() {
        let bridge = BridgeStore()
        let settings = BrowserSettings(
            userAgentPreset: .custom,
            customUserAgent: "Bridge-Browser-UA/1.0",
            viewportMode: .custom,
            customViewportWidth: 720,
            customViewportHeight: 512,
            idleTabTimeoutMinutes: 7
        )
        bridge.attachProductionServices(browserSettings: settings)

        #expect(bridge.productionBrowserTool?.session.idleTimeoutMinutes == 7)
        #expect(bridge.productionBrowserTool?.session.webView.customUserAgent == "Bridge-Browser-UA/1.0")
        #expect(bridge.productionBrowserTool?.session.webView.frame.size.width == 720)

        bridge.refreshProductionBrowserSettings(
            BrowserSettings(idleTabTimeoutMinutes: 9)
        )
        #expect(bridge.productionBrowserTool?.session.idleTimeoutMinutes == 9)
        bridge.productionBrowserTool?.session.close()
    }
}
