import Foundation
import Testing
@testable import MinisCore

// NOTE: Run on the CLT-only toolchain with the documented flags (see
// threads/B1-fix.log):
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-EnvVarStore-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Isolated UserDefaults so privacy marks never leak between tests or into
/// the real defaults.
private func makeIsolatedDefaults(_ label: String) -> UserDefaults {
    let suite = "MinisCore-EnvVarPrivacy-\(label)-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

// MARK: - In-memory Keychain (tests never touch the real macOS Keychain)

/// In-memory `KeychainBacking` so `EnvVarStore` tests exercise the migration /
/// storage logic without hitting Security.framework. Global name is unique
/// across the test target module.
final class KeychainStoreInMemoryBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
        return true  // idempotent: absent key is treated as success (matches real backing)
    }
}

/// Controllable failure backing for atomicity tests. A failed `set` never
/// mutates the previously stored value and never touches Security.framework.
final class ControllableKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]
    private var shouldFailSet = false

    func setSetFailure(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        shouldFailSet = enabled
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !shouldFailSet else { return false }
        store[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
        return true
    }
}

/// Read-reporting backing used to prove metadata-only provider saves do not
/// synchronously resolve a deferred Keychain reference.
struct KeychainOperationCounts: Equatable {
    let reads: Int
    let writes: Int
    let deletes: Int
}

final class RecordingKeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var readKeys: [String] = []
    private var setKeys: [String] = []
    private var deleteKeys: [String] = []
    private var readResultOverride: KeychainReadResult?

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        setKeys.append(key)
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        readKeys.append(key)
        return values[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deleteKeys.append(key)
        values.removeValue(forKey: key)
        return true
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        readKeys.append(key)
        if let readResultOverride { return readResultOverride }
        guard let value = values[key] else { return .missing }
        return .found(value)
    }

    func setReadResultOverride(_ result: KeychainReadResult?) {
        lock.lock(); defer { lock.unlock() }
        readResultOverride = result
    }

    func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    func resetReadTrace() {
        lock.lock(); defer { lock.unlock() }
        readKeys.removeAll()
    }

    func resetOperationTrace() {
        lock.lock(); defer { lock.unlock() }
        readKeys.removeAll()
        setKeys.removeAll()
        deleteKeys.removeAll()
    }

    var readKeysSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return readKeys
    }

    var setKeysSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return setKeys
    }

    var deleteKeysSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return deleteKeys
    }

    var operationCountsSnapshot: KeychainOperationCounts {
        lock.lock(); defer { lock.unlock() }
        return KeychainOperationCounts(
            reads: readKeys.count,
            writes: setKeys.count,
            deletes: deleteKeys.count
        )
    }
}

/// An `EnvVarStore` backed by a fresh in-memory Keychain (isolated per call).
private func makeStore(_ dir: URL) -> EnvVarStore {
    EnvVarStore(directory: dir, keychain: KeychainStore(backing: KeychainStoreInMemoryBacking()))
}


struct EnvVarStoreTests {

    @Test func explicitEditorPrivacySavePreservesGenericBoundaryAndFailureAtomicity() throws {
        let dir = try makeTempDir("explicit-editor-privacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeIsolatedDefaults("explicit-editor-privacy")
        let privacy = EnvVarPrivacyStore(defaults: defaults)
        let backing = ControllableKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain, privacyStore: privacy)
        let name = "OWNED_EDITOR_PLAIN"
        #expect(store.setEnvVar(name: name, value: "owned-only", isSecret: false))
        #expect(privacy.provenance(name: name) == .unclassified)
        let generic = try #require(store.entry(name: name))
        #expect(!store.mayDisplayValueInList(generic))
        #expect(store.setEnvVar(name: "OWNED_GENERIC_DEFAULT", value: "owned-default"))
        #expect(privacy.provenance(name: "OWNED_GENERIC_DEFAULT") == .unclassified)

        #expect(store.setEnvVarWithExplicitPrivacyClassification(
            name: name, value: "owned-only", isSecret: false))
        #expect(privacy.provenance(name: name) == .explicitNonSecret)
        let cold = EnvVarStore(directory: dir, keychain: keychain,
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let displayed = try #require(cold.entry(name: name))
        #expect(displayed.value == "owned-only")
        #expect(!displayed.isSecret && !displayed.valueInKeychain)
        #expect(cold.mayDisplayValueInList(displayed))

        let before = try Data(contentsOf: dir.appendingPathComponent(EnvVarStore.fileName))
        backing.setSetFailure(true)
        #expect(!store.setEnvVarWithExplicitPrivacyClassification(
            name: name, value: "synthetic-sensitive-replacement", isSecret: true))
        #expect(privacy.provenance(name: name) == .explicitNonSecret)
        #expect(store.entry(name: name) == displayed)
        #expect(try Data(contentsOf: dir.appendingPathComponent(EnvVarStore.fileName)) == before)
        #expect(!store.setEnvVarWithExplicitPrivacyClassification(
            name: "OWNED_FAILED_CLASSIFICATION", value: "synthetic-sensitive", isSecret: true))
        #expect(privacy.provenance(name: "OWNED_FAILED_CLASSIFICATION") == .unclassified)
        #expect(store.entry(name: "OWNED_FAILED_CLASSIFICATION") == nil)

        backing.setSetFailure(false)
        #expect(store.setEnvVarWithExplicitPrivacyClassification(
            name: name, value: "synthetic-sensitive-replacement", isSecret: true))
        #expect(privacy.provenance(name: name) == .explicitSecret)
        let secret = try #require(store.entry(name: name))
        #expect(secret.isSecret && secret.valueInKeychain)
        #expect(!store.mayDisplayValueInList(secret))
    }

    @Test func recordingBackingCountsSyntheticDirectGet() {
        let backing = RecordingKeychainBacking(values: ["SYNTHETIC_GET_KEY": "synthetic-value"])
        #expect(backing.get("SYNTHETIC_GET_KEY") == "synthetic-value")
        #expect(backing.readKeysSnapshot == ["SYNTHETIC_GET_KEY"])
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 1, writes: 0, deletes: 0))
    }

    @Test func keychainWriteReadbackRejectsWrongValueOrIdentity() {
        let reference = Data([0x01, 0x02, 0x03])
        let replacement = Data([0x04, 0x05, 0x06])

        #expect(SecItemKeychainBacking.persistentReferenceReadbackMatches(
            expectedValue: "updated-value",
            expectedReference: reference,
            actualValue: .found("updated-value"),
            firstReference: .found(reference),
            secondReference: .found(reference)
        ))
        #expect(!SecItemKeychainBacking.persistentReferenceReadbackMatches(
            expectedValue: "updated-value",
            expectedReference: reference,
            actualValue: .found("stale-value"),
            firstReference: .found(reference),
            secondReference: .found(reference)
        ))
        #expect(!SecItemKeychainBacking.persistentReferenceReadbackMatches(
            expectedValue: "updated-value",
            expectedReference: reference,
            actualValue: .found("updated-value"),
            firstReference: .found(replacement),
            secondReference: .found(reference)
        ))
        #expect(!SecItemKeychainBacking.persistentReferenceReadbackMatches(
            expectedValue: "updated-value",
            expectedReference: reference,
            actualValue: .found("updated-value"),
            firstReference: .found(reference),
            secondReference: .found(replacement)
        ))
        #expect(!SecItemKeychainBacking.persistentReferenceReadbackMatches(
            expectedValue: "updated-value",
            expectedReference: reference,
            actualValue: .found("updated-value"),
            firstReference: .duplicate,
            secondReference: .found(reference)
        ))
        #expect(!SecItemKeychainBacking.persistentReferenceReadbackMatches(
            expectedValue: "updated-value",
            expectedReference: reference,
            actualValue: .denied,
            firstReference: .found(reference),
            secondReference: .found(reference)
        ))
    }

    @Test func keychainReadDeleteRequireStableIdentity() {
        let reference = Data([0x01, 0x02, 0x03])
        let replacement = Data([0x04, 0x05, 0x06])

        #expect(SecItemKeychainBacking.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: .found("old-value"),
            firstReference: .found(reference),
            secondReference: .found(reference)
        ) == .found("old-value"))
        #expect(SecItemKeychainBacking.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: .found("replacement-value"),
            firstReference: .found(reference),
            secondReference: .found(replacement)
        ) == .failed)
        #expect(SecItemKeychainBacking.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: .found("old-value"),
            firstReference: .duplicate,
            secondReference: .found(reference)
        ) == .failed)
        #expect(SecItemKeychainBacking.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: .found("old-value"),
            firstReference: .denied,
            secondReference: .found(reference)
        ) == .failed)
        #expect(SecItemKeychainBacking.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: .denied,
            firstReference: .found(reference),
            secondReference: .found(reference)
        ) == .denied)
        #expect(SecItemKeychainBacking.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: .missing,
            firstReference: .missing,
            secondReference: .missing
        ) == .failed)
        #expect(SecItemKeychainBacking.deleteReadbackConfirmsRemoval(
            .missing,
            .missing
        ))
        #expect(!SecItemKeychainBacking.deleteReadbackConfirmsRemoval(
            .found(reference),
            .found(replacement)
        ))
        #expect(!SecItemKeychainBacking.deleteReadbackConfirmsRemoval(
            .found(reference),
            .denied
        ))
    }

    // MARK: - CRUD + persistence round trip

    @Test func setGetDeletePersistsAcrossStoreInstances() throws {
        let dir = try makeTempDir("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Shared in-memory Keychain so the secret survives a reload of the store.
        let keychain = KeychainStore(backing: KeychainStoreInMemoryBacking())
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.setEnvVar(name: "OPENAI_API_KEY", value: "sk-1234567890abcdef"))
        #expect(store.getEnvVar(name: "OPENAI_API_KEY") == "sk-1234567890abcdef")
        #expect(store.count == 1)
        // Lookups are case-insensitive (names canonicalized to uppercase).
        #expect(store.getEnvVar(name: "openai_api_key") == "sk-1234567890abcdef")

        // Persistence: a fresh store over the same directory sees the value.
        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reloaded.getEnvVar(name: "OPENAI_API_KEY") == "sk-1234567890abcdef")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(EnvVarStore.fileName).path))

        #expect(reloaded.deleteEnvVar(name: "OPENAI_API_KEY"))
        #expect(reloaded.getEnvVar(name: "OPENAI_API_KEY") == nil)

        // Deletion also persists.
        let reloadedAgain = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reloadedAgain.getEnvVar(name: "OPENAI_API_KEY") == nil)
        #expect(reloadedAgain.count == 0)
    }

    @Test func setEnvVarUpsertsExistingEntry() throws {
        let dir = try makeTempDir("upsert")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeStore(dir)
        #expect(store.setEnvVar(name: "FOO", value: "one"))
        #expect(store.setEnvVar(name: "foo", value: "two"))  // same canonical name
        #expect(store.count == 1)
        #expect(store.getEnvVar(name: "FOO") == "two")
        #expect(store.entry(name: "FOO")?.id == store.entry(name: "FOO")?.id)
    }

    @Test func invalidNameIsRejected() throws {
        let dir = try makeTempDir("invalid")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeStore(dir)
        #expect(!store.setEnvVar(name: "1BAD NAME!", value: "x"))
        #expect(!store.setEnvVar(name: "", value: "x"))
        #expect(store.count == 0)
    }

    // MARK: - Process environment import

    @Test func loadFromProcessEnvironmentImportsRuntimeVars() throws {
        let dir = try makeTempDir("import")
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "MINISCORE_TEST_IMPORT_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let store = makeStore(dir)
        let count = store.loadFromProcessEnvironment(source: [name: "imported-value"])
        #expect(count == 1)
        #expect(store.getEnvVar(name: name) == "imported-value")
    }

    @Test func loadFromProcessEnvironmentDoesNotClobberStoredValues() throws {
        let dir = try makeTempDir("noclobber")
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "MINISCORE_TEST_KEEP_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let store = makeStore(dir)
        #expect(store.setEnvVar(name: name, value: "stored-value"))
        let imported = store.loadFromProcessEnvironment(source: [name: "process-value"])
        #expect(store.getEnvVar(name: name) == "stored-value")  // stored wins
        #expect(imported == 0)
    }

    // MARK: - Secret flagging

    @Test func secretFlagDefaultsFromSensitiveList() throws {
        let dir = try makeTempDir("secretdefault")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeStore(dir)
        // Name matches the default sensitive suffixes → auto-marked secret.
        store.setEnvVar(name: "OPENAI_API_KEY", value: "sk-abc")
        #expect(store.entry(name: "OPENAI_API_KEY")?.isSecret == true)
        // Ordinary name → not secret.
        store.setEnvVar(name: "DATABASE_URL", value: "postgres://localhost")
        #expect(store.entry(name: "DATABASE_URL")?.isSecret == false)
        // Explicit override wins.
        store.setEnvVar(name: "MY_PASSWORD", value: "hunter2", isSecret: false)
        #expect(store.entry(name: "MY_PASSWORD")?.isSecret == false)
    }

    // MARK: - EnvVarRedactor

    @Test func redactMasksSingleValue() {
        #expect(EnvVarRedactor.redact("sk-1234567890abcdef") == String(repeating: "*", count: "sk-1234567890abcdef".count))
        #expect(EnvVarRedactor.redact("12345678") == "********")
        #expect(EnvVarRedactor.redact("short") == "*****")
        #expect(EnvVarRedactor.redact("") == "")
    }

    @Test func redactAllReplacesAllOccurrences() {
        let secret = "sk-1234567890abcdef"
        let (out, hits) = EnvVarRedactor.redactAll(
            in: "Authorization: Bearer \(secret) … \(secret)",
            values: [secret]
        )
        #expect(hits == 1)
        #expect(!out.contains(secret))
        let masked = String(repeating: "*", count: secret.count)
        #expect(out == "Authorization: Bearer \(masked) … \(masked)")
    }

    @Test func redactAllProcessesLongestFirst() {
        let long = "SECRET-KEY-123"
        // "KEY-123" is a substring of "SECRET-KEY-123"; longest-first must
        // win, otherwise the shorter match would mangle the longer value.
        let (out, _) = EnvVarRedactor.redactAll(in: long, values: ["KEY-123", long])
        #expect(out == String(repeating: "*", count: long.count))
    }

    @Test func redactAllSkipsShortAndNonSecretValues() {
        // Short values are skipped to avoid mangling common words.
        let (out, hits) = EnvVarRedactor.redactAll(in: "true value here", values: ["true"])
        #expect(hits == 0)
        #expect(out == "true value here")

        // Entries variant: only isSecret values are redacted.
        let entries = [
            EnvVarEntry(name: "OPENAI_API_KEY", value: "sk-1234567890abcdef", isSecret: true),
            EnvVarEntry(name: "DATABASE_URL", value: "postgres://localhost", isSecret: false),
        ]
        let (out2, hits2) = EnvVarRedactor.redactAll(
            in: "key sk-1234567890abcdef db postgres://localhost",
            entries: entries
        )
        #expect(hits2 == 1)
        #expect(out2.contains(EnvVarRedactor.redact("sk-1234567890abcdef")))
        #expect(out2.contains("postgres://localhost"))
    }

    @Test func redactBoundaryLengths() {
        // All lengths, including the old eight-character boundary, are fully masked.
        #expect(EnvVarRedactor.redact("1234567") == "*******")
        #expect(EnvVarRedactor.redact("abcdefgh") == "********")
        // Long values also retain no original prefix or suffix.
        let long = String(repeating: "x", count: 1000)
        #expect(EnvVarRedactor.redact(long) == String(repeating: "*", count: long.count))
    }

    @Test func redactAllEmptyAndExtremeInputs() {
        // 空值表：原样返回、0 命中
        #expect(EnvVarRedactor.redactAll(in: "hello secret", values: []).0 == "hello secret")
        #expect(EnvVarRedactor.redactAll(in: "hello secret", values: []).1 == 0)
        // 空文本：不崩、0 命中
        #expect(EnvVarRedactor.redactAll(in: "", values: ["SECRET123"]).0 == "")
        #expect(EnvVarRedactor.redactAll(in: "", values: ["SECRET123"]).1 == 0)
        // 全部短值：跳过
        let (out, hits) = EnvVarRedactor.redactAll(in: "ab cd ef", values: ["ab", "cd", "ef"])
        #expect(hits == 0)
        #expect(out == "ab cd ef")
        // 整段文本即密钥 → 全部掩掉（去重后只计 1 次命中）
        let (out2, hits2) = EnvVarRedactor.redactAll(
            in: "SK-ABCDEFGH",
            values: ["SK-ABCDEFGH", "SK-ABCDEFGH", "SK-ABCDEFGH"]
        )
        #expect(hits2 == 1)
        #expect(out2 == String(repeating: "*", count: "SK-ABCDEFGH".count))
    }

    // MARK: - EnvVarPrivacyStore

    @Test func defaultSensitiveSuffixesHit() {
        let store = EnvVarPrivacyStore(defaults: makeIsolatedDefaults("defaults"))
        #expect(store.isSecret(name: "OPENAI_API_KEY"))
        #expect(store.isSecret(name: "ANTHROPIC_TOKEN"))
        #expect(store.isSecret(name: "MY_PASSWORD"))
        #expect(store.isSecret(name: "FOO_KEY"))
        #expect(store.isSecret(name: "SECRET_TEST"))
        #expect(store.isSecret(name: "SERVICE_CREDENTIAL_BLOB"))
        #expect(!store.isSecret(name: "DATABASE_URL"))
        #expect(!store.isSecret(name: "HOME"))
        #expect(!store.isSecret(name: "SECRETARY"))  // suffix, not prefix
    }

    @Test func markAndUnmarkRoundTrip() {
        let store = EnvVarPrivacyStore(defaults: makeIsolatedDefaults("mark"))
        #expect(!store.isSecret(name: "DATABASE_URL"))
        store.markSecret(name: "DATABASE_URL")
        #expect(store.isSecret(name: "DATABASE_URL"))
        store.unmarkSecret(name: "DATABASE_URL")
        #expect(!store.isSecret(name: "DATABASE_URL"))
    }

    @Test func unmarkOverridesDefaultSensitiveList() {
        let store = EnvVarPrivacyStore(defaults: makeIsolatedDefaults("unmark"))
        #expect(store.isSecret(name: "OPENAI_API_KEY"))
        store.unmarkSecret(name: "OPENAI_API_KEY")
        #expect(!store.isSecret(name: "OPENAI_API_KEY"))
        store.markSecret(name: "OPENAI_API_KEY")
        #expect(store.isSecret(name: "OPENAI_API_KEY"))
    }

    // MARK: - AJ-39 供应商转换建议（providerSuggestion）

    @Test func dashScopeKeysSuggestDashScopeConfig() {
        let s = EnvVarStore.providerSuggestion(for: "DASHSCOPE_API_KEY")
        #expect(s?.providerLabel == "DashScope（阿里云百炼）")
        #expect(s?.protocolType == .openaiCompatible)
        #expect(s?.baseURL == "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        #expect(s?.modelNames == ["qwen3.8-max-preview"])
    }

    @Test func bailianKeysSuggestDashScopeConfig() {
        // BAILIAN_*_API_KEY 通配模式（含 BAILIAN_TOKEN_PLAN_API_KEY）。
        #expect(EnvVarStore.providerSuggestion(for: "BAILIAN_TOKEN_PLAN_API_KEY")?.providerLabel == "DashScope（阿里云百炼）")
        #expect(EnvVarStore.providerSuggestion(for: "BAILIAN_CUSTOM_API_KEY")?.providerLabel == "DashScope（阿里云百炼）")
        #expect(EnvVarStore.providerSuggestion(for: "bailian_foo_api_key")?.providerLabel == "DashScope（阿里云百炼）")
    }

    @Test func hermesCustomQwenKeySuggestDashScope() {
        #expect(EnvVarStore.providerSuggestion(for: "HERMES_CUSTOM_QWEN38_API_KEY")?.providerLabel == "DashScope（阿里云百炼）")
    }

    @Test func deepSeekKeysSuggestDeepSeekConfig() {
        let s = EnvVarStore.providerSuggestion(for: "DEEPSEEK_API_KEY")
        #expect(s?.providerLabel == "DeepSeek")
        #expect(s?.baseURL == DeepSeekProviderContract.baseURL)
        // B16：对齐 Hermes 侧 deepseek 通道（deepseek-v4-flash 为主模型），保留通用型号
        #expect(s?.modelNames == ["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat", "deepseek-reasoner", "deepseek-flash"])
        #expect(EnvVarStore.providerSuggestion(for: "HERMES_CUSTOM_DEEPSEEK_API_KEY")?.providerLabel == "DeepSeek")
    }

    @Test func genericApiKeySuggestsOpenAICompatibleBlank() {
        // 未知 *_API_KEY → 自定义 OpenAI 兼容（Base URL / 模型留空，用户自填）。
        let s = EnvVarStore.providerSuggestion(for: "MY_CUSTOM_PROVIDER_API_KEY")
        #expect(s?.providerLabel == "自定义 OpenAI 兼容")
        #expect(s?.protocolType == .openaiCompatible)
        #expect(s?.baseURL == nil)
        #expect(s?.modelNames.isEmpty == true)
    }

    @Test func nonApiKeyNamesGetNoSuggestion() {
        // 非 API key 名称（数据库 URL / 普通变量）→ 无转换建议（nil）。
        #expect(EnvVarStore.providerSuggestion(for: "DATABASE_URL") == nil)
        #expect(EnvVarStore.providerSuggestion(for: "HOME") == nil)
        #expect(EnvVarStore.providerSuggestion(for: "MY_PASSWORD") == nil)
        #expect(EnvVarStore.providerSuggestion(for: "PLAIN") == nil)
        // 大写规范化：小写输入同样命中。
        #expect(EnvVarStore.providerSuggestion(for: "dashscope_api_key")?.providerLabel == "DashScope（阿里云百炼）")
    }

    @Test func providerKeepExistingPreservesKeychainSecretAfterReload() async throws {
        let dir = try makeTempDir("provider-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)

        #expect(store.saveProvider(
            name: "KEEP_PROVIDER",
            apiKey: "sk-keep",
            baseURL: "https://old.example/v1",
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        backing.resetOperationTrace()
        let before = backing.operationCountsSnapshot
        #expect(reloaded.saveProvider(
            name: "KEEP_PROVIDER",
            credential: .keepExisting,
            baseURL: "https://new.example/v1",
            modelNames: ["new"],
            protocolType: .anthropic
        ))
        #expect(backing.operationCountsSnapshot == before)

        let final = EnvVarStore(directory: dir, keychain: keychain)
        #expect(final.entry(name: "KEEP_PROVIDER")?.baseURL == "https://new.example/v1")
        #expect(final.entry(name: "KEEP_PROVIDER")?.modelNames == ["new"])
        #expect(final.entry(name: "KEEP_PROVIDER")?.protocolType == .anthropic)
        #expect(final.entry(name: "KEEP_PROVIDER")?.valueInKeychain == true)
        #expect(final.entry(name: "KEEP_PROVIDER")?.value == "")
        #expect(backing.operationCountsSnapshot == before)
        #expect(await final.getEnvVarAsync(name: "KEEP_PROVIDER") == "sk-keep")
    }

    @Test func providerKeepExistingPreservesInMemoryCredentialWithZeroKeychainDelta() throws {
        let dir = try makeTempDir("provider-keep-in-memory")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)

        #expect(store.saveProvider(
            name: "IN_MEMORY_PROVIDER",
            credential: .replace("sk-in-memory"),
            baseURL: "https://old.example/v1",
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        let originalID = store.entry(name: "IN_MEMORY_PROVIDER")?.id
        backing.resetOperationTrace()

        #expect(store.saveProvider(
            name: "IN_MEMORY_PROVIDER",
            credential: .keepExisting,
            baseURL: "https://new.example/v1",
            modelNames: ["new"],
            protocolType: .anthropic
        ))
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
        #expect(store.entry(name: "IN_MEMORY_PROVIDER")?.id == originalID)
        #expect(store.entry(name: "IN_MEMORY_PROVIDER")?.value == "sk-in-memory")
        #expect(store.entry(name: "IN_MEMORY_PROVIDER")?.valueInKeychain == true)
        #expect(store.entry(name: "IN_MEMORY_PROVIDER")?.baseURL == "https://new.example/v1")
        #expect(backing.get("IN_MEMORY_PROVIDER") == "sk-in-memory")
    }

    @Test @MainActor func providerKeepExistingDoesNotResolveDeferredKeychainReference() async throws {
        let dir = try makeTempDir("provider-keep-no-read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)

        #expect(store.saveProvider(
            name: "NO_READ_PROVIDER",
            apiKey: "sk-no-read",
            baseURL: "https://old.example/v1",
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        backing.resetOperationTrace()

        #expect(reloaded.saveProvider(
            name: "NO_READ_PROVIDER",
            credential: .keepExisting,
            baseURL: "https://new.example/v1",
            modelNames: ["new"],
            protocolType: .anthropic
        ))
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
        #expect(reloaded.entry(name: "NO_READ_PROVIDER")?.valueInKeychain == true)
        #expect(reloaded.entry(name: "NO_READ_PROVIDER")?.value == "")
        let keptMetadata = try String(
            contentsOf: dir.appendingPathComponent(EnvVarStore.fileName),
            encoding: .utf8
        )
        #expect(!keptMetadata.contains("sk-no-read"))

        // The synchronous compatibility getter is fail-closed on the main
        // actor, while the async boundary resolves the same reference off-main.
        #expect(reloaded.getEnvVar(name: "NO_READ_PROVIDER") == nil)
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
        #expect(await reloaded.getEnvVarAsync(name: "NO_READ_PROVIDER") == "sk-no-read")
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 1, writes: 0, deletes: 0))
    }

    @Test func providerMissingReferenceDefersFailureUntilReadAndReplacementRepairsIt() async throws {
        let dir = try makeTempDir("provider-missing-reference")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)

        #expect(store.saveProvider(
            name: "MISSING_REFERENCE_PROVIDER",
            apiKey: "sk-before-missing",
            baseURL: nil,
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        backing.removeValue(forKey: "MISSING_REFERENCE_PROVIDER")
        backing.resetOperationTrace()

        #expect(reloaded.saveProvider(
            name: "MISSING_REFERENCE_PROVIDER",
            credential: .keepExisting,
            baseURL: "https://edited.example/v1",
            modelNames: ["edited"],
            protocolType: .anthropic
        ))
        #expect(reloaded.lastPersistenceError == nil)
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
        #expect(reloaded.entry(name: "MISSING_REFERENCE_PROVIDER")?.baseURL == "https://edited.example/v1")
        #expect(reloaded.entry(name: "MISSING_REFERENCE_PROVIDER")?.valueInKeychain == true)
        #expect(reloaded.entry(name: "MISSING_REFERENCE_PROVIDER")?.value == "")

        switch await reloaded.readEnvVarResultAsync(name: "MISSING_REFERENCE_PROVIDER") {
        case .success:
            Issue.record("missing deferred Keychain reference unexpectedly resolved")
        case .failure(let error):
            #expect(error == .keychainReadMissing)
        }
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 1, writes: 0, deletes: 0))

        #expect(reloaded.saveProvider(
            name: "MISSING_REFERENCE_PROVIDER",
            credential: .replace("sk-replacement"),
            baseURL: "https://replacement.example/v1",
            modelNames: ["replacement"],
            protocolType: .openaiCompatible
        ))
        #expect(backing.setKeysSnapshot.contains("MISSING_REFERENCE_PROVIDER"))
        #expect(backing.get("MISSING_REFERENCE_PROVIDER") == "sk-replacement")

        let reopened = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reopened.getEnvVar(name: "MISSING_REFERENCE_PROVIDER") == "sk-replacement")
        let repairedMetadata = try String(
            contentsOf: dir.appendingPathComponent(EnvVarStore.fileName),
            encoding: .utf8
        )
        #expect(!repairedMetadata.contains("sk-before-missing"))
        #expect(!repairedMetadata.contains("sk-replacement"))
    }

    @Test func providerKeepExistingDefersDeniedAndFailedUntilRealRead() async throws {
        let cases: [(String, KeychainReadResult, EnvVarPersistenceError)] = [
            ("denied", .denied, .keychainReadDenied),
            ("failed", .failed, .keychainReadFailed),
        ]

        for (label, readResult, expectedError) in cases {
            let dir = try makeTempDir("provider-keep-\(label)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let backing = RecordingKeychainBacking()
            let keychain = KeychainStore(backing: backing)
            let store = EnvVarStore(directory: dir, keychain: keychain)
            #expect(store.saveProvider(
                name: "DEFERRED_PROVIDER",
                credential: .replace("sk-deferred"),
                baseURL: "https://old.example/v1",
                modelNames: ["old"],
                protocolType: .openaiCompatible
            ))
            let reloaded = EnvVarStore(directory: dir, keychain: keychain)
            backing.setReadResultOverride(readResult)
            backing.resetOperationTrace()

            #expect(reloaded.saveProvider(
                name: "DEFERRED_PROVIDER",
                credential: .keepExisting,
                baseURL: "https://edited.example/v1",
                modelNames: ["edited"],
                protocolType: .anthropic
            ))
            #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
            #expect(reloaded.entry(name: "DEFERRED_PROVIDER")?.baseURL == "https://edited.example/v1")

            let actual = await reloaded.readEnvVarResultAsync(name: "DEFERRED_PROVIDER")
            #expect(actual == .failure(expectedError))
            #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 1, writes: 0, deletes: 0))
        }
    }

    @Test func providerKeepExistingMetadataFailureRollsBackWithoutKeychainOperations() throws {
        let dir = try makeTempDir("provider-keep-metadata-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.saveProvider(
            name: "ROLLBACK_PROVIDER",
            credential: .replace("sk-rollback"),
            baseURL: "https://old.example/v1",
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        let metadataURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let originalMetadata = try Data(contentsOf: metadataURL)
        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        let originalEntry = try #require(reloaded.entry(name: "ROLLBACK_PROVIDER"))
        backing.resetOperationTrace()
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)

        #expect(!reloaded.saveProvider(
            name: "ROLLBACK_PROVIDER",
            credential: .keepExisting,
            baseURL: "https://new.example/v1",
            modelNames: ["new"],
            protocolType: .anthropic
        ))
        #expect(reloaded.lastPersistenceError == .metadataWriteFailed)
        #expect(reloaded.entry(name: "ROLLBACK_PROVIDER") == originalEntry)
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))

        try FileManager.default.removeItem(at: metadataURL)
        try originalMetadata.write(to: metadataURL, options: .atomic)
        let reopened = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reopened.entry(name: "ROLLBACK_PROVIDER") == originalEntry)
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
    }

    @Test func providerReopenRebindsLegacyReferenceIntoSuccessorNamespace() async throws {
        let dir = try makeTempDir("provider-rebind-reopen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "HERMES_CUSTOM_DEEPSEEK_API_KEY"
        let legacy = RecordingKeychainBacking()
        let seededStore = EnvVarStore(
            directory: dir,
            keychain: KeychainStore(backing: legacy)
        )
        #expect(seededStore.saveProvider(
            name: key,
            apiKey: "sk-legacy-reference",
            baseURL: "https://legacy.example/v1",
            modelNames: ["legacy"],
            protocolType: .openaiCompatible
        ))

        let successor = RecordingKeychainBacking()
        let successorKeychain = KeychainStore(
            backing: successor,
            legacyBackings: [legacy]
        )
        let reopened = EnvVarStore(directory: dir, keychain: successorKeychain)
        #expect(await reopened.getEnvVarAsync(name: key) == "sk-legacy-reference")
        #expect(successor.get(key) == "sk-legacy-reference")
        #expect(legacy.get(key) == "sk-legacy-reference")
        #expect(successor.setKeysSnapshot == [key])
    }

    @Test func providerBlankLegacyEditMapsToKeepExisting() throws {
        let dir = try makeTempDir("provider-legacy-blank")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)

        #expect(store.saveProvider(
            name: "LEGACY_PROVIDER",
            apiKey: "sk-legacy",
            baseURL: "https://old.example/v1",
            modelNames: ["old"],
            protocolType: .openaiCompatible
        ))
        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        backing.resetOperationTrace()
        #expect(reloaded.saveProvider(
            name: "LEGACY_PROVIDER",
            apiKey: "   ",
            baseURL: "https://edited.example/v1",
            modelNames: ["edited"],
            protocolType: .anthropic
        ))
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))

        let reopened = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reopened.entry(name: "LEGACY_PROVIDER")?.baseURL == "https://edited.example/v1")
        #expect(reopened.entry(name: "LEGACY_PROVIDER")?.modelNames == ["edited"])
        #expect(reopened.entry(name: "LEGACY_PROVIDER")?.protocolType == .anthropic)
        #expect(reopened.entry(name: "LEGACY_PROVIDER")?.valueInKeychain == true)
        #expect(reopened.entry(name: "LEGACY_PROVIDER")?.value == "")
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
        #expect(backing.get("LEGACY_PROVIDER") == "sk-legacy")
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 1, writes: 0, deletes: 0))
    }

    @Test func providerReplaceUpdatesKeychainSecret() throws {
        let dir = try makeTempDir("provider-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = KeychainStore(backing: KeychainStoreInMemoryBacking())
        let store = EnvVarStore(directory: dir, keychain: keychain)

        #expect(store.saveProvider(
            name: "REPLACE_PROVIDER",
            apiKey: "sk-old",
            baseURL: nil,
            modelNames: ["model"],
            protocolType: .openaiCompatible
        ))
        #expect(store.saveProvider(
            name: "REPLACE_PROVIDER",
            credential: .replace("sk-new"),
            baseURL: nil,
            modelNames: ["model"],
            protocolType: .openaiCompatible
        ))

        let reloaded = EnvVarStore(directory: dir, keychain: keychain)
        #expect(reloaded.getEnvVar(name: "REPLACE_PROVIDER") == "sk-new")
    }

    @Test func providerMissingRejectsNewCredentiallessProvider() throws {
        let dir = try makeTempDir("provider-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)

        #expect(!store.saveProvider(
            name: "MISSING_PROVIDER",
            credential: .missing,
            baseURL: "https://example.com/v1",
            modelNames: ["model"],
            protocolType: .openaiCompatible
        ))
        #expect(!store.saveProvider(
            name: "MISSING_PROVIDER",
            credential: .replace("   "),
            baseURL: nil,
            modelNames: [],
            protocolType: .openaiCompatible
        ))
        #expect(store.providerRecords.isEmpty)
    }

    // MARK: - Secret persistence failure atomicity

    @Test func newProviderKeychainSetFailureIsAtomicAndNeverPersistsCredential() throws {
        let dir = try makeTempDir("provider-set-failure-new")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = ControllableKeychainBacking()
        backing.setSetFailure(true)
        let store = EnvVarStore(directory: dir, keychain: KeychainStore(backing: backing))
        #expect(store.setEnvVar(name: "BASELINE", value: "unchanged", isSecret: false))
        let metadataURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let before = try Data(contentsOf: metadataURL)
        let fixtureCredential = "fixture-new-provider-credential"

        #expect(!store.saveProvider(
            name: "FAILED_NEW_PROVIDER",
            credential: .replace(fixtureCredential),
            baseURL: "https://example.invalid/v1",
            modelNames: ["fixture-model"],
            protocolType: .openaiCompatible
        ))

        let after = try Data(contentsOf: metadataURL)
        #expect(store.entry(name: "FAILED_NEW_PROVIDER") == nil)
        #expect(backing.get("FAILED_NEW_PROVIDER") == nil)
        #expect(after == before)
        #expect(!String(decoding: after, as: UTF8.self).contains(fixtureCredential))
    }

    @Test func providerReplacementKeychainSetFailurePreservesPriorState() throws {
        let dir = try makeTempDir("provider-set-failure-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = ControllableKeychainBacking()
        let store = EnvVarStore(directory: dir, keychain: KeychainStore(backing: backing))
        let oldCredential = "fixture-prior-provider-credential"
        #expect(store.saveProvider(
            name: "ATOMIC_PROVIDER",
            credential: .replace(oldCredential),
            baseURL: "https://old.example.invalid/v1",
            modelNames: ["old-model"],
            protocolType: .openaiCompatible
        ))
        let metadataURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let beforeEntry = store.entry(name: "ATOMIC_PROVIDER")
        let before = try Data(contentsOf: metadataURL)
        let replacement = "fixture-replacement-provider-credential"
        backing.setSetFailure(true)

        #expect(!store.saveProvider(
            name: "ATOMIC_PROVIDER",
            credential: .replace(replacement),
            baseURL: "https://new.example.invalid/v1",
            modelNames: ["new-model"],
            protocolType: .anthropic
        ))

        let after = try Data(contentsOf: metadataURL)
        #expect(store.entry(name: "ATOMIC_PROVIDER") == beforeEntry)
        #expect(backing.get("ATOMIC_PROVIDER") == oldCredential)
        #expect(after == before)
        #expect(store.entry(name: "ATOMIC_PROVIDER")?.value != replacement)
        #expect(!String(decoding: after, as: UTF8.self).contains(replacement))
    }

    @Test func genericSecretSetFailureDoesNotCommit() throws {
        let dir = try makeTempDir("generic-secret-set-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = ControllableKeychainBacking()
        backing.setSetFailure(true)
        let store = EnvVarStore(directory: dir, keychain: KeychainStore(backing: backing))
        #expect(store.setEnvVar(name: "BASELINE", value: "unchanged", isSecret: false))
        let metadataURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let before = try Data(contentsOf: metadataURL)
        let fixtureCredential = "fixture-generic-secret-credential"

        #expect(!store.setEnvVar(
            name: "FAILED_GENERIC_SECRET",
            value: fixtureCredential,
            isSecret: true
        ))

        let after = try Data(contentsOf: metadataURL)
        #expect(store.count == 1)
        #expect(store.entry(name: "FAILED_GENERIC_SECRET") == nil)
        #expect(backing.get("FAILED_GENERIC_SECRET") == nil)
        #expect(after == before)
        #expect(!String(decoding: after, as: UTF8.self).contains(fixtureCredential))
    }

    @Test func secretEncoderNeverSerializesValueWithoutKeychainFlag() throws {
        let fixtureCredential = "fixture-encoder-secret-credential"
        let secret = EnvVarEntry(
            name: "INCONSISTENT_SECRET",
            value: fixtureCredential,
            isSecret: true,
            valueInKeychain: false
        )
        let encodedSecret = try JSONEncoder().encode(secret)
        let decodedSecret = try JSONDecoder().decode(EnvVarEntry.self, from: encodedSecret)
        #expect(!String(decoding: encodedSecret, as: UTF8.self).contains(fixtureCredential))
        #expect(decodedSecret.value.isEmpty)
        #expect(!decodedSecret.valueInKeychain)

        let plain = EnvVarEntry(name: "PLAIN", value: "plain-round-trip", isSecret: false)
        let encodedPlain = try JSONEncoder().encode(plain)
        let decodedPlain = try JSONDecoder().decode(EnvVarEntry.self, from: encodedPlain)
        #expect(decodedPlain.value == "plain-round-trip")
    }

    @Test func failedLegacySecretMigrationScrubsPlaintextAndDisablesCredential() throws {
        let dir = try makeTempDir("legacy-secret-migration-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixtureCredential = "fixture-legacy-plaintext-credential"
        let metadataURL = dir.appendingPathComponent(EnvVarStore.fileName)
        let legacyJSON = """
        [{"id":"legacy-fixture","name":"LEGACY_FAILED_SECRET","value":"\(fixtureCredential)","isSecret":true,"createdAt":0}]
        """
        try Data(legacyJSON.utf8).write(to: metadataURL, options: .atomic)
        let backing = ControllableKeychainBacking()
        backing.setSetFailure(true)

        let store = EnvVarStore(directory: dir, keychain: KeychainStore(backing: backing))

        #expect(store.getEnvVar(name: "LEGACY_FAILED_SECRET")?.isEmpty != false)
        #expect(backing.get("LEGACY_FAILED_SECRET") == nil)
        let rewritten = try Data(contentsOf: metadataURL)
        #expect(!String(decoding: rewritten, as: UTF8.self).contains(fixtureCredential))
        let entries = try JSONDecoder().decode([EnvVarEntry].self, from: rewritten)
        #expect(entries.count == 1)
        #expect(entries.first?.value.isEmpty == true)
        #expect(entries.first?.valueInKeychain == false)
    }
}

/// A controlled real facade backing: the paused read releases its mutex so a
/// concurrent writer can actually replace the value before the old read exits.
final class CredentialConsistencyRaceBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [String: String] = [:]
    private var pauseNext = false
    private var started = false
    private var released = false
    private var failAfterWrite = false
    func pauseNextRead() { condition.lock(); pauseNext = true; started = false; released = false; condition.unlock() }
    func failNextWriteAfterMutation() { condition.lock(); failAfterWrite = true; condition.unlock() }
    func releaseRead() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hasStarted() -> Bool { condition.lock(); defer { condition.unlock() }; return started }
    func waitUntilReadStarted() async throws {
        for _ in 0..<300 {
            if hasStarted() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        releaseRead()
        throw NSError(domain: "CredentialConsistencyFixture", code: 1)
    }
    func set(_ value: String, forKey key: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        values[key] = value
        let succeeds = !failAfterWrite
        failAfterWrite = false
        return succeeds
    }
    func get(_ key: String) -> String? {
        if case .found(let value) = readResult(forKey: key) { return value }
        return nil
    }
    func delete(_ key: String) -> Bool {
        condition.lock(); defer { condition.unlock() }; values.removeValue(forKey: key); return true
    }
    func readResult(forKey key: String) -> KeychainReadResult {
        condition.lock(); defer { condition.unlock() }
        let captured = values[key].map(KeychainReadResult.found) ?? .missing
        if pauseNext {
            pauseNext = false; started = true; condition.broadcast()
            while !released { condition.wait() }
        }
        return captured
    }
}

struct EnvVarCredentialConsistencyTests {
    @Test func sameIDReplacementAcrossInstancesRejectsCapturedOldRead() async throws {
        try await replacementRace(partialFailure: false)
    }
    @Test func actualBackingMutationFollowedByFailureStillRejectsOldRead() async throws {
        try await replacementRace(partialFailure: true)
    }
    private func replacementRace(partialFailure: Bool) async throws {
        let root = try makeTempDir("credential-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let backing = CredentialConsistencyRaceBacking()
        let domain = KeychainConsistencyDomain()
        let firstFacade = KeychainStore(backing: backing, consistencyDomain: domain)
        let secondFacade = KeychainStore(backing: backing, consistencyDomain: domain)
        let seed = EnvVarStore(directory: root, keychain: firstFacade)
        #expect(seed.saveProvider(name: "RACE_API_KEY", credential: .replace("synthetic-before"),
            baseURL: "https://example.invalid", modelNames: ["model"], protocolType: .openaiCompatible))
        let reader = EnvVarStore(directory: root, keychain: firstFacade)
        let writer = EnvVarStore(directory: root, keychain: secondFacade)
        let original = try #require(reader.credentialBinding(name: "RACE_API_KEY"))
        backing.pauseNextRead()
        let pending = Task { await reader.readEnvVarResultAsync(name: "RACE_API_KEY") }
        defer { backing.releaseRead(); pending.cancel() }
        try await backing.waitUntilReadStarted()
        if partialFailure { backing.failNextWriteAfterMutation() }
        let saved = writer.saveProvider(name: "RACE_API_KEY", credential: .replace("synthetic-after"),
            baseURL: "https://example.invalid", modelNames: ["model"], protocolType: .openaiCompatible)
        #expect(saved == !partialFailure)
        #expect(writer.entry(name: "RACE_API_KEY")?.id == original.recordID)
        backing.releaseRead()
        let result = await pending.value
        #expect(result == .failure(.keychainReadFailed))
        let current = try #require(reader.credentialBinding(name: "RACE_API_KEY"))
        #expect(current.recordID == original.recordID)
        #expect(current.revision != original.revision)
        let fresh = await reader.readEnvVarResultAsync(name: "RACE_API_KEY")
        #expect(fresh == .success("synthetic-after"))
    }

    @Test func metadataOnlyChangeAndDeleteRecreateInvalidateBindings() throws {
        let root = try makeTempDir("credential-metadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let backing = KeychainStoreInMemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: root, keychain: keychain)
        #expect(store.setEnvVar(name: "PLAIN_VALUE", value: "synthetic-one", isSecret: false))
        let first = try #require(store.credentialBinding(name: "PLAIN_VALUE"))
        #expect(store.setEnvVar(name: "PLAIN_VALUE", value: "synthetic-two", isSecret: false))
        let second = try #require(store.credentialBinding(name: "PLAIN_VALUE"))
        #expect(first.recordID == second.recordID)
        #expect(first.revision != second.revision)
        let staleInstance = EnvVarStore(directory: root, keychain: keychain)
        #expect(store.deleteEnvVar(name: "PLAIN_VALUE"))
        #expect(store.setEnvVar(name: "PLAIN_VALUE", value: "synthetic-three", isSecret: false))
        #expect(staleInstance.credentialBinding(name: "PLAIN_VALUE") == nil)
        #expect(store.credentialBinding(name: "PLAIN_VALUE")?.recordID != first.recordID)
    }
}

@Suite("O16a provider presentation identity")
struct O16ProviderDisplayNameTests {
    @Test func renameAndReloadPreserveCredentialAndRecordIdentity() throws {
        let dir = try makeTempDir("display-name")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = RecordingKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let store = EnvVarStore(directory: dir, keychain: keychain)
        #expect(store.saveProvider(name: "MY_PROVIDER_API_KEY", apiKey: "synthetic-display-test",
            baseURL: "https://example.invalid/v1", modelNames: ["model-a"], protocolType: .openaiCompatible))
        let before = try #require(store.entry(name: "MY_PROVIDER_API_KEY"))
        backing.resetOperationTrace()
        #expect(store.saveProvider(name: before.name, credential: .keepExisting,
            baseURL: before.baseURL, modelNames: before.modelNames, protocolType: before.protocolType,
            displayName: "我的 模型服务"))
        let reopened = EnvVarStore(directory: dir, keychain: keychain)
        let after = try #require(reopened.entry(name: before.name))
        #expect(after.providerDisplayName == "我的 模型服务")
        #expect(after.id == before.id && after.name == before.name)
        #expect(after.modelNames == before.modelNames && after.valueInKeychain)
        #expect(backing.operationCountsSnapshot == KeychainOperationCounts(reads: 0, writes: 0, deletes: 0))
    }

    @Test func oldMetadataDecodesWithoutDisplayNameAndCanBeRenamed() throws {
        let original = EnvVarEntry(name: "OPENAI_API_KEY", value: "", isSecret: true,
            valueInKeychain: true, modelNames: ["model-a"])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "displayName")
        var migrated = try JSONDecoder().decode(EnvVarEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!migrated.providerDisplayName.isEmpty)
        migrated.displayName = "中文 Provider"
        let roundTrip = try JSONDecoder().decode(EnvVarEntry.self, from: JSONEncoder().encode(migrated))
        #expect(roundTrip.providerDisplayName == "中文 Provider")
        #expect(roundTrip.id == original.id && roundTrip.name == original.name)
    }
}
