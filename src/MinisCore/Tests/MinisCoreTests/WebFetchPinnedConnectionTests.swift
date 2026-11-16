import XCTest
@testable import MinisCore

final class WebFetchPinnedConnectionTests: XCTestCase {
    func testInvocationPinsNumericEndpointWithoutChangingTLSOrigin() throws {
        let endpoint = try WebFetchEndpoint(URL(string: "https://Allowed.com:8443/a?b=c")!)
        let invocation = try WebFetchPinnedCurlInvocation(endpoint: endpoint,
            address: WebFetchNumericAddress("93.184.216.34"), route: .directConfirmed)
        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/curl")
        XCTAssertEqual(invocation.arguments.first, "-q")
        XCTAssertTrue(invocation.arguments.contains("Allowed.com:8443:93.184.216.34:8443"))
        XCTAssertEqual(invocation.arguments.last, endpoint.url.absoluteString)
        XCTAssertTrue(invocation.arguments.contains("--write-out"))
        XCTAssertTrue(invocation.arguments.contains("\n\u{1}MINIS_REMOTE_IP:%{remote_ip}\u{2}\n"))
        XCTAssertFalse(invocation.arguments.contains("--insecure"))
        XCTAssertFalse(invocation.arguments.contains("-L"))
        XCTAssertFalse(invocation.arguments.contains("--location"))
        XCTAssertNil(invocation.environment["HOME"])
        XCTAssertNil(invocation.environment["HTTPS_PROXY"])
    }

    func testDynamicConsentCannotReachLocalOrPrivateAddress() throws {
        let endpoint = try WebFetchEndpoint(URL(string: "https://example.com/")!)
        for raw in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.0.1", "169.254.1.2", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2002:0a00:0001::1", "2001::1", "2001:db8::1", "2001:10::1", "2001:20::1", "198.51.100.1", "203.0.113.1"] {
            XCTAssertThrowsError(try WebFetchPinnedCurlInvocation(endpoint: endpoint,
                address: WebFetchNumericAddress(raw), route: .directConfirmed), raw)
        }

    }

    func testUnknownProxyRouteNeverBecomesSilentDirect() throws {
        XCTAssertThrowsError(try WebFetchPinnedCurlInvocation(
            endpoint: WebFetchEndpoint(URL(string: "https://example.com/")!),
            address: WebFetchNumericAddress("93.184.216.34"), route: .unknown)) { XCTAssertEqual($0 as? WebFetchPinnedError, .unsupportedRoute) }
    }


    func testTrailingDotPinMatchesActualURLAuthority() throws {
        let endpoint = try WebFetchEndpoint(URL(string: "https://allowed.com./")!)
        let invocation = try WebFetchPinnedCurlInvocation(endpoint: endpoint,
            address: WebFetchNumericAddress("93.184.216.34"), route: .directConfirmed)
        XCTAssertEqual(endpoint.host, "allowed.com")
        XCTAssertTrue(invocation.arguments.contains("allowed.com.:443:93.184.216.34:443"))
    }

    func testDisplayKeepsConfiguredHTTPAWhileBRejectsCleartext() throws {
        let url = URL(string: "http://Allowed.com.:8080/page")!
        XCTAssertEqual(try WebFetchApprovalDisplay.authority(for: url), "allowed.com:8080")
        XCTAssertThrowsError(try WebFetchEndpoint(url))
    }

    func testCredentialsAndNonnumericPinRejected() {
        XCTAssertThrowsError(try WebFetchEndpoint(URL(string: "https://allowed.com@evil.com/")!))
        XCTAssertThrowsError(try WebFetchNumericAddress("example.com"))
    }
}
