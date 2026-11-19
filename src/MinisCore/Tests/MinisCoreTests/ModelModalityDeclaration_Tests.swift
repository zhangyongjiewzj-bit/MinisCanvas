import Foundation
import Testing
@testable import MinisCore

/// 自定义供应商的图片/音频输入声明：推断纯函数、存储兼容、保存修剪。合成夹具，内存 Keychain。
@Suite("自定义供应商模态声明与推断")
struct ModelModalityDeclaration_Tests {
    private func makeStore() -> (store: EnvVarStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modality-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (EnvVarStore(directory: directory, keychain: KeychainStore(backing: InMemoryKeychainBacking())), directory)
    }

    @Test(arguments: [
        "gpt-4o", "GPT-4o-mini", "openai/gpt-4.1", "gpt-5", "o3", "o4-mini", "claude-sonnet-4-6",
        "Claude-3-5-haiku", "qwen-vl-max", "qwen2.5-vl-72b-instruct", "glm-4v", "gemini-2.5-pro",
        "llava-1.6", "pixtral-12b", "InternVL3-8B"
    ])
    func inferredVisionModels(_ id: String) {
        #expect(ModelModalityInference.supportsImageInput(modelID: id))
    }

    @Test(arguments: ["deepseek-chat", "qwen-max", "llama-3-70b", "o3-mini", "text-embedding-3-large", "whisper-1", "pro3", ""])
    func inferredTextOnlyModels(_ id: String) {
        #expect(!ModelModalityInference.supportsImageInput(modelID: id))
    }

    @Test func audioInferenceIsNarrow() {
        #expect(ModelModalityInference.supportsAudioInput(modelID: "gemini-2.5-flash"))
        #expect(ModelModalityInference.supportsAudioInput(modelID: "qwen2.5-omni-7b"))
        #expect(!ModelModalityInference.supportsAudioInput(modelID: "gpt-4o"))
        #expect(!ModelModalityInference.supportsAudioInput(modelID: "whisper-1"))
    }

    @Test func entryDeclarationOverridesInferenceBothWays() {
        let entry = EnvVarEntry(
            name: "MODALITY_ENTRY", value: "", baseURL: "https://example.invalid/v1",
            modelNames: ["gpt-4o", "my-vision", "claude-x"],
            modelImageInput: ["gpt-4o": false, "my-vision": true], modelAudioInput: ["claude-x": true])
        #expect(!entry.supportsImageInput(modelID: "gpt-4o"))
        #expect(entry.supportsImageInput(modelID: "my-vision"))
        #expect(entry.supportsImageInput(modelID: "claude-x"))
        #expect(entry.supportsAudioInput(modelID: "claude-x"))
        #expect(!entry.supportsAudioInput(modelID: "my-vision"))
    }

    @Test func legacyJSONDecodesWithoutDeclarationsAndEncodesNothingWhenEmpty() throws {
        let legacy = Data("""
        {"id":"x","name":"LEGACY_MODALITY","value":"","isSecret":true,"createdAt":0,
         "valueInKeychain":true,"baseURL":"https://example.invalid/v1","modelNames":["m"]}
        """.utf8)
        let entry = try JSONDecoder().decode(EnvVarEntry.self, from: legacy)
        #expect(entry.modelImageInput == nil && entry.modelAudioInput == nil)
        let encoded = try String(decoding: JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!encoded.contains("modelImageInput") && !encoded.contains("modelAudioInput"))
        var emptied = entry
        emptied.modelImageInput = [:]
        let emptyEncoded = try String(decoding: JSONEncoder().encode(emptied), as: UTF8.self)
        #expect(!emptyEncoded.contains("modelImageInput"))
    }

    @Test func declarationsRoundTripThroughStoreAndSurviveMetadataSave() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.saveProvider(
            name: "MODALITY_STORE", apiKey: "synthetic-nonsecret", baseURL: "https://example.invalid/v1",
            modelNames: ["a", "b"], protocolType: .openaiCompatible))
        #expect(store.setModelModalityDeclarations(name: "MODALITY_STORE", image: ["a": true, "gone": true], audio: ["b": false]))
        // 不在模型列表里的键被修剪。
        #expect(store.entry(name: "MODALITY_STORE")?.modelImageInput == ["a": true])
        #expect(store.entry(name: "MODALITY_STORE")?.modelAudioInput == ["b": false])

        let reopened = EnvVarStore(directory: directory, keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        #expect(reopened.entry(name: "MODALITY_STORE")?.modelImageInput == ["a": true])

        // 再次保存元数据：保留声明；删掉模型 a 同步删声明。
        #expect(store.saveProvider(
            name: "MODALITY_STORE", credential: .keepExisting, baseURL: nil,
            modelNames: ["b"], protocolType: .openaiCompatible))
        #expect(store.entry(name: "MODALITY_STORE")?.modelImageInput == nil)
        #expect(store.entry(name: "MODALITY_STORE")?.modelAudioInput == ["b": false])

        #expect(store.setModelModalityDeclarations(name: "MODALITY_STORE", image: [:], audio: [:]))
        #expect(store.entry(name: "MODALITY_STORE")?.modelAudioInput == nil)
    }

    @Test func maxOutputTokensRoundTripPruneAndSurviveMetadataSave() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.saveProvider(
            name: "MAXOUT_STORE", apiKey: "synthetic-nonsecret", baseURL: "https://example.invalid/v1",
            modelNames: ["a", "b"], protocolType: .openaiCompatible))
        // 只保留模型列表内的正整数。
        #expect(store.setModelMaxOutputTokens(name: "MAXOUT_STORE", tokens: ["a": 16384, "b": 0, "gone": 8192]))
        #expect(store.entry(name: "MAXOUT_STORE")?.modelMaxOutputTokens == ["a": 16384])

        let reopened = EnvVarStore(directory: directory, keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        #expect(reopened.entry(name: "MAXOUT_STORE")?.modelMaxOutputTokens == ["a": 16384])

        // 再次保存供应商元数据：保留；删掉模型 a 同步删声明。
        #expect(store.saveProvider(
            name: "MAXOUT_STORE", credential: .keepExisting, baseURL: nil,
            modelNames: ["a", "b"], protocolType: .openaiCompatible))
        #expect(store.entry(name: "MAXOUT_STORE")?.modelMaxOutputTokens == ["a": 16384])
        #expect(store.saveProvider(
            name: "MAXOUT_STORE", credential: .keepExisting, baseURL: nil,
            modelNames: ["b"], protocolType: .openaiCompatible))
        #expect(store.entry(name: "MAXOUT_STORE")?.modelMaxOutputTokens == nil)

        // 旧数据（无此键）解码为 nil，且空声明不写入 JSON。
        var entry = try #require(store.entry(name: "MAXOUT_STORE"))
        entry.modelMaxOutputTokens = [:]
        let encoded = try String(decoding: JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!encoded.contains("modelMaxOutputTokens"))
        #expect(!store.setModelMaxOutputTokens(name: "NO_SUCH_PROVIDER", tokens: ["a": 1]))
    }

    @Test func settingDeclarationsOnMissingProviderFails() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!store.setModelModalityDeclarations(name: "NO_SUCH_PROVIDER", image: ["a": true], audio: [:]))
    }
}
