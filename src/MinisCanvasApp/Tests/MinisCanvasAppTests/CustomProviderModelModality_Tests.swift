import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 自定义供应商模型的输入模态：声明 ∪ 推断进入 `customProviderModel` 的 modalityOverride。
@Suite("自定义供应商模型输入模态")
struct CustomProviderModelModality_Tests {
    private func record(
        models: [String], image: [String: Bool]? = nil, audio: [String: Bool]? = nil,
        baseURL: String = "https://relay.example.invalid/v1"
    ) -> EnvVarEntry {
        EnvVarEntry(name: "RELAY_API_KEY", value: "synthetic", isSecret: true, baseURL: baseURL,
                    modelNames: models, protocolType: .openaiCompatible,
                    modelImageInput: image, modelAudioInput: audio)
    }

    @Test func inferredVisionModelAcceptsImagesWithoutDeclaration() {
        let rec = record(models: ["gpt-4o", "deepseek-chat"])
        let vision = ChatStore.customProviderModel(record: rec, modelID: "gpt-4o")
        #expect(vision.capabilities.supportedModalities.contains(.imageInput))
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: vision.capabilities).isAllowed)
        let text = ChatStore.customProviderModel(record: rec, modelID: "deepseek-chat")
        #expect(text.modalityOverride == nil)
        #expect(!text.capabilities.supportedModalities.contains(.imageInput))
    }

    @Test func userDeclarationBeatsInferenceInBothDirections() {
        let rec = record(models: ["gpt-4o", "my-private-vl"], image: ["gpt-4o": false, "my-private-vl": true])
        #expect(!ChatStore.customProviderModel(record: rec, modelID: "gpt-4o")
            .capabilities.supportedModalities.contains(.imageInput))
        #expect(ChatStore.customProviderModel(record: rec, modelID: "my-private-vl")
            .capabilities.supportedModalities.contains(.imageInput))
    }

    @Test func audioDeclarationAddsAudioInputOnTopOfTextOnly() {
        let rec = record(models: ["plain"], audio: ["plain": true])
        let modalities = ChatStore.customProviderModel(record: rec, modelID: "plain").capabilities.supportedModalities
        #expect(modalities.contains(.audioInput) && !modalities.contains(.imageInput))
    }

    /// F-13：自定义服务商的模型编号与内置清单同名时，沿用清单的思考内容回传字段；清单里没有的模型不带。
    @Test func customModelSharingABuiltinIDKeepsItsReasoningReplayField() {
        let rec = record(models: ["deepseek-v4-flash", "deepseek-reasoner", "my-private-model"])
        let builtin = LLMModel.allModels.filter { $0.interleavedReasoningField != nil }
        #expect(!builtin.isEmpty)
        for model in builtin {
            #expect(ChatStore.customProviderModel(record: record(models: [model.id]), modelID: model.id)
                .interleavedReasoningField == model.interleavedReasoningField)
        }
        #expect(ChatStore.customProviderModel(record: rec, modelID: "deepseek-v4-flash")
            .interleavedReasoningField == "reasoning_content")
        #expect(ChatStore.customProviderModel(record: rec, modelID: "my-private-model")
            .interleavedReasoningField == nil)
    }

    @Test func deepSeekFlashExceptionStillAppliesAndAlternatePortStaysTextOnly() {
        let canonical = record(models: ["deepseek-flash"], baseURL: DeepSeekProviderContract.baseURL)
        #expect(ChatStore.customProviderModel(record: canonical, modelID: "deepseek-flash")
            .capabilities.supportedModalities.contains(.imageInput))
        let other = record(models: ["deepseek-flash"], baseURL: "https://api.deepseek.com:8443")
        #expect(!ChatStore.customProviderModel(record: other, modelID: "deepseek-flash")
            .capabilities.supportedModalities.contains(.imageInput))
    }
}
