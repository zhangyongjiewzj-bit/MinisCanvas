import Foundation

/// Decoder for Anthropic Messages API SSE events (stream=true).
///
/// Event sequence for a text response:
/// ```
/// event: message_start      {"type":"message_start","message":{...,"usage":{...}}}
/// event: content_block_start {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
/// event: content_block_delta {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
/// event: content_block_stop  {"type":"content_block_stop","index":0}
/// event: message_delta      {"type":"message_delta","delta":{"stop_reason":"end_turn",...},"usage":{"output_tokens":N}}
/// event: message_stop       {"type":"message_stop"}
/// ```
/// Plus `ping` heartbeats and `error` events.
public enum AnthropicStreamDecoder {

    /// A decoded Anthropic stream event.
    public enum Event: Equatable, Sendable {
        /// `message_start` — carries the message-level usage.
        case messageStart(usage: LLMUsage?)
        /// `content_block_start` — `type` is the content block type ("text", "tool_use", …).
        case contentBlockStart(index: Int, blockType: String)
        /// `content_block_delta` — `text` is non-nil for text_delta; tool input
        /// deltas carry `partial_json` (exposed via `toolInputJSON`).
        case contentBlockDelta(index: Int, text: String?, toolInputJSON: String?)
        /// `content_block_stop`.
        case contentBlockStop(index: Int)
        /// `message_delta` — carries stop_reason and output usage.
        case messageDelta(stopReason: String?, usage: LLMUsage?)
        /// `message_stop`.
        case messageStop
        /// `ping` heartbeat.
        case ping
        /// `error` — human-readable provider error message.
        case error(message: String)
    }

    /// Decode one event from its JSON payload (the `data:` value).
    public static func decode(data: String) -> Event? {
        guard let d = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return decode(json: json)
    }

    /// Decode one event from a JSON object.
    public static func decode(json: [String: Any]) -> Event? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "message_start":
            let message = json["message"] as? [String: Any] ?? [:]
            return .messageStart(usage: parseUsage(message["usage"] as? [String: Any]))

        case "content_block_start":
            let index = json["index"] as? Int ?? 0
            let block = json["content_block"] as? [String: Any] ?? [:]
            return .contentBlockStart(index: index, blockType: block["type"] as? String ?? "")

        case "content_block_delta":
            let index = json["index"] as? Int ?? 0
            let delta = json["delta"] as? [String: Any] ?? [:]
            let deltaType = delta["type"] as? String ?? ""
            switch deltaType {
            case "text_delta":
                return .contentBlockDelta(index: index, text: delta["text"] as? String, toolInputJSON: nil)
            case "input_json_delta":
                return .contentBlockDelta(index: index, text: nil, toolInputJSON: delta["partial_json"] as? String)
            default:
                return .contentBlockDelta(index: index, text: nil, toolInputJSON: nil)
            }

        case "content_block_stop":
            return .contentBlockStop(index: json["index"] as? Int ?? 0)

        case "message_delta":
            let delta = json["delta"] as? [String: Any] ?? [:]
            return .messageDelta(
                stopReason: delta["stop_reason"] as? String,
                usage: parseUsage(json["usage"] as? [String: Any])
            )

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            let errorObj = json["error"] as? [String: Any] ?? [:]
            return .error(message: errorObj["message"] as? String ?? "Unknown Anthropic stream error")

        default:
            return nil
        }
    }

    // MARK: - Usage

    /// Parse an Anthropic usage dict (both `message_start.message.usage` and
    /// `message_delta.usage` shapes).
    public static func parseUsage(_ usage: [String: Any]?) -> LLMUsage? {
        guard let usage else { return nil }
        // message_delta usage only carries output_tokens.
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        if inputTokens == 0 && outputTokens == 0 {
            return nil
        }
        return LLMUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int,
            cacheReadInputTokens: usage["cache_read_input_tokens"] as? Int,
            cacheHitInputTokens: LLMUsage.anthropicCacheHitInputTokens(usage)
        )
    }
}
