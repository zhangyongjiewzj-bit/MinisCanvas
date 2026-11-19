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

    @Test("V-8 anthropic-ratelimit-*-reset headers become a bounded retry_after when Retry-After is absent")
    func rateLimitResetHeaders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func stamp(_ offset: Double) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: now.addingTimeInterval(offset))
        }
        func seconds(_ headers: [String: String], status: Int = 429) -> Int? {
            ProviderAnthropicErrorProjectionPolicy.project(statusCode: status, headers: headers, now: now).retryAfterSeconds
        }

        // 单个重置点（带小数秒），向上取整。
        #expect(seconds(["anthropic-ratelimit-requests-reset": stamp(12.3)]) == 13)
        // 用完的那一类优先，多类用完取最晚；没用完的更早重置点不参与。
        #expect(seconds([
            "anthropic-ratelimit-requests-remaining": "5", "anthropic-ratelimit-requests-reset": stamp(5),
            "anthropic-ratelimit-tokens-remaining": "0", "anthropic-ratelimit-tokens-reset": stamp(30),
            "anthropic-ratelimit-output-tokens-remaining": "0", "anthropic-ratelimit-output-tokens-reset": stamp(45),
        ]) == 45)
        // 没有哪一类标明用完：取最早的重置点。
        #expect(seconds([
            "Anthropic-RateLimit-Requests-Reset": stamp(40), "anthropic-ratelimit-tokens-reset": stamp(9),
        ]) == 9)
        // 已过去的重置点不会变成负数。
        #expect(seconds(["anthropic-ratelimit-requests-reset": stamp(-5)]) == 0)
        // Retry-After 优先于重置点。
        #expect(seconds(["Retry-After": "7", "anthropic-ratelimit-requests-reset": stamp(30)]) == 7)
        // 解析不了的时间点、过大的值、非 429 都不产生提示。
        #expect(seconds(["anthropic-ratelimit-requests-reset": "tomorrow"]) == nil)
        #expect(seconds(["anthropic-ratelimit-requests-reset": stamp(200_000)]) == 86_400)
        #expect(seconds(["anthropic-ratelimit-requests-reset": stamp(10)], status: 503) == nil)

        let detail = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 429, headers: ["anthropic-ratelimit-requests-reset": stamp(10)], now: now).safeDetail
        #expect(detail == "status=429; category=rate_limited; retry_after=10")
    }

    @Test("V-9 stream error events map to the same retryable errors as the matching HTTP status")
    func streamErrorsMapToStatusErrors() {
        func event(_ type: String) -> [String: Any] {
            ["type": "error", "request_id": "request-secret", "error": ["type": type, "message": "fixture-secret"]]
        }
        let overloaded = ProviderAnthropicErrorProjectionPolicy.streamLLMError(event("overloaded_error"))
        guard case .httpStatus(let overloadedCode, let overloadedDetail) = overloaded else {
            Issue.record("expected httpStatus, got \(overloaded)")
            return
        }
        #expect(overloadedCode == 529 && overloaded.isRetryable)
        #expect(overloadedDetail == "status=529; category=server; request_id=present")

        let limited = ProviderAnthropicErrorProjectionPolicy.streamLLMError(event("rate_limit_error"))
        guard case .httpStatus(let limitedCode, let limitedDetail) = limited else {
            Issue.record("expected httpStatus, got \(limited)")
            return
        }
        #expect(limitedCode == 429 && limited.isRetryable)
        #expect(limitedDetail == "status=429; category=rate_limited; request_id=present")

        let api = ProviderAnthropicErrorProjectionPolicy.streamLLMError(event("api_error"))
        guard case .transientError = api else {
            Issue.record("expected transientError, got \(api)")
            return
        }
        #expect(api.isRetryable)

        // 其余类型保持原来的不可重试服务错误，且仍然只带固定类别。
        let invalid = ProviderAnthropicErrorProjectionPolicy.streamLLMError(event("invalid_request_error"))
        guard case .providerError(let message) = invalid else {
            Issue.record("expected providerError, got \(invalid)")
            return
        }
        #expect(!invalid.isRetryable)
        #expect(message == "category=request; request_id=present")
        #expect(!overloadedDetail.contains("fixture-secret") && !limitedDetail.contains("fixture-secret"))
    }

    @Test("known reason labels are canonical while arbitrary body text is discarded")
    func reasonRedaction() {
        let known = ProviderAnthropicErrorProjectionPolicy.project(
            statusCode: 403,
            body: "{\"error\":{\"message\":\"quota exceeded\"}}"
        )
        #expect(known.safeDetail.contains("reason=quota"))

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
        #expect(detail.contains("reason=quota"))
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
