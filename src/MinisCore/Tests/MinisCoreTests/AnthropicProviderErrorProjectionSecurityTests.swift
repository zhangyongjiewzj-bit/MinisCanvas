import Foundation
import Testing
@testable import MinisCore

@Suite("Anthropic provider error projection security")
struct AnthropicProviderErrorProjectionSecurityTests {
    @Test("HTTP status, retry-after, and request-id classification is actionable")
    func httpClassification() {
        let projection = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 429,
            headers: [
                "retry-after": " 17 ",
                "request-id": "request-secret-should-not-be-retained"
            ],
            body: "rate limit; Authorization: Bearer fixture-secret"
        )

        #expect(projection.statusCode == 429)
        #expect(projection.category == .rateLimited)
        #expect(projection.retryAfterSeconds == 17)
        #expect(projection.requestIDPresent)
        #expect(projection.safeDetail.contains("status=429"))
        #expect(projection.safeDetail.contains("category=rate_limited"))
        #expect(projection.safeDetail.contains("retry_after=17"))
        #expect(projection.safeDetail.contains("request_id=present"))
        #expect(!projection.safeDetail.contains("request-secret"))
        #expect(!projection.safeDetail.contains("Authorization"))
        #expect(!projection.safeDetail.contains("fixture-secret"))
    }

    @Test("retry metadata is bounded and duplicate headers fail closed")
    func retryAfterBoundary() {
        let outOfRange = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 429,
            headers: ["Retry-After": "86401"]
        )
        #expect(outOfRange.retryAfterSeconds == nil)
        #expect(!outOfRange.safeDetail.contains("retry_after="))

        let duplicate = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 429,
            headers: ["Retry-After": "1", "retry-after": "2"]
        )
        #expect(duplicate.retryAfterSeconds == nil)

        let nonRateLimited = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 500,
            headers: ["Retry-After": "1"]
        )
        #expect(nonRateLimited.retryAfterSeconds == nil)
    }

    @Test("known reason labels are canonical while arbitrary body text is discarded")
    func reasonRedaction() {
        let known = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 403,
            body: "{\"error\":{\"message\":\"quota exceeded\"}}"
        )
        #expect(known.safeDetail.contains("reason=quota exceeded"))

        let unknown = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 503,
            body: "provider URL=https://api.example.invalid token=fixture-secret raw diagnostic"
        )
        #expect(unknown.category == .server)
        #expect(!unknown.safeDetail.contains("api.example.invalid"))
        #expect(!unknown.safeDetail.contains("fixture-secret"))
        #expect(!unknown.safeDetail.contains("raw diagnostic"))
    }

    @Test("Anthropic mapHTTPError retains safe classification only")
    func providerHTTPErrorIsSafe() {
        let provider = AnthropicProvider(apiKey: "fixture-api-key")
        let error = provider.mapHTTPError(
            statusCode: 403,
            body: "provider returned quota exceeded with fixture-secret",
            headers: ["Anthropic-Request-Id": "request-secret"]
        )
        guard case .httpStatus(let code, let detail) = error else {
            Issue.record("expected httpStatus, got \(error)")
            return
        }
        #expect(code == 403)
        #expect(detail.contains("status=403"))
        #expect(detail.contains("category=permission_denied"))
        #expect(detail.contains("reason=quota exceeded"))
        #expect(detail.contains("request_id=present"))
        #expect(!detail.contains("fixture-secret"))
        #expect(!detail.contains("request-secret"))
    }

    @Test("SSE provider error projects category without raw message")
    func streamErrorIsSafe() {
        let event: [String: Any] = [
            "type": "error",
            "request_id": "request-secret",
            "error": [
                "type": "overloaded_error",
                "message": "Authorization Bearer fixture-secret provider detail"
            ]
        ]
        let detail = ProviderAnthropicErrorProjectionPolicy.projectStreamError(event)
        #expect(detail == "category=server_overloaded; request_id=present")
        #expect(!detail.contains("fixture-secret"))
        #expect(!detail.contains("Authorization"))
        #expect(!detail.contains("request-secret"))
    }
}
