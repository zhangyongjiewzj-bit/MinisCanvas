import Foundation
import Testing
@testable import MinisCore

private final class Provider22TransportMockURLProtocol: URLProtocol, @unchecked Sendable {
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
        configuration.protocolClasses = [Provider22TransportMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        error = nil
    }
}

@Suite("OpenAI-compatible request termination security", .serialized)
struct OpenAICompatibleRequestTerminationSecurityTests {
    private static func provider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: "fixture-request-secret",
            customBaseURL: "https://fixture.invalid/v1",
            session: Provider22TransportMockURLProtocol.makeSession()
        )
    }

    private static func send(_ provider: OpenAICompatibleProvider) async throws -> LLMResponse {
        try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "fixture")],
            systemPrompt: nil,
            tools: [
                AgentToolDefinition(
                    name: "fixture_tool",
                    description: "fixture",
                    parameters: [:],
                    required: []
                )
            ],
            maxTokens: 8,
            temperature: nil
        )
    }

    @Test("non-streaming cancellation is terminal and not retryable")
    func cancellationIsPayloadFree() async {
        defer { Provider22TransportMockURLProtocol.reset() }
        Provider22TransportMockURLProtocol.error = URLError(.cancelled)

        do {
            _ = try await Self.send(Self.provider())
            Issue.record("expected non-streaming cancellation")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected LLMError.cancelled, got \(error)")
                return
            }
            #expect(error.isRetryable == false)
            #expect(error.technicalDetail.contains("fixture-request-secret") == false)
        } catch {
            Issue.record("expected payload-free LLMError, got \(error)")
        }
    }

    @Test("non-streaming timeout retains only stable code")
    func timeoutIsPayloadFree() async {
        defer { Provider22TransportMockURLProtocol.reset() }
        Provider22TransportMockURLProtocol.error = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLErrorKey:
                    URL(string: "https://fixture.invalid/v1?api_key=fixture-query-secret")!,
                NSLocalizedDescriptionKey: "Authorization: Bearer fixture-body-secret"
            ]
        )

        do {
            _ = try await Self.send(Self.provider())
            Issue.record("expected non-streaming timeout")
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
                !$0.contains("fixture-request-secret")
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
