import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - B3 边界：OptimizePromptService 输入边界测试
//
// 本轮补边界（现有 OptimizePromptServiceTests 5 用例未覆盖）：
// 1. 空字符串输入 → 原样透传给 provider（无服务层守卫；记录契约，见 issues 报告 P3）
// 2. 纯空白输入 → 原样透传（服务层只 trim 结果、不 trim 输入）
// 3. 超长输入（100_000 字符）→ 不截断、完整透传
// 4. providerFactory 抛错 → 错误传播、sendMessage 不被调用

/// 捕获型 stub：记录收到的消息内容与调用次数，可配置返回 / 抛错 / 工厂抛错。
final class CapturingOptimizeStub: LLMProvider, @unchecked Sendable {
    var name: String { "CaptureStub" }
    var model: LLMModel = LLMModel(id: "stub", displayName: "Stub", provider: "Test")
    var result: Result<String, Error> = .success("优化后文本")
    private let lock = NSLock()
    private var _capturedMessages: [LLMMessage] = []
    private var _sendCount = 0

    var capturedMessages: [LLMMessage] {
        lock.lock(); defer { lock.unlock() }
        return _capturedMessages
    }

    var sendCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _sendCount
    }

    /// 同步记录（async 上下文直接调 NSLock 会被 Swift 6 拒绝，经此同步方法中转）
    private func record(_ messages: [LLMMessage]) {
        lock.lock()
        _capturedMessages = messages
        _sendCount += 1
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        record(messages)
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

@Suite("B3 优化提示词服务边界")
struct OptimizePromptBoundaryTests {

    private func makeService(_ stub: CapturingOptimizeStub) -> OptimizePromptService {
        OptimizePromptService(providerFactory: { stub })
    }

    @Test func emptyStringInputIsForwardedVerbatim() async throws {
        let stub = CapturingOptimizeStub()
        stub.result = .success("ok")

        let text = try await makeService(stub).optimize("")

        #expect(text == "ok")
        #expect(stub.sendCount == 1)
        let message = try #require(stub.capturedMessages.first)
        #expect(message.role == .user)
        #expect(message.content == "",
                "记录契约：服务层对空输入无守卫、原样透传（UI 需自行禁用空输入；见 issues 报告 P3）")
    }

    @Test func whitespaceOnlyInputIsForwardedAsIs() async throws {
        let stub = CapturingOptimizeStub()
        stub.result = .success("ok")
        let whitespace = " \n\t  \r\n "

        let text = try await makeService(stub).optimize(whitespace)

        #expect(text == "ok")
        let message = try #require(stub.capturedMessages.first)
        #expect(message.content == whitespace,
                "记录契约：输入不做 trim（服务层仅 trim 结果）；若 UI 无空白校验会空转一次 LLM 调用")
    }

    @Test func veryLongInputIsNotTruncated() async throws {
        let stub = CapturingOptimizeStub()
        stub.result = .success("ok")
        let longInput = String(repeating: "超长分镜提示词内容。", count: 100_000 / 9 + 1)

        let text = try await makeService(stub).optimize(longInput)

        #expect(text == "ok")
        let message = try #require(stub.capturedMessages.first)
        #expect(message.content.count == longInput.count,
                "超长输入不得被截断；期望 \\(longInput.count) 实际 \\(message.content.count)")
        #expect(message.content == longInput)
    }

    @Test func providerFactoryErrorPropagatesAndSkipsSend() async {
        struct FactoryFailure: Error, Equatable {}

        let service = OptimizePromptService(providerFactory: { throw FactoryFailure() })

        await #expect(throws: FactoryFailure.self) {
            try await service.optimize("原稿")
        }
        // 工厂抛错路径：无法拿到 provider，sendMessage 不可能被调用（无 crash / 无吞错）
    }
}
