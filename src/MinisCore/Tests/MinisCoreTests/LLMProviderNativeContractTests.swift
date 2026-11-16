import Testing
@testable import MinisCore

private final class TextOnlyNativeContractProvider: LLMProvider, @unchecked Sendable {
    let name = "Text only"
    var model = LLMModel(id: "text-only", displayName: "Text only", provider: "Test")
    private(set) var forwarded: (message: String, prompt: String?, limit: Int, temperature: Double?)?

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        forwarded = (messages.first?.content ?? "", systemPrompt, maxTokens, temperature)
        return LLMResponse(text: "text reply", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class ToolsNativeContractProvider: LLMProvider, @unchecked Sendable {
    let name = "Tools"
    var model = LLMModel(id: "tools", displayName: "Tools", provider: "Test")
    let capabilities: Set<ProviderCapability> = [.tools]
    private(set) var offered: [String] = []

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "plain", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        offered = tools.map(\.name)
        return LLMResponse(text: "native tools", stopReason: "tool_calls", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct LLMProviderNativeContractTests {
    private let tool = AgentToolDefinition(
        name: "echo", description: "Echo text", parameters: [:], required: []
    )

    @Test func emptyToolsKeepPlainSendAndArguments() async throws {
        let concrete = TextOnlyNativeContractProvider()
        let provider: any LLMProvider = concrete
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: "system", tools: [], maxTokens: 73, temperature: 0.25
        )
        #expect(response.text == "text reply")
        #expect(concrete.forwarded?.message == "hello")
        #expect(concrete.forwarded?.prompt == "system")
        #expect(concrete.forwarded?.limit == 73)
        #expect(concrete.forwarded?.temperature == 0.25)
        #expect(provider.capabilities.isEmpty)
    }

    @Test func nonemptyToolsFailClosedWithoutWireImplementation() async throws {
        let provider: any LLMProvider = TextOnlyNativeContractProvider()
        do {
            _ = try await provider.sendMessage(
                messages: [], systemPrompt: nil, tools: [tool], maxTokens: 8, temperature: nil
            )
            Issue.record("tool request unexpectedly fell back to text")
        } catch let error as LLMError {
            guard case .unsupportedCapability(.tools) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }

    @Test func existentialDispatchKeepsNativeToolOverride() async throws {
        let concrete = ToolsNativeContractProvider()
        let provider: any LLMProvider = concrete
        let response = try await provider.sendMessage(
            messages: [], systemPrompt: nil, tools: [tool], maxTokens: 8, temperature: nil
        )
        #expect(response.text == "native tools")
        #expect(concrete.offered == ["echo"])
    }
}
