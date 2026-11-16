import Foundation
import Testing
@testable import MinisCore

@Suite("Provider HTTP error adapter")
struct ProviderHTTPErrorAdapterTests {

    @Test func statusMappingIsTypedRetryableAndPayloadFree() {
        let secretHeaders = [
            "Authorization": "Bearer fixture-provider-secret",
            "X-Query": "token=fixture-query-secret",
            "Retry-After": "17",
        ]
        let cases: [(Int, ProviderReadinessFailureCategory, Bool)] = [
            (401, .unauthorized, false),
            (403, .permissionDenied, false),
            (404, .notFound, false),
            (408, .timeout, true),
            (429, .rateLimited, true),
            (500, .server, true),
            (503, .server, true),
        ]

        for (statusCode, category, retryable) in cases {
            let classification = ProviderHTTPErrorAdapter.classify(
                statusCode: statusCode,
                headers: secretHeaders
            )
            #expect(classification.statusCode == statusCode)
            #expect(classification.category == category)
            #expect(classification.isRetryable == retryable)
            #expect(classification.retryAfterSeconds == (statusCode == 429 ? 17 : nil))

            let readiness = classification.readinessError
            #expect(readiness.category == category)
            #expect((classification.llmError.errorDescription ?? "").hasPrefix("HTTP \(statusCode)"))

            let publicSurfaces = [
                String(describing: classification),
                String(describing: readiness),
                classification.llmError.errorDescription ?? "",
                classification.llmError.userMessageZH,
                classification.llmError.userMessageEN,
                classification.llmError.technicalDetail,
            ]
            #expect(publicSurfaces.allSatisfy {
                !$0.contains("Authorization")
                    && !$0.contains("Bearer")
                    && !$0.contains("fixture-provider-secret")
                    && !$0.contains("fixture-query-secret")
            })
        }
    }

    @Test func transportMappingUsesStableCodeOnly() {
        let payload = "Authorization: Bearer fixture-transport-secret"
        let timeout = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: payload]
        )
        let classification = ProviderHTTPErrorAdapter.classify(transport: timeout)

        #expect(classification.code == NSURLErrorTimedOut)
        #expect(classification.category == .timeout)
        #expect(classification.isRetryable)
        #expect(classification.readinessError.category == .timeout)
        #expect(classification.llmError.isNetworkError)

        let surfaces = [
            String(describing: classification),
            classification.llmError.errorDescription ?? "",
            classification.llmError.userMessageZH,
            classification.llmError.userMessageEN,
            classification.llmError.technicalDetail,
        ]
        #expect(surfaces.allSatisfy {
            !$0.contains(payload)
                && !$0.contains("Authorization")
                && !$0.contains("Bearer")
                && !$0.contains("fixture-transport-secret")
        })
    }

    @Test func cancellationAndUnknownTransportFailClosed() {
        let cancelled = ProviderHTTPErrorAdapter.classify(
            transport: URLError(.cancelled)
        )
        #expect(cancelled.isCancelled)
        #expect(!cancelled.isRetryable)
        guard case .cancelled = cancelled.llmError else {
            Issue.record("cancelled transport must map to LLMError.cancelled")
            return
        }

        let unknown = NSError(
            domain: "fixture.provider.secret-domain",
            code: 77,
            userInfo: [NSLocalizedDescriptionKey: "Bearer fixture-unknown-secret"]
        )
        let classification = ProviderHTTPErrorAdapter.classify(transport: unknown)
        #expect(classification.code == -1)
        #expect(classification.category == .transport)
        #expect(!classification.isRetryable)
        #expect(classification.llmError.technicalDetail.contains("ProviderTransportCodeError"))
        #expect(!classification.llmError.technicalDetail.contains("fixture-unknown-secret"))
        #expect(!classification.llmError.technicalDetail.contains("secret-domain"))
    }
}
