import Foundation
import Testing
@testable import MinisCanvasApp
import MinisCore

/// Exercises the state and effect dispatcher consumed by BrowserTabView.
/// Navigation closures are boundary observers, not WebKit/network substitutes.
/// Actual WKWebView loads remain a separate package-field/UI check.
@Suite("Browser tab initial activation authorization", .serialized)
@MainActor
struct BrowserInitialActivationAuthorizationTests {
    @Test("ordinary first activation emits no host authorization or navigation")
    func ordinaryFirstActivationHasNoAddressEffects() async throws {
        var state = BrowserNavigationState()
        let action = state.activate(fieldInitialURL: nil)
        var authorizations = 0
        var navigations = 0
        var policy = BrowserNavigationPolicy()

        try await BrowserAddressNavigation.dispatch(action, authorize: { target in
            authorizations += 1
            return policy.authorize(target)
        }, navigate: { _ in navigations += 1 })

        #expect(action == .none)
        #expect(state.phase == .idle)
        #expect(state.requestID == 0)
        #expect(state.lastSuccessfulURL == nil)
        #expect(authorizations == 0)
        #expect(navigations == 0)
        #expect(policy.allowedHosts.isEmpty)
    }

    @Test("ordinary activation cannot reinterpret an existing address as a new request")
    func ordinaryActivationPreservesExistingRequestIdentity() throws {
        var state = BrowserNavigationState()
        guard case .navigate(let requestID, let target) = state.start(
            rawInput: "https://explicit.example/path"
        ) else {
            Issue.record("explicit address did not produce a request")
            return
        }
        let completed = state.complete(requestID: requestID, target: target, result: .success)
        #expect(completed)
        let before = state
        #expect(state.activate(fieldInitialURL: nil) == .none)
        #expect(state == before)
    }

    @Test("explicit user address still authorizes exactly its host before navigation")
    func explicitAddressKeepsOriginalAuthorizationBoundary() async throws {
        var state = BrowserNavigationState()
        #expect(state.activate(fieldInitialURL: nil) == .none)
        let action = state.start(rawInput: "https://explicit.example/path")
        var policy = BrowserNavigationPolicy()
        var effects: [String] = []
        try await BrowserAddressNavigation.dispatch(action, authorize: { target in
            effects.append("authorize")
            return policy.authorize(target)
        }, navigate: { target in
            effects.append("navigate")
            #expect(target.absoluteString == "https://explicit.example/path")
        })
        #expect(effects == ["authorize", "navigate"])
        #expect(policy.allowedHosts == Set(["explicit.example"]))
        #expect(policy.decision(
            for: URL(string: "https://other.example/path"), source: .initial
        ) == .deny(.domainNotAuthorized))
        let subdomain = try #require(URL(string: "https://sub.explicit.example/path"))
        #expect(policy.decision(for: subdomain, source: .initial) == .deny(.domainNotAuthorized))
        let agentPolicy = BrowserNavigationPolicy(allowedDomains: ["explicit.example"])
        #expect(agentPolicy.decision(for: subdomain, source: .initial).isAllowed)
    }

    @Test("retry dispatch cannot grant an address that never reached authorization")
    func retryRechecksWithoutCreatingAnAddressGrant() async throws {
        var state = BrowserNavigationState()
        guard case .navigate(let requestID, let target) = state.start(rawInput: "https://retry.example") else {
            Issue.record("The submitted address must enter the loading state")
            return
        }
        let completed = state.complete(requestID: requestID, target: target,
            result: .failure("resource acquisition failed"))
        try #require(completed)
        let retry = state.retry()
        var policy = BrowserNavigationPolicy()
        var authorizations = 0
        var navigations = 0
        do {
            try await BrowserAddressNavigation.dispatch(retry, authorize: { url in
                authorizations += 1
                return policy.authorize(url)
            }, navigate: { url in
                guard policy.decision(for: url, source: .initial).isAllowed else {
                    throw BrowserError.navigationDenied(.domainNotAuthorized)
                }
                navigations += 1
            })
            Issue.record("Retry without a prior grant must remain blocked")
        } catch BrowserError.navigationDenied(let denial) {
            #expect(denial == .domainNotAuthorized)
        }
        #expect(authorizations == 0)
        #expect(navigations == 0)
        #expect(policy.allowedHosts.isEmpty)
    }

    @Test("opted-in fixed field page keeps its controlled loopback address dispatch")
    func fixedLocalFieldActivationStillDispatches() async throws {
        var state = BrowserNavigationState()
        let action = state.activate(fieldInitialURL: BrowserLocalPackageFieldFixture.localURL)
        var policy = BrowserNavigationPolicy()
        var authorizations = 0
        var targets: [URL] = []
        try await BrowserAddressNavigation.dispatch(action, authorize: { target in
            authorizations += 1
            return policy.authorize(target)
        }, navigate: { target in targets.append(target) })
        #expect(authorizations == 1)
        #expect(targets == [BrowserLocalPackageFieldFixture.localURL])
        #expect(policy.allowedHosts == Set(["127.0.0.1"]))
        #expect(state.phase == .loading(
            target: BrowserLocalPackageFieldFixture.localURL, previousURL: nil
        ))
    }

    @Test("automatic activation never accepts an external or nonfixture override")
    func unrecognizedInitialOverrideHasNoAddressEffects() async throws {
        for raw in ["https://example.com", "http://127.0.0.1:22872/index.html", "about:blank"] {
            var state = BrowserNavigationState()
            let url = try #require(URL(string: raw))
            let action = state.activate(fieldInitialURL: url)
            var authorizations = 0
            var navigations = 0
            try await BrowserAddressNavigation.dispatch(action, authorize: { _ in
                authorizations += 1
                return true
            }, navigate: { _ in navigations += 1 })
            #expect(action == .none)
            #expect(state.phase == .idle)
            #expect(authorizations == 0)
            #expect(navigations == 0)
        }
    }

    @Test("address authorization denial still prevents navigation")
    func explicitDenialDoesNotDispatchNavigation() async throws {
        var state = BrowserNavigationState()
        let action = state.start(rawInput: "https://explicit.example")
        var authorizations = 0
        var navigations = 0
        do {
            try await BrowserAddressNavigation.dispatch(action, authorize: { _ in
                authorizations += 1
                return false
            }, navigate: { _ in navigations += 1 })
            Issue.record("a denied address must keep the existing typed refusal")
        } catch BrowserError.navigationDenied(let denial) {
            #expect(denial == .domainNotAuthorized)
        }
        #expect(authorizations == 1)
        #expect(navigations == 0)
    }

    @Test("unsafe user schemes remain rejected without address effects")
    func invalidInputKeepsOriginalURLBoundary() async throws {
        for raw in ["about:blank", "file:///synthetic/index.html", "javascript:alert(1)"] {
            var state = BrowserNavigationState()
            let action = state.start(rawInput: raw)
            var effects = 0
            try await BrowserAddressNavigation.dispatch(action, authorize: { _ in
                effects += 1
                return true
            }, navigate: { _ in effects += 1 })
            #expect(action == .none)
            #expect(effects == 0)
            #expect(state.phase == .failure(.invalidInput(rawInput: raw), previousURL: nil))
        }
    }
}
