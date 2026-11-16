import Foundation
import Testing
@testable import MinisCore

/// Only synthetic strings live in this backing; no Security.framework or real
/// environment source is consulted by this test.
final class CREDDTypedVaultSpy: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    enum ReadMode: Sendable { case denied, failed }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readMode: ReadMode?
    private var reads = 0
    private var writes = 0
    private var deletes = 0

    func setReadMode(_ mode: ReadMode?) {
        lock.lock(); defer { lock.unlock() }
        readMode = mode
    }

    func resetCounts() {
        lock.lock(); defer { lock.unlock() }
        reads = 0; writes = 0; deletes = 0
    }

    func snapshot(for key: String) -> (value: String?, reads: Int, writes: Int, deletes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (values[key], reads, writes, deletes)
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes += 1
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        switch readMode {
        case .denied: return .denied
        case .failed: return .failed
        case nil: return values[key].map(KeychainReadResult.found) ?? .missing
        }
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deletes += 1
        values.removeValue(forKey: key)
        return true
    }
}

@Suite("D-CREDD explicit replacement intent preserves old Key")
struct CREDDReplaceIntent2018Tests {
    @Test("empty replacement is rejected without deleting the old Key under typed read failure",
          arguments: [CREDDTypedVaultSpy.ReadMode.denied, .failed])
    func emptyReplacementNeverDeletesOldKey(mode: CREDDTypedVaultSpy.ReadMode) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("credd-2018-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let name = "CREDD_SYNTHETIC_API_KEY"
        let oldKey = "FAKE_CREDD_OLD_KEY_2018"
        let newKey = "FAKE_CREDD_NEW_KEY_2018"
        let backing = CREDDTypedVaultSpy()
        let first = EnvVarStore(directory: root, keychain: KeychainStore(backing: backing))
        #expect(first.saveProvider(name: name, credential: .replace(oldKey),
                                   baseURL: "https://old.example.invalid/v1",
                                   modelNames: ["old-model"], protocolType: .openaiCompatible))
        let metadataURL = root.appendingPathComponent(EnvVarStore.fileName)
        let oldMetadata = try Data(contentsOf: metadataURL)

        // Reopening leaves the credential opaque in provider metadata. A typed
        // denial/failure of the old read is visible before the edit, but must
        // never turn an explicit empty replacement into a deletion.
        let store = EnvVarStore(directory: root, keychain: KeychainStore(backing: backing))
        backing.setReadMode(mode)
        let read = await store.readEnvVarResultAsync(name: name)
        switch mode {
        case .denied: #expect(read == .failure(.keychainReadDenied))
        case .failed: #expect(read == .failure(.keychainReadFailed))
        }
        backing.resetCounts()
        #expect(!store.saveProvider(name: name, credential: .replace(" \n\t "),
                                    baseURL: "https://new.example.invalid/v2",
                                    modelNames: ["new-model"], protocolType: .anthropic))
        #expect(store.lastPersistenceError == .missingCredential)
        var state = backing.snapshot(for: name)
        #expect(state.value == oldKey)
        #expect(state.reads == 0 && state.writes == 0 && state.deletes == 0)
        #expect(try Data(contentsOf: metadataURL) == oldMetadata)

        // An empty edit of non-secret fields is a distinct keepExisting intent.
        #expect(store.saveProvider(name: name, credential: .keepExisting,
                                   baseURL: "https://metadata.example.invalid/v2",
                                   modelNames: ["metadata-model"], protocolType: .anthropic))
        state = backing.snapshot(for: name)
        #expect(state.value == oldKey)
        #expect(state.reads == 0 && state.writes == 0 && state.deletes == 0)

        // Only a nonempty, explicit replacement may update the opaque item;
        // denied/failed old reads do not block a valid new value.
        #expect(store.saveProvider(name: name, credential: .replace(newKey),
                                   baseURL: "https://new.example.invalid/v2",
                                   modelNames: ["new-model"], protocolType: .anthropic))
        state = backing.snapshot(for: name)
        #expect(state.value == newKey)
        #expect(state.reads == 0 && state.writes == 1 && state.deletes == 0)
        let persisted = try Data(contentsOf: metadataURL)
        #expect(!String(decoding: persisted, as: UTF8.self).contains(oldKey))
        #expect(!String(decoding: persisted, as: UTF8.self).contains(newKey))
    }
}
