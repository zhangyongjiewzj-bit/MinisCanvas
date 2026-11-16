import Foundation
import Testing
@testable import MinisCore

private final class AnthropicAssemblyBarrier2556: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var onMain = false
    private var expired = false

    var ranOnMainThread: Bool { lock.withLock { onMain } }
    var timedOut: Bool { lock.withLock { expired } }

    func waitUntilEntered() async -> Bool {
        // The fixture waiter must not occupy a Swift cooperative executor.
        // This bounded worker owns the sole resume, including late completion.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func blockAtRealAssembly() {
        lock.withLock { onMain = Thread.isMainThread }
        entered.signal()
        let didExpire = release.wait(timeout: .now() + 3) == .timedOut
        lock.withLock { expired = didExpire }
    }
}

@Suite("D-PERF-06 Anthropic production request assembly", .serialized)
struct AnthropicRequestAssembly2556Tests {
    @Test @MainActor
    func controlledRequestAssemblyKeepsMainActorResponsive() async throws {
        let barrier = AnthropicAssemblyBarrier2556()
        let provider = AnthropicProvider(
            apiKey: "unit-test-key", basePath: "not-a-valid-url",
            requestAssemblyProbe: { barrier.blockAtRealAssembly() }
        )
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: String(repeating: "x", count: 64_000))],
                systemPrompt: nil, maxTokens: 64, temperature: nil
            )
        }
        defer { barrier.release.signal() }
        let entered = await barrier.waitUntilEntered()
        guard entered else {
            pending.cancel()
            Issue.record("production Anthropic request assembly was not reached")
            return
        }
        let heartbeat = Task { @MainActor in true }
        #expect(await heartbeat.value)
        #expect(!barrier.ranOnMainThread)
        #expect(!barrier.timedOut)
        barrier.release.signal()
        do {
            _ = try await pending.value
            Issue.record("unsafe URL unexpectedly reached transport")
        } catch let error as LLMError {
            guard case .providerError = error else {
                Issue.record("expected URL validation error after responsive assembly")
                return
            }
        }
    }

    @Test @MainActor
    func rebindDuringAssemblyCannotDispatchFrozenRequest() async throws {
        let barrier = AnthropicAssemblyBarrier2556()
        let provider = AnthropicProvider(
            apiKey: "unit-test-key", basePath: "https://mock.test",
            requestAssemblyProbe: { barrier.blockAtRealAssembly() }
        )
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "before rebind")],
                systemPrompt: nil, maxTokens: 64, temperature: nil
            )
        }
        defer { barrier.release.signal() }
        let entered = await barrier.waitUntilEntered()
        guard entered else {
            pending.cancel()
            Issue.record("production Anthropic request assembly was not reached")
            return
        }
        provider.model = LLMModel(id: "changed-model", displayName: "Changed", provider: "Anthropic")
        barrier.release.signal()
        do {
            _ = try await pending.value
            Issue.record("superseded Anthropic request reached transport")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected cancelled superseded request")
                return
            }
        }
    }

    @Test @MainActor
    func cancellationDuringAssemblyCannotDispatchRequest() async throws {
        let barrier = AnthropicAssemblyBarrier2556()
        let provider = AnthropicProvider(
            apiKey: "unit-test-key", basePath: "https://mock.test",
            requestAssemblyProbe: { barrier.blockAtRealAssembly() }
        )
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "cancel me")],
                systemPrompt: nil, maxTokens: 64, temperature: nil
            )
        }
        defer { barrier.release.signal() }
        let entered = await barrier.waitUntilEntered()
        guard entered else {
            pending.cancel()
            Issue.record("production Anthropic request assembly was not reached")
            return
        }
        pending.cancel()
        barrier.release.signal()
        do {
            _ = try await pending.value
            Issue.record("cancelled Anthropic request reached transport")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected cancelled request")
                return
            }
        }
    }
}
