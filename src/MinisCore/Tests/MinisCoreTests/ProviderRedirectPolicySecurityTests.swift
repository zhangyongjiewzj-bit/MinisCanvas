import Foundation
import Testing
@testable import MinisCore

@Suite("Provider redirect policy security")
struct ProviderRedirectPolicySecurityTests {
    private static let resolutionSnapshot = ProviderAddressResolutionSnapshot(
        addressesByHost: [
            "api.example.com": ["93.184.216.34"],
            "other.example.com": ["93.184.216.35"]
        ]
    )

    @Test("same-origin redirects retain credential headers")
    func sameOriginRetainsHeaders() throws {
        let source = try #require(URL(string: "https://api.example.com/v1"))
        let destination = try #require(URL(string: "https://api.example.com/v1/responses"))
        var request = URLRequest(url: destination)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.setValue("provider-api-key", forHTTPHeaderField: "X-API-Key")
        request.setValue("session-cookie", forHTTPHeaderField: "Cookie")

        let redirected = try #require(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: request,
            hopCount: 1,
            visitedCanonicalURLs: [try ProviderEndpointPolicy.canonicalize(source.absoluteString).identity],
            resolutionSnapshot: Self.resolutionSnapshot
        ))
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(redirected.value(forHTTPHeaderField: "X-API-Key") == "provider-api-key")
        #expect(redirected.value(forHTTPHeaderField: "Cookie") == "session-cookie")
    }

    @Test("cross-origin redirects strip authorization API key and cookie headers")
    func crossOriginStripsCredentialHeaders() throws {
        let source = try #require(URL(string: "https://api.example.com/v1"))
        let destination = try #require(URL(string: "https://other.example.com/v1"))
        var request = URLRequest(url: destination)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.setValue("provider-api-key", forHTTPHeaderField: "X-API-Key")
        request.setValue("session-cookie", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let redirected = try #require(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: request,
            hopCount: 1,
            visitedCanonicalURLs: [try ProviderEndpointPolicy.canonicalize(source.absoluteString).identity],
            resolutionSnapshot: Self.resolutionSnapshot
        ))
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.value(forHTTPHeaderField: "X-API-Key") == nil)
        #expect(redirected.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(redirected.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(!redirected.httpShouldHandleCookies)
    }

    @Test("unsafe destination loop and hop limit are explicit nil failures")
    func unsafeLoopAndHopLimitFailClosed() throws {
        let source = try #require(URL(string: "https://api.example.com/v1"))
        let sourceID = try ProviderEndpointPolicy.canonicalize(source.absoluteString).identity
        var request = URLRequest(url: source)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")

        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: request,
            hopCount: 1,
            visitedCanonicalURLs: [sourceID],
            resolutionSnapshot: Self.resolutionSnapshot
        ) == nil)
        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: URLRequest(url: try #require(URL(string: "https://other.example.com/v1"))),
            hopCount: ProviderRedirectPolicy.maximumRedirectHops + 1,
            visitedCanonicalURLs: [sourceID],
            resolutionSnapshot: Self.resolutionSnapshot
        ) == nil)
        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: URLRequest(url: try #require(URL(string: "https://other.example.com/v1?api_key=secret"))),
            hopCount: 1,
            visitedCanonicalURLs: [sourceID],
            resolutionSnapshot: Self.resolutionSnapshot
        ) == nil)
    }

    @Test("resolver snapshots reject special or unapproved private targets")
    func resolverSnapshotRejectsUnsafeAddresses() throws {
        let source = try #require(URL(string: "https://api.example.com/v1"))
        let sourceID = try ProviderEndpointPolicy.canonicalize(source.absoluteString).identity
        let unsafeSnapshot = ProviderAddressResolutionSnapshot(
            addressesByHost: [
                "private.example.com": ["192.168.1.10"],
                "link-local.example.com": ["169.254.1.10"],
                "multicast.example.com": ["224.0.0.1"],
                "unspecified.example.com": ["0.0.0.0"],
                "ipv6-link-local.example.com": ["fe80::1"],
                "ipv6-multicast.example.com": ["ff02::1"]
            ]
        )
        for host in [
            "private.example.com",
            "link-local.example.com",
            "multicast.example.com",
            "unspecified.example.com",
            "ipv6-link-local.example.com",
            "ipv6-multicast.example.com"
        ] {
            let destination = try #require(URL(string: "https://\(host)/v1"))
            #expect(ProviderRedirectPolicy.redirectedRequest(
                from: source,
                to: URLRequest(url: destination),
                hopCount: 1,
                visitedCanonicalURLs: [sourceID],
                resolutionSnapshot: unsafeSnapshot
            ) == nil)
        }

        let approvedSnapshot = ProviderAddressResolutionSnapshot(
            addressesByHost: [
                "api.example.com": ["93.184.216.34"],
                "approved-private.example.com": ["192.168.1.10"]
            ],
            approvedPrivateAddresses: ["192.168.1.10"]
        )
        let approved = try #require(URL(string: "https://approved-private.example.com/v1"))
        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: URLRequest(url: approved),
            hopCount: 1,
            visitedCanonicalURLs: [sourceID],
            resolutionSnapshot: approvedSnapshot
        ) != nil)
    }

    @Test("a changed resolver snapshot cannot rebind a visited host")
    func resolverSnapshotDriftFailsClosed() throws {
        let source = try #require(URL(string: "https://api.example.com/v1"))
        let destination = try #require(URL(string: "https://api.example.com/v1/next"))
        let sourceID = try ProviderEndpointPolicy.canonicalize(source.absoluteString).identity
        let driftedSnapshot = ProviderAddressResolutionSnapshot(
            addressesByHost: ["api.example.com": ["93.184.216.99"]]
        )
        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: source,
            to: URLRequest(url: destination),
            hopCount: 1,
            visitedCanonicalURLs: [sourceID],
            resolutionSnapshot: driftedSnapshot,
            resolvedAddressHistory: ["api.example.com": ["93.184.216.34"]]
        ) == nil)
    }

    @Test("HTTPS cannot downgrade and explicit loopback HTTP can stay HTTP")
    func downgradeBoundaryIsFailClosed() throws {
        let httpsSource = try #require(URL(string: "https://api.example.com/v1"))
        let httpsSourceID = try ProviderEndpointPolicy.canonicalize(httpsSource.absoluteString).identity
        let loopbackHTTP = try #require(URL(string: "http://127.0.0.1:8080/v1"))
        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: httpsSource,
            to: URLRequest(url: loopbackHTTP),
            hopCount: 1,
            visitedCanonicalURLs: [httpsSourceID],
            resolutionSnapshot: Self.resolutionSnapshot
        ) == nil)

        let loopbackSource = try #require(URL(string: "http://127.0.0.1:11434/v1"))
        let loopbackDestination = try #require(URL(string: "http://127.0.0.1:8080/v1"))
        let loopbackSourceID = try ProviderEndpointPolicy.canonicalize(loopbackSource.absoluteString).identity
        #expect(ProviderRedirectPolicy.redirectedRequest(
            from: loopbackSource,
            to: URLRequest(url: loopbackDestination),
            hopCount: 1,
            visitedCanonicalURLs: [loopbackSourceID]
        ) != nil)
    }

    @Test("real URLSession delegate path tracks redirect chain and loop")
    func delegateTracksChain() throws {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        let first = try #require(URL(string: "https://api.example.com/v1"))
        let second = try #require(URL(string: "https://api.example.com/v1/next"))
        let task = session.dataTask(with: first)
        let redirectGuard = ProviderRedirectGuard(resolutionSnapshot: Self.resolutionSnapshot)
        let response1 = try #require(HTTPURLResponse(url: first, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        var request1 = URLRequest(url: second)
        request1.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        var firstDecision: URLRequest?
        redirectGuard.urlSession(session, task: task, willPerformHTTPRedirection: response1, newRequest: request1) {
            firstDecision = $0
        }
        #expect(firstDecision?.url == second)
        #expect(firstDecision?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")

        let response2 = try #require(HTTPURLResponse(url: second, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        var loopRequest = URLRequest(url: first)
        loopRequest.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        var loopDecision: URLRequest?
        redirectGuard.urlSession(session, task: task, willPerformHTTPRedirection: response2, newRequest: loopRequest) {
            loopDecision = $0
        }
        #expect(loopDecision == nil)
        redirectGuard.urlSession(session, task: task, didCompleteWithError: nil)
        session.invalidateAndCancel()
    }
}
