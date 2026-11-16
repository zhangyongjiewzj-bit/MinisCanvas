import Foundation
import Testing
@testable import MinisCore

@Suite("OpenAI-compatible provider error projection security")
struct OpenAICompatibleErrorProjectionSecurityTests {
    @Test("buffered and streaming callers preserve safe header classification")
    func headerClassification() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-api-key")
        let error = provider.mapHTTPError(
            statusCode: 429,
            body: "Authorization: Bearer fixture-secret raw body",
            headers: [
                "Retry-After": " 23 ",
                "OpenAI-Request-ID": "request-secret"
            ]
        )
        guard case .httpStatus(let code, let detail) = error else {
            Issue.record("expected httpStatus, got \(error)")
            return
        }
        #expect(code == 429)
        #expect(detail.contains("status=429"))
        #expect(detail.contains("category=rateLimited"))
        #expect(detail.contains("retry_after=23"))
        #expect(detail.contains("request_id=present"))
        #expect(!detail.contains("fixture-secret"))
        #expect(!detail.contains("request-secret"))
    }

    @Test("status categories remain adapter-compatible")
    func statusCategories() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-api-key")
        let expected: [(Int, String)] = [
            (401, "unauthorized"),
            (403, "permissionDenied"),
            (404, "notFound"),
            (429, "rateLimited"),
            (500, "server")
        ]
        for (status, category) in expected {
            let error = provider.mapHTTPError(
                statusCode: status,
                body: "raw provider body",
                headers: ["x-request-id": "fixture-request"]
            )
            guard case .httpStatus(let code, let detail) = error else {
                Issue.record("expected httpStatus for \(status), got \(error)")
                continue
            }
            #expect(code == status)
            #expect(detail.contains("category=\(category)"))
            #expect(detail.contains("request_id=present"))
            #expect(!detail.contains("raw provider body"))
        }
    }

    @Test("invalid retry metadata and blank request ids are discarded")
    func metadataBoundaries() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-api-key")
        let error = provider.mapHTTPError(
            statusCode: 429,
            body: "fixture-secret",
            headers: [
                "retry-after": "86401",
                "x-request-id": "   "
            ]
        )
        guard case .httpStatus(_, let detail) = error else {
            Issue.record("expected httpStatus, got \(error)")
            return
        }
        #expect(!detail.contains("retry_after="))
        #expect(!detail.contains("request_id=present"))
        #expect(!detail.contains("fixture-secret"))
    }

    @Test("legacy body-only mapping stays payload-free")
    func bodyIsIgnored() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-api-key")
        let error = provider.mapHTTPError(
            statusCode: 401,
            body: "Authorization: Bearer fixture-secret https://provider.invalid/raw"
        )
        guard case .httpStatus(let code, let detail) = error else {
            Issue.record("expected httpStatus, got \(error)")
            return
        }
        #expect(code == 401)
        #expect(detail.isEmpty)
        #expect(!detail.contains("fixture-secret"))
        #expect(!detail.contains("provider.invalid"))
    }
}
