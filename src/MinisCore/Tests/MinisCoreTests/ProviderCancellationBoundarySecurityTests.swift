import Foundation
import Testing
@testable import MinisCore

private enum Provider36CancellationKind: CaseIterable, Sendable {
    case taskCancellation
    case providerCancellation
    case urlSessionCancellation
    case wrappedURLSessionCancellation
}

private func provider36CancellationError(_ kind: Provider36CancellationKind) -> Error {
    switch kind {
    case .taskCancellation:
        return CancellationError()
    case .providerCancellation:
        return LLMError.cancelled
    case .urlSessionCancellation:
        return URLError(.cancelled)
    case .wrappedURLSessionCancellation:
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "fixture cancellation"]
        )
        return NSError(
            domain: "Provider36Wrapper",
            code: 36,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
    }
}

private struct Provider36WorkflowProvider: WorkflowProvider, Sendable {
    let kind: Provider36CancellationKind
    let cancelledStepID: String

    func generate(prompt _: String, step: WorkflowStep) async throws -> String {
        if step.id == cancelledStepID {
            throw provider36CancellationError(kind)
        }
        return "fixture-output"
    }
}

private struct Provider36ThrowingLLMProvider: LLMProvider, Sendable {
    let kind: Provider36CancellationKind

    var name: String { "provider36-primary" }
    var model: LLMModel = .gpt4oMini
    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }

    func sendMessage(
        messages _: [LLMMessage],
        systemPrompt _: String?,
        maxTokens _: Int,
        temperature _: Double?
    ) async throws -> LLMResponse {
        throw provider36CancellationError(kind)
    }

    func sendMessage(
        messages _: [LLMMessage],
        systemPrompt _: String?,
        tools _: [AgentToolDefinition],
        maxTokens _: Int,
        temperature _: Double?
    ) async throws -> LLMResponse {
        throw provider36CancellationError(kind)
    }

    func streamMessage(
        messages _: [LLMMessage],
        systemPrompt _: String?,
        maxTokens _: Int,
        temperature _: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw provider36CancellationError(kind)
    }
}

private struct Provider36SuccessLLMProvider: LLMProvider, Sendable {
    var name: String { "provider36-backup" }
    var model: LLMModel = .gpt4oMini
    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }

    func sendMessage(
        messages _: [LLMMessage],
        systemPrompt _: String?,
        maxTokens _: Int,
        temperature _: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "backup-output", stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages _: [LLMMessage],
        systemPrompt _: String?,
        tools _: [AgentToolDefinition],
        maxTokens _: Int,
        temperature _: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "backup-output", stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages _: [LLMMessage],
        systemPrompt _: String?,
        maxTokens _: Int,
        temperature _: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct Provider36TextOnlyCancellationError: Error, LocalizedError, Sendable {
    var errorDescription: String? { "cancelled" }
}

private actor Provider36Probe {
    private(set) var factoryIDs: [String] = []
    private(set) var retrySleeps = 0

    func recordFactory(_ id: String) {
        factoryIDs.append(id)
    }

    func recordRetrySleep() {
        retrySleeps += 1
    }
}

@Suite("Provider cancellation boundary", .serialized)
struct ProviderCancellationBoundarySecurityTests {
    private static let workflowTemplate = WorkflowTemplate(
        id: "provider36-cancellation",
        name: "Provider cancellation",
        description: "cancellation checkpoint boundary",
        steps: [
            WorkflowStep(
                id: "first",
                type: .custom,
                title: "First",
                promptTemplate: "fixed",
                outputKey: "first"
            ),
            WorkflowStep(
                id: "cancelled",
                type: .custom,
                title: "Cancelled",
                promptTemplate: "use {{first}}",
                inputs: ["first"],
                outputKey: "second"
            ),
        ]
    )

    @Test("all provider cancellation forms become CancellationError without checkpoint writes")
    func workflowCancellationIsTerminal() async {
        for kind in Provider36CancellationKind.allCases {
            let runner = WorkflowRunner()
            do {
                _ = try await runner.run(
                    template: Self.workflowTemplate,
                    inputs: [:],
                    provider: Provider36WorkflowProvider(kind: kind, cancelledStepID: "cancelled")
                )
                Issue.record("expected cancellation for \(kind)")
            } catch {
                #expect(error is CancellationError)
                #expect(!(error is WorkflowError))
                #expect(ProviderCancellationPolicy.isCancellation(error))
            }
            #expect(runner.completedOutputs(templateID: Self.workflowTemplate.id).isEmpty)
        }
    }

    @Test("cancellation words alone do not bypass ordinary failure handling")
    func textOnlyCancellationIsNotTypedCancellation() {
        #expect(!ProviderCancellationPolicy.isCancellation(Provider36TextOnlyCancellationError()))
    }

    @Test("plain router cancellation skips fallback trail and retry")
    func plainRouterCancellationDoesNotFallbackOrRetry() async {
        let probe = Provider36Probe()
        var router = FallbackRouter(
            providerIDs: ["primary", "backup"],
            retryPolicy: LLMRetryPolicy(
                maxRetries: 3,
                sleeper: { _ in await probe.recordRetrySleep() }
            )
        )

        do {
            _ = try await router.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil,
                maxTokens: 8,
                temperature: nil
            ) { id in
                await probe.recordFactory(id)
                if id == "primary" {
                    return Provider36ThrowingLLMProvider(kind: .urlSessionCancellation)
                }
                return Provider36SuccessLLMProvider()
            }
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
            #expect(!(error is FallbackRouterError))
        }

        #expect(await probe.factoryIDs == ["primary"])
        #expect(await probe.retrySleeps == 0)
        #expect(router.events.isEmpty)
    }

    @Test("tools and stream acquisition preserve cancellation terminal")
    func toolsAndStreamDoNotFallback() async {
        let messages = [LLMMessage(role: .user, content: "fixture")]
        let tools = [AgentToolDefinition(name: "fixture", description: "fixture", parameters: [:], required: [])]

        var toolsRouter = FallbackRouter(providerIDs: ["primary", "backup"])
        do {
            _ = try await toolsRouter.sendMessage(
                messages: messages,
                systemPrompt: nil,
                tools: tools,
                maxTokens: 8,
                temperature: nil
            ) { id in
                if id == "primary" {
                    return Provider36ThrowingLLMProvider(kind: .providerCancellation)
                }
                return Provider36SuccessLLMProvider()
            }
            Issue.record("expected tools cancellation")
        } catch {
            #expect(error is CancellationError)
            #expect(!(error is FallbackRouterError))
        }
        #expect(toolsRouter.events.isEmpty)

        var streamRouter = FallbackRouter(providerIDs: ["primary", "backup"])
        do {
            _ = try await streamRouter.streamMessage(
                messages: messages,
                systemPrompt: nil,
                maxTokens: 8,
                temperature: nil
            ) { id in
                if id == "primary" {
                    return Provider36ThrowingLLMProvider(kind: .wrappedURLSessionCancellation)
                }
                return Provider36SuccessLLMProvider()
            }
            Issue.record("expected stream cancellation")
        } catch {
            #expect(error is CancellationError)
            #expect(!(error is FallbackRouterError))
        }
        #expect(streamRouter.events.isEmpty)
    }
}
