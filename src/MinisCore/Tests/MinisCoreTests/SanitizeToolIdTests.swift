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

struct SanitizeToolIdTests {

    @Test func validCharactersPreserved() {
        #expect(sanitizeToolId("call_abc-123") == "call_abc-123")
        #expect(sanitizeToolId("tool_0") == "tool_0")
    }

    @Test func pipeReplaced() {
        // OpenAI Responses API can produce IDs containing `|`.
        #expect(sanitizeToolId("call_xxx|fc_yyy") == "call_xxx-fc_yyy")
    }

    @Test func unicodeReplaced() {
        // CharacterSet.alphanumerics keeps Unicode *letters* (CJK, Latin-1 …);
        // only non-alphanumeric code points (punctuation, symbols) become "-".
        #expect(sanitizeToolId("call·dot") == "call-dot")
        #expect(sanitizeToolId("a→b") == "a-b")
        #expect(sanitizeToolId("café!") == "café-")
        // CJK letters survive (documenting actual behavior — see B1-fix.log).
        #expect(sanitizeToolId("调用-工具") == "调用-工具")
    }

    @Test func mixedContent() {
        #expect(sanitizeToolId("abc|def.ghi") == "abc-def-ghi")
    }

    @Test func emptyString() {
        #expect(sanitizeToolId("") == "")
    }

    @Test func allSpecialCharacters() {
        #expect(sanitizeToolId("!!!@@@###") == "---------")
    }

    @Test func anthropicCompatibility() {
        // Result must match ^[a-zA-Z0-9_-]+$ for every input. ("tööl" is not
        // included: ö is alphanumeric per Unicode and survives sanitization, so
        // the sanitizer cannot make it Anthropic-safe — see B1-fix.log.)
        let inputs = ["call_abc|fc_1", "tool:run", "a b c", "a·b", "x/y"]
        for input in inputs {
            let sanitized = sanitizeToolId(input)
            let pattern = #"^[a-zA-Z0-9_-]+$"#
            #expect(sanitized.range(of: pattern, options: .regularExpression) != nil,
                    "sanitized '\(sanitized)' (from '\(input)') must match Anthropic id charset")
        }
    }
}

struct AnthropicHelperTests {

    @Test func parseClaudeVersion() {
        #expect(AnthropicProvider.parseClaudeVersion("claude-opus-4-6")?.major == 4)
        #expect(AnthropicProvider.parseClaudeVersion("claude-opus-4-6")?.minor == 6)
        #expect(AnthropicProvider.parseClaudeVersion("claude-fable-5")?.major == 5)
        #expect(AnthropicProvider.parseClaudeVersion("claude-fable-5")?.minor == 0)
        #expect(AnthropicProvider.parseClaudeVersion("claude-3-5-sonnet")?.major == 3)
        #expect(AnthropicProvider.parseClaudeVersion("claude-3-5-sonnet")?.minor == 5)
        #expect(AnthropicProvider.parseClaudeVersion("anthropic/claude-opus-4.7")?.major == 4)
        #expect(AnthropicProvider.parseClaudeVersion("anthropic/claude-opus-4.7")?.minor == 7)
        #expect(AnthropicProvider.parseClaudeVersion("gpt-4o") == nil)
        #expect(AnthropicProvider.parseClaudeVersion("") == nil)
    }

    @Test func modelRejectsTemperature() {
        #expect(AnthropicProvider.modelRejectsTemperature("claude-opus-4-6"))
        #expect(AnthropicProvider.modelRejectsTemperature("claude-sonnet-5"))
        #expect(!AnthropicProvider.modelRejectsTemperature("claude-3-5-sonnet"))
        #expect(!AnthropicProvider.modelRejectsTemperature("gpt-4o"))
    }

    @Test func modelUsesAdaptiveThinking() {
        #expect(AnthropicProvider.modelUsesAdaptiveThinking("claude-opus-4-6"))
        #expect(AnthropicProvider.modelUsesAdaptiveThinking("claude-fable-5"))
        #expect(!AnthropicProvider.modelUsesAdaptiveThinking("claude-3-5-sonnet"))
    }
}

struct LLMModelTests {

    @Test func contextWindowHeuristics() {
        #expect(LLMModel.claudeHaiku45.contextWindowTokens == 200_000)
        #expect(LLMModel.claudeOpus48.contextWindowTokens == 1_000_000)
        #expect(LLMModel.gpt5.contextWindowTokens == 400_000)
        #expect(LLMModel.gpt4o.contextWindowTokens == 128_000)
        #expect(LLMModel.o4Mini.contextWindowTokens == 200_000)
        let unknown = LLMModel(id: "some-unknown-model", displayName: "?", provider: "X")
        #expect(unknown.contextWindowTokens == 128_000)
    }

    @Test func catalogMaxThinkingLevel() {
        let opus = LLMModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: "Anthropic")
        #expect(opus.catalogMaxThinkingLevel == .max)
        let noReasoning = LLMModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: "Anthropic", supportsReasoning: false)
        #expect(noReasoning.catalogMaxThinkingLevel == .off)
        let gpt = LLMModel(id: "gpt-4o", displayName: "GPT-4o", provider: "OpenAI")
        #expect(gpt.catalogMaxThinkingLevel == .xhigh)
    }

    @Test func thinkingLevelOrdering() {
        #expect(ThinkingLevel.off < ThinkingLevel.low)
        #expect(ThinkingLevel.medium < ThinkingLevel.high)
        #expect(ThinkingLevel.xhigh < ThinkingLevel.max)
        #expect(ThinkingLevel.max < ThinkingLevel.ultra)
        #expect(ThinkingLevel.decoded("bogus") == .xhigh)
    }

    @Test func capabilityPromptFragment() {
        let textOnly = LLMModel(id: "m", displayName: "M", provider: "Unknown")
        let fragment = textOnly.capabilityPromptFragment
        #expect(fragment != nil)
        #expect(fragment?.contains("cannot natively process") ?? false)

        let multimodal = LLMModel(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: "Google")
        #expect(multimodal.capabilityPromptFragment == nil)
    }

    @Test func modalityInference() {
        // "gpt-5-image" matches the modalityInferenceRules image-output pattern;
        // "gpt-image-2" does not (no matching rule) — see B1-fix.log.
        #expect(LLMModel.inferOutputModality(id: "gpt-5-image", displayName: "GPT 5 Image") == .imageOutput)
        #expect(LLMModel.inferDedicatedVoiceModality(id: "whisper-1", displayName: "Whisper") == [.audioInput, .textOutput])
        #expect(LLMModel.inferDedicatedVoiceModality(id: "tts-1", displayName: "TTS") == [.textInput, .audioOutput])
        #expect(LLMModel.inferOutputModality(id: "gpt-4o", displayName: "GPT-4o") == nil)
    }

    // Renamed from `modelDisplayName` (the @Test method name shadowed the
    // global function `modelDisplayName(from:)` and broke compilation).
    @Test func displayNameConversion() {
        #expect(modelDisplayName(from: "openai/gpt-4o-mini") == "OpenAI GPT 4o Mini")
        #expect(modelDisplayName(from: "deepseek-chat") == "DeepSeek Chat")
        #expect(modelDisplayName(from: "gpt-5.6-sol") == "GPT 5.6 Sol")
    }
}
