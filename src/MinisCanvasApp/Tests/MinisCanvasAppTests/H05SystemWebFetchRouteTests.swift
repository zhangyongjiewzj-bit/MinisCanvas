import Foundation
import CFNetwork
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("H05 exact URL system proxy policy classification")
struct H05SystemWebFetchRouteTests {
    private func classify(_ types: [String?], present: Bool = true,
                          automatic: [Bool?] = [false, false],
                          environment: Bool = false, app: Bool = false) -> WebFetchPinnedRoute {
        H05SystemWebFetchRoute.classify(systemSettingsPresent: present,
            automaticProxyFlags: automatic, orderedProxyTypes: types,
            environmentDirectivePresent: environment, appProxyDirectivePresent: app)
    }

    @Test("only an explicit single None policy confirms direct")
    func explicitSingleNone() {
        #expect(classify([kCFProxyTypeNone as String]) == .directConfirmed)
        #expect(classify([kCFProxyTypeNone as String], present: false) == .unknown)
        #expect(classify([]) == .unknown)
        #expect(classify([nil]) == .unknown)
    }

    @Test("ordered proxy and direct fallback never become direct")
    func fallbackAndProxy() {
        #expect(classify([kCFProxyTypeHTTP as String, kCFProxyTypeNone as String]) == .proxyRequiresExistingRoute)
        #expect(classify([kCFProxyTypeNone as String, kCFProxyTypeSOCKS as String]) == .proxyRequiresExistingRoute)
        #expect(classify([kCFProxyTypeAutoConfigurationURL as String]) == .proxyRequiresExistingRoute)
    }

    @Test("PAC automatic and explicit environment or App directives keep their route")
    func explicitDirectives() {
        let none = [kCFProxyTypeNone as String]
        #expect(classify(none, automatic: [true, false]) == .proxyRequiresExistingRoute)
        #expect(classify(none, automatic: [false, true]) == .proxyRequiresExistingRoute)
        #expect(classify(none, automatic: [nil, false]) == .unknown)
        #expect(classify(none, environment: true) == .proxyRequiresExistingRoute)
        #expect(classify(none, app: true) == .proxyRequiresExistingRoute)
    }
}
