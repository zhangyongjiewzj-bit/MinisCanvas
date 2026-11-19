import Foundation
import Testing
@testable import MinisCore

/// 11/16：浏览器被拒时，给模型的工具结果文本带"去哪设置"的说明；结构化 detail 与规范码不变。
@Suite("Browser refusal model guidance 2026-11-16")
struct BrowserRefusalModelGuidance20261116Tests {
    private let expectedGuidance =
        "该网站未被允许访问。请告诉用户：到设置 → 智能体运行 → 运行安全上限 → 允许访问的网站，保存后新回合生效。"

    @Test("domain and cross-origin refusals carry the fixed settings guidance")
    func guidanceForAuthorizationRefusals() {
        for denial in [BrowserNavigationPolicy.Denial.domainNotAuthorized, .crossOriginNotAuthorized] {
            #expect(BrowserNavigationPolicy.modelFacingGuidance(
                forBrowserRefusalReason: "navigation_denied:" + denial.rawValue) == expectedGuidance)
        }
    }

    @Test("other refusals and nil carry no guidance")
    func noGuidanceForOtherReasons() {
        #expect(BrowserNavigationPolicy.modelFacingGuidance(forBrowserRefusalReason: nil) == nil)
        #expect(BrowserNavigationPolicy.modelFacingGuidance(forBrowserRefusalReason: "write_authorization_required") == nil)
        #expect(BrowserNavigationPolicy.modelFacingGuidance(forBrowserRefusalReason: "invalid_scope") == nil)
        #expect(BrowserNavigationPolicy.modelFacingGuidance(
            forBrowserRefusalReason: "navigation_denied:" + BrowserNavigationPolicy.Denial.downloadNotAuthorized.rawValue) == nil)
    }

    @Test("denied browser result feedback appends guidance while detail keeps the canonical code")
    func terminalFeedbackAppendsGuidance() throws {
        let raw = try BrowserToolResponse.navigationDenied(
            action: "navigate", scopeID: "scope-a", denial: .domainNotAuthorized)
        let terminal = try #require(AgentLoop.browserTerminal(
            toolName: BrowserTool.toolName, input: ["action": "navigate"], output: raw))
        #expect(terminal.isError)
        #expect(terminal.status == .failed)
        #expect(terminal.feedback == raw + "\n" + expectedGuidance)
        #expect(terminal.detail?.refusalReason == "navigation_denied:domain_not_authorized")
        #expect(terminal.detail?.outcome == "denied")
    }

    @Test("a denial without settings guidance keeps the raw JSON as feedback")
    func terminalFeedbackUnchangedForWriteDenial() throws {
        let raw = try BrowserToolResponse(outcome: "denied", action: "click", scopeID: "scope-a",
            refusalReason: "write_authorization_required").encoded()
        let terminal = try #require(AgentLoop.browserTerminal(
            toolName: BrowserTool.toolName, input: ["action": "click"], output: raw))
        #expect(terminal.feedback == raw)
    }
}
