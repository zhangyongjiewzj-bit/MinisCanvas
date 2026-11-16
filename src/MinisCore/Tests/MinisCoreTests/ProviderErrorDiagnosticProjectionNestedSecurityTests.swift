import Foundation
import Testing
@testable import MinisCore

private let unsafeNestedProviderPayload =
    "Authorization: Bearer fixture-nested-secret https://example.test/raw?token=fixture-query-secret "
        + "/private/tmp/provider-response.json "
        + String(repeating: "n", count: 640) + "\u{0000}"

@Suite("Nested provider error diagnostic security", .serialized)
struct ProviderErrorDiagnosticProjectionNestedSecurityTests {
    @Test("NSError underlying payload is not unwrapped into diagnostics")
    func wrappedNSErrorFailsClosed() {
        let wrapped = NSError(
            domain: "fixture-wrapper",
            code: 77,
            userInfo: [
                NSLocalizedDescriptionKey: unsafeNestedProviderPayload,
                NSUnderlyingErrorKey: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: unsafeNestedProviderPayload]
                )
            ]
        )

        let projected = ProviderErrorDiagnosticProjectionPolicy.project(wrapped)

        #expect(projected == "Provider error")
        #expect(!projected.contains("fixture-nested-secret"))
        #expect(!projected.contains("fixture-query-secret"))
        #expect(!projected.contains("/private/tmp/provider-response.json"))
    }

    @Test("typed nested provider errors retain only stable categories")
    func typedNestedErrorsRemainPayloadFree() {
        let network = ProviderErrorDiagnosticProjectionPolicy.project(
            LLMError.networkError(underlying: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: unsafeNestedProviderPayload]
            ))
        )
        let decoding = ProviderErrorDiagnosticProjectionPolicy.project(
            LLMError.decodingError(underlying: LeakyNestedError(message: unsafeNestedProviderPayload))
        )
        let bodyMapped = ProviderErrorDiagnosticProjectionPolicy.project(
            ProviderHTTPErrorAdapter.classify(
                statusCode: 429,
                headers: ["Retry-After": "23"]
            ).llmError
        )

        #expect(network == "Network error")
        #expect(decoding == "Decoding error")
        #expect(bodyMapped == "HTTP 429")
    }

    @Test("fallback aggregate keeps a bounded stable classification")
    func fallbackAggregateIsBounded() {
        let event = FallbackRouter.FallbackEvent(
            providerID: "fixture-provider",
            errorDescription: unsafeNestedProviderPayload,
            attempt: 1
        )
        let projected = ProviderErrorDiagnosticProjectionPolicy.project(
            FallbackRouterError.allProvidersFailed([event])
        )

        #expect(projected == "All providers failed (attempts=1)")
        #expect(projected.count <= 128)
        #expect(!projected.contains("fixture-nested-secret"))
        #expect(!projected.contains("fixture-query-secret"))
    }

    @Test("WorkflowRunner preserves aggregate classification and cancellation")
    func workflowRunnerNestedOutletsRemainStable() async throws {
        let template = WorkflowTemplate(
            id: "aggregate-error",
            name: "Provider聚合错误",
            description: "聚合错误诊断边界",
            steps: [
                WorkflowStep(
                    id: "step",
                    type: .custom,
                    title: "步骤",
                    promptTemplate: "固定提示",
                    outputKey: "output"
                )
            ]
        )

        do {
            _ = try await WorkflowRunner().run(
                template: template,
                inputs: [:],
                provider: AggregateFailingWorkflowProvider()
            )
            Issue.record("expected the workflow provider to fail")
        } catch let error as WorkflowError {
            guard case let .stepFailed(_, _, underlying) = error else {
                Issue.record("unexpected workflow error shape")
                return
            }
            #expect(underlying == "All providers failed (attempts=1)")
            #expect(!underlying.contains("fixture"))
        } catch {
            Issue.record("unexpected non-workflow error shape")
        }

        #expect(
            ProviderErrorDiagnosticProjectionPolicy.project(CancellationError())
                == "Request was cancelled"
        )
    }
}

private struct LeakyNestedError: Error, LocalizedError, CustomStringConvertible, Sendable {
    let message: String

    var errorDescription: String? { message }
    var description: String { message }
}

private struct AggregateFailingWorkflowProvider: WorkflowProvider {
    func generate(prompt _: String, step _: WorkflowStep) async throws -> String {
        throw FallbackRouterError.allProvidersFailed([
            FallbackRouter.FallbackEvent(
                providerID: "fixture-provider",
                errorDescription: unsafeNestedProviderPayload,
                attempt: 1
            )
        ])
    }
}
