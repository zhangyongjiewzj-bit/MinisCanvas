import Foundation
import Testing
@testable import MinisCore

@Suite("Provider chat response shape policy security")
struct ProviderChatResponseShapePolicySecurityTests {
    private static func validResponse() -> [String: Any] {
        [
            "choices": [[
                "message": [
                    "content": "hello",
                    "tool_calls": [[
                        "id": "call-1",
                        "function": ["name": "lookup", "arguments": "{}"]
                    ]]
                ],
                "finish_reason": "stop"
            ]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1]
        ]
    }

    @Test("normal content and tool call projection remains admissible")
    func validProjectionShape() throws {
        try ProviderChatResponseShapePolicy.validate(Self.validResponse())
    }

    @Test("MC4-004：只有 error 没有 choices 的帧被拒绝，带 choices 或 error 为 null 的帧照常通过")
    func upstreamErrorFrameIsRejected() throws {
        #expect(throws: ProviderChatResponseShapePolicyError.upstreamErrorFrame) {
            try ProviderChatResponseShapePolicy.validate(["error": ["message": "synthetic upstream failure"]])
        }
        #expect(throws: ProviderChatResponseShapePolicyError.upstreamErrorFrame) {
            try ProviderChatResponseShapePolicy.validate(["error": "boom"])
        }
        var withNull = Self.validResponse()
        withNull["error"] = NSNull()
        try ProviderChatResponseShapePolicy.validate(withNull)
        var withChoices = Self.validResponse()
        withChoices["error"] = ["message": "finish_reason 形态由原有分支处理"]
        try ProviderChatResponseShapePolicy.validate(withChoices)
    }

    @Test("choice content and tool-call counts fail closed")
    func countLimits() {
        var tooManyChoices = Self.validResponse()
        let basicChoice: [String: Any] = ["message": ["content": "x"]]
        tooManyChoices["choices"] = Array(
            repeating: basicChoice,
            count: ProviderChatResponseShapePolicy.maximumChoices + 1
        )
        #expect(throws: ProviderChatResponseShapePolicyError.choicesTooMany) {
            try ProviderChatResponseShapePolicy.validate(tooManyChoices)
        }

        var tooManyBlocks = Self.validResponse()
        let blockChoice: [String: Any] = ["message": [
            "content": Array(
                repeating: ["type": "text", "text": "x"],
                count: ProviderChatResponseShapePolicy.maximumContentBlocks + 1
            )
        ]]
        tooManyBlocks["choices"] = [blockChoice]
        #expect(throws: ProviderChatResponseShapePolicyError.contentBlocksTooMany) {
            try ProviderChatResponseShapePolicy.validate(tooManyBlocks)
        }

        var tooManyCalls = Self.validResponse()
        let callsChoice: [String: Any] = ["message": [
            "content": "x",
            "tool_calls": Array(
                repeating: ["function": ["name": "lookup", "arguments": "{}"]],
                count: ProviderChatResponseShapePolicy.maximumToolCalls + 1
            )
        ]]
        tooManyCalls["choices"] = [callsChoice]
        #expect(throws: ProviderChatResponseShapePolicyError.toolCallsTooMany) {
            try ProviderChatResponseShapePolicy.validate(tooManyCalls)
        }
    }

    @Test("string and nested object budgets reject pathological projection input")
    func stringAndDepthLimits() {
        var huge = Self.validResponse()
        let hugeChoice: [String: Any] = ["message": [
            "content": String(repeating: "x", count: ProviderChatResponseShapePolicy.maximumStringBytes + 1)
        ]]
        huge["choices"] = [hugeChoice]
        #expect(throws: ProviderChatResponseShapePolicyError.stringTooLarge) {
            try ProviderChatResponseShapePolicy.validate(huge)
        }

        var deep: Any = "leaf"
        for _ in 0...ProviderChatResponseShapePolicy.maximumNestingDepth {
            deep = ["nested": deep]
        }
        let deeplyNested: [String: Any] = ["choices": [["message": ["content": deep]]]]
        #expect(throws: ProviderChatResponseShapePolicyError.nestingTooDeep) {
            try ProviderChatResponseShapePolicy.validate(deeplyNested)
        }
    }

    @Test("shape policy errors are fixed and payload-free")
    func errorsAreRedacted() {
        let error = ProviderChatResponseShapePolicyError.stringTooLarge
        #expect(error.localizedDescription == "Provider response string is too large")
        #expect(!error.localizedDescription.contains("provider.example"))
        #expect(!error.localizedDescription.contains("fixture-secret"))
    }
}
