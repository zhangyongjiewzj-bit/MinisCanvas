import Foundation
import Testing
@testable import MinisCore

@Suite("OpenAI-compatible stream termination security")
struct OpenAICompatibleStreamTerminationSecurityTests {
    @Test("cancellation is a terminal cancelled result for raw streaming")
    func cancellationIsNotRetriedOrLeaked() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-stream-secret")
        let error = provider.mapError(URLError(.cancelled))

        guard case .cancelled = error else {
            Issue.record("raw stream cancellation must map to LLMError.cancelled, got \(error)")
            return
        }
        #expect(error.isRetryable == false)
        #expect(error.technicalDetail.contains("fixture-stream-secret") == false)
    }

    @Test("timeout keeps stable code and drops URL and provider payload")
    func timeoutIsPayloadFree() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-stream-secret")
        let raw = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLErrorKey:
                    URL(string: "https://fixture.invalid/chat?api_key=fixture-query-secret")!,
                NSLocalizedDescriptionKey: "Authorization: Bearer fixture-body-secret"
            ]
        )
        let error = provider.mapError(raw)

        guard case .networkError(let underlying) = error else {
            Issue.record("raw stream timeout must map to LLMError.networkError, got \(error)")
            return
        }
        guard let code = underlying as? ProviderTransportCodeError else {
            Issue.record("timeout must retain only ProviderTransportCodeError")
            return
        }
        #expect(code.code == NSURLErrorTimedOut)
        #expect(error.providerFailureCategory == .timeout)
        let surfaces = [
            error.errorDescription ?? "",
            error.userMessageZH,
            error.userMessageEN,
            error.technicalDetail
        ]
        #expect(surfaces.allSatisfy {
            !$0.contains("fixture-stream-secret")
                && !$0.contains("fixture-query-secret")
                && !$0.contains("fixture-body-secret")
                && !$0.contains("fixture.invalid")
                && !$0.contains("Authorization")
        })
    }
}
