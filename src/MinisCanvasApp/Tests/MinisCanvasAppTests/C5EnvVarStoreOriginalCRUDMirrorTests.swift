import Foundation
import Testing
import Darwin
@testable import MinisCore
private final class C5OriginalEnvRAMBacking: KeychainBacking, @unchecked Sendable {
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

@Suite(.serialized)
struct C5EnvVarStoreOriginalCRUDMirrorTests {
    @Test
    func setGetDeletePersistsAcrossStoreInstances() throws {
        let actualMainThread = Thread.isMainThread
        print("C5_CORE_ENV_EXECUTOR method=setGetDeletePersistsAcrossStoreInstances Thread.isMainThread=\(actualMainThread)")
        try #require(!actualMainThread, "Core sync credential contract requires original non-main executor; do not prewarm or bypass guard")
        let c5 = try C5CoreNonActorOwnedFixture()
        let dir = c5.root
        let privacy = EnvVarPrivacyStore(defaults: c5.defaults)
        defer { c5.cleanup() }

        // Shared in-memory Keychain so the secret survives a reload of the store.
        let keychain = KeychainStore(backing: C5OriginalEnvRAMBacking())
        let store = EnvVarStore(directory: dir, keychain: keychain, privacyStore: privacy)
        #expect(store.setEnvVar(name: "OPENAI_API_KEY", value: "sk-1234567890abcdef"))
        #expect(store.getEnvVar(name: "OPENAI_API_KEY") == "sk-1234567890abcdef")
        #expect(store.count == 1)
        // Lookups are case-insensitive (names canonicalized to uppercase).
        #expect(store.getEnvVar(name: "openai_api_key") == "sk-1234567890abcdef")

        // Persistence: a fresh store over the same directory sees the value.
        let reloaded = EnvVarStore(directory: dir, keychain: keychain, privacyStore: privacy)
        #expect(reloaded.getEnvVar(name: "OPENAI_API_KEY") == "sk-1234567890abcdef")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(EnvVarStore.fileName).path))

        #expect(reloaded.deleteEnvVar(name: "OPENAI_API_KEY"))
        #expect(reloaded.getEnvVar(name: "OPENAI_API_KEY") == nil)

        // Deletion also persists.
        let reloadedAgain = EnvVarStore(directory: dir, keychain: keychain, privacyStore: privacy)
        #expect(reloadedAgain.getEnvVar(name: "OPENAI_API_KEY") == nil)
        #expect(reloadedAgain.count == 0)
    }

    @Test
    func setEnvVarUpsertsExistingEntry() throws {
        let actualMainThread = Thread.isMainThread
        print("C5_CORE_ENV_EXECUTOR method=setEnvVarUpsertsExistingEntry Thread.isMainThread=\(actualMainThread)")
        try #require(!actualMainThread, "Core sync credential contract requires original non-main executor; do not prewarm or bypass guard")
        let c5 = try C5CoreNonActorOwnedFixture()
        let dir = c5.root
        let privacy = EnvVarPrivacyStore(defaults: c5.defaults)
        defer { c5.cleanup() }

        let store = EnvVarStore(directory: dir, keychain: KeychainStore(backing: C5OriginalEnvRAMBacking()), privacyStore: privacy)
        #expect(store.setEnvVar(name: "FOO", value: "one"))
        #expect(store.setEnvVar(name: "foo", value: "two"))  // same canonical name
        #expect(store.count == 1)
        #expect(store.getEnvVar(name: "FOO") == "two")
        #expect(store.entry(name: "FOO")?.id == store.entry(name: "FOO")?.id)
    }
}

// Non-actor fixture for original Core synchronous tests. No App types or logging singleton.
// The actual target's driver and description have no default MainActor isolation.
private final class C5CoreNonActorOwnedFixture {
    let root: URL
    let defaults: UserDefaults
    private let suite: String
    private let device: dev_t
    private let inode: ino_t
    init() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let directory = formal.rootDirectory.appendingPathComponent("C5-core-env-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var state = stat()
        try #require(lstat(directory.path, &state) == 0 && state.st_mode & S_IFMT == S_IFDIR && state.st_uid == geteuid() && state.st_mode & 0o777 == 0o700)
        root = directory; device = state.st_dev; inode = state.st_ino
        suite = "com.miniscanvas.c5.core-env." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        // Any throwing construction failure preserves the exact private root for diagnosis.
    }
    func cleanup() {
        var state = stat()
        let same = lstat(root.path, &state) == 0 && state.st_mode & S_IFMT == S_IFDIR && state.st_uid == geteuid() && state.st_dev == device && state.st_ino == inode && state.st_mode & 0o777 == 0o700
        #expect(same, "C5 Core owned root changed; preserve root")
        guard same else { return }
        defaults.removePersistentDomain(forName: suite)
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("C5 Core owned cleanup failed; preserve evidence") }
        #expect(!FileManager.default.fileExists(atPath: root.path), "C5 Core owned root post-cleanup absence")
    }
}
