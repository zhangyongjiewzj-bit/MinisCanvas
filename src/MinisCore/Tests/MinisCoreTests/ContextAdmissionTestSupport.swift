import Foundation
@testable import MinisCore

/// Scripted external-boundary Provider shared by the C2/C10 loop tests.
///
/// `deliver` stands in for the App's delivery projection: its last stage is
/// `ContextReductionState.apply`, which is what the App installs. The provider
/// records what it was actually handed after that stage.
final class ScriptedWindowProvider: LLMProvider, @unchecked Sendable {
    enum Outcome {
        case response(LLMResponse)
        case failure(Error)
    }
    var name: String { "ScriptedWindow" }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var delivered: [[LLMMessage]] = []
    private let deliver: @Sendable ([LLMMessage]) -> [LLMMessage]

    init(
        model: LLMModel = .deepSeekChat,
        outcomes: [Outcome],
        deliver: @escaping @Sendable ([LLMMessage]) -> [LLMMessage] = { $0 }
    ) {
        self.model = model
        self.outcomes = outcomes
        self.deliver = deliver
    }

    var requests: [[LLMMessage]] { lock.withLock { delivered } }
    var callCount: Int { lock.withLock { delivered.count } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        let outcome: Outcome = lock.withLock {
            delivered.append(deliver(messages))
            return outcomes.isEmpty ? .response(LLMResponse(text: "完成", stopReason: nil, usage: nil)) : outcomes.removeFirst()
        }
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Returns a fixed large text for every tool call, so the history grows.
final class LargeResultToolExecutor: ToolExecutor, @unchecked Sendable {
    let characters: Int
    init(characters: Int) { self.characters = characters }
    func execute(name: String, input: [String: Any]) async throws -> String {
        String(repeating: "x", count: characters)
    }
}

func windowTestToolCallResponse(_ id: String, usage: LLMUsage? = nil) -> LLMResponse {
    let path = "/data/\(id).txt"
    return LLMResponse(
        text: "", stopReason: nil, usage: usage,
        toolCalls: [LLMToolCall(
            id: id, name: "file_read", rawArguments: "{\"path\":\"\(path)\"}", arguments: ["path": path])])
}

func windowTestCharacterCount(_ messages: [LLMMessage]) -> Int {
    messages.reduce(0) { $0 + $1.content.count }
}

/// Alternating user/assistant messages with identical text: the strict
/// verbatim Compactor can pack these into a much shorter dictionary form.
func windowTestRepeatedHistory(messages count: Int, characters: Int) -> [LLMMessage] {
    let text = String(repeating: "重复内容", count: characters / 4)
    return (0..<count).map { LLMMessage(role: $0 % 2 == 0 ? .user : .assistant, content: text) }
}
