import Foundation
import Testing
@testable import MinisCore

@Suite("Provider endpoint policy security")
struct ProviderEndpointPolicySecurityTests {
    @Test("canonical identity normalizes scheme host default port and trailing path slash")
    func canonicalIdentityIsStable() throws {
        let first = try ProviderEndpointPolicy.canonicalize("  HTTPS://API.Example.COM:443/v1///  ")
        let second = try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1")

        #expect(first.identity == second.identity)
        #expect(first.canonicalURL.absoluteString == "https://api.example.com/v1")
        #expect(first.scheme == "https")
        #expect(first.host == "api.example.com")
        #expect(first.port == nil)
        #expect(first.path == "/v1")
    }

    @Test("semantic non-default ports and paths remain distinct")
    func nonDefaultPortAndPathRemainMeaningful() throws {
        let first = try ProviderEndpointPolicy.canonicalize("https://api.example.com:8443/v1")
        let second = try ProviderEndpointPolicy.canonicalize("https://api.example.com:8443/v2")

        #expect(first.port == 8443)
        #expect(first.path == "/v1")
        #expect(first.identity != second.identity)
        #expect(second.path == "/v2")
    }

    @Test("credential-like query and fragment fields fail closed")
    func credentialLikeComponentsAreRejected() {
        #expect(throws: ProviderEndpointPolicyError.credentialInQuery) {
            try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1?api_key=secret")
        }
        #expect(throws: ProviderEndpointPolicyError.credentialInQuery) {
            try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1?api%5Fkey=secret")
        }
        #expect(throws: ProviderEndpointPolicyError.credentialInFragment) {
            try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1#access_token=secret")
        }
        #expect(throws: ProviderEndpointPolicyError.credentialInQuery) {
            try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1?mode=secret")
        }
    }

    @Test("scheme host userinfo and control character boundaries stay fail closed")
    func endpointBoundariesAreRejected() {
        #expect(throws: ProviderEndpointPolicyError.unsupportedScheme("ftp")) {
            try ProviderEndpointPolicy.canonicalize("ftp://api.example.com/v1")
        }
        #expect(throws: ProviderEndpointPolicyError.emptyHost) {
            try ProviderEndpointPolicy.canonicalize("https:///v1")
        }
        #expect(throws: ProviderEndpointPolicyError.embeddedCredentials) {
            try ProviderEndpointPolicy.canonicalize("https://user:pass@api.example.com/v1")
        }
        #expect(throws: ProviderEndpointPolicyError.controlCharacter) {
            try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1\u{0000}")
        }
        #expect(throws: ProviderEndpointPolicyError.controlCharacter) {
            try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1/%00")
        }
        #expect(throws: ProviderEndpointPolicyError.nonHTTPSHost) {
            try ProviderEndpointPolicy.canonicalize("http://api.example.com/v1")
        }
    }

    @Test("loopback HTTP and benign query remain available")
    func loopbackAndBenignQueryAreAllowed() throws {
        let loopback = try ProviderEndpointPolicy.canonicalize("HTTP://LOCALHOST:80/v1?mode=stream")
        let ipv4 = try ProviderEndpointPolicy.canonicalize("http://127.0.0.1:8080/v1")
        let https = try ProviderEndpointPolicy.canonicalize("https://api.example.com/v1?mode=stream")

        #expect(loopback.canonicalURL.absoluteString == "http://localhost/v1?mode=stream")
        #expect(ipv4.canonicalURL.absoluteString == "http://127.0.0.1:8080/v1")
        #expect(https.canonicalURL.absoluteString == "https://api.example.com/v1?mode=stream")
    }

    @Test("existing custom URL gate and redirect guard use the same policy")
    func productionGatesSharePolicy() throws {
        let valid = try CustomProviderURL.validate(" HTTPS://API.Example.COM:443/v1/// ")
        #expect(valid.absoluteString == "https://api.example.com/v1")
        #expect(CustomProviderURL.isSafeDestination(URL(string: "https://api.example.com/v1?mode=stream")!))
        #expect(ProviderRedirectGuard.guardedRedirect(
            for: URLRequest(url: URL(string: "https://api.example.com/v1?mode=stream")!)
        ) != nil)
        #expect(ProviderRedirectGuard.guardedRedirect(
            for: URLRequest(url: URL(string: "https://api.example.com/v1?api_key=secret")!)
        ) == nil)

        do {
            _ = try CustomProviderURL.validate("https://api.example.com/v1?api_key=do-not-echo")
            Issue.record("expected credential-like query rejection")
        } catch let error as CustomProviderURL.Failure {
            #expect(error == .credentialInQuery)
            let message = String(describing: error)
            #expect(!message.contains("do-not-echo"))
            #expect(!message.contains("https://api.example.com"))
        }

        do {
            _ = try CustomProviderURL.validate("https://[invalid?private-value")
            Issue.record("expected invalid URL rejection")
        } catch let error as CustomProviderURL.Failure {
            #expect(error == .invalidURL("https://[invalid?private-value"))
            #expect(!String(describing: error).contains("private-value"))
        }
    }
}
