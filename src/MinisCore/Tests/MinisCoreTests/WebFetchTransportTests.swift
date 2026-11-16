import Foundation
import Testing
@testable import MinisCore

@Suite("H05 web_fetch synthetic contracts; no external requests")
struct WebFetchTransportTests {
    private func url(_ path: String) -> URL { URL(string: path)! }

    @Test func emptyDomainsDenyBeforeLoading() async throws {
        let fixture = WebFetchFixture()
        let transport = WebFetchTransport(allowedDomains: [], load: { request in try await fixture.load(request) })
        await #expect(throws: WebFetchError.policyDenied(.domainNotAuthorized)) {
            try await transport.fetch(url("https://example.test/"))
        }
        #expect(await fixture.requested.isEmpty)
    }

    @Test func credentialsAndNonWebSchemesNeverLoad() async throws {
        let fixture = WebFetchFixture()
        let transport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await fixture.load(request) })
        await #expect(throws: WebFetchError.policyDenied(.credentialsInURL)) {
            try await transport.fetch(url("https://user:pass@example.test/"))
        }
        await #expect(throws: WebFetchError.policyDenied(.unsupportedScheme)) {
            try await transport.fetch(url("file:///tmp/fixture"))
        }
        #expect(await fixture.requested.isEmpty)
    }

    @Test func redirectDestinationIsAuthorizedBeforeSecondLoad() async throws {
        let fixture = WebFetchFixture(routes: [
            "https://example.test/": .init(status: 302, headers: ["Location": "https://other.test/private"])
        ])
        let transport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await fixture.load(request) })
        await #expect(throws: WebFetchError.policyDenied(.crossOriginNotAuthorized)) {
            try await transport.fetch(url("https://example.test/"))
        }
        #expect(await fixture.requested == [url("https://example.test/")])
    }

    @Test func relativeRedirectAndAuthorizedSubdomainProduceInertText() async throws {
        let fixture = WebFetchFixture(routes: [
            "https://docs.example.test/": .init(status: 301, headers: ["Location": "/page"]),
            "https://docs.example.test/page": .init(status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: "<html><body><h1>Hello &amp; world</h1><script>BAD</script><p>Text</p></body></html>")
        ])
        let transport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await fixture.load(request) })
        let text = try await transport.fetch(url("https://docs.example.test/"))
        #expect(text == "Hello & world Text")
        #expect(await fixture.requested.count == 2)
    }

    @Test func httpsDowngradeIsDeniedEvenForAllowedDomain() async throws {
        let fixture = WebFetchFixture(routes: [
            "https://example.test/": .init(status: 302, headers: ["Location": "http://example.test/"])
        ])
        let transport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await fixture.load(request) })
        await #expect(throws: WebFetchError.policyDenied(.insecureRedirect)) {
            try await transport.fetch(url("https://example.test/"))
        }
        #expect(await fixture.requested.count == 1)
    }

    @Test func loopAndHopLimitFailWithoutExtraRequest() async throws {
        let loop = WebFetchFixture(routes: [
            "https://example.test/": .init(status: 302, headers: ["Location": "/"])
        ])
        let loopTransport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await loop.load(request) })
        await #expect(throws: WebFetchError.redirectLoop) {
            try await loopTransport.fetch(url("https://example.test/"))
        }
        #expect(await loop.requested.count == 1)
        var routes: [String: WebFetchFixture.Route] = [:]
        for i in 0...5 {
            routes["https://example.test/\(i)"] = .init(status: 302, headers: ["Location": "/\(i + 1)"])
        }
        let chain = WebFetchFixture(routes: routes)
        let chainTransport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await chain.load(request) })
        await #expect(throws: WebFetchError.redirectLimit) {
            try await chainTransport.fetch(url("https://example.test/0"))
        }
        #expect(await chain.requested.count == 6)
    }

    @Test func statusAndMissingLocationSurfaceErrors() async throws {
        for (status, expected) in [(404, WebFetchError.httpStatus(404)), (302, .missingRedirectLocation)] {
            let fixture = WebFetchFixture(routes: ["https://example.test/": .init(status: status)])
            let transport = WebFetchTransport(allowedDomains: ["example.test"], load: { request in try await fixture.load(request) })
            await #expect(throws: expected) { try await transport.fetch(url("https://example.test/")) }
        }
    }

    @Test func adapterCannotHideFollowedRedirectOrOversizedBody() async throws {
        let original = url("https://example.test/")
        let wrongURL = url("https://other.test/")
        let hidden = WebFetchTransport(allowedDomains: ["example.test"]) { _ in
            WebFetchHop(response: HTTPURLResponse(url: wrongURL, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!, body: Data())
        }
        await #expect(throws: WebFetchError.unexpectedRedirect) { try await hidden.fetch(original) }
        let huge = WebFetchTransport(allowedDomains: ["example.test"]) { target in
            WebFetchHop(response: HTTPURLResponse(url: target, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!,
                body: Data(repeating: 65, count: WebFetchTransport.maximumBytes + 1))
        }
        await #expect(throws: WebFetchError.responseTooLarge) { try await huge.fetch(original) }
    }

    @Test func cancellationPropagatesAndDoesNotBecomeEmptySuccess() async throws {
        let transport = WebFetchTransport(allowedDomains: ["example.test"]) { _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            try await transport.fetch(url("https://example.test/"))
        }
    }

    @Test func rendererRejectsBinaryAndUnsupportedEncoding() throws {
        #expect(throws: WebFetchError.unsupportedContentType) {
            try WebFetchRenderer.text(from: Data(), mimeType: "image/png", characterEncoding: nil)
        }
        #expect(throws: WebFetchError.unsupportedEncoding) {
            try WebFetchRenderer.text(from: Data(), mimeType: "text/html", characterEncoding: "shift_jis")
        }
        #expect(throws: WebFetchError.unsupportedEncoding) {
            try WebFetchRenderer.text(from: Data([0xff]), mimeType: "text/plain", characterEncoding: nil)
        }
    }
}

private actor WebFetchFixture {
    struct Route: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = ""
    }
    let routes: [String: Route]
    private(set) var requested: [URL] = []
    init(routes: [String: Route] = [:]) { self.routes = routes }
    func load(_ url: URL) throws -> WebFetchHop {
        requested.append(url)
        guard let route = routes[url.absoluteString] else { throw WebFetchError.invalidResponse }
        return WebFetchHop(response: HTTPURLResponse(url: url, statusCode: route.status,
            httpVersion: "HTTP/1.1", headerFields: route.headers)!, body: Data(route.body.utf8))
    }
}
