import Foundation
import Testing
import WebKit
@testable import MinisCore

/// Pure D-BROWSER-07 navigation callback contract. These tests do not start
/// WebKit and do not claim that fetch/XHR subresource writes are intercepted.
struct P3AcceptanceM06BrowserNavigationSideEffectTests {
    @Test("form submit and resubmit cannot send a mutating navigation")
    func formSubmissionMethodsFailClosed() {
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .formSubmitted,
            httpMethod: "POST",
            actionRequestsDownload: false
        ) == .deny(.formSubmissionNotAuthorized))
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .formResubmitted,
            httpMethod: "PUT",
            actionRequestsDownload: false
        ) == .deny(.formSubmissionNotAuthorized))
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .formSubmitted,
            httpMethod: nil,
            actionRequestsDownload: false
        ) == .deny(.formSubmissionNotAuthorized))
    }

    @Test("ordinary GET and HEAD navigation retain their URL and download gates")
    func readMethodsKeepExistingDecisions() {
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .other,
            httpMethod: "GET",
            actionRequestsDownload: false
        ) == .allow)
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .formSubmitted,
            httpMethod: "head",
            actionRequestsDownload: false
        ) == .allow)
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .formResubmitted,
            httpMethod: "GET",
            actionRequestsDownload: true
        ) == .deny(.downloadNotAuthorized))
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .other,
            httpMethod: nil,
            actionRequestsDownload: false,
            allowsLocalBootstrapWithoutMethod: true
        ) == .allow)
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .deny(.crossOriginNotAuthorized),
            navigationType: .other,
            httpMethod: "GET",
            actionRequestsDownload: false
        ) == .deny(.crossOriginNotAuthorized))
    }

    @Test("implicit browser GET navigation types accept nil methods and preserve gates")
    func implicitGETNavigationTypesAllowNilMethod() {
        for navigationType in [WKNavigationType.linkActivated, .backForward, .reload] {
            #expect(BrowserSession.navigationActionDecision(
                navigationDecision: .allow,
                navigationType: navigationType,
                httpMethod: nil,
                actionRequestsDownload: false
            ) == .allow)
        }
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .allow,
            navigationType: .linkActivated,
            httpMethod: nil,
            actionRequestsDownload: true
        ) == .deny(.downloadNotAuthorized))
        #expect(BrowserSession.navigationActionDecision(
            navigationDecision: .deny(.crossOriginNotAuthorized),
            navigationType: .linkActivated,
            httpMethod: nil,
            actionRequestsDownload: false
        ) == .deny(.crossOriginNotAuthorized))
    }

    @Test("unknown or non-read request methods fail closed")
    func missingAndOtherMethodsAreDenied() {
        let methods: [String?] = [nil, "", "  ", "PATCH", "POST"]
        for method in methods {
            #expect(BrowserSession.navigationActionDecision(
                navigationDecision: .allow,
                navigationType: .other,
                httpMethod: method,
                actionRequestsDownload: false
            ) == .deny(.requestMethodNotAuthorized))
        }
    }

    @Test("method denial remains a structured browser tool refusal")
    func methodDenialHasAStableConsumerReason() throws {
        let raw = try BrowserToolResponse.navigationDenied(
            action: "navigate",
            scopeID: "fixture-scope",
            denial: .formSubmissionNotAuthorized
        )
        let decoded = try JSONDecoder().decode(
            BrowserToolResponse.self, from: Data(raw.utf8)
        )
        #expect(decoded.outcome == "denied")
        #expect(decoded.refusalReason == "navigation_denied:form_submission_not_authorized")
        #expect(decoded.result == nil)
    }
}
