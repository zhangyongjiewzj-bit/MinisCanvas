import Foundation

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - OpenAI Responses API（/v1/responses）wire 类型与解析工具
//
// 规格来源：OpenAI 官方 OpenAPI 规范（openai/openai-openapi，createResponse /
// ResponseStreamEvent）。与 Chat Completions 的关键区别：
//   - 请求体用 `input`（替代 messages）+ `instructions`（替代 system role），
//     token 上限字段是 `max_output_tokens`；
//   - 非流式响应是 Response 对象：文本在 output[].content[] 中
//     type=="output_text" 的 text 字段；
//   - 流式是带 `event:` 名称的 SSE（response.created / response.output_text.delta
//     / response.completed / error …），没有 Chat Completions 的 `[DONE]` 哨兵。
// 本文件只放纯数据类型与纯函数解析器，Provider 逻辑在
// OpenAIResponsesProvider.swift（便于离线单测）。

// MARK: - Errors

/// Responses API 协议层错误（解析/流语义），与 HTTP 层 LLMError.httpStatus 互补。
public enum ResponsesAPIError: Error, Equatable, Sendable, LocalizedError {
    /// 响应中没有任何 message 文本输出（output 为空 / 无 output_text 部件）。
    case emptyResponseOutput
    /// 流在未收到 response.completed / response.failed 前就结束了（中途 EOF）。
    case prematureStreamEnd
    /// 服务端在流内发送了 `error` 事件。
    case serverStreamError(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponseOutput:
            return "Responses API returned an empty response: no message text in output"
        case .prematureStreamEnd:
            return "Responses API stream ended before response.completed"
        case .serverStreamError(let code, let message):
            return "Responses API stream error\(code.map { " [\($0)]" } ?? ""): \(message)"
        }
    }
}

// MARK: - Request body

/// POST /v1/responses 请求体。字段按 Responses API 官方规格命名。
public struct ResponsesAPIRequestBody: Encodable, @unchecked Sendable {
    public struct InputMessage: Encodable, Sendable {
        /// 内容部件：input_text / input_image / input_audio。
        public struct ContentPart: Encodable, Sendable {
            public struct ImageURL: Encodable, Sendable {
                public let url: String
                public init(url: String) { self.url = url }
            }
            public struct InputAudio: Encodable, Sendable {
                public let data: String
                public let format: String
                public init(data: String, format: String) {
                    self.data = data
                    self.format = format
                }
            }

            /// 部件类型："input_text" | "input_image" | "input_audio"。
            public let type: String
            /// input_text 的文本内容。
            public let text: String?
            /// input_image 的图片引用（外链 URL 或 data: URL）。
            public let imageURL: ImageURL?
            /// input_audio 的音频数据（base64 + 格式）。
            public let inputAudio: InputAudio?

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
                case inputAudio = "input_audio"
            }

            public init(type: String, text: String?, imageURL: ImageURL?, inputAudio: InputAudio?) {
                self.type = type
                self.text = text
                self.imageURL = imageURL
                self.inputAudio = inputAudio
            }

            /// Responses 规格：`input_image.image_url` 是字符串（外链或 data: URL），
            /// 不是 Chat Completions 的 `{"url": ...}` 对象；对象形态会被服务端以 400 拒绝。
            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(type, forKey: .type)
                try container.encodeIfPresent(text, forKey: .text)
                try container.encodeIfPresent(imageURL?.url, forKey: .imageURL)
                try container.encodeIfPresent(inputAudio, forKey: .inputAudio)
            }

            public static func textPart(_ text: String) -> ContentPart {
                ContentPart(type: "input_text", text: text, imageURL: nil, inputAudio: nil)
            }

            /// 历史里的助手文本：Responses 只接受 `output_text`（或 refusal），`input_text` 会被拒。
            public static func outputTextPart(_ text: String) -> ContentPart {
                ContentPart(type: "output_text", text: text, imageURL: nil, inputAudio: nil)
            }

            public static func imagePart(dataURL: String) -> ContentPart {
                ContentPart(type: "input_image", text: nil, imageURL: ImageURL(url: dataURL), inputAudio: nil)
            }

            public static func audioPart(base64Data: String, format: String) -> ContentPart {
                ContentPart(type: "input_audio", text: nil, imageURL: nil,
                            inputAudio: InputAudio(data: base64Data, format: format))
            }
        }

        /// "user" | "assistant"（Responses API 的 input item 角色）。
        public let role: String
        public let content: [ContentPart]

        public init(role: String, content: [ContentPart]) {
            self.role = role
            self.content = content
        }
    }

    /// Mixed Responses input item. Function calls and function outputs are
    /// separate items in the Responses protocol, unlike Chat Completions'
    /// assistant `tool_calls` plus `tool` role pair.
    public enum InputItem: Encodable, Sendable {
        case message(InputMessage)
        case functionCall(callID: String, name: String, arguments: String)
        case functionCallOutput(callID: String, output: String)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            switch self {
            case .message(let message):
                try container.encode(message.role, forKey: DynamicCodingKey("role"))
                try container.encode(message.content, forKey: DynamicCodingKey("content"))
            case .functionCall(let callID, let name, let arguments):
                try container.encode("function_call", forKey: DynamicCodingKey("type"))
                try container.encode(callID, forKey: DynamicCodingKey("call_id"))
                try container.encode(name, forKey: DynamicCodingKey("name"))
                try container.encode(arguments, forKey: DynamicCodingKey("arguments"))
            case .functionCallOutput(let callID, let output):
                try container.encode("function_call_output", forKey: DynamicCodingKey("type"))
                try container.encode(callID, forKey: DynamicCodingKey("call_id"))
                try container.encode(output, forKey: DynamicCodingKey("output"))
            }
        }
    }

    /// 模型 ID。
    public let model: String
    /// 输入：纯字符串（单条纯文本消息）或 item 数组；编码为 JSON 字符串或数组。
    public let input: AnyCodableInput
    /// 系统指令（Responses API 中取代 system/developer role 消息）。
    public let instructions: String?
    /// 最大输出 token（Responses API 字段名，非 max_tokens）。
    public let maxOutputTokens: Int
    /// 采样温度（可选）。
    public let temperature: Double?
    /// 是否流式。
    public let stream: Bool
    /// Responses function tools in the flat Responses wire shape.
    public let tools: [[String: Any]]

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case stream
        case tools
    }

    public init(model: String, input: AnyCodableInput, instructions: String?,
                maxOutputTokens: Int, temperature: Double?, stream: Bool,
                tools: [[String: Any]] = []) {
        self.model = model
        self.input = input
        self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.stream = stream
        self.tools = tools
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(input, forKey: .input)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encode(stream, forKey: .stream)
        if !tools.isEmpty {
            let value = MCPJSONValue.array(tools.map { MCPJSONValue.fromAny($0) })
            try container.encode(value, forKey: .tools)
        }
    }
}

/// `input` 字段的二态编码：纯文本快捷形式（String）或完整 item 数组形式。
public enum AnyCodableInput: Encodable, Sendable {
    case text(String)
    case messages([ResponsesAPIRequestBody.InputMessage])
    case items([ResponsesAPIRequestBody.InputItem])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try container.encode(s)
        case .messages(let items):
            try container.encode(items)
        case .items(let items):
            try container.encode(items)
        }
    }
}

// MARK: - Response parsing（纯函数，便于离线单测）

public enum ResponsesAPIResponseParser {

    /// Extract text and native function calls from a non-streaming Responses
    /// response. A function-call-only response is valid and does not trigger
    /// the empty-text error.
    public static func extractResponse(from responseJSON: [String: Any]) throws -> (text: String, status: String?, toolCalls: [LLMToolCall]) {
        let status = responseJSON["status"] as? String
        if let errorObj = responseJSON["error"] as? [String: Any], let message = errorObj["message"] as? String {
            throw ResponsesAPIError.serverStreamError(code: errorObj["code"] as? String, message: message)
        }
        let output = responseJSON["output"] as? [[String: Any]] ?? []
        var text = ""
        var toolCalls: [LLMToolCall] = []
        for item in output {
            switch item["type"] as? String {
            case "message":
                let content = item["content"] as? [[String: Any]] ?? []
                for part in content where part["type"] as? String == "output_text" {
                    if let value = part["text"] as? String { text += value }
                }
            case "function_call":
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                let id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "call_\(toolCalls.count)"
                let rawArguments = (item["arguments"] as? String) ?? "{}"
                let arguments = (try? JSONSerialization.jsonObject(with: Data(rawArguments.utf8))) as? [String: Any] ?? [:]
                toolCalls.append(LLMToolCall(id: id, name: name, rawArguments: rawArguments, arguments: arguments))
            default:
                continue
            }
        }
        guard !text.isEmpty || !toolCalls.isEmpty else {
            throw ResponsesAPIError.emptyResponseOutput
        }
        return (text, status, toolCalls)
    }

    /// 从非流式 Response 对象中提取 message 文本与终止状态。
    /// - Returns: (text, status)；status 为顶层 status（completed/incomplete/failed…）。
    /// - Throws: `ResponsesAPIError.emptyResponseOutput` 当 output 中没有文本。
    public static func extractMessageText(from responseJSON: [String: Any]) throws -> (text: String, status: String?) {
        let extracted = try extractResponse(from: responseJSON)
        guard !extracted.text.isEmpty else { throw ResponsesAPIError.emptyResponseOutput }
        return (extracted.text, extracted.status)
    }

    /// 解析 Responses API usage：input_tokens / output_tokens，
    /// input_tokens 保留协议的全部输入数；cached_tokens 单独保留。
    public static func parseUsage(_ json: [String: Any]) -> LLMUsage? {
        guard !json.isEmpty, json["input_tokens"] != nil || json["output_tokens"] != nil else { return nil }
        let inputTokens = json["input_tokens"] as? Int ?? 0
        let outputTokens = json["output_tokens"] as? Int ?? 0
        let cached = (json["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return LLMUsage(inputTokens: inputTokens, outputTokens: outputTokens,
                        cacheCreationInputTokens: nil, cacheReadInputTokens: cached,
                        cacheHitInputTokens: (json["input_tokens"] as? Int).flatMap { total in
                            guard total >= 0, (cached ?? 0) >= 0, (cached ?? 0) <= total else { return nil }
                            return total
                        })
    }

    /// 流式事件语义（对 SSEStreamParser 产出的 event 做 Responses 语义解释）。
    public enum StreamEvent: Equatable, Sendable {
        /// response.output_text.delta 的文本增量。
        case textDelta(String)
        /// response.completed：携带解析好的 usage（文本已由 delta 累积）。
        case completed(LLMUsage?)
        /// response.failed：携带 response.error.message。
        case failed(String)
        /// response.incomplete：携带 incomplete_details.reason（如 max_output_tokens）。
        case incomplete(String?)
        /// `error` 事件：code + message。
        case error(code: String?, message: String)
        /// 其余事件（response.created / response.in_progress /
        /// response.output_item.* / response.content_part.* /
        /// response.output_text.done 等）无需处理。
        case ignored
    }

    /// 按 event 名称（SSE `event:` 字段）分发；data 解析失败 → ignored。
    /// 注意：Responses API 的流终止信号是 response.completed/failed/incomplete
    /// 事件，不存在 Chat Completions 的 `[DONE]`。
    public static func interpret(eventName: String?, dataJSON: [String: Any]) -> StreamEvent {
        switch eventName {
        case "response.output_text.delta":
            if let delta = dataJSON["delta"] as? String, !delta.isEmpty {
                return .textDelta(delta)
            }
            return .ignored
        case "response.completed":
            let response = dataJSON["response"] as? [String: Any] ?? [:]
            let usage = (response["usage"] as? [String: Any]).flatMap { parseUsage($0) }
            return .completed(usage)
        case "response.failed":
            let response = dataJSON["response"] as? [String: Any] ?? [:]
            let message = (response["error"] as? [String: Any])?["message"] as? String
                ?? "response failed"
            return .failed(message)
        case "response.incomplete":
            let response = dataJSON["response"] as? [String: Any] ?? [:]
            let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
            return .incomplete(reason)
        case "error":
            return .error(code: dataJSON["code"] as? String,
                          message: dataJSON["message"] as? String ?? "unknown stream error")
        default:
            // response.created / response.in_progress / response.output_item.added /
            // response.content_part.added / response.output_text.done /
            // response.content_part.done / response.output_item.done /
            // response.output_text.annotation.added / reasoning 摘要事件等。
            return .ignored
        }
    }
}
