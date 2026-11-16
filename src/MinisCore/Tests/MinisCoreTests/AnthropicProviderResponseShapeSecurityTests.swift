import Foundation
import Testing
@testable import MinisCore

@Suite("Anthropic provider response shape security")
struct AnthropicProviderResponseShapeSecurityTests {
    private static func validTextDelta() -> [String: Any] {
        [
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "text_delta", "text": "hello"]
        ]
    }

    private static func validToolStart() -> [String: Any] {
        [
            "type": "content_block_start",
            "index": 0,
            "content_block": [
                "type": "tool_use",
                "id": "tool-1",
                "name": "lookup",
                "input": ["query": "weather"]
            ]
        ]
    }

    @Test("normal text and tool-use events remain admissible")
    func validEvents() throws {
        try ProviderAnthropicResponseShapePolicy.validate(Self.validTextDelta())
        try ProviderAnthropicResponseShapePolicy.validate(Self.validToolStart())
    }

    @Test("message content block count fails closed")
    func contentBlockLimit() {
        let blocks = Array(
            repeating: ["type": "text", "text": "x"] as [String: Any],
            count: ProviderAnthropicResponseShapePolicy.maximumContentBlocks + 1
        )
        let event: [String: Any] = [
            "type": "message_start",
            "message": ["content": blocks]
        ]

        #expect(throws: ProviderAnthropicResponseShapePolicyError.contentBlocksTooMany) {
            try ProviderAnthropicResponseShapePolicy.validate(event)
        }
    }

    @Test("event depth and aggregate strings reject pathological JSON")
    func eventShapeLimits() {
        var deep: Any = "leaf"
        for _ in 0...ProviderAnthropicResponseShapePolicy.maximumEventNestingDepth {
            deep = ["nested": deep]
        }
        let deepEvent: [String: Any] = ["type": "custom", "payload": deep]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.eventNestingTooDeep) {
            try ProviderAnthropicResponseShapePolicy.validate(deepEvent)
        }

        let oversizedString: [String: Any] = [
            "type": "custom",
            "payload": String(
                repeating: "x",
                count: ProviderAnthropicResponseShapePolicy.maximumStringBytes + 1
            )
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.eventStringTooLarge) {
            try ProviderAnthropicResponseShapePolicy.validate(oversizedString)
        }

        let halfBudget = ProviderAnthropicResponseShapePolicy.maximumTotalStringBytes / 2
        let aggregate: [String: Any] = [
            "type": "custom",
            "first": String(repeating: "x", count: halfBudget),
            "second": String(repeating: "y", count: halfBudget)
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.eventStringBudgetExceeded) {
            try ProviderAnthropicResponseShapePolicy.validate(aggregate)
        }
    }

    @Test("tool input depth, object, fragment, and token limits fail closed")
    func toolInputLimits() {
        var deepInput: Any = "leaf"
        for _ in 0...ProviderAnthropicResponseShapePolicy.maximumToolInputNestingDepth {
            deepInput = ["nested": deepInput]
        }
        let deepEvent: [String: Any] = [
            "type": "content_block_start",
            "content_block": ["type": "tool_use", "input": ["nested": deepInput]]
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.toolInputTooDeep) {
            try ProviderAnthropicResponseShapePolicy.validate(deepEvent)
        }

        let keys = Dictionary(uniqueKeysWithValues: (0...ProviderAnthropicResponseShapePolicy.maximumToolInputObjectKeys).map {
            ("key\($0)", 1 as Any)
        })
        let wideEvent: [String: Any] = [
            "type": "content_block_start",
            "content_block": ["type": "tool_use", "input": keys]
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.toolInputTooLarge) {
            try ProviderAnthropicResponseShapePolicy.validate(wideEvent)
        }

        let largeFragmentEvent: [String: Any] = [
            "type": "content_block_delta",
            "delta": [
                "type": "input_json_delta",
                "partial_json": String(
                    repeating: "x",
                    count: ProviderAnthropicResponseShapePolicy.maximumToolInputFragmentBytes + 1
                )
            ]
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.toolInputFragmentTooLarge) {
            try ProviderAnthropicResponseShapePolicy.validate(largeFragmentEvent)
        }

        let deepFragmentEvent: [String: Any] = [
            "type": "content_block_delta",
            "delta": [
                "type": "input_json_delta",
                "partial_json": String(
                    repeating: "{",
                    count: ProviderAnthropicResponseShapePolicy.maximumToolInputNestingDepth + 1
                )
            ]
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.toolInputTooDeep) {
            try ProviderAnthropicResponseShapePolicy.validate(deepFragmentEvent)
        }

        let complexFragment = String(
            repeating: "{},",
            count: ProviderAnthropicResponseShapePolicy.maximumToolInputStructuralTokens / 3 + 1
        )
        let complexFragmentEvent: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "input_json_delta", "partial_json": complexFragment]
        ]
        #expect(throws: ProviderAnthropicResponseShapePolicyError.toolInputStructureTooComplex) {
            try ProviderAnthropicResponseShapePolicy.validate(complexFragmentEvent)
        }
    }

    @Test("shape policy errors are fixed and payload-free")
    func errorsAreRedacted() {
        let error = ProviderAnthropicResponseShapePolicyError.toolInputTooLarge
        #expect(error.localizedDescription == "Anthropic tool input is too large")
        #expect(!error.localizedDescription.contains("api.anthropic.com"))
        #expect(!error.localizedDescription.contains("fixture-secret"))
    }
}
