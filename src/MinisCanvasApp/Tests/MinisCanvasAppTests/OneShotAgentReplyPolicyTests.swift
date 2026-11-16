import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// oneShotAgentReply 路径的脚本化 Provider：第一次返回工具调用，之后返回纯文本。
/// 记录收到的 tool-role 回填内容，用于断言工具结果是否为 is_error（未执行）。
private final class OneShotToolEmittingProvider: LLMProvider, @unchecked Sendable {
    let name = "OneShot policy provider"
    var model = LLMModel(id: "one-shot-policy", displayName: "OneShot policy", provider: "Test")
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]

    private let toolName: String
    private let toolArguments: [String: Any]
    private var callIndex = 0
    private var toolResultMessages: [String] = []

    init(toolName: String, toolArguments: [String: Any]) {
        self.toolName = toolName
        self.toolArguments = toolArguments
    }

    var receivedToolResults: [String] { toolResultMessages }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "OK", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        for message in messages where message.role == .tool {
            toolResultMessages.append(message.content)
        }
        defer { callIndex += 1 }
        if callIndex == 0 {
            return LLMResponse(
                text: "",
                stopReason: "tool_calls",
                usage: nil,
                toolCalls: [LLMToolCall(
                    id: "one-shot-tool-1",
                    name: toolName,
                    rawArguments: (try? JSONSerialization.data(withJSONObject: toolArguments))
                        .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}",
                    arguments: toolArguments
                )]
            )
        }
        return LLMResponse(text: "OK", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// S7：oneShotAgentReply 是纯文本路径 —— 模型发起的任何工具调用都必须被策略层
/// 拒绝（底层执行 = 0），不得在 HOME 下落地副作用。
@Suite("S7 oneShotAgentReply policy")
struct OneShotAgentReplyPolicyTests {

    private func markerURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".oneShotBypassMarker-\(UUID().uuidString).txt")
    }

    @Test func modelInitiatedFileWriteDoesNotLand() async throws {
        let marker = markerURL()
        defer { try? FileManager.default.removeItem(at: marker) }

        let provider = OneShotToolEmittingProvider(
            toolName: "file_write",
            toolArguments: ["path": marker.path, "content": "PWN"]
        )
        let reply = try await AgentLoopChatEngine.oneShotAgentReply(
            provider: provider,
            systemPrompt: "只输出纯文本，禁止调用工具",
            userText: "调整节点内容",
            maxTokens: 256
        )

        // 核心判据：file_write 不得落地（底层执行 = 0）。
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // 工具结果必须是 is_error（被策略拒绝），而不是成功写盘回执。
        #expect(provider.receivedToolResults.contains { $0.contains("Error executing tool file_write") })
        // 纯文本路径保持可用。
        #expect(reply == "OK")
    }

    @Test func modelInitiatedShellExecuteDoesNotLand() async throws {
        let marker = markerURL()
        defer { try? FileManager.default.removeItem(at: marker) }

        let provider = OneShotToolEmittingProvider(
            toolName: "shell_execute",
            toolArguments: ["command": "touch '\(marker.path)'"]
        )
        let reply = try await AgentLoopChatEngine.oneShotAgentReply(
            provider: provider,
            systemPrompt: "只输出纯文本，禁止调用工具",
            userText: "总结节点",
            maxTokens: 256
        )

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(provider.receivedToolResults.contains { $0.contains("Error executing tool shell_execute") })
        #expect(reply == "OK")
    }
}
