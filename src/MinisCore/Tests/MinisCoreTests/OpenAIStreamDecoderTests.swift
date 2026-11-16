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

struct OpenAIStreamDecoderTests {

    @Test func textChunkDecode() {
        let json: [String: Any] = [
            "id": "chatcmpl-1",
            "choices": [["index": 0, "delta": ["content": "Hello"], "finish_reason": NSNull()]],
        ]
        let chunk = OpenAIStreamDecoder.decodeChunk(json)
        #expect(chunk?.textDelta == "Hello")
        #expect(chunk?.finishReason == nil)
    }

    @Test func finishReasonChunk() {
        let json: [String: Any] = [
            "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]],
        ]
        let chunk = OpenAIStreamDecoder.decodeChunk(json)
        #expect(chunk?.finishReason == "tool_calls")
        #expect(chunk?.textDelta == nil)
    }

    @Test func usageChunk() {
        let json: [String: Any] = [
            "choices": [],
            "usage": ["prompt_tokens": 100, "completion_tokens": 25, "total_tokens": 125],
        ]
        let chunk = OpenAIStreamDecoder.decodeChunk(json)
        #expect(chunk?.usage?.inputTokens == 100)
        #expect(chunk?.usage?.outputTokens == 25)
    }

    @Test func deepSeekCacheUsageShape() {
        let json: [String: Any] = [
            "choices": [],
            "usage": ["prompt_tokens": 1000, "prompt_cache_hit_tokens": 900, "completion_tokens": 50],
        ]
        let chunk = OpenAIStreamDecoder.decodeChunk(json)
        #expect(chunk?.usage?.cacheReadInputTokens == 900)
        #expect(chunk?.usage?.inputTokens == 100)
    }

    @Test func invalidPayloadReturnsNil() {
        #expect(OpenAIStreamDecoder.decodeChunk(payload: "not json") == nil)
        #expect(OpenAIStreamDecoder.decodeChunk(payload: "") == nil)
    }

    @Test func toolCallDeltaDecode() {
        let json: [String: Any] = [
            "choices": [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call_abc",
                        "function": ["name": "shell_execute", "arguments": "{\"command\""],
                    ]],
                ],
                "finish_reason": NSNull(),
            ]],
        ]
        let chunk = OpenAIStreamDecoder.decodeChunk(json)
        #expect(chunk?.toolCallDeltas.count == 1)
        let delta = chunk?.toolCallDeltas[0]
        #expect(delta?.id == "call_abc")
        #expect(delta?.name == "shell_execute")
        #expect(delta?.arguments == "{\"command\"")
    }

    @Test func toolCallAccumulationAcrossChunks() {
        var acc = OpenAIStreamDecoder.ToolCallAccumulator()

        acc.apply(.init(index: 0, id: "call_abc", name: "shell_execute", arguments: "{\"command\": "))
        acc.apply(.init(index: 0, arguments: "\"ls -la\"}"))
        acc.apply(.init(index: 1, name: "file_read", arguments: "{\"path\": \"/tmp/x\"}"))

        let calls = acc.completedCalls()
        #expect(calls.count == 2)
        #expect(calls[0].id == "call_abc")
        #expect(calls[0].name == "shell_execute")
        #expect(calls[0].arguments == "{\"command\": \"ls -la\"}")
        #expect(calls[0].parsedArguments()?["command"] as? String == "ls -la")
        #expect(calls[1].name == "file_read")
        #expect(calls[1].parsedArguments()?["path"] as? String == "/tmp/x")
    }

    @Test func incompleteToolCallNotCompleted() {
        var acc = OpenAIStreamDecoder.ToolCallAccumulator()
        acc.apply(.init(index: 0, arguments: "{\"partial\":"))
        #expect(acc.completedCalls().isEmpty)
    }

    @Test func openAIMessageDictWithImageAttachment() {
        let image = LLMMessage.ImageAttachment(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let msg = LLMMessage(role: .user, content: "describe this", images: [image])
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg)

        #expect(dict["role"] as? String == "user")
        let content = dict["content"] as? [[String: Any]]
        #expect(content?.count == 2)
        let firstBlockType = content?[0]["type"] as? String
        #expect(firstBlockType == "image_url")
        let url = (content?[0]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url?.hasPrefix("data:image/png;base64,") ?? false)
        let secondBlockType = content?[1]["type"] as? String
        #expect(secondBlockType == "text")
    }

    @Test func openAIMessageDictPlainText() {
        let msg = LLMMessage(role: .assistant, content: "plain")
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg)
        #expect(dict["role"] as? String == "assistant")
        #expect(dict["content"] as? String == "plain")
    }
}
