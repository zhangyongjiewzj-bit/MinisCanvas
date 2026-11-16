import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class BudgetCountingBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; values[key] = value; return true
    }
    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }; reads += 1; return values[key]
    }
    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }; reads += 1
        return values[key].map(KeychainReadResult.found) ?? .missing
    }
    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key); return true
    }
}

@Suite("Owned MM credential fetch admission; synthetic backing only", .serialized)
struct MMOwnedCredentialReadBudgetTests {
    private let nonce = "0123456789abcdef0123456789abcdef"
    private let value = "owned-synthetic-budget-fixture"

    @Test func getAndTypedAsyncAcrossFacadesShareOneExactLimit() async throws {
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(policy.arm())
        #expect(policy.install(nonce: nonce, limit: 4, deadline: Date().addingTimeInterval(60)))
        let backing = BudgetCountingBacking()
        let a = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
        let b = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
        #expect(a.set(value, forKey: "owned"))
        #expect(a.get("owned") == value)
        #expect(b.readResult(forKey: "owned") == .found(value))
        #expect(await b.readResultAsync(forKey: "owned") == .found(value))
        #expect(a.get("owned") == value)
        #expect(a.get("owned") == nil)
        #expect(await b.readResultAsync(forKey: "owned") == .failed)
        #expect(backing.readCount == 4)
        #expect(policy.snapshot.reserved == 4 && policy.snapshot.refused == 2)
    }

    @Test func concurrentConsumersCannotOverrunTheReservedLimit() {
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(policy.arm())
        #expect(policy.install(nonce: nonce, limit: 7, deadline: Date().addingTimeInterval(60)))
        let backing = BudgetCountingBacking()
        let store = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
        #expect(store.set(value, forKey: "owned"))
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index.isMultiple(of: 2) { _ = store.get("owned") }
            else { _ = store.readResult(forKey: "owned") }
        }
        #expect(backing.readCount == 7)
        #expect(policy.snapshot.reserved == 7 && policy.snapshot.refused == 57)
    }

    @Test func envStoreAsyncAndDirectFacadeReadShareTheBackingGate() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("BudgetEnv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let suite = "MMBudgetEnv-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            // Qualified MM SDK parent owns the final retained namespace.
            if ProcessInfo.processInfo.environment["MINISCANVAS_MM01_PARENT_RETAIN_ROOTS"] == nil {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
        }
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(policy.arm())
        #expect(policy.install(nonce: nonce, limit: 2, deadline: Date().addingTimeInterval(60)))
        let backing = BudgetCountingBacking()
        let store = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
        let env = EnvVarStore(directory: root, keychain: store,
            privacyStore: EnvVarPrivacyStore(defaults: defaults))
        #expect(env.setEnvVar(name: "BUDGET_SYNTHETIC", value: value, isSecret: true))
        #expect(await env.getEnvVarAsync(name: "BUDGET_SYNTHETIC") == value)
        #expect(store.get("BUDGET_SYNTHETIC") == value)
        #expect(await env.getEnvVarAsync(name: "BUDGET_SYNTHETIC") == nil)
        #expect(backing.readCount == 2 && policy.snapshot.reserved == 2)
    }

    @Test func writesNewFacadeAndReplacementPlanCannotReplenishQuota() {
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        #expect(policy.arm())
        let end = Date().addingTimeInterval(60)
        #expect(policy.install(nonce: nonce, limit: 1, deadline: end))
        let backing = BudgetCountingBacking()
        let a = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
        #expect(a.set(value, forKey: "owned"))
        #expect(a.get("owned") == value)
        #expect(a.delete("owned"))
        #expect(a.set(value, forKey: "owned"))
        #expect(!policy.arm())
        #expect(!policy.install(nonce: nonce, limit: 1, deadline: end))
        #expect(!policy.install(nonce: "ffffffffffffffffffffffffffffffff", limit: 100, deadline: end))
        let b = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
        #expect(b.get("owned") == nil)
        #expect(backing.readCount == 1 && policy.snapshot.reserved == 1)
    }

    @Test func missingInvalidOrExpiredPlanNeverReachesBacking() {
        for kind in 0..<4 {
            let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
            let backing = BudgetCountingBacking()
            let store = KeychainStore(backing: backing, ownedMMReadPolicy: policy)
            #expect(store.set(value, forKey: "owned"))
            if kind != 0 {
                #expect(policy.arm())
                #expect(!policy.install(nonce: kind == 1 ? "bad" : nonce,
                    limit: kind == 2 ? 0 : 1,
                    deadline: kind == 3 ? .distantPast : Date().addingTimeInterval(60)))
            }
            #expect(store.get("owned") == nil)
            #expect(store.readResult(forKey: "owned") == .failed)
            #expect(backing.readCount == 0 && policy.snapshot.reserved == 0)
        }
    }
}
