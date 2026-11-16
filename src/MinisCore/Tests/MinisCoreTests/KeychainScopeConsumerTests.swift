import Foundation
import Testing
@testable import MinisCore

private final class ScopeConsumerBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var results: [String: KeychainReadResult]
    private var reads: [String] = []
    private var writes: [String] = []
    private var deletes: [String] = []

    init(
        values: [String: String] = [:],
        results: [String: KeychainReadResult] = [:]
    ) {
        self.values = values
        self.results = results
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes.append(key)
        values[key] = value
        results.removeValue(forKey: key)
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        deletes.append(key)
        values.removeValue(forKey: key)
        return true
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        reads.append(key)
        if let result = results[key] { return result }
        return values[key].map(KeychainReadResult.found) ?? .missing
    }

    var readKeys: [String] { lock.lock(); defer { lock.unlock() }; return reads }
    var writeKeys: [String] { lock.lock(); defer { lock.unlock() }; return writes }
    var deleteKeys: [String] { lock.lock(); defer { lock.unlock() }; return deletes }
    var storedValues: [String: String] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite("Keychain scope resolver consumer")
struct KeychainScopeConsumerTests {
    private let account = "HERMES_CUSTOM_DEEPSEEK_API_KEY"

    @Test("canonical hit wins and never consults the legacy namespace")
    func canonicalFirst() {
        let current = ScopeConsumerBacking(values: [account: "current"])
        let legacy = ScopeConsumerBacking(values: [account: "old"])
        let store = KeychainStore(backing: current, legacyBackings: [legacy])

        #expect(store.readResult(forKey: " hermes_custom_deepseek_api_key ") == .found("current"))
        #expect(current.readKeys == [account])
        #expect(legacy.readKeys.isEmpty)
        #expect(current.writeKeys.isEmpty)
    }

    @Test("known legacy DeepSeek alias copies to canonical and leaves old item")
    func legacyRebindWritesCanonicalOnly() {
        let current = ScopeConsumerBacking()
        let legacy = ScopeConsumerBacking(values: [account: "old"])
        let store = KeychainStore(backing: current, legacyBackings: [legacy])

        #expect(store.readResult(forKey: account) == .found("old"))
        #expect(current.storedValues[account] == "old")
        #expect(current.writeKeys == [account])
        #expect(legacy.storedValues[account] == "old")
        #expect(legacy.deleteKeys.isEmpty)
    }

    @Test("unknown account is isolated from legacy providers and keeps typed failure")
    func unknownAndDeniedFailClosed() {
        let current = ScopeConsumerBacking()
        let legacy = ScopeConsumerBacking(
            results: [
                "UNKNOWN_PROVIDER_API_KEY": .denied,
                "DEEPSEEK_API_KEY": .denied,
            ]
        )
        let store = KeychainStore(backing: current, legacyBackings: [legacy])

        #expect(store.readResult(forKey: "UNKNOWN_PROVIDER_API_KEY") == .missing)
        #expect(legacy.readKeys.isEmpty)
        #expect(store.readResult(forKey: "DEEPSEEK_API_KEY") == .denied)
        #expect(legacy.readKeys == ["DEEPSEEK_API_KEY"])
        #expect(current.writeKeys.isEmpty)
        #expect(legacy.deleteKeys.isEmpty)
    }
}
