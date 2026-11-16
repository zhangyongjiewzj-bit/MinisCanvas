import Foundation
import Testing
@testable import MinisCore

/// Status-aware in-memory backing. It never calls Security.framework; the
/// denied mode stands in for an old item that would otherwise request UI.
private final class PromptGuardKeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    enum ReadMode: Sendable {
        case missing
        case denied
        case failed
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private let mode: ReadMode
    private(set) var readCount = 0
    private(set) var setCount = 0
    private(set) var deleteCount = 0

    init(mode: ReadMode) {
        self.mode = mode
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        setCount += 1
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        switch mode {
        case .missing: return .missing
        case .denied: return .denied
        case .failed: return .failed
        }
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        deleteCount += 1
        return true
    }
}

private func p0ReadFailureTempDir(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-P0-read-failure-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeUnreadableSecretMetadata(to directory: URL, name: String = "HERMES_CUSTOM_DEEPSEEK_API_KEY") throws {
    let entry = EnvVarEntry(name: name, value: "", isSecret: true, valueInKeychain: true)
    let data = try JSONEncoder().encode([entry])
    try data.write(to: directory.appendingPathComponent(EnvVarStore.fileName), options: .atomic)
}

struct P0KeychainReadFailureFocusedTests {
    @Test("denied old read is typed and does not expose a credential")
    func deniedReadIsFailClosedAndSecretFree() throws {
        let directory = try p0ReadFailureTempDir("denied")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUnreadableSecretMetadata(to: directory)
        let backing = PromptGuardKeychainBacking(mode: .denied)
        let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))

        let result = store.readEnvVarResult(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        guard case .failure(let error) = result else {
            Issue.record("expected typed denied read failure")
            return
        }
        #expect(error == .keychainReadDenied)
        #expect(backing.readCount == 1)
        #expect(!String(describing: error).contains("HERMES_CUSTOM_DEEPSEEK_API_KEY"))
        #expect(store.getEnvVar(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY") == nil)
        #expect(store.lastPersistenceError == .keychainReadDenied)
    }

    @Test("explicit new key replaces an unreadable old item without reading it")
    func explicitReplacementDoesNotProbeOldKeychainItem() throws {
        let directory = try p0ReadFailureTempDir("replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUnreadableSecretMetadata(to: directory)
        let backing = PromptGuardKeychainBacking(mode: .denied)
        let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))
        let replacement = "fixture-replacement-credential"

        #expect(store.setEnvVar(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY", value: replacement, isSecret: true))
        #expect(backing.readCount == 0)
        #expect(backing.setCount == 1)
        #expect(backing.get("HERMES_CUSTOM_DEEPSEEK_API_KEY") == replacement)
        #expect(store.getEnvVar(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY") == replacement)
        let metadata = try String(
            contentsOf: directory.appendingPathComponent(EnvVarStore.fileName),
            encoding: .utf8
        )
        #expect(!metadata.contains(replacement))
    }

    @Test("deleting an old item does not read it first")
    func deleteDoesNotProbeOldKeychainItem() throws {
        let directory = try p0ReadFailureTempDir("delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUnreadableSecretMetadata(to: directory)
        let backing = PromptGuardKeychainBacking(mode: .denied)
        let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))

        #expect(store.deleteEnvVar(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY"))
        #expect(backing.readCount == 0)
        #expect(backing.deleteCount == 1)
        #expect(store.entry(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY") == nil)
    }
}
