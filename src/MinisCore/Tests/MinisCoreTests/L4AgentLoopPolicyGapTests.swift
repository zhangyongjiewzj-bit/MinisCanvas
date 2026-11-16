import Foundation
import Testing
@testable import MinisCore

struct L4AgentLoopPolicyGapTests {
    @Test("legacy builtin executor cannot write when approval is absent")
    func nilApprovalGateDoesNotAuthorizeBuiltinFileWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("L4AgentLoopPolicyGap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("should-not-write.txt")
        let provider = L4ScriptedProvider(responses: [
            L4ToolCallEnvelope.make(
                id: "write-1",
                name: "file_write",
                input: ["path": target.path, "content": "unauthorized"]
            ),
            "done",
        ])
        let loop = AgentLoop(maxIterations: 2, approvalGate: nil, loopDetector: nil)
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "write")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            tools: [
                AgentToolDefinition(
                    name: "file_write",
                    description: "write",
                    parameters: [:],
                    required: []
                ),
            ]
        )

        #expect(result.messages.last?.content == "done")
        #expect(FileManager.default.fileExists(atPath: target.path) == false)
        #expect(result.messages.contains { message in
            message.toAgentContentParts().contains { part in
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part {
                    return isError && !content.isEmpty
                }
                return false
            }
        })
    }
}

private final class L4ScriptedProvider: LLMProvider, @unchecked Sendable {
    let name = "l4-scripted"
    var model = LLMModel(id: "l4-model", displayName: "L4 Model", provider: "l4-scripted")
    let capabilities: Set<ProviderCapability> = [.tools]
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let response = responses.isEmpty ? "done" : responses.removeFirst()
        return LLMResponse(text: response, stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private enum L4ToolCallEnvelope {
    static func make(id: String, name: String, input: [String: Any]) -> String {
        let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}
