import Foundation

// MARK: - Assistant streaming seam (D-CHAT-03)
//
// The default production producer is `AgentLoop`, which historically called
// only the buffered `LLMProvider.sendMessage` and therefore could surface at
// most ONE final text delta per turn. This seam lets a provider expose
// incremental assistant TEXT for a tools-aware request without touching the
// buffered `sendMessage` contract:
//
// - `LLMAssistantStreamEvent.textDelta` carries append-only reply text.
// - `LLMAssistantStreamEvent.completed` carries the exact same
//   `LLMResponse` a buffered `sendMessage` call would have returned
//   (full text, usage, native tool calls). It is the authoritative terminal
//   fact every wrapper (budget recording, tool-call tracking, retry, runtime
//   route) reconciles against.
//
// CONTRACT (must be honored by every conformance, buffered or streaming):
// 1. The `completed` event MUST be the final event before the stream
//    finishes normally, and MUST carry a response whose `text` equals the
//    concatenation of all streamed `textDelta`s when the implementation
//    streams text at all (wrappers that synthesize emit deltas only via the
//    completed response and stream none).
// 2. `textDelta` MUST only carry content that is legitimately part of the
//    user-visible assistant reply. Tool-call arguments (native `tool_calls`
//    payloads or legacy `{"tool_calls": …}` envelope JSON) MUST NEVER be
//    streamed as text deltas — they belong exclusively to the `completed`
//    response. Consumers render streamed deltas directly into the transcript
//    and cannot retract them.
// 3. Throwing before any event (or failing acquisition) keeps the buffered
//    error semantics unchanged; mid-stream failures throw from the stream.
//
// Wrapper conformance discipline (zero-behavior-change rule): a wrapper whose
// inner provider does NOT conform synthesizes a single `.completed` event from
// its OWN buffered `sendMessage` path, so retry/budget/fallback/route/receipt
// semantics stay byte-for-byte identical to today. Only when the inner
// provider conforms does the wrapper forward the real event stream.

/// One event on the assistant-text streaming seam of a tools-aware request.
public enum LLMAssistantStreamEvent: Sendable {
    /// Append-only user-visible assistant reply text.
    case textDelta(String)
    /// Append-only model reasoning text for display only. It is never part of
    /// `completed.text` and must not be echoed back as ordinary history.
    case thinkingDelta(String)
    /// Authoritative terminal response (identical shape to the buffered
    /// `sendMessage` result). Always the last event of a successful stream.
    case completed(LLMResponse)
}

/// Optional streaming capability of an `LLMProvider` for the AgentLoop path.
///
/// `LLMProvider.streamMessage` is text-only (no tools). This seam is the
/// tools-aware counterpart used by `AgentLoop` when an
/// `onAssistantTextDelta` handler is installed.
public protocol AssistantStreamingLLMProvider: LLMProvider {
    nonisolated(nonsending) func streamAssistantMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error>

    /// Shared parent/child thinking API. nil preserves the existing wire request.
    nonisolated(nonsending) func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error>

}

public extension AssistantStreamingLLMProvider {
    nonisolated(nonsending) func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?, thinkingLevel: ThinkingLevel?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        // Existing wrappers remain source compatible. They must explicitly
        // forward a non-nil level when the protected call chain is connected.
        return try await streamAssistantMessage(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature)
    }
}

/// Buffered synthesis helper shared by all wrapper conformances: produces a
/// one-event stream carrying exactly the buffered `LLMResponse`.
public func llmAssistantCompletedStream(
    _ response: LLMResponse
) -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.completed(response))
        continuation.finish()
    }
}
