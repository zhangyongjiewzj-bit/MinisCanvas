import Foundation
import Testing
@testable import MinisCore

@Suite("Fallback router failure metadata security", .serialized)
struct FallbackRouterFailureMetadataSecurityTests {
    private static let sensitiveReason =
        "Authorization: Bearer fixture-provider-secret body=/private/tmp/provider.json?token=fixture-query-secret"

    private static func assertGeneric(_ event: FallbackRouter.FallbackEvent) {
        #expect(event.errorDescription == "Provider error")
        #expect(!event.errorDescription.contains("fixture-provider-secret"))
        #expect(!event.errorDescription.contains("fixture-query-secret"))
        #expect(!event.errorDescription.contains("Authorization"))
        #expect(!event.errorDescription.contains("/private/tmp/provider.json"))
    }

    @Test("programmatic fallback reason rejects secret and path text")
    func programmaticReasonIsPayloadFree() {
        let event = FallbackRouter.FallbackEvent(
            providerID: "openai",
            errorDescription: Self.sensitiveReason,
            attempt: 1
        )
        Self.assertGeneric(event)
    }

    @Test("control and oversized fallback reasons are bounded")
    func malformedReasonIsBounded() {
        let control = FallbackRouter.FallbackEvent(
            providerID: "openai",
            errorDescription: "Provider error\nfixture-body",
            attempt: 1
        )
        let oversized = FallbackRouter.FallbackEvent(
            providerID: "openai",
            errorDescription: String(repeating: "x", count: 257),
            attempt: 1
        )
        Self.assertGeneric(control)
        Self.assertGeneric(oversized)
    }

    @Test("Codable decode uses the same failure projection")
    func decodedReasonIsPayloadFree() throws {
        let payload = """
        {
          "providerID": "provider://fixture-provider-secret/path?token=fixture-query-secret",
          "errorDescription": "\(Self.sensitiveReason)",
          "attempt": 9223372036854775807
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(
            FallbackRouter.FallbackEvent.self,
            from: payload
        )

        #expect(event.providerID == "provider")
        #expect(event.attempt == 1_024)
        Self.assertGeneric(event)
    }

    @Test("stable provider reason remains available")
    func stableReasonRemainsReadable() {
        let event = FallbackRouter.FallbackEvent(
            providerID: "openai",
            errorDescription: "HTTP 429",
            attempt: 1
        )
        #expect(event.errorDescription == "HTTP 429")
    }
}
