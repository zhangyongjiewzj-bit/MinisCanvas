import Foundation
import Testing
@testable import MinisCore

@Suite("Provider HTTP error adapter consumers")
struct ProviderHTTPErrorConsumerTests {

    @Test func readinessConsumerUsesTypedAdapterWithoutBody() {
        let body = "Authorization: Bearer fixture-readiness-secret?token=fixture-query"
        let statuses: [(Int, ProviderReadinessFailureCategory)] = [
            (401, .unauthorized),
            (403, .permissionDenied),
            (404, .notFound),
            (408, .timeout),
            (429, .rateLimited),
            (500, .server),
            (503, .server),
        ]

        for (statusCode, category) in statuses {
            let failure = ProviderReadinessHTTPFailure.make(
                statusCode: statusCode,
                headers: statusCode == 429
                    ? ["Retry-After": "9", "Authorization": "Bearer fixture-header-secret"]
                    : ["X-Query": "token=fixture-query"],
                body: body,
                secrets: ["fixture-readiness-secret"]
            )
            #expect(failure?.failureCategory == category)
            #expect(failure?.retryAfterSeconds == (statusCode == 429 ? 9 : nil))
            #expect(failure?.redactedDetail == "HTTP \(statusCode)")
            #expect(failure?.redactedDetail.contains("Authorization") == false)
            #expect(failure?.redactedDetail.contains("Bearer") == false)
            #expect(failure?.redactedDetail.contains("fixture") == false)
        }
    }

    @Test func generationConsumerDoesNotParseHTTPBody() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-generation-secret")
        let body = "{\"error\":{\"message\":\"Authorization: Bearer fixture-generation-secret\"}}"

        for statusCode in [401, 403, 404, 408, 429, 500, 503] {
            let error = provider.mapHTTPError(statusCode: statusCode, body: body)
            guard case .httpStatus(let actualStatus, let detail) = error else {
                Issue.record("expected httpStatus for \(statusCode), got \(error)")
                continue
            }
            #expect(actualStatus == statusCode)
            #expect(detail.isEmpty)
            #expect((error.errorDescription ?? "").contains("fixture-generation-secret") == false)
            #expect(error.userMessageZH.contains("fixture-generation-secret") == false)
            #expect(error.userMessageEN.contains("fixture-generation-secret") == false)
            #expect(error.technicalDetail.contains("fixture-generation-secret") == false)
        }
    }

    @Test func generationTransportConsumerUsesCodeOnly() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-transport-secret")
        let rawError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSLocalizedDescriptionKey: "Authorization: Bearer fixture-transport-secret",
                NSURLErrorFailingURLStringErrorKey: "https://api.deepseek.com/v1/chat/completions?token=fixture-query",
            ]
        )

        let error = provider.mapError(rawError)
        #expect(error.isNetworkError)
        #expect(error.errorDescription?.contains("fixture-transport-secret") == false)
        #expect(error.userMessageZH.contains("fixture-transport-secret") == false)
        #expect(error.userMessageEN.contains("fixture-transport-secret") == false)
        #expect(error.technicalDetail.contains("fixture-transport-secret") == false)
        #expect(error.technicalDetail.contains("api.deepseek.com") == false)
        #expect(error.technicalDetail.contains("token=") == false)
    }

    @Test func retryAfterConsumerRejectsUnboundedOrAmbiguousValues() {
        let malformedValues = [
            "-1",
            "86401",
            "9223372036854775807",
            "NaN",
            "Wed, 21 Oct 2015 07:28:00 GMT",
            "5, 10",
            "５",
        ]

        for value in malformedValues {
            let classification = ProviderHTTPErrorAdapter.classify(
                statusCode: 429,
                headers: [
                    "Retry-After": value,
                    "Authorization": "Bearer fixture-retry-secret",
                ]
            )
            #expect(classification.retryAfterSeconds == nil)
            #expect(classification.llmError.technicalDetail.contains("fixture-retry-secret") == false)
        }

        #expect(
            ProviderHTTPErrorAdapter.classify(
                statusCode: 429,
                headers: ["Retry-After": " 86400 "]
            ).retryAfterSeconds == 86400
        )

        #expect(
            ProviderHTTPErrorAdapter.classify(
                statusCode: 429,
                headers: ["Retry-After": "5", "retry-after": "10"]
            ).retryAfterSeconds == nil
        )
    }
}
