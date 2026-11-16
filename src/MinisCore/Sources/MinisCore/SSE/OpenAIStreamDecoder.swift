import Foundation

/// Decoder for OpenAI Chat Completions SSE chunks (and their OpenAI-compatible
/// clones: DeepSeek, 百炼, Ollama, OpenRouter, …).
///
/// Each non-`[DONE]` `data:` payload is one JSON object like:
/// ```json
/// {"id":"chatcmpl-…","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}],"usage":null}
/// ```
/// Tool-call deltas ride in `delta.tool_calls[].function.{name,arguments}`.
public enum OpenAIStreamDecoder {

    /// A single decoded chunk.
    public struct Chunk: Equatable, Sendable {
        public var textDelta: String?
        /// Optional interleaved reasoning fragment emitted by compatible
        /// providers (for example DeepSeek/Kimi).
        public var reasoningDelta: String?
        public var finishReason: String?
        public var usage: LLMUsage?
        public var toolCallDeltas: [ToolCallDelta] = []

        public init(textDelta: String? = nil, reasoningDelta: String? = nil, finishReason: String? = nil, usage: LLMUsage? = nil, toolCallDeltas: [ToolCallDelta] = []) {
            self.textDelta = textDelta
            self.reasoningDelta = reasoningDelta
            self.finishReason = finishReason
            self.usage = usage
            self.toolCallDeltas = toolCallDeltas
        }

        public var hasToolCallDeltas: Bool { !toolCallDeltas.isEmpty }
    }

    /// Incremental tool-call fragment (OpenAI streams name + arguments across
    /// multiple chunks; arguments arrive as partial JSON strings).
    public struct ToolCallDelta: Equatable, Sendable {
        public let index: Int
        public let id: String?
        public let name: String?
        public let arguments: String?

        public init(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) {
            self.index = index
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    // MARK: - Decode

    /// Decode one chunk from a JSON object.
    public static func decodeChunk(_ json: [String: Any]) -> Chunk? {
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else {
            // Chunks without choices (e.g. a standalone usage chunk) may still
            // carry usage.
            if let usage = json["usage"] as? [String: Any] {
                return Chunk(usage: OpenAICompatibleProvider.parseChatCompletionsUsage(usage))
            }
            return nil
        }

        var chunk = Chunk()
        if let finish = choice["finish_reason"] as? String, finish != "null" {
            chunk.finishReason = finish
        }

        if let delta = choice["delta"] as? [String: Any] {
            chunk.textDelta = text(from: delta["content"])
            // Different OpenAI-compatible gateways use one of these names;
            // retain the fragment so an agent/UI consumer can choose whether
            // to render or merely echo it in the next request.
            chunk.reasoningDelta = (delta["reasoning_content"] as? String)
                ?? (delta["reasoning"] as? String)
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let index = tc["index"] as? Int ?? 0
                    let id = tc["id"] as? String
                    var name: String?
                    var arguments: String?
                    if let fn = tc["function"] as? [String: Any] {
                        name = fn["name"] as? String
                        arguments = fn["arguments"] as? String
                    }
                    chunk.toolCallDeltas.append(ToolCallDelta(index: index, id: id, name: name, arguments: arguments))
                }
            }
        }

        if let usage = json["usage"] as? [String: Any] {
            // Only attach usage when it contains real numeric data (some
            // clones emit a null usage object on ordinary text chunks).
            let parsed = OpenAICompatibleProvider.parseChatCompletionsUsage(usage)
            if (usage["prompt_tokens"] as? Int ?? 0) > 0
                || (usage["completion_tokens"] as? Int ?? 0) > 0 {
                chunk.usage = parsed
            }
        }

        return chunk
    }

    /// Decode one chunk from raw bytes.
    public static func decodeChunk(data: Data) -> Chunk? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decodeChunk(obj)
    }

    /// Decode one chunk from a `data:` payload string (without the `data:`
    /// prefix and without `[DONE]`).
    public static func decodeChunk(payload: String) -> Chunk? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return decodeChunk(data: data)
    }

    /// Extract text from both the classic string delta and the content-block
    /// array emitted by a few OpenAI-compatible gateways.
    private static func text(from value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        return text.isEmpty ? nil : text
    }

    // MARK: - Tool-call accumulation

    /// Accumulator that folds incremental tool-call deltas into complete calls.
    public struct ToolCallAccumulator: Sendable {
        public struct Call: Equatable, Sendable {
            public var id: String?
            public var name: String?
            public var arguments: String = ""

            public init(id: String? = nil, name: String? = nil, arguments: String = "") {
                self.id = id
                self.name = name
                self.arguments = arguments
            }

            /// Parse the accumulated arguments JSON into a dictionary
            /// (nil when incomplete/invalid).
            public func parsedArguments() -> [String: Any]? {
                guard let data = arguments.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return obj
            }
        }

        public private(set) var calls: [Int: Call] = [:]

        public init() {}

        public mutating func apply(_ delta: ToolCallDelta) {
            var call = calls[delta.index] ?? Call()
            if let id = delta.id { call.id = id }
            if let name = delta.name { call.name = name }
            if let args = delta.arguments { call.arguments += args }
            calls[delta.index] = call
        }

        /// Completed calls in index order (only those with a name).
        public func completedCalls() -> [Call] {
            calls.keys.sorted().compactMap { index in
                let call = calls[index]!
                guard call.name != nil else { return nil }
                return call
            }
        }
    }
}
