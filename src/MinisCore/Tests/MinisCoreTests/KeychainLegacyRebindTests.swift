import Foundation
import Testing
@testable import MinisCore

private final class LegacyRebindMockBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var readResults: [String: KeychainReadResult]
    private let setSucceeds: Bool
    private var readKeys: [String] = []
    private var setKeys: [String] = []
    private var deleteKeys: [String] = []

    init(values: [String: String] = [:], readResults: [String: KeychainReadResult] = [:], setSucceeds: Bool = true) {
        self.values = values
        self.readResults = readResults
        self.setSucceeds = setSucceeds
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        setKeys.append(key)
        guard setSucceeds else { return false }
        values[key] = value
        readResults.removeValue(forKey: key)
        return true
    }

    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deleteKeys.append(key); values.removeValue(forKey: key); return true
    }
    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        readKeys.append(key)
        if let result = readResults[key] { return result }
        guard let value = values[key] else { return .missing }
        return .found(value)
    }
    func value(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    var readKeysSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return readKeys }
    var setKeysSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return setKeys }
    var deleteKeysSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return deleteKeys }
}

@Suite("packaged field Keychain legacy rebind")
struct KeychainLegacyRebindTests {
    private let key = "HERMES_CUSTOM_DEEPSEEK_API_KEY"

    @Test("current hit wins and does not probe legacy")
    func currentHitDoesNotProbeLegacy() {
        let current = LegacyRebindMockBacking(values: [key: "current-value"])
        let legacy = LegacyRebindMockBacking(readResults: [key: .denied])
        let store = KeychainStore(backing: current, legacyBackings: [legacy])
        #expect(store.readResult(forKey: key) == .found("current-value"))
        #expect(current.readKeysSnapshot == [key])
        #expect(legacy.readKeysSnapshot.isEmpty)
        #expect(current.setKeysSnapshot.isEmpty)
    }

    @Test("legacy hit is copied to current and legacy remains available")
    func legacyHitCopiesWithoutDeletingLegacy() {
        let current = LegacyRebindMockBacking()
        let legacy = LegacyRebindMockBacking(values: [key: "legacy-value"])
        let store = KeychainStore(backing: current, legacyBackings: [legacy])
        #expect(store.readResult(forKey: key) == .found("legacy-value"))
        #expect(current.value(forKey: key) == "legacy-value")
        #expect(legacy.value(forKey: key) == "legacy-value")
        #expect(current.setKeysSnapshot == [key])
        #expect(legacy.setKeysSnapshot.isEmpty)
        #expect(legacy.deleteKeysSnapshot.isEmpty)
    }

    @Test("missing current and legacy remains missing without a write")
    func missingDoesNotWrite() {
        let current = LegacyRebindMockBacking(); let legacy = LegacyRebindMockBacking()
        let store = KeychainStore(backing: current, legacyBackings: [legacy])
        #expect(store.readResult(forKey: key) == .missing)
        #expect(current.setKeysSnapshot.isEmpty)
        #expect(legacy.setKeysSnapshot.isEmpty)
    }

    @Test("legacy denied or failed remains typed and fail closed")
    func legacyFailuresRemainTyped() {
        for expected in [KeychainReadResult.denied, .failed] {
            let current = LegacyRebindMockBacking()
            let legacy = LegacyRebindMockBacking(readResults: [key: expected])
            let store = KeychainStore(backing: current, legacyBackings: [legacy])
            #expect(store.readResult(forKey: key) == expected)
            #expect(current.setKeysSnapshot.isEmpty)
        }
    }

    @Test("failed rebind write is typed and does not delete legacy")
    func failedCopyFailsClosed() {
        let current = LegacyRebindMockBacking(setSucceeds: false)
        let legacy = LegacyRebindMockBacking(values: [key: "legacy-value"])
        let store = KeychainStore(backing: current, legacyBackings: [legacy])
        #expect(store.readResult(forKey: key) == .failed)
        #expect(current.setKeysSnapshot == [key])
        #expect(legacy.value(forKey: key) == "legacy-value")
        #expect(legacy.deleteKeysSnapshot.isEmpty)
    }

    @Test("set and delete target only the current service")
    func mutationsNeverTouchLegacy() {
        let current = LegacyRebindMockBacking()
        let legacy = LegacyRebindMockBacking(values: [key: "legacy-value"])
        let store = KeychainStore(backing: current, legacyBackings: [legacy])
        #expect(store.set("replacement-value", forKey: key))
        #expect(store.delete(key))
        #expect(current.setKeysSnapshot == [key])
        #expect(current.deleteKeysSnapshot == [key])
        #expect(legacy.setKeysSnapshot.isEmpty)
        #expect(legacy.deleteKeysSnapshot.isEmpty)
    }

    @Test("service aliases are fixed, deduplicated, and absent in production")
    func serviceWhitelistAndProductionNoAlias() {
        let production = KeychainStore(secItemService: KeychainStore.defaultService)
        #expect(production.configuredLegacyServiceNames.isEmpty)
        let field = KeychainStore(secItemService: "com.miniscanvas.packaged-field.fixture", legacyServices: [
            "com.unknown.legacy", KeychainStore.defaultService,
            KeychainStore.defaultService, "com.miniscanvas.packaged-field.fixture"
        ])
        #expect(field.configuredLegacyServiceNames == [KeychainStore.defaultService])
    }
}
