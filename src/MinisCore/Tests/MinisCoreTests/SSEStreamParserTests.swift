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

struct SSEStreamParserTests {

    @Test func singleDataEvent() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("data: hello world\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "hello world")
        #expect(events[0].eventName == nil)
    }

    @Test func dataWithAndWithoutSpace() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("data:no-space\n\ndata: with-space\n\n")
        #expect(events.count == 2)
        #expect(events[0].data == "no-space")
        #expect(events[1].data == "with-space")
    }

    @Test func multiLineData() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("data: line1\ndata: line2\ndata: line3\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "line1\nline2\nline3")
    }

    @Test func doneSentinel() {
        var parser = SSEStreamParser()
        let outputs = parser.feed("data: [DONE]\n\n")
        #expect(outputs.count == 1)
        if case .done = outputs[0] {
        } else {
            Issue.record("expected .done, got \(outputs[0])")
        }
    }

    @Test func eventNameAndId() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("event: message_start\nid: msg_123\ndata: {\"type\":\"x\"}\n\n")
        #expect(events.count == 1)
        #expect(events[0].eventName == "message_start")
        #expect(events[0].id == "msg_123")
        #expect(events[0].data == "{\"type\":\"x\"}")
        #expect(events[0].jsonObject != nil)
    }

    @Test func retryField() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("retry: 3000\ndata: x\n\n")
        #expect(events.count == 1)
        #expect(events[0].retry == 3000)
    }

    @Test func crlfLines() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("data: crlf-line\r\n\r\n")
        #expect(events.count == 1)
        #expect(events[0].data == "crlf-line")
    }

    @Test func commentsIgnored() {
        var parser = SSEStreamParser()
        let events = parser.parseAll(": keep-alive comment\ndata: real\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "real")
    }

    @Test func multipleEvents() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("data: one\n\ndata: two\n\ndata: three\n\n")
        #expect(events.count == 3)
        #expect(events.map(\.data) == ["one", "two", "three"])
    }

    @Test func incrementalChunksAcrossBoundaries() {
        var parser = SSEStreamParser()
        let stream = "data: incremental\n\ndata: second\n\n"
        var allOutputs: [SSEStreamParser.Output] = []
        for char in stream {
            allOutputs += parser.feed(String(char))
        }
        var events: [SSEStreamParser.Event] = []
        for output in allOutputs {
            if case .event(let e) = output { events.append(e) }
        }
        #expect(events.map(\.data) == ["incremental", "second"])
    }

    @Test func chunkSplitMidEvent() {
        var parser = SSEStreamParser()
        var outputs = parser.feed("data: hel")
        #expect(outputs.isEmpty)
        outputs = parser.feed("lo world\n\n")
        #expect(outputs.count == 1)
        guard case .event(let e) = outputs[0] else {
            Issue.record("expected event")
            return
        }
        #expect(e.data == "hello world")
    }

    @Test func lineWithoutColonIsEmptyValueField() {
        var parser = SSEStreamParser()
        let events = parser.parseAll("data\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "")
    }

    @Test func flushPendingWithoutTrailingBlankLine() {
        var parser = SSEStreamParser()
        // A final newline (line terminator) but NO blank-line terminator.
        _ = parser.feed("data: no-trailing-blank\n")
        #expect(parser.hasPendingEvent)
        let flushed = parser.flushPending()
        #expect(flushed?.data == "no-trailing-blank")
        #expect(parser.flushPending() == nil)
    }

    @Test func ssePayloadHelper() {
        #expect(SSEStreamParser.ssePayload(fromLine: "data: hello") == "hello")
        #expect(SSEStreamParser.ssePayload(fromLine: "data:hello") == "hello")
        #expect(SSEStreamParser.ssePayload(fromLine: "data: [DONE]") == "[DONE]")
        #expect(SSEStreamParser.ssePayload(fromLine: "event: message_start") == nil)
        #expect(SSEStreamParser.ssePayload(fromLine: "random line") == nil)
    }

    @Test func openAIStyleSampleStream() {
        let sample = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

        data: [DONE]


        """
        var parser = SSEStreamParser()
        var events: [SSEStreamParser.Event] = []
        var sawDone = false
        for output in parser.feed(sample) {
            switch output {
            case .event(let e): events.append(e)
            case .done: sawDone = true
            }
        }
        #expect(events.count == 4)
        #expect(sawDone)

        var text = ""
        var finish: String?
        var usage: LLMUsage?
        for event in events {
            if let chunk = OpenAIStreamDecoder.decodeChunk(payload: event.data) {
                if let t = chunk.textDelta { text += t }
                if let f = chunk.finishReason { finish = f }
                if let u = chunk.usage { usage = u }
            }
        }
        #expect(text == "Hello world")
        #expect(finish == "stop")
        #expect(usage?.inputTokens == 10)
        #expect(usage?.outputTokens == 2)
    }
}
