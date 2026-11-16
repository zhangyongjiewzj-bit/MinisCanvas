import Foundation
import Testing
@testable import MinisCore

/// Keychain migration tests: `KeychainStore` (SecItem wrapper) + the
/// `EnvVarStore` route for `*_API_KEY`-class secrets, plus backwards
/// compatibility for old `envvars.json` files that still hold plaintext keys.
///
/// All tests use the in-memory `KeychainStoreInMemoryBacking` (defined in
/// `EnvVarStoreTests.swift`, shared test-target module) so nothing touches the
/// real macOS Keychain.
struct KeychainStoreTests {

    /// Unique temp directory per test (tests run in parallel; never share paths).
    private func makeKeychainTempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-Keychain-" + label + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A KeychainStore backed by a fresh in-memory store.
    private func makeInMemoryKeychain() -> KeychainStore {
        KeychainStore(backing: KeychainStoreInMemoryBacking())
    }

    // MARK: - KeychainStore CRUD

    @Test func keychainSetGetDeleteRoundTrip() {
        let kc = makeInMemoryKeychain()
        #expect(kc.set("secret-value-a", forKey: "KEY_A"))
        #expect(kc.get("KEY_A") == "secret-value-a")
        #expect(kc.set("secret-value-b", forKey: "KEY_B"))
        #expect(kc.get("KEY_B") == "secret-value-b")
        // Overwrite an existing key.
        #expect(kc.set("updated-a", forKey: "KEY_A"))
        #expect(kc.get("KEY_A") == "updated-a")
        // Delete removes; deleting an absent key is idempotent (true).
        #expect(kc.delete("KEY_A"))
        #expect(kc.get("KEY_A") == nil)
        #expect(kc.delete("KEY_A"))
    }

    @Test func keychainGetMissingReturnsNil() {
        let kc = makeInMemoryKeychain()
        #expect(kc.get("NEVER_SET") == nil)
        #expect(kc.delete("NEVER_SET"))
    }

    // MARK: - EnvVarStore routes secrets to the Keychain

    @Test func secretValueStoredInKeychainNotInJson() throws {
        let dir = try makeKeychainTempDir("secret")
        defer { try? FileManager.default.removeItem(at: dir) }

        let keychain = makeInMemoryKeychain()
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.setEnvVar(name: "OPENAI_API_KEY", value: "KC_TEST_VALUE_1234567890"))

        // In-memory value is the real one; read path hits the Keychain copy.
        #expect(store.getEnvVar(name: "OPENAI_API_KEY") == "KC_TEST_VALUE_1234567890")
        #expect(keychain.get("OPENAI_API_KEY") == "KC_TEST_VALUE_1234567890")

        // The JSON metadata file must NOT contain the plaintext; only a placeholder.
        let json = try String(contentsOf: dir.appendingPathComponent(EnvVarStore.fileName), encoding: .utf8)
        #expect(!json.contains("KC_TEST_VALUE_1234567890"))
        #expect(json.contains("\"valueInKeychain\":true"))
        #expect(json.contains("\"value\":\"\""))
    }

    @Test func nonSecretValueStaysInJson() throws {
        let dir = try makeKeychainTempDir("nonsecret")
        defer { try? FileManager.default.removeItem(at: dir) }

        let keychain = makeInMemoryKeychain()
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.setEnvVar(name: "DATABASE_URL", value: "postgres://localhost"))

        #expect(keychain.get("DATABASE_URL") == nil)
        #expect(store.entry(name: "DATABASE_URL")?.valueInKeychain == false)
        let json = try String(contentsOf: dir.appendingPathComponent(EnvVarStore.fileName), encoding: .utf8)
        // JSONEncoder escapes "/" as "\/", so decode the array and compare values.
        let decoded = try JSONDecoder().decode([EnvVarEntry].self, from: Data(json.utf8))
        #expect(decoded.first?.value == "postgres://localhost")
        #expect(decoded.first?.valueInKeychain == false)
    }

    @Test func saveProviderRoutesApiKeyToKeychain() throws {
        let dir = try makeKeychainTempDir("provider")
        defer { try? FileManager.default.removeItem(at: dir) }

        let keychain = makeInMemoryKeychain()
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.saveProvider(
            name: "DASHSCOPE_API_KEY",
            apiKey: "KC_TEST_VALUE_1234567890",
            baseURL: "https://api.example.com/v1",
            modelNames: ["qwen3.8-max-preview"],
            protocolType: .openaiCompatible
        ))

        #expect(store.getEnvVar(name: "DASHSCOPE_API_KEY") == "KC_TEST_VALUE_1234567890")
        #expect(keychain.get("DASHSCOPE_API_KEY") == "KC_TEST_VALUE_1234567890")
        #expect(store.entry(name: "DASHSCOPE_API_KEY")?.isSecret == true)
        let json = try String(contentsOf: dir.appendingPathComponent(EnvVarStore.fileName), encoding: .utf8)
        #expect(!json.contains("KC_TEST_VALUE_1234567890"))
    }

    @Test func deleteEnvVarAlsoRemovesKeychainCopy() throws {
        let dir = try makeKeychainTempDir("delete")
        defer { try? FileManager.default.removeItem(at: dir) }

        let keychain = makeInMemoryKeychain()
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.setEnvVar(name: "OPENAI_API_KEY", value: "KC_TEST_VALUE_1234567890"))
        #expect(keychain.get("OPENAI_API_KEY") == "KC_TEST_VALUE_1234567890")

        #expect(store.deleteEnvVar(name: "OPENAI_API_KEY"))
        #expect(store.getEnvVar(name: "OPENAI_API_KEY") == nil)
        #expect(keychain.get("OPENAI_API_KEY") == nil)
    }

    // MARK: - Backwards compatibility: old plaintext JSON auto-migrates

    @Test func backwardCompatMigratesPlaintextOnLoad() throws {
        let dir = try makeKeychainTempDir("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate an OLD envvars.json (no `valueInKeychain` field) holding a
        // plaintext secret plus a non-secret value.
        let fileURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let oldJSON = """
        [
          {"id":"old-1","name":"DASHSCOPE_API_KEY","value":"OLD_PLAINTEXT_123456","isSecret":true,"createdAt":0},
          {"id":"old-2","name":"DATABASE_URL","value":"postgres://localhost","isSecret":false,"createdAt":0}
        ]
        """
        try oldJSON.write(to: fileURL, atomically: true, encoding: .utf8)

        let keychain = makeInMemoryKeychain()
        let store = EnvVarStore(directory: dir, keychain: keychain)

        // Values still readable...
        #expect(store.getEnvVar(name: "DASHSCOPE_API_KEY") == "OLD_PLAINTEXT_123456")
        #expect(store.getEnvVar(name: "DATABASE_URL") == "postgres://localhost")

        // ...the secret was migrated into the Keychain on first load...
        #expect(keychain.get("DASHSCOPE_API_KEY") == "OLD_PLAINTEXT_123456")
        #expect(store.entry(name: "DASHSCOPE_API_KEY")?.valueInKeychain == true)
        // ...but the non-secret was NOT migrated.
        #expect(keychain.get("DATABASE_URL") == nil)

        // The store resaved the JSON, stripping the plaintext secret.
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!json.contains("OLD_PLAINTEXT_123456"))
        #expect(json.contains("\"valueInKeychain\":true"))
    }

    @Test func reloadReadsSecretFromKeychain() throws {
        let dir = try makeKeychainTempDir("reload")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Shared in-memory Keychain across two store instances (same as the
        // real app's Keychain service surviving a store reload).
        let keychain = makeInMemoryKeychain()
        let store1 = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store1.setEnvVar(name: "DASHSCOPE_API_KEY", value: "KC_TEST_VALUE_1234567890"))

        let store2 = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store2.getEnvVar(name: "DASHSCOPE_API_KEY") == "KC_TEST_VALUE_1234567890")
        #expect(store2.entry(name: "DASHSCOPE_API_KEY")?.valueInKeychain == true)
    }

    // MARK: - EnvVarEntry Codable with valueInKeychain

    @Test func valueInKeychainEncodesPlaceholderAndDecodes() throws {
        let entry = EnvVarEntry(
            name: "OPENAI_API_KEY",
            value: "KC_TEST_VALUE_1234567890",
            isSecret: true,
            valueInKeychain: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(EnvVarEntry.self, from: data)
        #expect(decoded.valueInKeychain == true)
        // The plaintext is never persisted; the encoded value is a placeholder.
        #expect(decoded.value == "")
        #expect(decoded.isSecret == true)
    }

    @Test func oldEntryWithoutValueInKeychainDecodesAsFalse() throws {
        let oldData = """
        {"id":"x","name":"FOO","value":"bar","isSecret":false,"createdAt":0}
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(EnvVarEntry.self, from: oldData)
        #expect(entry.valueInKeychain == false)
        #expect(entry.value == "bar")
    }
}
struct KeychainConsistencyDomainTests {
    @Test func productionServicesShareOnlyTheirExactDomainWithoutReadingSecrets() throws {
        let service = "test.consistency." + UUID().uuidString
        let first = KeychainStore(secItemService: service)
        let same = KeychainStore(secItemService: service)
        let other = KeychainStore(secItemService: service + ".other")
        #expect(first.consistencyToken(forKey: "KEY") == same.consistencyToken(forKey: "KEY"))
        #expect(first.consistencyToken(forKey: "KEY") != other.consistencyToken(forKey: "KEY"))
    }

    @Test func existingClassInjectionSharesActualBackingIdentityWithoutANewNoncePerFacade() {
        let backing = KeychainStoreInMemoryBacking()
        let first = KeychainStore(backing: backing)
        let same = KeychainStore(backing: backing)
        let separate = KeychainStore(backing: KeychainStoreInMemoryBacking())
        #expect(first.consistencyToken(forKey: "KEY") == same.consistencyToken(forKey: "KEY"))
        #expect(first.consistencyToken(forKey: "KEY") != separate.consistencyToken(forKey: "KEY"))
        let before = first.consistencyToken(forKey: "KEY")
        #expect(same.set("synthetic", forKey: "KEY"))
        #expect(first.consistencyToken(forKey: "KEY") != before)
    }

    @Test func sharedInjectedCapabilityRejectsDirectWriterButIsolatedDomainDoesNot() async throws {
        let backing = CredentialConsistencyRaceBacking()
        let shared = KeychainConsistencyDomain()
        let reader = KeychainStore(backing: backing, consistencyDomain: shared)
        let writer = KeychainStore(backing: backing, consistencyDomain: shared)
        let isolated = KeychainStore(backing: KeychainStoreInMemoryBacking())
        #expect(writer.set("synthetic-before", forKey: "KEY"))
        let isolatedStamp = try #require(isolated.consistencyToken(forKey: "KEY"))
        backing.pauseNextRead()
        let pending = Task { await reader.readResultAsync(forKey: "KEY") }
        defer { backing.releaseRead(); pending.cancel() }
        try await backing.waitUntilReadStarted()
        #expect(writer.set("synthetic-after", forKey: "KEY"))
        backing.releaseRead()
        let old = await pending.value
        #expect(old == .failed)
        #expect(isolated.consistencyToken(forKey: "KEY") == isolatedStamp)
        let fresh = await reader.readResultAsync(forKey: "KEY")
        #expect(fresh == .found("synthetic-after"))
        let stamp = reader.consistencyToken(forKey: "KEY")
        #expect(writer.delete("KEY"))
        #expect(reader.consistencyToken(forKey: "KEY") != stamp)
    }
}
