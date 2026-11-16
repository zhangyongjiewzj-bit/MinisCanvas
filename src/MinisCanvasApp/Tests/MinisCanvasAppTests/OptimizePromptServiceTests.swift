import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - B3 文本节点「优化提示词」服务测试

/// 脚本化 stub：可配置返回文本 / 抛错，捕获收到的 systemPrompt 与消息。
final class OptimizeStubProvider: LLMProvider, @unchecked Sendable {
    var name: String { "Stub" }
    var model: LLMModel = LLMModel(id: "stub", displayName: "Stub", provider: "Test")
    var result: Result<String, Error> = .success("优化后文本")
    private let lock = NSLock()
    private var _capturedSystemPrompt: String?

    var capturedSystemPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _capturedSystemPrompt
    }

    /// 同步记录（async 上下文直接调 NSLock 会被 Swift 6 拒绝，经此同步方法中转）
    private func capture(_ prompt: String?) {
        lock.lock()
        _capturedSystemPrompt = prompt
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        capture(systemPrompt)
        switch result {
        case .success(let text):
            return LLMResponse(text: text, stopReason: "end_turn", usage: nil)
        case .failure(let error):
            throw error
        }
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("B3 优化提示词服务")
struct OptimizePromptServiceTests {

    private func makeService(_ stub: OptimizeStubProvider) -> OptimizePromptService {
        OptimizePromptService(providerFactory: { stub })
    }

    @Test func returnsProviderText() async throws {
        let stub = OptimizeStubProvider()
        stub.result = .success("精修后的分镜提示词")
        let text = try await makeService(stub).optimize("原始分镜草稿")
        #expect(text == "精修后的分镜提示词")
    }

    @Test func sendsDraftAndEngineerSystemPrompt() async throws {
        let stub = OptimizeStubProvider()
        stub.result = .success("ok")
        _ = try await makeService(stub).optimize("把画面拉近到人物面部")
        let prompt = try #require(stub.capturedSystemPrompt)
        #expect(prompt.contains("提示词工程师"))
        #expect(prompt.contains("不虚构内容"))
    }

    @Test func trimsWhitespaceAroundResult() async throws {
        let stub = OptimizeStubProvider()
        stub.result = .success("  精修结果  \n")
        let text = try await makeService(stub).optimize("原稿")
        #expect(text == "精修结果")
    }

    @Test func throwsEmptyResultError() async {
        let stub = OptimizeStubProvider()
        stub.result = .success("   \n")
        await #expect(throws: OptimizePromptService.ServiceError.emptyResult) {
            try await makeService(stub).optimize("原稿")
        }
    }

    @Test func propagatesProviderError() async {
        let stub = OptimizeStubProvider()
        stub.result = .failure(URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) {
            try await makeService(stub).optimize("原稿")
        }
    }
}
