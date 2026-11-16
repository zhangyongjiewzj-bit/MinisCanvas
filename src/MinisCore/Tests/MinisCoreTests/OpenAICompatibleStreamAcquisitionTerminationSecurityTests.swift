import Foundation
import Testing
@testable import MinisCore

private final class Provider23StreamTransportMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: Self.error ?? URLError(.unknown)
        )
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Provider23StreamTransportMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        error = nil
    }
}

@Suite("OpenAI-compatible stream acquisition termination security", .serialized)
struct OpenAICompatibleStreamAcquisitionTerminationSecurityTests {
    private static func provider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: "fixture-acquisition-secret",
            customBaseURL: "https://fixture.invalid/v1",
            session: Provider23StreamTransportMockURLProtocol.makeSession()
        )
    }

    private static func acquire(_ provider: OpenAICompatibleProvider) async throws {
        _ = try await provider.streamMessage(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            maxTokens: 8,
            temperature: nil
        )
    }

    @Test("stream acquisition cancellation is terminal and not retryable")
    func cancellationIsPayloadFree() async {
        defer { Provider23StreamTransportMockURLProtocol.reset() }
        Provider23StreamTransportMockURLProtocol.error = URLError(.cancelled)

        do {
            try await Self.acquire(Self.provider())
            Issue.record("expected stream acquisition cancellation")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected LLMError.cancelled, got \(error)")
                return
            }
            #expect(error.isRetryable == false)
            #expect(error.technicalDetail.contains("fixture-acquisition-secret") == false)
        } catch {
            Issue.record("expected payload-free LLMError, got \(error)")
        }
    }

    @Test("stream acquisition timeout retains only stable code")
    func timeoutIsPayloadFree() async {
        defer { Provider23StreamTransportMockURLProtocol.reset() }
        Provider23StreamTransportMockURLProtocol.error = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLErrorKey:
                    URL(string: "https://fixture.invalid/v1?token=fixture-query-secret")!,
                NSLocalizedDescriptionKey: "Authorization: Bearer fixture-body-secret"
            ]
        )

        do {
            try await Self.acquire(Self.provider())
            Issue.record("expected stream acquisition timeout")
        } catch let error as LLMError {
            guard case .networkError(let underlying) = error else {
                Issue.record("expected LLMError.networkError, got \(error)")
                return
            }
            guard let code = underlying as? ProviderTransportCodeError else {
                Issue.record("expected stable ProviderTransportCodeError")
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
                !$0.contains("fixture-acquisition-secret")
                    && !$0.contains("fixture-query-secret")
                    && !$0.contains("fixture-body-secret")
                    && !$0.contains("fixture.invalid")
                    && !$0.contains("Authorization")
            })
        } catch {
            Issue.record("expected payload-free LLMError, got \(error)")
        }
    }
}
