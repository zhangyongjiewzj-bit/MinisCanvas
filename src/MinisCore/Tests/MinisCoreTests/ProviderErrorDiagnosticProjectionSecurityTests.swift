import Foundation
import Testing
@testable import MinisCore

private let unsafeProviderDiagnostic =
    "Authorization: Bearer fixture-provider-secret https://example.test/raw?token=fixture-query-secret "
        + "/private/tmp/provider-response.json "
        + String(repeating: "p", count: 640) + "\u{0000}"

@Suite("Provider error diagnostic projection security", .serialized)
struct ProviderErrorDiagnosticProjectionSecurityTests {
    @Test("unknown provider errors use a fixed payload-free projection")
    func unknownProviderErrorIsFailClosed() {
        let projected = ProviderErrorDiagnosticProjectionPolicy.project(
            LeakyProviderError(message: unsafeProviderDiagnostic)
        )

        #expect(projected == "Provider error")
        #expect(projected.count <= 128)
        #expect(!projected.contains("fixture-provider-secret"))
        #expect(!projected.contains("fixture-query-secret"))
        #expect(!projected.contains("/private/tmp/provider-response.json"))
    }

    @Test("known provider and transport errors keep stable classifications")
    func knownErrorsRemainStableAndPayloadFree() {
        let providerError = ProviderErrorDiagnosticProjectionPolicy.project(
            LLMError.providerError(message: unsafeProviderDiagnostic)
        )
        let transportError = ProviderErrorDiagnosticProjectionPolicy.project(
            URLError(.timedOut)
        )
        let endpointError = ProviderErrorDiagnosticProjectionPolicy.project(
            ProviderEndpointPolicyError.unsupportedScheme("fixture-token")
        )

        #expect(providerError == "Provider error")
        #expect(transportError == "Network error")
        #expect(endpointError == "Provider endpoint rejected")
        #expect(!providerError.contains("fixture-provider-secret"))
        #expect(!endpointError.contains("fixture-token"))
    }

    @Test("WorkflowRunner real provider failure outlet is payload-free")
    func workflowRunnerUsesSharedProjection() async throws {
        let template = WorkflowTemplate(
            id: "provider-error",
            name: "Provider错误",
            description: "Provider错误诊断边界",
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
                provider: LeakyWorkflowProvider(message: unsafeProviderDiagnostic)
            )
            Issue.record("expected the workflow provider to fail")
        } catch let error as WorkflowError {
            guard case let .stepFailed(_, _, underlying) = error else {
                Issue.record("unexpected workflow error shape")
                return
            }
            #expect(underlying == "Provider error")
            #expect(!underlying.contains("fixture-provider-secret"))
            #expect(!underlying.contains("fixture-query-secret"))
            #expect(!underlying.contains("/private/tmp/provider-response.json"))
            #expect(underlying.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            })
        } catch {
            Issue.record("unexpected non-workflow error shape")
        }
    }
}

private struct LeakyProviderError: Error, LocalizedError, CustomStringConvertible, Sendable {
    let message: String

    var errorDescription: String? { message }
    var description: String { message }
}

private struct LeakyWorkflowProvider: WorkflowProvider {
    let message: String

    func generate(prompt _: String, step _: WorkflowStep) async throws -> String {
        throw LeakyProviderError(message: message)
    }
}
