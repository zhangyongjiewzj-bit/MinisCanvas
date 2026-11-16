import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Unified completion contract for tests that explicitly opt into the
/// legacy Canvas command adapter. The adapter still executes through the
/// injected coordinator; this only awaits its observable completion.
@MainActor
func awaitLegacyCanvasCommandCompletion(_ bridge: BridgeStore) async {
    guard let task = bridge.lastCanvasMutationTask else {
        Issue.record("legacy Canvas command did not publish a completion task")
        return
    }
    await task.value
}

/// Explicit adapter for legacy tests that intentionally do not exercise
/// Composer policy. Production engines must keep the snapshot overload
/// fail-closed; only these test doubles may forward to their legacy seam.
protocol ComposerSnapshotForwardingTestEngine: ChatAgentEngine {}

extension ComposerSnapshotForwardingTestEngine {
    nonisolated(nonsending) func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            turnID: turnID
        )
    }

    @MainActor
    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            turnID: turnID,
            composerSnapshot: composerSnapshot
        )
    }

    @MainActor
    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            turnID: turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity
        )
    }
}

/// Offline ChatStore adapter used by the legacy streaming regression tests.
/// It delegates to the injected mock provider, while opting into the explicit
/// test-only snapshot forwarding contract above.
final class ComposerSnapshotMockChatEngine: ComposerSnapshotForwardingTestEngine, @unchecked Sendable {
    var isAvailable: Bool { false }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let source = try await provider.streamMessage(
            messages: history.map {
                LLMMessage(
                    role: $0.role == .user ? .user : .assistant,
                    content: $0.content,
                    images: $0.llmImages,
                    audios: $0.llmAudios
                )
            },
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: 0.7
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        if Task.isCancelled {
                            break
                        }
                        switch chunk {
                        case .started:
                            break
                        case .text(let text):
                            continuation.yield(.textDelta(text))
                        case .usage(let usage):
                            continuation.yield(.usage(usage))
                        case .finished(let reason):
                            continuation.yield(.done(stopReason: mapLLMStopReason(reason)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func interrupt() {}

    func compactContext(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}
