import Foundation
import Testing
@testable import MinisCore

// 快档修复 线 C：RED。
// M10：前回合工具结果占位必须是事实说明；4：Responses 的 incomplete(...) 视为截断。

private final class QuickFixCStopProvider: LLMProvider, @unchecked Sendable {
    let stopReason: String
    init(stopReason: String) { self.stopReason = stopReason }
    var name: String { "QuickFixCStop" }
    var model = LLMModel(id: "qfc-stop", displayName: "QFC", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "尚未完成的回答", stopReason: stopReason, usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("QuickFixC 工具结果占位与截断")
struct QuickFixCTruncationAndToolPlaceholderTests {
    @Test("M10：占位明确说明工具已真实执行、正文未保留需重新调用，并保留统计")
    func toolOutputPlaceholderStatesFactsAndKeepsMetrics() throws {
        let output = "line1\nline2\n"
        let suffix = try #require(
            ToolOutputSummary.capture(toolName: "file_read", output: output).displaySuffix)
        #expect(suffix.contains("已真实执行"))
        #expect(suffix.contains("需要时重新"))
        #expect(suffix.contains("返回 \(output.utf8.count) 字节、2 行"))
    }

    @Test("M10：shell 结果占位同样说明已真实执行，并保留退出码统计")
    func shellPlaceholderStatesFacts() throws {
        let output = #"{"exit_code":7,"stdout":"a\n","stderr":""}"#
        let suffix = try #require(
            ToolOutputSummary.capture(toolName: "shell_execute", output: output).displaySuffix)
        #expect(suffix.contains("已真实执行"))
        #expect(suffix.contains("需要时重新"))
        #expect(suffix.contains("退出码 7"))
    }

    @Test("Responses 的 incomplete(max_output_tokens) 按截断处理而非正常完成",
          arguments: ["incomplete(max_output_tokens)", "incomplete(content_filter)"])
    func incompleteStopReasonIsTruncation(reason: String) async {
        let loop = AgentLoop(maxIterations: 2)
        let executor = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory)
        var observed: Error?
        do {
            _ = try await loop.run(
                messages: [.init(role: .user, content: "长回答")], systemPrompt: nil,
                provider: QuickFixCStopProvider(stopReason: reason),
                toolExecutor: executor, tools: [])
        } catch { observed = error }
        #expect((observed as? AgentLoopError) == .outputTruncated,
                "incomplete(...) 不应被当作正常完成")
    }
}
