import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class FollowupKeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectWrites = false
    private var rejectReads = false
    private var readCount = 0
    private var writeCount = 0
    private var deleteCount = 0

    func setWriteFailure(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        rejectWrites = enabled
    }

    func setReadFailure(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        rejectReads = enabled
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        guard !rejectWrites else { return false }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return values[key]
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        guard !rejectReads else { return .denied }
        guard let value = values[key] else { return .missing }
        return .found(value)
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        values.removeValue(forKey: key)
        return true
    }

    func resetOperationCounts() {
        lock.lock(); defer { lock.unlock() }
        readCount = 0
        writeCount = 0
        deleteCount = 0
    }

    var operationCounts: (reads: Int, writes: Int, deletes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (readCount, writeCount, deleteCount)
    }
}

private func followupTemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCanvas-L03-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("L03 credential persistence follow-up")
struct P3CredentialPersistenceFollowupTests {
    private let fieldArguments = [
        "/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
        RuntimeIsolationProfile.fieldActivationArgument
    ]

    @Test("synthetic direct Keychain get contributes exactly one read")
    func directBackingGetIsCounted() {
        let backing = FollowupKeychainBacking()
        #expect(backing.set("synthetic-value", forKey: "SYNTHETIC_GET_KEY"))
        backing.resetOperationCounts()
        #expect(backing.get("SYNTHETIC_GET_KEY") == "synthetic-value")
        let counts = backing.operationCounts
        #expect(counts.reads == 1)
        #expect(counts.writes == 0)
        #expect(counts.deletes == 0)
    }

    @Test("packaged-field namespace is stable while isolated tests stay UUID scoped")
    func packagedNamespaceIsStableAcrossProfileRecreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvas-L03-stable-\(UUID().uuidString)", isDirectory: true)
        let environment = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: root.path
        ]
        let first = try RuntimeIsolationProfile.makePackagedField(
            label: "followup-field",
            processEnvironment: environment,
            processArguments: fieldArguments
        )
        let second = try RuntimeIsolationProfile.makePackagedField(
            label: "followup-field",
            processEnvironment: environment,
            processArguments: fieldArguments
        )
        defer { try? first.cleanupDisposableRoots() }

        #expect(first.keychainService == second.keychainService)
        #expect(first.userDefaultsSuiteName == second.userDefaultsSuiteName)

        let isolatedOne = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "followup-test",
            processEnvironment: [:],
            processArguments: ["/tmp/followup.xctest"]
        )
        let isolatedTwo = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "followup-test",
            processEnvironment: [:],
            processArguments: ["/tmp/followup.xctest"]
        )
        defer {
            try? isolatedOne.cleanupDisposableRoots()
            try? isolatedTwo.cleanupDisposableRoots()
        }
        #expect(isolatedOne.keychainService != isolatedTwo.keychainService)
    }

    @Test("typed persistence failures are mapped without exposing credentials")
    @MainActor
    func settingsCenterMapsKeychainAndMetadataFailures() throws {
        let directory = try followupTemporaryDirectory("failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = FollowupKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        let envStore = EnvVarStore(directory: directory, keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: envStore,
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )

        let oldCredential = "followup-old-secret"
        let newCredential = "followup-new-secret"
        #expect(center.saveProvider(
            name: "FOLLOWUP_API_KEY",
            apiKey: oldCredential,
            baseURL: "https://example.invalid/v1",
            modelNames: ["followup-model"],
            protocolType: .openaiCompatible
        ))
        backing.setWriteFailure(true)
        #expect(!center.saveProvider(
            name: "FOLLOWUP_API_KEY",
            apiKey: newCredential,
            baseURL: "https://example.invalid/v2",
            modelNames: ["changed-model"],
            protocolType: .openaiCompatible
        ))
        #expect(center.providerSaveFailure == .keychainWriteFailed)
        #expect(center.providerCredential(named: "FOLLOWUP_API_KEY") == oldCredential)
        #expect(center.providerSaveFailure?.message.contains(oldCredential) == false)
        #expect(center.providerSaveFailure?.message.contains(newCredential) == false)

        backing.setWriteFailure(false)
        let metadataURL = directory.appendingPathComponent(EnvVarStore.fileName)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        #expect(!center.saveProvider(
            name: "FOLLOWUP_API_KEY",
            apiKey: "followup-metadata-secret",
            baseURL: "https://example.invalid/v3",
            modelNames: ["metadata-model"],
            protocolType: .openaiCompatible
        ))
        #expect(center.providerSaveFailure == .metadataWriteFailed)
        #expect(center.providerCredential(named: "FOLLOWUP_API_KEY") == oldCredential)
    }

    @Test("provider row and credential lookup share the injected store binding")
    @MainActor
    func providerRowAndSupplementaryCredentialUseSameBinding() throws {
        let directory = try followupTemporaryDirectory("binding")
        defer { try? FileManager.default.removeItem(at: directory) }
        let envStore = EnvVarStore(
            directory: directory,
            keychain: KeychainStore(backing: FollowupKeychainBacking())
        )
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: envStore,
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )
        let credential = "followup-binding-secret"
        #expect(center.saveProvider(
            name: "BINDING_API_KEY",
            apiKey: credential,
            baseURL: "https://example.invalid/v1",
            modelNames: ["binding-model"],
            protocolType: .openaiCompatible
        ))
        let row = try #require(center.providerRecords.first)
        #expect(row.name == "BINDING_API_KEY")
        #expect(center.providerCredential(named: row.name) == credential)

        let previousSource = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = previousSource }
        EnvCredentials.supplementarySource = { name in envStore.getEnvVar(name: name) }
        #expect(EnvCredentials.value(for: row.name) == credential)
        #expect(center.providerSaveFailure == nil)
    }

    @Test("explicit replacement bypasses an unreadable old Keychain item")
    @MainActor
    func explicitNewKeyIsNotBlockedByLegacyReadDenial() async throws {
        let directory = try followupTemporaryDirectory("replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = FollowupKeychainBacking()
        let initialStore = EnvVarStore(
            directory: directory,
            keychain: KeychainStore(backing: backing)
        )
        let initialCenter = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: initialStore,
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )
        #expect(initialCenter.saveProvider(
            name: "HERMES_CUSTOM_DEEPSEEK_API_KEY",
            apiKey: "old-key-for-fixture",
            baseURL: "https://api.deepseek.com/v1",
            modelNames: ["deepseek-v4-flash"],
            protocolType: .openaiCompatible
        ))

        // Reload metadata so the provider value is represented as a
        // Keychain-backed empty projection, then make only old reads fail.
        backing.setReadFailure(true)
        let reloadedCenter = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(
                directory: directory,
                keychain: KeychainStore(backing: backing)
            ),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )

        #expect(reloadedCenter.saveProvider(
            name: "HERMES_CUSTOM_DEEPSEEK_API_KEY",
            apiKey: "new-key-for-fixture",
            baseURL: "https://api.deepseek.com/v1",
            modelNames: ["deepseek-v4-flash"],
            protocolType: .openaiCompatible
        ))
        #expect(backing.get("HERMES_CUSTOM_DEEPSEEK_API_KEY") == "new-key-for-fixture")
        #expect(reloadedCenter.providerSaveFailure == nil)

        // A blank secure field is the explicit retain-old path. Metadata saves
        // without touching Keychain; an explicit later read still exposes the
        // typed denial rather than silently replacing or clearing the value.
        let blankFieldCenter = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(
                directory: directory,
                keychain: KeychainStore(backing: backing)
            ),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )
        backing.resetOperationCounts()
        #expect(blankFieldCenter.saveProvider(
            name: "HERMES_CUSTOM_DEEPSEEK_API_KEY",
            credential: .keepExisting,
            baseURL: "https://metadata.deepseek.example/v2",
            modelNames: ["deepseek-metadata-edited"],
            protocolType: .anthropic
        ))
        #expect(blankFieldCenter.providerSaveFailure == nil)
        var counts = backing.operationCounts
        #expect(counts.reads == 0)
        #expect(counts.writes == 0)
        #expect(counts.deletes == 0)
        #expect(backing.get("HERMES_CUSTOM_DEEPSEEK_API_KEY") == "new-key-for-fixture")
        #expect(backing.operationCounts.reads == 1)
        backing.resetOperationCounts()

        let reopenedCenter = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(
                directory: directory,
                keychain: KeychainStore(backing: backing)
            ),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
        )
        let persisted = try #require(reopenedCenter.providerRecords.first {
            $0.name == "HERMES_CUSTOM_DEEPSEEK_API_KEY"
        })
        #expect(persisted.baseURL == "https://metadata.deepseek.example/v2")
        #expect(persisted.modelNames == ["deepseek-metadata-edited"])
        #expect(persisted.protocolType == .anthropic)
        #expect(persisted.valueInKeychain == true)
        #expect(persisted.value == "")
        counts = backing.operationCounts
        #expect(counts.reads == 0)
        #expect(counts.writes == 0)
        #expect(counts.deletes == 0)

        let read = await reopenedCenter.providerCredentialReadAsync(
            named: "HERMES_CUSTOM_DEEPSEEK_API_KEY"
        )
        #expect(read == .failure(.denied))
        counts = backing.operationCounts
        #expect(counts.reads == 1)
        #expect(counts.writes == 0)
        #expect(counts.deletes == 0)
    }

    @Test("save outcome is closed over non-sensitive sheet messages")
    func saveOutcomeContractDoesNotDismissOnFailure() {
        let outcome = ProviderEditSaveOutcome.failed(.metadataWriteFailed)
        #expect(outcome != .saved)
        if case .failed(let category) = outcome {
            #expect(category.message == "保存失败：供应商元数据写入失败，当前内容未改变。")
            #expect(!category.message.contains("secret"))
        } else {
            Issue.record("expected a failed save outcome")
        }
    }
}
