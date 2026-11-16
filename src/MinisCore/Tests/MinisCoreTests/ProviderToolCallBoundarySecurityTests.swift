import Foundation
import Testing
@testable import MinisCore

@Suite("ProviderToolCallBoundary")
struct ProviderToolCallBoundarySecurityTests {

    @Test func openAIRequiresWireShapeIdentityAndObjectArguments() {
        let valid: [String: Any] = [
            "id": "call-1",
            "type": "function",
            "function": ["name": "lookup", "arguments": "{\"query\":\"x\"}"],
        ]
        #expect(ProviderToolCallBoundary.parseOpenAI(valid)?.name == "lookup")
        #expect(ProviderToolCallBoundary.parseOpenAI([
            "id": "call-2",
            "type": "custom",
            "function": ["name": "lookup", "arguments": "{}"],
        ]) == nil)
        #expect(ProviderToolCallBoundary.parseOpenAI([
            "type": "function",
            "function": ["name": "lookup", "arguments": "{}"],
        ]) == nil)
        #expect(ProviderToolCallBoundary.parseOpenAI([
            "id": "call-3",
            "type": "function",
            "function": ["name": "lookup", "arguments": "[]"],
        ]) == nil)
        #expect(ProviderToolCallBoundary.parseOpenAI([
            "id": "call-4",
            "type": "function",
            "function": ["name": "lookup", "arguments": "{not-json}"],
        ]) == nil)

        let duplicateMessage: [String: Any] = [
            "tool_calls": [valid, [
                "id": "call-1",
                "type": "function",
                "function": ["name": "other", "arguments": "{}"],
            ]],
        ]
        #expect(OpenAICompatibleProvider.parseNativeToolCalls(from: duplicateMessage).isEmpty)
    }

    @Test func argumentsRejectOversizedAndPathologicalObjects() {
        var wide: [String: Any] = [:]
        for index in 0..<(ProviderToolCallBoundary.maximumObjectKeys + 1) {
            wide["key-\(index)"] = "value"
        }
        #expect(ProviderToolCallBoundary.validateInputObject(wide) == false)

        var deep: [String: Any] = ["leaf": true]
        for index in 0...ProviderToolCallBoundary.maximumNestingDepth {
            deep = ["level-\(index)": deep]
        }
        #expect(ProviderToolCallBoundary.validateInputObject(deep) == false)

        let huge = String(repeating: "x", count: ProviderToolCallBoundary.maximumArgumentsBytes)
        #expect(ProviderToolCallBoundary.parseArguments("{\"value\":\"\(huge)\"}") == nil)
    }

    @Test func anthropicRequiresIdentityAndInputObject() {
        let valid: [String: Any] = [
            "type": "tool_use",
            "id": "call_x|1",
            "name": "lookup",
            "input": ["query": "x"],
        ]
        #expect(ProviderToolCallBoundary.parseAnthropic(valid)?.id == "call_x-1")
        #expect(ProviderToolCallBoundary.parseAnthropic([
            "type": "tool_use",
            "name": "lookup",
            "input": [:],
        ]) == nil)
        #expect(ProviderToolCallBoundary.parseAnthropic([
            "type": "tool_use",
            "id": "call-2",
            "name": "lookup",
            "input": ["items": Array(repeating: "x", count: ProviderToolCallBoundary.maximumArrayElements + 1)],
        ]) == nil)
    }

    @Test func textEnvelopeRejectsSyntheticIdentityAndInvalidInput() throws {
        let valid = """
        {"tool_calls":[{"id":"call-1","name":"lookup","input":{"query":"x"}}]}
        """
        let data = try #require(valid.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try #require(object["tool_calls"] as? [[String: Any]])
        #expect(ProviderToolCallBoundary.parseTextEnvelopeCall(calls[0])?.id == "call-1")
        #expect(ProviderToolCallBoundary.parseTextEnvelopeCall([
            "name": "lookup",
            "input": [:],
        ]) == nil)
        #expect(ProviderToolCallBoundary.parseTextEnvelopeCall([
            "id": "call-2",
            "name": "lookup",
            "input": ["nested": ["bad": Date()]],
        ]) == nil)

        let duplicateEnvelope = """
        {"tool_calls":[{"id":"call-1","name":"lookup","input":{}},{"id":"call-1","name":"other","input":{}}]}
        """
        #expect(AgentLoop.parseToolCalls(from: duplicateEnvelope) == nil)
    }

    @Test func realAnthropicCallerRejectsIdentityFreeCall() {
        let response: [String: Any] = [
            "content": [["type": "tool_use", "name": "lookup", "input": [:]]],
        ]
        #expect(AnthropicProvider.parseNativeToolCalls(from: response).isEmpty)
    }

    @Test func agentEnvelopeConversionDropsMalformedToolUse() {
        let malformed = LLMMessage(
            role: .assistant,
            content: "{\"type\":\"tool_use\",\"id\":\"call-1\",\"name\":\"lookup\",\"input\":[]}")
        let parts = malformed.toAgentContentParts()
        #expect(parts.count == 1)
        guard case .text = parts[0] else {
            Issue.record("malformed tool_use must remain plain text")
            return
        }
    }
}
