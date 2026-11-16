import Foundation
import Testing
@testable import MinisCore

// NOTE: This suite runs on the CLT-only toolchain (no Xcode). XCTest.framework
// does not exist there (`import XCTest` fails with "no such module 'XCTest'");
// Swift Testing (`import Testing`) ships with the CLT and is the only runnable
// test framework. Run with the documented flags:
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
// See threads/B1-fix.log for the evidence chain.

struct AnthropicStreamDecoderTests {

    @Test func sampleTextStream() {
        let sample = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-6","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        var parser = SSEStreamParser()
        var events: [AnthropicStreamDecoder.Event] = []
        for output in parser.feed(sample) {
            if case .event(let e) = output, let decoded = AnthropicStreamDecoder.decode(data: e.data) {
                events.append(decoded)
            }
        }

        var text = ""
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        for event in events {
            switch event {
            case .messageStart(let u):
                // message_start carries the message-level input usage.
                inputTokens = u?.inputTokens
            case .contentBlockDelta(_, let t, _):
                if let t { text += t }
            case .messageDelta(let stop, let u):
                // message_delta carries only the incremental output usage.
                stopReason = stop
                outputTokens = u?.outputTokens
            default: break
            }
        }

        #expect(text == "Hello world")
        #expect(stopReason == "end_turn")
        #expect(inputTokens == 25)
        #expect(outputTokens == 2)
    }

    @Test func pingAndIgnoredEvents() {
        var parser = SSEStreamParser()
        let sample = """
        event: ping
        data: {"type":"ping"}

        event: message_stop
        data: {"type":"message_stop"}


        """
        var events: [AnthropicStreamDecoder.Event] = []
        for output in parser.feed(sample) {
            if case .event(let e) = output, let decoded = AnthropicStreamDecoder.decode(data: e.data) {
                events.append(decoded)
            }
        }
        #expect(events.count == 2)
        if case .ping = events[0] {} else {
            Issue.record("expected .ping, got \(events[0])")
        }
        if case .messageStop = events[1] {} else {
            Issue.record("expected .messageStop, got \(events[1])")
        }
    }

    @Test func errorEvent() {
        let event = AnthropicStreamDecoder.decode(data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        guard case .error(let message) = event else {
            Issue.record("expected .error, got \(String(describing: event))")
            return
        }
        #expect(message == "Overloaded")
    }

    @Test func toolInputJSONDelta() {
        let json: [String: Any] = [
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": "{\"command\""],
        ]
        let event = AnthropicStreamDecoder.decode(json: json)
        guard case .contentBlockDelta(_, let text, let toolInput) = event else {
            Issue.record("expected contentBlockDelta")
            return
        }
        #expect(text == nil)
        #expect(toolInput == "{\"command\"")
    }

    @Test func parseUsageEmptyReturnsNil() {
        #expect(AnthropicStreamDecoder.parseUsage([:]) == nil)
        #expect(AnthropicStreamDecoder.parseUsage(nil) == nil)
        let u = AnthropicStreamDecoder.parseUsage([
            "input_tokens": 5,
            "output_tokens": 3,
            "cache_read_input_tokens": 2,
        ])
        #expect(u?.inputTokens == 5)
        #expect(u?.cacheReadInputTokens == 2)
    }

    @Test func anthropicMessageDictWithImage() {
        let image = LLMMessage.ImageAttachment(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        let msg = LLMMessage(role: .user, content: "what is this", images: [image])
        let dict = AnthropicProvider.anthropicMessageDict(msg)

        #expect(dict["role"] as? String == "user")
        let blocks = dict["content"] as? [[String: Any]]
        #expect(blocks?.count == 2)
        let firstBlockType = blocks?[0]["type"] as? String
        #expect(firstBlockType == "image")
        let source = blocks?[0]["source"] as? [String: Any]
        let mediaType = source?["media_type"] as? String
        #expect(mediaType == "image/jpeg")
        let sourceType = source?["type"] as? String
        #expect(sourceType == "base64")
        let secondBlockType = blocks?[1]["type"] as? String
        #expect(secondBlockType == "text")
    }

    @Test func parseMessagesResult() {
        let json: [String: Any] = [
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "text", "text": "First"],
                ["type": "text", "text": "Second"],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]
        let response = AnthropicProvider.parseMessagesResult(json)
        #expect(response.text == "FirstSecond")
        #expect(response.stopReason == "end_turn")
        #expect(response.usage?.inputTokens == 10)
        #expect(response.usage?.outputTokens == 20)
    }
}
