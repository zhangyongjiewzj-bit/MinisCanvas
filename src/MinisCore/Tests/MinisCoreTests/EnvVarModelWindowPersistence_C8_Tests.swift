import Foundation
import Testing
@testable import MinisCore

/// C8（L4a）：供应商记录的可选 `modelContextWindows`。合成夹具，内存 Keychain，不碰真实凭据。
@Suite("C8 供应商记录模型窗口持久化")
struct EnvVarModelWindowPersistence_C8_Tests {
    private func makeStore() -> (store: EnvVarStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c8-window-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return (EnvVarStore(directory: directory, keychain: keychain), directory)
    }

    @Test func savedWindowRoundTripsThroughProviderRecord() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.saveProvider(
            name: "C8_ROUNDTRIP", apiKey: "synthetic-nonsecret", baseURL: "https://example.invalid/v1",
            modelNames: ["small-local", "other"], protocolType: .openaiCompatible,
            modelContextWindows: ["small-local": 32_000]))
        #expect(store.entry(name: "C8_ROUNDTRIP")?.modelContextWindows == ["small-local": 32_000])

        let reopened = EnvVarStore(directory: directory, keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        #expect(reopened.entry(name: "C8_ROUNDTRIP")?.modelContextWindows == ["small-local": 32_000])
    }

    @Test func legacyJSONWithoutTheKeyDecodesAsNil() throws {
        let legacy = Data("""
        {"id":"x","name":"C8_LEGACY","value":"","isSecret":true,"createdAt":0,
         "valueInKeychain":true,"baseURL":"https://example.invalid/v1","modelNames":["m"]}
        """.utf8)
        let decoder = JSONDecoder()
        let entry = try decoder.decode(EnvVarEntry.self, from: legacy)
        #expect(entry.modelContextWindows == nil)
        #expect(entry.modelNames == ["m"])
    }

    @Test func removedModelDropsItsWindow() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.saveProvider(
            name: "C8_DROP", apiKey: "synthetic-nonsecret", baseURL: nil,
            modelNames: ["a", "b"], protocolType: .openaiCompatible,
            modelContextWindows: ["a": 1_000, "b": 2_000]))
        #expect(store.saveProvider(
            name: "C8_DROP", credential: .keepExisting, baseURL: nil,
            modelNames: ["b"], protocolType: .openaiCompatible,
            modelContextWindows: ["a": 1_000, "b": 2_000]))
        #expect(store.entry(name: "C8_DROP")?.modelContextWindows == ["b": 2_000])
    }

    @Test func omittedParameterKeepsExistingWindowsAndEmptyDictionaryClears() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.saveProvider(
            name: "C8_KEEP", apiKey: "synthetic-nonsecret", baseURL: nil,
            modelNames: ["a"], protocolType: .openaiCompatible, modelContextWindows: ["a": 4_096]))
        #expect(store.saveProvider(
            name: "C8_KEEP", credential: .keepExisting, baseURL: nil,
            modelNames: ["a"], protocolType: .openaiCompatible))
        #expect(store.entry(name: "C8_KEEP")?.modelContextWindows == ["a": 4_096])
        #expect(store.saveProvider(
            name: "C8_KEEP", credential: .keepExisting, baseURL: nil,
            modelNames: ["a"], protocolType: .openaiCompatible, modelContextWindows: [:]))
        #expect(store.entry(name: "C8_KEEP")?.modelContextWindows == nil)
    }

    @Test func savingWindowsDoesNotChangeCredentialFields() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.saveProvider(
            name: "C8_CRED", apiKey: "synthetic-nonsecret", baseURL: nil,
            modelNames: ["a"], protocolType: .openaiCompatible))
        let before = store.entry(name: "C8_CRED")
        #expect(store.saveProvider(
            name: "C8_CRED", credential: .keepExisting, baseURL: nil,
            modelNames: ["a"], protocolType: .openaiCompatible, modelContextWindows: ["a": 8_000]))
        let after = store.entry(name: "C8_CRED")
        #expect(after?.isSecret == before?.isSecret)
        #expect(after?.valueInKeychain == before?.valueInKeychain)
        #expect(after?.value == before?.value)
        #expect(after?.id == before?.id)
    }
}
