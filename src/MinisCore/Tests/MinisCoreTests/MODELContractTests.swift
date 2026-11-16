import Foundation
import Testing
@testable import MinisCore

@Suite("MODEL cleanroom behavior contracts")
struct MODELContractTests {
    @Test
    func modalityIntegerPersistenceAndDirectionIsolation() throws {
        let unknown = ModelModality(rawValue: 1 << 18)
        let combined: ModelModality = [.textInput, .imageOutput, unknown]
        #expect(combined.inputs == .textInput)
        #expect(combined.outputs == .imageOutput)
        #expect(combined.contains(unknown))
        #expect(ModelModality.fullMultimodal == .fullMultimodalInput)
        #expect(!ModelModality.fullMultimodal.contains(.audioOutput))
        let persisted = ModelModality(rawValue: (1 << 18) | ModelModality.textOnly.rawValue)
        let encoded = try JSONEncoder().encode(persisted)
        #expect(String(data: encoded, encoding: .utf8) == "262147")
        #expect(try JSONDecoder().decode(ModelModality.self, from: encoded) == persisted)
        #expect(try JSONDecoder().decode(ModelModality.self, from: Data("3".utf8)) == .textOnly)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ModelModality.self, from: Data(#"{"rawValue":3}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ModelModality.self, from: Data("null".utf8))
        }
    }

    @Test
    func providerOverridePreservesAuthenticationAndOriginalValue() {
        let original = LLMModel(id: "synthetic-empty-media", displayName: "Fixture", provider: "Google")
        let replaced = original.withModalityOverride([])
        #expect(original.capabilities.supportedModalities == .fullMultimodalInput)
        #expect(replaced.capabilities.supportedModalities == [])
        #expect(replaced.capabilities.supportedAuth == original.capabilities.supportedAuth)
        #expect(original.modalityOverride == nil)
        let unknown = LLMModel(id: "sora-fixture", displayName: "video-gen", provider: "google")
        #expect(unknown.capabilities.supportedModalities == .textOnly)
    }

    @Test
    func contextFallbackPrecedenceAndExplicitPositiveOverride() {
        // C6 (requirement 2159 #4b; pre-review C-3): no blanket 1M for claude, unlisted
        // claude IDs fall back to 200,000; family rules match by prefix, not substring.
        let fixtures: [(String, Int)] = [
            ("claude-haiku-fixture", 200_000), ("claude-fixture", 200_000),
            ("gemini-pro-fixture-1.0", 1_000_000), ("gemini-2.5-pro-fixture", 1_000_000),
            ("gpt-3.5-fixture", 16_000), ("gpt-4o-fixture", 128_000),
            ("gpt-4-turbo-fixture", 128_000), ("gpt-5-fixture", 400_000),
            ("gpt-4-fixture", 8_000), ("o3-fixture", 200_000),
            ("o4-fixture", 200_000), ("codex-fixture", 200_000), ("unrecognized-fixture", 128_000),
            ("claude-gemini-gpt-3.5", 200_000), ("claude-haiku-gemini-gpt-5", 200_000),
            ("claude-3-gpt-5", 200_000), ("gemini-1.0-gpt-3.5", 32_000),
            ("gemini-gpt-3.5", 1_000_000), ("gpt-3.5-gpt-4o-gpt-5", 16_000),
            ("gpt-4o-gpt-5", 128_000), ("gpt-4-turbo-gpt-5", 128_000),
            ("gpt-5-gpt-4", 400_000), ("gpt-4-o3", 8_000),
            ("o3-deepseek", 200_000), ("codex-qwen", 200_000)
        ]
        let fallbackInputs: [Int?] = [nil, 0, -37]
        for (identity, expected) in fixtures {
            for variant in [identity, identity.uppercased()] {
                for supplied in fallbackInputs {
                    let model = LLMModel(id: variant, displayName: "Fixture", provider: "Synthetic", contextWindow: supplied)
                    #expect(model.contextWindowTokens == expected)
                    #expect(model.contextWindow == supplied)
                }
                #expect(LLMModel(id: variant, displayName: "Fixture", provider: "Synthetic", contextWindow: 17).contextWindowTokens == 17)
            }
        }
    }

    @Test
    func voiceRecognitionAndOutputInferenceRemainIndependent() {
        #expect(LLMModel.inferDedicatedVoiceModality(id: "voice-output-fixture", displayName: "WHISPER fixture") == [.audioInput, .textOutput])
        #expect(LLMModel.inferDedicatedVoiceModality(id: "fixture", displayName: "text2speech") == [.textInput, .audioOutput])
        #expect(LLMModel.inferDedicatedVoiceModality(id: "plain", displayName: "ordinary") == nil)
        #expect(LLMModel.inferOutputModality(id: "image-gen-fixture", displayName: "speech video-gen") == [.imageOutput, .audioOutput, .videoOutput])
        #expect(LLMModel.inferOutputModality(id: "speech-to-text", displayName: "Fixture") == .audioOutput)
        #expect(LLMModel.inferOutputModality(id: "plain", displayName: "ordinary") == nil)
    }

    @Test
    func displayNameUsesApprovedSeparatorsAndCasing() {
        #expect(modelDisplayName(from: "openai/gpt-4o-mini") == "OpenAI GPT 4o Mini")
        #expect(modelDisplayName(from: "deepseek/GLM-fp16") == "DeepSeek GLM FP16")
        #expect(modelDisplayName(from: "mYmodel") == "MYmodel")
        #expect(modelDisplayName(from: "foo_bar") == "Foo_bar")
        #expect(modelDisplayName(from: " /--  /") == "")
        #expect(modelDisplayName(from: "  a--b//c  ") == "A B C")
    }

    @Test
    func speedClassificationKeepsDefaultDifferencesAndInputOrder() {
        #expect(ModelSpeedTier.ultraFast.defaultModelID == "deepseek-chat")
        #expect(ModelSpeedTier.fast.defaultModelID == "qwen-turbo-latest")
        #expect(ModelSpeedTier.tier(forModelID: ModelSpeedTier.ultraFast.defaultModelID) == .fast)
        #expect(ModelSpeedTier.tier(forModelID: ModelSpeedTier.fast.defaultModelID) == .ultraFast)
        for identity in ["deepseek-v4-flash", "deepseek-v4-pro", "qwen3-vl-plus"] {
            #expect(LLMModel.allModels.contains { $0.id == identity })
            #expect(ModelSpeedTier.tier(forModelID: identity) == nil)
        }
        let a = LLMModel(id: "deepseek-chat", displayName: "First", provider: "Synthetic")
        let b = LLMModel(id: "unclassified", displayName: "Second", provider: "Synthetic")
        let c = LLMModel(id: "deepseek-chat", displayName: "Third", provider: "Synthetic")
        #expect(ModelSpeedTier.fast.models(in: [a, b, c, a]) == [a, c, a])
    }

    @Test
    func entryProjectionKeepsBaseIdentityAndExplicitFalsyOverrides() {
        let base = LLMModel(id: "a/b", displayName: "Base", provider: "Synthetic", modalityOverride: .vision,
                            contextWindow: 99, maxOutputTokens: 88, supportsReasoning: true,
                            interleavedReasoningField: "trace")
        let overrides = ModelOverrides(displayName: "", maxOutputTokens: 0, modalityOverride: [], contextWindow: 0, supportsReasoning: false)
        let entry = ModelEntry(uuid: "fixture", providerInstanceId: " edge ", model: base, overrides: overrides)
        #expect(!overrides.isEmpty)
        #expect(entry.isUserModified)
        #expect(entry.baseModel == base)
        #expect(entry.overrides == overrides)
        #expect(entry.model.displayName == "")
        #expect(entry.model.maxOutputTokens == 0)
        #expect(entry.model.modalityOverride == [])
        #expect(entry.model.contextWindow == 0)
        #expect(entry.model.supportsReasoning == false)
        #expect(entry.model.interleavedReasoningField == "trace")
        #expect(entry.id == " edge /a/b")
        #expect(entry.selectionAccessibilityIdentifier == "model-picker.edge.a_b")
        let other = ModelEntry(uuid: "fixture", providerInstanceId: "other", model: base)
        #expect(entry.id != other.id)
        #expect(ModelEntry(providerInstanceId: "", model: LLMModel(id: "", displayName: "", provider: "")).selectionAccessibilityIdentifier == "model-picker.unknown.unknown")
    }

    @Test
    func entryLegacyDecodeAndEncodingUseTheBaseModel() throws {
        let bytes = Data(#"{"providerInstanceId":"instance","model":{"id":"synthetic","displayName":"Base","provider":"Synthetic"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ModelEntry.self, from: bytes)
        #expect(!decoded.uuid.isEmpty)
        #expect(decoded.overrides.isEmpty)
        #expect(!decoded.isCustom)
        #expect(!decoded.isHidden)
        #expect(decoded.id == "instance/synthetic")
        var modified = decoded
        modified.overrides.displayName = "Shown"
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(modified)) as? [String: Any])
        #expect(object["baseModel"] == nil)
        let storedModel = try #require(object["model"] as? [String: Any])
        #expect(storedModel["displayName"] as? String == "Base")
        #expect(try JSONDecoder().decode(ModelEntry.self, from: JSONEncoder().encode(modified)) == modified)
        let noOverrides = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(noOverrides["overrides"] == nil)
    }

    @Test
    func groupPersistenceKeepsDuplicatesAndIndependentLimits() throws {
        let bytes = Data(#"{"id":"group-fixture","name":"Synthetic","memberEntryIds":["p/a","p/a","unknown"],"strategy":"fallback"}"#.utf8)
        var group = try JSONDecoder().decode(ModelGroup.self, from: bytes)
        #expect(group.memberEntryIds == ["p/a", "p/a", "unknown"])
        #expect(group.fallbackStrategy == .limited)
        #expect(group.contextLimitTokens == nil)
        #expect(group.lastContextLimitTokens == nil)
        group.lastContextLimitTokens = 31
        group.contextLimitTokens = -3
        #expect(group.lastContextLimitTokens == 31)
        group.contextLimitTokens = nil
        #expect(group.lastContextLimitTokens == 31)
        #expect(try JSONDecoder().decode(ModelGroup.self, from: JSONEncoder().encode(group)) == group)
        let missingID = Data(#"{"name":"Synthetic","memberEntryIds":[],"strategy":"fallback"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelGroup.self, from: missingID) }
        let unknownStrategy = Data(#"{"id":"g","name":"Synthetic","memberEntryIds":[],"strategy":"unknown"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelGroup.self, from: unknownStrategy) }
    }

    @Test
    func toolWireArgumentsUseOriginalStringInsteadOfDictionary() throws {
        let call = LLMToolCall(id: "fixture-call", name: "synthetic", rawArguments: "not parsed", arguments: ["different": 41])
        let function = try #require(call.openAIDict["function"] as? [String: Any])
        #expect(function["arguments"] as? String == "not parsed")
        #expect(call.arguments["different"] as? Int == 41)
    }

    @Test
    func anthropicCacheSumHandlesRequiredMissingNegativeAndOverflow() {
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": 7, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 2]) == 12)
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": 7]) == 7)
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": 0]) == 0)
        #expect(LLMUsage.anthropicCacheHitInputTokens([:]) == nil)
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": -1]) == nil)
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": 7, "cache_read_input_tokens": -1]) == nil)
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": 7, "cache_creation_input_tokens": -1]) == nil)
        #expect(LLMUsage.anthropicCacheHitInputTokens(["input_tokens": Int.max, "cache_read_input_tokens": 1]) == nil)
    }

    @Test
    func thinkingCompatibilityDelegatesUnknownStringsAndCatalog() throws {
        let overrides = try JSONDecoder().decode(ModelOverrides.self, from: Data(#"{"maxThinkingLevel":"retired-fixture"}"#.utf8))
        #expect(overrides.maxThinkingLevel == .xhigh)
        #expect(!overrides.isEmpty)
        #expect(!ModelOverrides(maxThinkingLevel: .off).isEmpty)
        let disabled = LLMModel(id: "claude-opus-4-fixture", displayName: "Fixture", provider: "Synthetic", supportsReasoning: false)
        #expect(disabled.catalogMaxThinkingLevel == .off)
        let declared = LLMModel(id: "CLAUDE-OPUS-4-fixture", displayName: "Fixture", provider: "Synthetic")
        #expect(declared.catalogMaxThinkingLevel == .max)
    }

    @Test
    func overridesRoundTripPreservesIntentAndNestedIntegerModality() throws {
        let fixture = ModelOverrides(displayName: "", maxOutputTokens: 0,
                                     modalityOverride: ModelModality(rawValue: (1 << 18) | 4),
                                     contextWindow: -7, supportsReasoning: false, maxThinkingLevel: .off)
        let bytes = try JSONEncoder().encode(fixture)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object.count == 6)
        #expect(object["modalityOverride"] as? Int == 262148)
        #expect(object["maxThinkingLevel"] as? String == "off")
        let restored = try JSONDecoder().decode(ModelOverrides.self, from: bytes)
        #expect(restored == fixture)
        #expect(!restored.isEmpty)
        #expect(restored.modalityOverride?.inputs == .imageInput)
        #expect(restored.modalityOverride?.outputs == [])
        let emptyBytes = try JSONEncoder().encode(ModelOverrides())
        let emptyObject = try #require(JSONSerialization.jsonObject(with: emptyBytes) as? [String: Any])
        #expect(emptyObject.isEmpty)
        #expect(try JSONDecoder().decode(ModelOverrides.self, from: emptyBytes).isEmpty)
        let embedded = Data(#"{"providerInstanceId":"p","model":{"id":"m","displayName":"M","provider":"Synthetic","modalityOverride":3},"overrides":{"modalityOverride":68,"supportsReasoning":false}}"#.utf8)
        let entry = try JSONDecoder().decode(ModelEntry.self, from: embedded)
        #expect(entry.baseModel.modalityOverride == .textOnly)
        #expect(entry.model.modalityOverride == [.imageInput, .imageOutput])
        #expect(entry.model.supportsReasoning == false)
        #expect(try JSONDecoder().decode(ModelEntry.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test
    func capabilityPromptMatchesDisplayBytesRegardlessOfOutputBits() {
        let fallback = "To handle unsupported media, use shell_execute to run ffmpeg or other CLI tools."
        let fixtures: [(ModelModality, String?)] = [
            ([], "You cannot natively process images or PDFs or audio or video. " + fallback),
            (.textOnly, "You cannot natively process images or PDFs or audio or video. " + fallback),
            (.vision, "You can natively process images and PDFs in this conversation. You cannot natively process audio or video. " + fallback),
            (.imageInput, "You can natively process images in this conversation. You cannot natively process PDFs or audio or video. " + fallback),
            ([.imageInput, .audioInput], "You can natively process images and audio in this conversation. You cannot natively process PDFs or video. " + fallback),
            (.fullMultimodalInput, nil),
            ([.imageInput, .pdfInput, .audioInput, .videoInput], nil)
        ]
        let outputVariants: [ModelModality] = [[], [.imageOutput, .audioOutput, .videoOutput]]
        for (modality, expected) in fixtures {
            for outputs in outputVariants {
                let model = LLMModel(id: "synthetic-prompt", displayName: "Fixture", provider: "Synthetic", modalityOverride: modality.union(outputs))
                #expect(model.capabilityPromptFragment == expected)
            }
        }
    }
}
