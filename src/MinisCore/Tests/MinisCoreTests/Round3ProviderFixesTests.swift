import Foundation
import Testing
@testable import MinisCore

// 第三轮修复（服务商域）：R3-07 温度、R3-08 输出上限、B-8 DeepSeek reasoning_content 回传、
// V-6 工具参数超限、V-11 Responses 流失败日志短语。
// 全部离线：每个套件自带 URLProtocol 桩；E-1（非 JSON 的 413）在 ProviderContextOverflowClassification_C2_Tests。

// MARK: - 离线桩

private final class R3WireURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Data, String))?

    static func reset(contentType: String = "application/json", body: Data) {
        requests = []
        responder = { _ in (body, contentType) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [R3WireURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func body(of request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let object = try JSONSerialization.jsonObject(with: try #require(data))
        return try #require(object as? [String: Any])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (body, contentType) = Self.responder?(request) ?? (Data(), "application/json")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let r3OpenAIJSON = Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8)
private let r3AnthropicJSON = Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)

private func r3SSE(_ payloads: [String]) -> Data {
    Data(payloads.map { "data: \($0)\n\n" }.joined().utf8)
}

private func r3JSON(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func r3Model(_ id: String) throws -> LLMModel {
    try #require(LLMModel.allModels.first { $0.id == id })
}

private func r3Completed(_ stream: AsyncThrowingStream<LLMAssistantStreamEvent, Error>) async throws -> LLMResponse {
    var completed: LLMResponse?
    for try await event in stream {
        if case .completed(let response) = event { completed = response }
    }
    return try #require(completed)
}

// MARK: - R3-07：不传温度时，各家请求体都不带温度字段

@Suite("R3-07 温度不进请求体", .serialized)
struct R3TemperatureWireTests {
    @Test("OpenAI 兼容线路：nil 温度时 gpt-5、o3、gpt-4o 的请求体没有 temperature",
          arguments: ["gpt-5", "o3", "gpt-4o"])
    func openAIChatOmitsTemperature(modelID: String) async throws {
        R3WireURLProtocol.reset(body: r3OpenAIJSON)
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key", model: try r3Model(modelID),
                                                session: R3WireURLProtocol.session())
        _ = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "你好")],
                                           systemPrompt: nil, maxTokens: 16, temperature: nil)
        let body = try R3WireURLProtocol.body(of: try #require(R3WireURLProtocol.requests.first))
        #expect(body["model"] as? String == modelID)
        #expect(body["temperature"] == nil)
    }

    @Test("OpenAI 兼容线路：调用方明确给了温度时仍照传（工具内部的确定性调用不受影响）")
    func openAIChatKeepsExplicitTemperature() async throws {
        R3WireURLProtocol.reset(body: r3OpenAIJSON)
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key", model: .gpt4oMini,
                                                session: R3WireURLProtocol.session())
        _ = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "你好")],
                                           systemPrompt: nil, maxTokens: 16, temperature: 0)
        let body = try R3WireURLProtocol.body(of: try #require(R3WireURLProtocol.requests.first))
        #expect(body["temperature"] as? Double == 0)
    }

    @Test("Anthropic 线路：nil 温度时请求体没有 temperature")
    func anthropicOmitsTemperature() async throws {
        R3WireURLProtocol.reset(body: r3AnthropicJSON)
        let provider = AnthropicProvider(apiKey: "fixture-key", model: .claudeSonnet46,
                                         session: R3WireURLProtocol.session())
        _ = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "你好")],
                                           systemPrompt: nil, maxTokens: 16, temperature: nil)
        let body = try R3WireURLProtocol.body(of: try #require(R3WireURLProtocol.requests.first))
        #expect(body["temperature"] == nil)
    }

    @Test("Responses 线路：nil 温度时请求体没有 temperature")
    func responsesOmitsTemperature() throws {
        let request = ResponsesAPIRequestBody(model: "gpt-5", input: .text("你好"), instructions: nil,
                                              maxOutputTokens: 16, temperature: nil, stream: false)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let body = try #require(object as? [String: Any])
        #expect(body["temperature"] == nil)
        #expect(body["model"] as? String == "gpt-5")
    }
}

private final class R3SummaryRecorder: LLMProvider, @unchecked Sendable {
    var name: String { "R3SummaryRecorder" }
    var model = LLMModel(id: "r3-summary", displayName: "R3", provider: "test", contextWindow: 200_000)
    private let lock = NSLock()
    private var seen: [Double?] = []
    private var replies: [(String, String)]
    init(replies: [(String, String)]) { self.replies = replies }
    var temperatures: [Double?] { lock.withLock { seen } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let reply: (String, String) = lock.withLock {
            seen.append(temperature)
            return replies.isEmpty ? ("摘要", "end_turn") : replies.removeFirst()
        }
        return LLMResponse(text: reply.0, stopReason: reply.1, usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens,
                              temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("R3-07 摘要请求不传温度")
struct R3SummaryTemperatureTests {
    @Test("摘要请求（含被截断后的重试）都不传温度")
    func summaryRequestsCarryNoTemperature() async throws {
        let provider = R3SummaryRecorder(replies: [("半截摘要", "length"), ("完整摘要：下一步 X", "end_turn")])
        let messages = (0..<10).map {
            LLMMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "MSG_\($0)_正文")
        }
        _ = try await LossySummaryCompaction.compact(messages: messages, keepRecent: 2, provider: provider)
        let temperatures = provider.temperatures
        #expect(temperatures.count == 2)
        #expect(temperatures.allSatisfy { $0 == nil })
    }
}

// MARK: - R3-08：内置模型的输出上限

@Suite("R3-08 内置模型输出上限")
struct R3OutputLimitCatalogTests {
    @Test("官方输出上限低于聊天默认值（32000）的内置模型都声明了上限",
          arguments: [("gpt-4o", 16384), ("gpt-4o-mini", 16384), ("openai/gpt-4o", 16384)])
    func lowLimitModelsDeclareTheirLimit(modelID: String, limit: Int) throws {
        #expect(try r3Model(modelID).maxOutputTokens == limit)
    }

    @Test("内置清单里已声明的上限都是正数")
    func declaredLimitsArePositive() {
        for model in LLMModel.allModels {
            if let limit = model.maxOutputTokens { #expect(limit > 0, "\(model.id)") }
        }
    }
}

// MARK: - B-8：DeepSeek 思考模式 + 工具调用，同轮回传 reasoning_content

@Suite("B-8 reasoning_content 回传", .serialized)
struct R3ReasoningReplayTests {
    private func reasoningCall(_ reasoning: String?) -> LLMToolCall {
        var call = LLMToolCall(id: "call_1", name: "file_read", rawArguments: "{\"path\":\"a\"}",
                               arguments: ["path": "a"])
        call.reasoningContent = reasoning
        return call
    }

    private func history(_ reasoning: String?) -> [LLMMessage] {
        [LLMMessage(role: .user, content: "读文件"),
         LLMMessage(role: .assistant, content: "", toolCalls: [reasoningCall(reasoning)]),
         LLMMessage(role: .tool, content: "内容", toolCallID: "call_1")]
    }

    @Test("助手消息序列化：只在声明了字段、且是带思考文本的助手消息时写 reasoning_content")
    func messageDictReplaysOnlyForDeclaredField() {
        let assistant = LLMMessage(role: .assistant, content: "", toolCalls: [reasoningCall("先读文件")])
        #expect(OpenAICompatibleProvider.openAIMessageDict(assistant, reasoningField: "reasoning_content")["reasoning_content"] as? String == "先读文件")
        #expect(OpenAICompatibleProvider.openAIMessageDict(assistant)["reasoning_content"] == nil)
        let empty = LLMMessage(role: .assistant, content: "", toolCalls: [reasoningCall("")])
        #expect(OpenAICompatibleProvider.openAIMessageDict(empty, reasoningField: "reasoning_content")["reasoning_content"] == nil)
        let noCalls = LLMMessage(role: .assistant, content: "好")
        #expect(OpenAICompatibleProvider.openAIMessageDict(noCalls, reasoningField: "reasoning_content")["reasoning_content"] == nil)
        let user = LLMMessage(role: .user, content: "你好", toolCalls: [reasoningCall("不该出现")])
        #expect(OpenAICompatibleProvider.openAIMessageDict(user, reasoningField: "reasoning_content")["reasoning_content"] == nil)
    }

    @Test("请求体：DeepSeek 思考模型回传，其他模型不回传，没有思考文本不回传",
          arguments: [("deepseek-v4-flash", "先读文件", true), ("gpt-4o", "先读文件", false), ("deepseek-v4-flash", nil, false)])
    func requestBodyReplaysOnlyForDeepSeekThinking(modelID: String, reasoning: String?, expectsReplay: Bool) async throws {
        R3WireURLProtocol.reset(body: r3OpenAIJSON)
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key", model: try r3Model(modelID),
                                                customBaseURL: "https://api.deepseek.com", appendV1Suffix: false,
                                                session: R3WireURLProtocol.session())
        _ = try await provider.sendMessage(messages: history(reasoning), systemPrompt: nil,
                                           maxTokens: 16, temperature: nil)
        let body = try R3WireURLProtocol.body(of: try #require(R3WireURLProtocol.requests.first))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        if expectsReplay {
            #expect(assistant["reasoning_content"] as? String == "先读文件")
        } else {
            #expect(assistant["reasoning_content"] == nil)
        }
    }

    @Test("流式：思考增量拼成完整 reasoning_content，挂在第一个工具调用上")
    func streamAttachesReasoningToFirstToolCall() async throws {
        let frames = [
            #"{"choices":[{"delta":{"reasoning_content":"先"}}]}"#,
            #"{"choices":[{"delta":{"reasoning_content":"读文件"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"a\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ]
        R3WireURLProtocol.reset(contentType: "text/event-stream", body: r3SSE(frames))
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key", model: .deepSeekV4Flash,
                                                customBaseURL: "https://api.deepseek.com", appendV1Suffix: false,
                                                session: R3WireURLProtocol.session())
        let stream = try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "读文件")], systemPrompt: nil,
            tools: [], maxTokens: 16, temperature: nil)
        let response = try await r3Completed(stream)
        let call = try #require(response.toolCalls.first)
        #expect(call.id == "call_1")
        #expect(call.reasoningContent == "先读文件")
        #expect(response.text.isEmpty)
    }

    @Test("非流式：message.reasoning_content 挂在第一个工具调用上")
    func bufferedAttachesReasoningToFirstToolCall() {
        let json: [String: Any] = ["choices": [["message": [
            "role": "assistant", "content": "", "reasoning_content": "先读文件",
            "tool_calls": [["id": "call_1", "type": "function",
                            "function": ["name": "file_read", "arguments": "{\"path\":\"a\"}"]]],
        ], "finish_reason": "tool_calls"]]]
        let response = OpenAICompatibleProvider.parseChatCompletionsResult(json)
        #expect(response.toolCalls.first?.reasoningContent == "先读文件")
    }
}

// MARK: - V-6：工具参数超限

@Suite("V-6 工具参数超限", .serialized)
struct R3OversizedArgumentsTests {
    private func openAIItem(arguments: String) -> [String: Any] {
        ["id": "call_big", "type": "function", "function": ["name": "file_write", "arguments": arguments]]
    }

    @Test("OpenAI 形态：超过 64KB 或数组超过 64 项的调用变成带标记的占位调用，参数为空对象")
    func openAIOversizedBecomesFlaggedPlaceholder() throws {
        let hugeBytes = "{\"content\":\"" + String(repeating: "x", count: ProviderToolCallBoundary.maximumArgumentsBytes) + "\"}"
        let wideArray = try r3JSON(["items": Array(repeating: 1, count: ProviderToolCallBoundary.maximumArrayElements + 1)])
        for raw in [hugeBytes, wideArray] {
            let call = try #require(ProviderToolCallBoundary.parseOpenAIAdmittingOversized(openAIItem(arguments: raw)))
            #expect(call.argumentsExceedLimit)
            #expect(call.id == "call_big" && call.name == "file_write")
            #expect(call.rawArguments == "{}" && call.arguments.isEmpty)
        }
        // 原有入口不变：超限仍返回 nil。
        #expect(ProviderToolCallBoundary.parseOpenAI(openAIItem(arguments: hugeBytes)) == nil)
    }

    @Test("OpenAI 形态：正常调用不带标记；不是合法 JSON（例如被输出上限截断）仍被丢弃")
    func openAIOrdinaryAndMalformedAreUnchanged() throws {
        let ordinary = try #require(ProviderToolCallBoundary.parseOpenAIAdmittingOversized(
            openAIItem(arguments: "{\"path\":\"a\"}")))
        #expect(!ordinary.argumentsExceedLimit)
        #expect(ordinary.arguments["path"] as? String == "a")
        #expect(ProviderToolCallBoundary.parseOpenAIAdmittingOversized(openAIItem(arguments: "{\"path\":")) == nil)
    }

    @Test("Anthropic 形态：数组超过 64 项的调用变成带标记的占位调用")
    func anthropicOversizedBecomesFlaggedPlaceholder() throws {
        let item: [String: Any] = ["type": "tool_use", "id": "call_big", "name": "file_write",
            "input": ["items": Array(repeating: "x", count: ProviderToolCallBoundary.maximumArrayElements + 1)]]
        let call = try #require(ProviderToolCallBoundary.parseAnthropicAdmittingOversized(item))
        #expect(call.argumentsExceedLimit && call.id == "call_big" && call.arguments.isEmpty)
        let calls = AnthropicProvider.parseNativeToolCalls(from: ["content": [item]])
        #expect(calls.count == 1 && calls[0].argumentsExceedLimit)
    }

    @Test("非流式整条路径：超限调用保留在响应里，没有被悄悄丢掉")
    func bufferedResponseKeepsOversizedCall() {
        let wide = (try? r3JSON(["items": Array(repeating: 1, count: 65)])) ?? "{}"
        let json: [String: Any] = ["choices": [["message": [
            "role": "assistant", "content": "好的", "tool_calls": [openAIItem(arguments: wide)],
        ], "finish_reason": "tool_calls"]]]
        let response = OpenAICompatibleProvider.parseChatCompletionsResult(json)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.argumentsExceedLimit == true)
    }

    @Test("OpenAI 流式：参数累计超过 64KB 不再整轮失败，调用以超限标记收尾")
    func openAIStreamOversizedDoesNotFailTheTurn() async throws {
        let chunk = String(repeating: "x", count: 30_000)
        let first = try r3JSON(["choices": [["delta": ["tool_calls": [[
            "index": 0, "id": "call_big", "type": "function",
            "function": ["name": "file_write", "arguments": "{\"content\":\"" + chunk],
        ]]]]]])
        func more(_ text: String) throws -> String {
            try r3JSON(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": text]]]]]]])
        }
        let frames = [first, try more(chunk), try more(chunk), try more("\"}"),
                      #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "[DONE]"]
        R3WireURLProtocol.reset(contentType: "text/event-stream", body: r3SSE(frames))
        let provider = OpenAICompatibleProvider(apiKey: "fixture-key", model: .gpt4o,
                                                session: R3WireURLProtocol.session())
        let stream = try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "写个大文件")], systemPrompt: nil,
            tools: [], maxTokens: 16, temperature: nil)
        let response = try await r3Completed(stream)
        #expect(response.toolCalls.count == 1)
        let call = try #require(response.toolCalls.first)
        #expect(call.argumentsExceedLimit && call.id == "call_big" && call.name == "file_write")
        #expect(call.rawArguments == "{}")
    }

    @Test("Anthropic 流式：参数累计超过 64KB 不再整轮失败，调用以超限标记收尾")
    func anthropicStreamOversizedDoesNotFailTheTurn() async throws {
        let chunk = String(repeating: "x", count: 30_000)
        let frames: [[String: Any]] = [
            ["type": "message_start", "message": ["usage": ["input_tokens": 10, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0,
             "content_block": ["type": "tool_use", "id": "call_big", "name": "file_write"]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": "{\"content\":\"" + chunk]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": chunk]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": chunk]],
            ["type": "content_block_delta", "index": 0,
             "delta": ["type": "input_json_delta", "partial_json": "\"}"]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 20]],
            ["type": "message_stop"],
        ]
        R3WireURLProtocol.reset(contentType: "text/event-stream", body: r3SSE(try frames.map(r3JSON)))
        let provider = AnthropicProvider(apiKey: "fixture-key", model: .claudeSonnet46,
                                         session: R3WireURLProtocol.session())
        let stream = try await provider.streamAssistantMessage(
            messages: [LLMMessage(role: .user, content: "写个大文件")], systemPrompt: nil,
            tools: [], maxTokens: 16, temperature: nil)
        let response = try await r3Completed(stream)
        #expect(response.toolCalls.count == 1)
        let call = try #require(response.toolCalls.first)
        #expect(call.argumentsExceedLimit && call.id == "call_big" && call.name == "file_write")
    }
}

// MARK: - V-11：Responses 流失败的本机日志短语

@Suite("V-11 Responses 流失败日志")
struct R3ResponsesStreamFailureLogTests {
    @Test("本地写死的原因短语原样写进日志")
    func localReasonPhraseIsLogged() {
        let line = OpenAIResponsesProvider.streamFailureDiagnostic(
            code: nil, message: "invalid output item identity", serverReported: false)
        #expect(line.contains("invalid output item identity"))
    }

    @Test("服务端事件只记‘服务端返回失败事件’和已识别的固定错误码，不写服务端原文")
    func serverMessageIsNeverLogged() {
        let leak = "SERVER-ECHO-sk-live-123 请求体片段"
        for code in [nil, "server_error", "context_length_exceeded", "insufficient_quota"] as [String?] {
            let line = OpenAIResponsesProvider.streamFailureDiagnostic(code: code, message: leak, serverReported: true)
            #expect(!line.contains(leak))
            #expect(!line.contains("sk-live"))
            #expect(line.contains("服务端返回失败事件"))
        }
        let unknown = OpenAIResponsesProvider.streamFailureDiagnostic(
            code: "weird\ncode<secret>", message: "x", serverReported: true)
        #expect(!unknown.contains("secret"))
    }
}
