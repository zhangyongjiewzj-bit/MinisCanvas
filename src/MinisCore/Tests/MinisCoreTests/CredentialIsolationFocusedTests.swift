import Foundation
import Testing
@testable import MinisCore

/// Synthetic backing used only by this focused suite. It never touches the
/// platform Keychain and can deterministically reject writes.
private final class CredentialIsolationBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectWrites = false

    func setWriteFailure(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        rejectWrites = enabled
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rejectWrites else { return false }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }
}

private func credentialIsolationDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-CredentialIsolation-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct CredentialIsolationFocusedTests {
    @Test func providerConfigNeverSerializesOrRevivesDirectCredential() throws {
        let config = ProviderConfig(
            label: "fixture-provider",
            providerType: .openAI,
            apiKeyEnvVar: "FIXTURE_API_KEY",
            apiKey: "fixture-credential-should-never-leave-memory"
        )
        let data = try JSONEncoder().encode(config)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("fixture-credential-should-never-leave-memory"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["apiKey"] == nil)

        let legacy = """
        {"id":"legacy","label":"fixture-provider","providerType":"openAI","credentialType":"apiKey","isEnabled":true,"createdAt":0,"apiKey":"fixture-legacy-secret"}
        """
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacy.utf8))
        #expect(decoded.apiKey == nil)
    }

    @Test func providerEnvSecretIsPlaceholderOnlyInMetadata() throws {
        let directory = try credentialIsolationDirectory("placeholder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = CredentialIsolationBacking()
        let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))

        #expect(store.saveProvider(
            name: "FIXTURE_API_KEY",
            apiKey: "fixture-credential-123456789",
            baseURL: "https://example.invalid/v1",
            modelNames: ["fixture-model"],
            protocolType: .openaiCompatible
        ))
        let metadata = try String(
            contentsOf: directory.appendingPathComponent(EnvVarStore.fileName),
            encoding: .utf8
        )
        #expect(!metadata.contains("fixture-credential-123456789"))
        #expect(metadata.contains("\"value\":\"\""))
        #expect(metadata.contains("\"valueInKeychain\":true"))
    }

    @Test func keychainFailureRetainsPriorCredentialAndReportsSafeError() throws {
        let directory = try credentialIsolationDirectory("keychain-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = CredentialIsolationBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: directory, keychain: keychain)
        #expect(store.saveProvider(
            name: "FIXTURE_API_KEY",
            apiKey: "fixture-old-credential",
            baseURL: nil,
            modelNames: [],
            protocolType: .openaiCompatible
        ))

        backing.setWriteFailure(true)
        #expect(!store.saveProvider(
            name: "FIXTURE_API_KEY",
            apiKey: "fixture-new-credential",
            baseURL: nil,
            modelNames: [],
            protocolType: .openaiCompatible
        ))
        #expect(store.getEnvVar(name: "FIXTURE_API_KEY") == "fixture-old-credential")
        #expect(backing.get("FIXTURE_API_KEY") == "fixture-old-credential")
        #expect(store.lastPersistenceError == .keychainWriteFailed)
        #expect(!String(describing: store.lastPersistenceError!).contains("fixture"))
    }

    @Test func metadataFailureRollsBackKeychainAndInMemoryCredential() throws {
        let directory = try credentialIsolationDirectory("metadata-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = CredentialIsolationBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: directory, keychain: keychain)
        #expect(store.saveProvider(
            name: "FIXTURE_API_KEY",
            apiKey: "fixture-old-credential",
            baseURL: nil,
            modelNames: [],
            protocolType: .openaiCompatible
        ))

        let metadataURL = directory.appendingPathComponent(EnvVarStore.fileName)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        #expect(!store.saveProvider(
            name: "FIXTURE_API_KEY",
            apiKey: "fixture-new-credential",
            baseURL: nil,
            modelNames: [],
            protocolType: .openaiCompatible
        ))
        #expect(store.getEnvVar(name: "FIXTURE_API_KEY") == "fixture-old-credential")
        #expect(backing.get("FIXTURE_API_KEY") == "fixture-old-credential")
        #expect(store.lastPersistenceError == .metadataWriteFailed)
    }
}
