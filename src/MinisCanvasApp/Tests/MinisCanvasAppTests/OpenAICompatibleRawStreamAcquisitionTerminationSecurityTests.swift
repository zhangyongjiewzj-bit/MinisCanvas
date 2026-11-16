import Foundation
import Testing
@testable import MinisCore

private final class Provider24RawStreamTransportMockURLProtocol: URLProtocol, @unchecked Sendable {
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
        configuration.protocolClasses = [Provider24RawStreamTransportMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        error = nil
    }
}

@Suite("OpenAI-compatible raw stream acquisition termination security", .serialized)
struct OpenAICompatibleRawStreamAcquisitionTerminationSecurityTests {
    private static func provider(session: URLSession) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: "fixture-raw-acquisition-secret",
            customBaseURL: "https://fixture.invalid/v1",
            session: session
        )
    }

    private static func acquire(_ provider: OpenAICompatibleProvider) async throws {
        _ = try await provider.streamRaw(
            body: [
                "model": "fixture-model",
                "messages": [],
                "stream": true
            ]
        )
    }

    @Test
    func cancellationIsPayloadFree() async throws {
        try await B1ProviderAssemblyFixtureSupport.withNonActorSession(protocols: [Provider24RawStreamTransportMockURLProtocol.self], afterQuiescence: { Provider24RawStreamTransportMockURLProtocol.reset() }) { session in
        Provider24RawStreamTransportMockURLProtocol.error = URLError(.cancelled)

        do {
            try await Self.acquire(Self.provider(session: session))
            Issue.record("expected raw stream acquisition cancellation")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected LLMError.cancelled, got \(error)")
                return
            }
            #expect(error.isRetryable == false)
            #expect(error.technicalDetail.contains("fixture-raw-acquisition-secret") == false)
        } catch {
            Issue.record("expected payload-free LLMError, got \(error)")
        }
            }
    }

    @Test
    func timeoutIsPayloadFree() async throws {
        try await B1ProviderAssemblyFixtureSupport.withNonActorSession(protocols: [Provider24RawStreamTransportMockURLProtocol.self], afterQuiescence: { Provider24RawStreamTransportMockURLProtocol.reset() }) { session in
        Provider24RawStreamTransportMockURLProtocol.error = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLErrorKey:
                    URL(string: "https://fixture.invalid/v1?token=fixture-query-secret")!,
                NSLocalizedDescriptionKey: "Authorization: Bearer fixture-body-secret"
            ]
        )

        do {
            try await Self.acquire(Self.provider(session: session))
            Issue.record("expected raw stream acquisition timeout")
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
                !$0.contains("fixture-raw-acquisition-secret")
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
}
