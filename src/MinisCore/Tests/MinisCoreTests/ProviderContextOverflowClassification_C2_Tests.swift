import Foundation
import Testing
@testable import MinisCore

/// C2（分类部分）：三家 Provider 把“上下文超长”映射为 `LLMError.contextLengthExceeded`，
/// 且错误对象不保留任何远端正文。循环里“压缩一次、重试一次”的用例归 C-L2
/// （ProviderContextOverflowRecovery_C2_Loop_Tests），依赖本文件的分类。
///
/// 夹具均为合成响应体：
/// - OpenAI：错误体形态 {"error":{"code":"context_length_exceeded",...}}，来自设计稿/先例 b53f1e7e；
///   developers.openai.com 的 error-codes 页面未收录该 code，故该 code 字面量“未核实官方文档”。
/// - Anthropic：官方 context-windows 页写明输入本身超窗时返回 400 invalid_request_error（“prompt is too long”）；
///   完整 message 的后缀数字格式未核实，夹具里的数字为合成。
@Suite("C2 上下文超长分类")
struct ProviderContextOverflowClassificationC2Tests {
    private static let leakMarker = "SECRET-PROMPT-ECHO-7731"

    private static let openAIOverflowBody = """
    {"error":{"message":"This model's maximum context length is 128000 tokens. However, your messages resulted in 130001 tokens. \(leakMarker)","type":"invalid_request_error","param":"messages","code":"context_length_exceeded"}}
    """
    private static let anthropicOverflowBody = """
    {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum \(leakMarker)"},"request_id":"req_synthetic"}
    """

    private func responsesProvider() -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            apiKey: "fixture-key", model: .gpt4oMini, customBaseURL: "https://mock.test",
            appendV1Suffix: true, session: nil, providerName: "OpenAI Responses",
            attemptCheckpointDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("c2-" + UUID().uuidString, isDirectory: true))
    }

    private func isOverflow(_ error: LLMError) -> Bool {
        if case .contextLengthExceeded = error { return true }
        return false
    }

    private func assertNoRemoteText(_ error: LLMError) {
        for text in [String(describing: error), error.technicalDetail, error.friendlyMessage(locale: Locale(identifier: "zh")),
                     error.userMessageEN, error.userMessageZH, error.localizedDescription] {
            #expect(!text.contains(Self.leakMarker))
            #expect(!text.contains("128000"))
            #expect(!text.contains("210000"))
        }
    }

    @Test func openAICompatibleOverflowBodyMapsToTypedError() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key")
        let error = provider.mapHTTPError(statusCode: 400, body: Self.openAIOverflowBody, headers: [:])
        #expect(isOverflow(error))
        assertNoRemoteText(error)
    }

    @Test func openAICompatibleOtherBadRequestStaysHTTPStatus() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key")
        let body = #"{"error":{"message":"bad param","type":"invalid_request_error","code":"invalid_value"}}"#
        let error = provider.mapHTTPError(statusCode: 400, body: body, headers: [:])
        guard case .httpStatus(let code, _) = error else { Issue.record("expected httpStatus"); return }
        #expect(code == 400)
    }

    @Test func openAICompatibleOverflowCodeOnNon400IsNotClassified() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key")
        let error = provider.mapHTTPError(statusCode: 500, body: Self.openAIOverflowBody, headers: [:])
        #expect(!isOverflow(error))
    }

    @Test func openAICompatibleNonJSONBodyStaysHTTPStatus() {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key")
        let error = provider.mapHTTPError(statusCode: 400, body: "context_length_exceeded", headers: [:])
        #expect(!isOverflow(error))
    }

    @Test func anthropicOverflowBodyMapsToTypedError() {
        let provider = AnthropicProvider(apiKey: "fixture-key")
        let error = provider.mapHTTPError(statusCode: 400, body: Self.anthropicOverflowBody, headers: [:])
        #expect(isOverflow(error))
        assertNoRemoteText(error)
    }

    @Test func anthropicOtherInvalidRequestStaysHTTPStatus() {
        let provider = AnthropicProvider(apiKey: "fixture-key")
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.0.content: Input should be a valid list"}}"#
        let error = provider.mapHTTPError(statusCode: 400, body: body, headers: [:])
        guard case .httpStatus(let code, _) = error else { Issue.record("expected httpStatus"); return }
        #expect(code == 400)
    }

    @Test func anthropicPromptTooLongPhraseOnNon400IsNotClassified() {
        let provider = AnthropicProvider(apiKey: "fixture-key")
        let error = provider.mapHTTPError(statusCode: 529, body: Self.anthropicOverflowBody, headers: [:])
        #expect(!isOverflow(error))
    }

    @Test func responsesOverflowBodyMapsToTypedErrorWhereTheBodyIsAvailable() {
        // 仅覆盖带 body 的入口（非流式 HTTP 错误）。流式入口当前不读错误体，见回报“未覆盖”。
        let error = responsesProvider().mapHTTPError(statusCode: 400, body: Self.openAIOverflowBody)
        #expect(isOverflow(error))
        assertNoRemoteText(error)
    }

    @Test func overflowIsNeitherRetryableNorFallbackable() {
        let error = LLMError.contextLengthExceeded
        #expect(!error.isRetryable)
        #expect(!error.isFallbackable)
        #expect(error.providerFailureCategory == nil)
    }

    @Test func failureProjectionExplainsContextOverflowWithoutOfferingRetry() {
        let zh = ChatGenerationFailureProjection(error: LLMError.contextLengthExceeded, locale: Locale(identifier: "zh-Hans"))
        #expect(zh.category == .contextLength)
        #expect(!zh.retryable)
        #expect(!zh.fallbackable)
        #expect(zh.actionableRecoveryAction == .none)
        #expect(zh.httpStatus == nil)
        #expect(zh.message.contains("上下文"))
        let en = ChatGenerationFailureProjection(error: LLMError.contextLengthExceeded, locale: Locale(identifier: "en"))
        // F2-03：界面只说中文，任何区域设置都给同一句中文指引。
        #expect(en.message == zh.message)
    }
}
