import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class V425RebindKeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    enum ReadMode {
        case stored
        case missing
        case denied
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readMode: ReadMode = .stored
    private var readCount = 0

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func delete(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        switch readMode {
        case .stored:
            return values[key].map(KeychainReadResult.found) ?? .missing
        case .missing:
            return .missing
        case .denied:
            return .denied
        }
    }

    func setReadMode(_ mode: ReadMode) {
        lock.lock()
        defer { lock.unlock() }
        readMode = mode
    }

    func removeValue(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    func readCountSnapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }
}

@Suite("V425 credential rebind end-to-end contract")
@MainActor
struct V425RebindEndToEndContractTests {
    @Test("missing old item accepts explicit replacement, atomically publishes metadata, and scopes readiness")
    func missingOldItemReplacementClosesAcrossModules() throws {
        let fixture = try makeFixture(label: "missing")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let oldKey = "v425-old-missing"
        let newKey = "v425-new-missing"
        let center = makeCenter(directory: fixture.directory, backing: fixture.backing, readinessStore: fixture.readinessStore)
        #expect(center.saveProvider(
            name: fixture.providerName,
            apiKey: oldKey,
            baseURL: "https://old.example/v1",
            modelNames: [fixture.modelID],
            protocolType: .openaiCompatible
        ))
        seedReadiness(in: fixture.readinessStore, providerID: fixture.providerName, modelID: fixture.modelID)
        seedReadiness(in: fixture.readinessStore, providerID: "V425_OTHER_PROVIDER", modelID: "other-model")

        fixture.backing.removeValue(forKey: fixture.providerName)
        fixture.backing.setReadMode(.missing)
        let reloaded = makeCenter(
            directory: fixture.directory,
            backing: fixture.backing,
            readinessStore: fixture.readinessStore
        )
        let readsBeforeReplacement = fixture.backing.readCountSnapshot()

        #expect(reloaded.saveProvider(
            name: fixture.providerName,
            apiKey: newKey,
            baseURL: "https://new.example/v2",
            modelNames: [fixture.modelID],
            protocolType: .anthropic
        ))
        #expect(fixture.backing.readCountSnapshot() == readsBeforeReplacement)
        try assertPublishedProvider(
            center: reloaded,
            backing: fixture.backing,
            directory: fixture.directory,
            providerName: fixture.providerName,
            key: newKey,
            baseURL: "https://new.example/v2",
            protocolType: .anthropic
        )
        assertReadinessScope(
            store: fixture.readinessStore,
            changedProviderID: fixture.providerName,
            changedModelID: fixture.modelID,
            preservedProviderID: "V425_OTHER_PROVIDER",
            preservedModelID: "other-model"
        )
    }

    @Test("denied old item accepts explicit replacement without reading the old key")
    func deniedOldItemReplacementClosesAcrossModules() throws {
        let fixture = try makeFixture(label: "denied")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let center = makeCenter(directory: fixture.directory, backing: fixture.backing, readinessStore: fixture.readinessStore)
        #expect(center.saveProvider(
            name: fixture.providerName,
            apiKey: "v425-old-denied",
            baseURL: "https://old.example/v1",
            modelNames: [fixture.modelID],
            protocolType: .openaiCompatible
        ))
        seedReadiness(in: fixture.readinessStore, providerID: fixture.providerName, modelID: fixture.modelID)
        seedReadiness(in: fixture.readinessStore, providerID: "V425_OTHER_PROVIDER", modelID: "other-model")

        fixture.backing.setReadMode(.denied)
        let reloaded = makeCenter(
            directory: fixture.directory,
            backing: fixture.backing,
            readinessStore: fixture.readinessStore
        )
        let readsBeforeReplacement = fixture.backing.readCountSnapshot()
        #expect(reloaded.saveProvider(
            name: fixture.providerName,
            apiKey: "v425-new-denied",
            baseURL: "https://new.example/v2",
            modelNames: [fixture.modelID],
            protocolType: .openaiCompatible
        ))
        #expect(fixture.backing.readCountSnapshot() == readsBeforeReplacement)
        #expect(fixture.backing.get(fixture.providerName) == "v425-new-denied")
        #expect(reloaded.providerSaveFailure == nil)
        assertReadinessScope(
            store: fixture.readinessStore,
            changedProviderID: fixture.providerName,
            changedModelID: fixture.modelID,
            preservedProviderID: "V425_OTHER_PROVIDER",
            preservedModelID: "other-model"
        )
    }

    private struct Fixture {
        let directory: URL
        let backing: V425RebindKeychainBacking
        let readinessStore: ProviderReadinessStore
        let providerName = "V425_REBIND_PROVIDER"
        let modelID = "v425-model"
    }

    private func makeFixture(label: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v425-rebind-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backing = V425RebindKeychainBacking()
        return Fixture(
            directory: directory,
            backing: backing,
            readinessStore: ProviderReadinessStore(directory: directory)
        )
    }

    private func makeCenter(
        directory: URL,
        backing: V425RebindKeychainBacking,
        readinessStore: ProviderReadinessStore
    ) -> SettingsCenter {
        let envStore = EnvVarStore(
            directory: directory,
            keychain: KeychainStore(backing: backing)
        )
        return SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: envStore,
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills")),
            providerReadinessStore: readinessStore
        )
    }

    private func seedReadiness(
        in store: ProviderReadinessStore,
        providerID: String,
        modelID: String
    ) {
        store.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: providerID,
                modelID: modelID,
                status: .passed,
                readinessState: .live,
                checkedAt: Date(timeIntervalSince1970: 1_787_300_000),
                evidenceID: "live-settings:" + String(repeating: "a", count: 64),
                isApplied: true
            )
        )
    }

    private func assertPublishedProvider(
        center: SettingsCenter,
        backing: V425RebindKeychainBacking,
        directory: URL,
        providerName: String,
        key: String,
        baseURL: String,
        protocolType: ProviderWireProtocol
    ) throws {
        let provider = try #require(center.providerRecords.first {
            $0.name == providerName
        })
        #expect(backing.get(providerName) == key)
        #expect(provider.baseURL == baseURL)
        #expect(provider.modelNames == ["v425-model"])
        #expect(provider.protocolType == protocolType)
        #expect(provider.value.isEmpty)
        #expect(provider.valueInKeychain)
        let metadata = try Data(contentsOf: directory.appendingPathComponent(EnvVarStore.fileName))
        let persisted = try JSONDecoder().decode([EnvVarEntry].self, from: metadata)
        let persistedProvider = try #require(persisted.first { $0.name == providerName })
        #expect(persistedProvider.value.isEmpty)
        #expect(String(decoding: metadata, as: UTF8.self).contains(key) == false)
    }

    private func assertReadinessScope(
        store: ProviderReadinessStore,
        changedProviderID: String,
        changedModelID: String,
        preservedProviderID: String,
        preservedModelID: String
    ) {
        let changed = store.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(changedProviderID) && $0.modelID == changedModelID
        }
        #expect(changed?.status == .discovered)
        #expect(changed?.readinessState == .unverified)
        #expect(changed?.isApplied == false)
        #expect(changed?.evidenceID == nil)
        #expect(changed?.applyReceiptID == nil)

        let preserved = store.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(preservedProviderID) && $0.modelID == preservedModelID
        }
        #expect(preserved?.status == .passed)
        #expect(preserved?.readinessState == .live)
        #expect(preserved?.isApplied == true)
        #expect(preserved?.evidenceID?.hasPrefix("live-settings:") == true)
    }
}
