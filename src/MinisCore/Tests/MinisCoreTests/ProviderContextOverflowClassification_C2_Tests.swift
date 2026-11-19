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

    // C-1：兼容端 code 不是 context_length_exceeded，只在 message 里写原因。
    @Test(arguments: [
        // DeepSeek / vLLM 系
        #"{"error":{"message":"This model's maximum context length is 131072 tokens. However, you requested 140000 tokens.","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#,
        // 通义 DashScope 兼容模式
        #"{"error":{"message":"Range of input length should be [1, 129024]","type":"invalid_request_error","param":null,"code":"invalid_parameter_error"}}"#,
        // Ollama
        #"{"error":{"message":"prompt too long; exceeded max context length by 1200 tokens","type":"api_error","param":null,"code":null}}"#,
        // OpenAI Responses 文案、code 缺省
        #"{"error":{"message":"Your input exceeds the context window of this model. Please adjust your input and try again.","type":"invalid_request_error"}}"#,
        // 转发 Anthropic 报错的 OpenAI 兼容网关
        #"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum","type":"invalid_request_error"}}"#,
    ])
    func openAICompatibleMessageOnlyOverflowMapsToTypedError(body: String) {
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key")
        #expect(isOverflow(provider.mapHTTPError(statusCode: 400, body: body, headers: [:])))
        #expect(isOverflow(provider.mapHTTPError(statusCode: 413, body: body, headers: [:])))
        // 同样的 message 在 500 上不算超窗。
        #expect(!isOverflow(provider.mapHTTPError(statusCode: 500, body: body, headers: [:])))
    }

    @Test func anthropicCompatibleGatewayPhraseNotAtStartMapsToTypedError() {
        let provider = AnthropicProvider(apiKey: "fixture-key")
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"Upstream said: prompt is too long: 250000 tokens"}}"#
        #expect(isOverflow(provider.mapHTTPError(statusCode: 400, body: body, headers: [:])))
    }

    // C3-10：较新的 Anthropic 模型对“输入 + max_tokens 超窗”回的说明不含 “prompt is too long”。
    @Test func anthropicInputPlusMaxTokensExceedingTheWindowMapsToTypedError() {
        let provider = AnthropicProvider(apiKey: "fixture-key")
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"input length and `max_tokens` exceed context limit: 180000 + 64000 > 200000, decrease input length or `max_tokens` and try again"}}"#
        #expect(isOverflow(provider.mapHTTPError(statusCode: 400, body: body, headers: [:])))
        // 不是 invalid_request_error 的同样文字、或状态码不是 400，都不算。
        let wrongType = #"{"type":"error","error":{"type":"api_error","message":"input length and `max_tokens` exceed context limit"}}"#
        #expect(!isOverflow(provider.mapHTTPError(statusCode: 400, body: wrongType, headers: [:])))
        #expect(!isOverflow(provider.mapHTTPError(statusCode: 500, body: body, headers: [:])))
    }

    @Test func responsesMessageOnlyOverflowMapsToTypedError() {
        let body = #"{"error":{"message":"Your input exceeds the context window of this model.","type":"invalid_request_error"}}"#
        #expect(isOverflow(responsesProvider().mapHTTPError(statusCode: 400, body: body)))
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

    // E-1：网关（nginx、CDN）的 413 常是 HTML 或纯文本，不是 JSON；413 本身就是“请求太大”，三家都要认出来。
    @Test(arguments: [
        "<html><head><title>413 Request Entity Too Large</title></head><body>nginx</body></html>",
        "Request Entity Too Large",
        "",
    ])
    func nonJSON413MapsToTypedErrorOnAllProviders(body: String) {
        #expect(isOverflow(OpenAICompatibleProvider(apiKey: "fixture-key")
            .mapHTTPError(statusCode: 413, body: body, headers: [:])))
        #expect(isOverflow(AnthropicProvider(apiKey: "fixture-key")
            .mapHTTPError(statusCode: 413, body: body, headers: [:])))
        #expect(isOverflow(responsesProvider().mapHTTPError(statusCode: 413, body: body)))
        // 400 带同样的非 JSON 正文仍不算超窗。
        #expect(!isOverflow(OpenAICompatibleProvider(apiKey: "fixture-key")
            .mapHTTPError(statusCode: 400, body: body, headers: [:])))
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
        // 这里只覆盖直接传 body 的映射函数；流式入口读错误体的整条路径见 OpenAIResponsesAssistantStreamTests。
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

    @Test func failureProjectionOffersCompactAndRetryForContextOverflow() {
        let zh = ChatGenerationFailureProjection(error: LLMError.contextLengthExceeded, locale: Locale(identifier: "zh-Hans"))
        #expect(zh.category == .contextLength)
        #expect(!zh.retryable)
        // 对齐 Claude Code：不原样重试，改为"压缩后重试"。
        #expect(zh.actionableRecoveryAction == .compactAndRetry)
        #expect(zh.httpStatus == nil)
        #expect(zh.message.contains("上下文"))
        let en = ChatGenerationFailureProjection(error: LLMError.contextLengthExceeded, locale: Locale(identifier: "en"))
        // F2-03：界面只说中文，任何区域设置都给同一句中文指引。
        #expect(en.message == zh.message)
    }
}
