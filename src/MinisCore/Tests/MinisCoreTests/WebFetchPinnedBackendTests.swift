import Foundation
import Testing
@testable import MinisCore

@Suite("H05 B bounded curl response source parsing")
struct WebFetchPinnedBackendTests {
    @Test func singleHopMetadataPreservesRedirectForSeparateApproval() throws {
        let url = URL(string: "https://first.example/page")!
        let raw = Data("HTTP/1.1 302 Found\r\nLocation: https://second.example/\r\nSet-Cookie: secret=a\r\nSet-Cookie: secret=b\r\n\r\n".utf8)
        let hop = try WebFetchPinnedBackend.parse(raw, url: url)
        #expect(hop.response.url == url)
        #expect(hop.response.statusCode == 302)
        #expect(hop.response.value(forHTTPHeaderField: "Location") == "https://second.example/")
        #expect(hop.response.value(forHTTPHeaderField: "Set-Cookie") == nil)
    }
    @Test func malformedAmbiguousOrCompressedMetadataIsRejected() {
        let url = URL(string: "https://example.com/")!
        for raw in ["no status\r\n\r\nbody",
                    "HTTP/1.1 302 Found\r\nLocation: https://a.example/\r\nLocation: https://b.example/\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nbody"] {
            #expect(throws: (any Error).self) { try WebFetchPinnedBackend.parse(Data(raw.utf8), url: url) }
        }
    }
    @Test func bodyBoundAppliesBeforeRenderer() {
        let url = URL(string: "https://example.com/")!
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".utf8)
        raw.append(Data(repeating: 65, count: WebFetchTransport.maximumBytes + 1))
        #expect(throws: WebFetchError.responseTooLarge) { try WebFetchPinnedBackend.parse(raw, url: url) }
    }

    private func curlOutput(body: String, remote: String) -> Data {
        Data(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n" + body
            + "\n\u{1}MINIS_REMOTE_IP:" + remote + "\u{2}\n").utf8)
    }

    @Test func actualRemoteIPMismatchRejectsEntireResponse() throws {
        let pinned = try WebFetchNumericAddress("93.184.216.34")
        #expect(throws: WebFetchPinnedError.connectionFailed) {
            try WebFetchPinnedBackend.parseCurlOutput(curlOutput(body: "page", remote: "93.184.216.35"),
                url: URL(string: "https://example.com/")!, pinnedAddress: pinned)
        }
    }

    @Test func missingTerminalRemoteIPRecordRejectsEntireResponse() throws {
        #expect(throws: WebFetchPinnedError.connectionFailed) {
            try WebFetchPinnedBackend.parseCurlOutput(Data("HTTP/1.1 200 OK\r\n\r\npage".utf8),
                url: URL(string: "https://example.com/")!,
                pinnedAddress: WebFetchNumericAddress("93.184.216.34"))
        }
    }

    @Test func bodyMarkerCannotOverrideTerminalRecordOrBecomeTrailer() throws {
        let url = URL(string: "https://example.com/")!
        let pinned = try WebFetchNumericAddress("93.184.216.34")
        let fake = "page\n\u{1}MINIS_REMOTE_IP:10.0.0.1\u{2}\nmore body"
        let hop = try WebFetchPinnedBackend.parseCurlOutput(curlOutput(body: fake, remote: "93.184.216.34"),
            url: url, pinnedAddress: pinned)
        #expect(hop.body == Data(fake.utf8)) // terminal record is stripped, body is unchanged
        let matchingFake = "page\n\u{1}MINIS_REMOTE_IP:93.184.216.34\u{2}\n"
        #expect(throws: WebFetchPinnedError.connectionFailed) {
            try WebFetchPinnedBackend.parseCurlOutput(curlOutput(body: matchingFake, remote: "10.0.0.1"),
                url: url, pinnedAddress: pinned)
        }
    }

    @Test func equivalentIPv6SpellingsCompareByAddressBytes() throws {
        let hop = try WebFetchPinnedBackend.parseCurlOutput(curlOutput(body: "page", remote: "2001:4860::8888"),
            url: URL(string: "https://example.com/")!,
            pinnedAddress: WebFetchNumericAddress("2001:4860:0:0:0:0:0:8888"))
        #expect(hop.body == Data("page".utf8))
    }
}
