import Foundation
import Testing
@testable import MinisCore

/// Focused P0 fixtures.  The backing is deliberately status-aware and never
/// calls Security.framework or reads a real user credential.
private final class P0KeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    enum ReadMode: Sendable {
        case missing
        case denied
        case failed
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var mode: ReadMode?
    private var failWrites = false
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    private(set) var setKeys: [String] = []

    func seed(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        mode = nil
    }

    func setReadMode(_ mode: ReadMode?) {
        lock.lock(); defer { lock.unlock() }
        self.mode = mode
    }

    func setWriteFailure(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        failWrites = enabled
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        guard !failWrites else { return false }
        values[key] = value
        mode = nil
        setKeys.append(key)
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if let mode {
            switch mode {
            case .missing: return .missing
            case .denied: return .denied
            case .failed: return .failed
            }
        }
        guard let value = values[key] else { return .missing }
        return .found(value)
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        values.removeValue(forKey: key)
        return true
    }
}

private func p0TempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-P0-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeP0ProviderMetadata(to directory: URL, name: String = "HERMES_CUSTOM_DEEPSEEK_API_KEY") throws {
    let entry = EnvVarEntry(
        name: name,
        value: "",
        isSecret: true,
        valueInKeychain: true,
        baseURL: "https://api.example.invalid/v1",
        modelNames: ["deepseek-v4-flash"]
    )
    let data = try JSONEncoder().encode([entry])
    try data.write(to: directory.appendingPathComponent(EnvVarStore.fileName), options: .atomic)
}

struct P0ProviderKeychainOverwriteTests {
    @Test("explicit replacement creates a missing old Keychain item without reading it")
    func replacementDoesNotRequireOldRead() throws {
        let directory = try p0TempDir("replace-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeP0ProviderMetadata(to: directory)
        let backing = P0KeychainBacking()
        backing.setReadMode(.missing)
        let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))

        #expect(store.saveProvider(
            name: "HERMES_CUSTOM_DEEPSEEK_API_KEY",
            apiKey: "fixture-new-secret-123456",
            baseURL: "https://api.example.invalid/v1",
            modelNames: ["deepseek-v4-flash"],
            protocolType: .openaiCompatible
        ))
        #expect(backing.readCount == 0)
        #expect(backing.setKeys == ["HERMES_CUSTOM_DEEPSEEK_API_KEY"])
        #expect(store.getEnvVar(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY") == "fixture-new-secret-123456")
        let json = try String(contentsOf: directory.appendingPathComponent(EnvVarStore.fileName), encoding: .utf8)
        #expect(!json.contains("fixture-new-secret-123456"))
    }

    @Test("Keychain write failure leaves committed provider metadata unchanged")
    func failedReplacementDoesNotDriftMetadata() throws {
        let directory = try p0TempDir("replace-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = P0KeychainBacking()
        let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))
        #expect(store.saveProvider(
            name: "ATOMIC_PROVIDER",
            apiKey: "fixture-old-secret-123456",
            baseURL: "https://old.example.invalid/v1",
            modelNames: ["old-model"],
            protocolType: .openaiCompatible
        ))
        let metadataURL = directory.appendingPathComponent(EnvVarStore.fileName)
        let before = try Data(contentsOf: metadataURL)
        let beforeEntry = store.entry(name: "ATOMIC_PROVIDER")
        backing.setWriteFailure(true)

        #expect(!store.saveProvider(
            name: "ATOMIC_PROVIDER",
            apiKey: "fixture-new-secret-123456",
            baseURL: "https://new.example.invalid/v1",
            modelNames: ["new-model"],
            protocolType: .anthropic
        ))
        #expect(store.lastPersistenceError == .keychainWriteFailed)
        #expect(try Data(contentsOf: metadataURL) == before)
        #expect(store.entry(name: "ATOMIC_PROVIDER") == beforeEntry)
        #expect(backing.get("ATOMIC_PROVIDER") == "fixture-old-secret-123456")
        #expect(!String(decoding: before, as: UTF8.self).contains("fixture-new-secret-123456"))
    }

    @Test("blank edit saves metadata without Keychain access, then real read classifies failures")
    func blankEditIsTypedAndFailClosed() async throws {
        for mode in [P0KeychainBacking.ReadMode.missing, .denied, .failed] {
            let directory = try p0TempDir("blank-\(String(describing: mode))")
            defer { try? FileManager.default.removeItem(at: directory) }
            try writeP0ProviderMetadata(to: directory)
            let backing = P0KeychainBacking()
            backing.setReadMode(mode)
            let store = EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing))

            #expect(store.saveProvider(
                name: "HERMES_CUSTOM_DEEPSEEK_API_KEY",
                credential: .keepExisting,
                baseURL: "https://metadata.example.invalid/v2",
                modelNames: ["edited-model"],
                protocolType: .anthropic
            ))
            #expect(store.lastPersistenceError == nil)
            #expect(backing.readCount == 0)
            #expect(backing.writeCount == 0)
            #expect(backing.deleteCount == 0)

            let reopened = EnvVarStore(
                directory: directory,
                keychain: KeychainStore(backing: backing)
            )
            let persisted = try #require(reopened.entry(name: "HERMES_CUSTOM_DEEPSEEK_API_KEY"))
            #expect(persisted.baseURL == "https://metadata.example.invalid/v2")
            #expect(persisted.modelNames == ["edited-model"])
            #expect(persisted.protocolType == .anthropic)
            #expect(persisted.valueInKeychain == true)
            #expect(persisted.value == "")
            #expect(backing.readCount == 0)
            #expect(backing.writeCount == 0)
            #expect(backing.deleteCount == 0)

            let read = await reopened.readEnvVarResultAsync(
                name: "HERMES_CUSTOM_DEEPSEEK_API_KEY"
            )
            switch mode {
            case .missing: #expect(read == .failure(.keychainReadMissing))
            case .denied: #expect(read == .failure(.keychainReadDenied))
            case .failed: #expect(read == .failure(.keychainReadFailed))
            }
            #expect(backing.readCount == 1)
            #expect(backing.writeCount == 0)
            #expect(backing.deleteCount == 0)
        }
    }
}
