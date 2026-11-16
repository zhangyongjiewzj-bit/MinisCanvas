import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

@Suite("D-BROWSER-04 App URL boundary")
struct BrowserURLValidationIncrementTests {

    @Test("the App validator shares the Core web URL boundary")
    func appAndCoreRejectTheSameUnsafeInputs() {
        for raw in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>",
            "miniscanvas://open/settings",
            "https://user:password@example.com/private"
        ] {
            #expect(BrowserURLValidator.validatedURL(from: raw) == nil)
        }
        #expect(BrowserURLValidator.validatedURL(from: " https://example.com/docs ") != nil)
    }

    @Test("a bare domain is normalized before the shared policy sees it")
    func bareDomainRemainsAnExplicitHTTPSHost() throws {
        let url = try #require(BrowserURLValidator.validatedURL(from: "example.com"))
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(BrowserNavigationPolicy.isValidWebURL(url))
    }
}
