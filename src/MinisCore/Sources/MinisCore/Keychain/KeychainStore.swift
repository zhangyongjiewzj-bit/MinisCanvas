import Foundation
import LocalAuthentication
import Security

/// Abstraction over macOS Keychain item access so the real `SecItem`
/// implementation can be swapped for an in-memory mock in tests.
///
/// All methods are synchronous and must be safe to call from any thread.
public protocol KeychainBacking: Sendable {
    /// Store (create or overwrite) a secret value under `key`. Returns true on success.
    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool
    /// Retrieve the stored secret for `key`, or nil when absent.
    func get(_ key: String) -> String?
    /// Delete the stored secret for `key`. Returns true when the item was
    /// removed or was already absent.
    @discardableResult
    func delete(_ key: String) -> Bool
}

/// A non-sensitive classification for a Keychain read.  Callers must not
/// collapse access denial or an operational failure into "missing": a user
/// can recover a missing item by entering a new credential, while a denied or
/// failed read must remain fail-closed.
public enum KeychainReadResult: Equatable, Sendable {
    case found(String)
    case missing
    case denied
    case failed
}

/// Optional status-reporting seam for backings.  It is deliberately separate
/// from `KeychainBacking` so existing injected test backings remain source
/// compatible; `KeychainStore` falls back to the legacy nil == missing
/// contract when a backing does not implement this protocol.
public protocol KeychainReadReporting: Sendable {
    func readResult(forKey key: String) -> KeychainReadResult
}

/// Non-secret identity outcome used to fence writes to one physical item.
/// This remains internal so the public backing contract stays unchanged.
enum KeychainPersistentReferenceResult: Equatable, Sendable {
    case found(Data)
    case missing
    case denied
    case failed
    case duplicate
}

/// Real Keychain backing built on Security.framework's `SecItem` APIs.
///
/// Each secret is stored as a generic password under `service` (a stable
/// namespace) + `account = key` (the env-var name). Access-control is the
/// default `kSecAttrAccessibleWhenUnlocked` / `AfterFirstUnlockThisDeviceOnly`
/// policy so values never appear in plaintext JSON or backups.
public final class SecItemKeychainBacking: KeychainBacking, KeychainReadReporting {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    /// Builds the modern fail-closed authentication context that replaces the
    /// deprecated `kSecUseAuthenticationUI`/`kSecUseAuthenticationUIFail` pair.
    /// The SDK deprecation annotation for `kSecUseAuthenticationUIFail`
    /// (Security.framework `secitem.h`, macOS 10.11–11.0) directs callers to
    /// use `kSecUseAuthenticationContext` with `LAContext.interactionNotAllowed`
    /// set; that property's exact semantic is to return `errSecInteractionNotAllowed`
    /// instead of showing any authentication UI, reproducing the old
    /// "fail rather than interact" contract. A fresh context is created per
    /// operation inside the synchronous caller, so no previously-authenticated
    /// state is ever reused or shared, the context never crosses a concurrency
    /// domain, and this type can never prompt the user.
    private static func failClosedAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    public func set(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)
        var addQuery = baseQuery
        addQuery[kSecAttrAccount as String] = key
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecUseAuthenticationContext as String] = Self.failClosedAuthenticationContext()

        addQuery[kSecReturnPersistentRef as String] = true
        var addedReferenceResult: AnyObject?
        let status = SecItemAdd(addQuery as CFDictionary, &addedReferenceResult)
        if status == errSecSuccess {
            guard let addedReference = addedReferenceResult as? Data,
                  !addedReference.isEmpty else {
                return false
            }
            let referenceBeforeValue = persistentReferenceResult(forKey: key)
            let actualValue = readResult(forKey: key)
            let referenceAfterValue = persistentReferenceResult(forKey: key)
            return Self.persistentReferenceReadbackMatches(
                expectedValue: value,
                expectedReference: addedReference,
                actualValue: actualValue,
                firstReference: referenceBeforeValue,
                secondReference: referenceAfterValue
            )
        }
        // Item already exists → update its value in place.
        if status == errSecDuplicateItem {
            // Resolve one physical item before updating. A service/account
            // query may match more than one item and must fail closed.
            guard case .found(let reference) = persistentReferenceResult(forKey: key) else {
                return false
            }
            let match: [String: Any] = [
                kSecValuePersistentRef as String: reference,
                kSecUseAuthenticationContext as String: Self.failClosedAuthenticationContext(),
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            guard SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecSuccess else {
                return false
            }
            let referenceBeforeValue = persistentReferenceResult(forKey: key)
            let actualValue = readResult(forKey: key)
            let referenceAfterValue = persistentReferenceResult(forKey: key)
            return Self.persistentReferenceReadbackMatches(
                expectedValue: value,
                expectedReference: reference,
                actualValue: actualValue,
                firstReference: referenceBeforeValue,
                secondReference: referenceAfterValue
            )
        }
        return false
    }

    /// Resolve the unique physical item behind a service/account identity.
    /// `matchLimitAll` is intentional: returning an arbitrary match would
    /// make an update report success for the wrong credential.
    func persistentReferenceResult(forKey key: String) -> KeychainPersistentReferenceResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: Self.failClosedAuthenticationContext(),
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return .missing }
    if status == errSecAuthFailed || status == errSecInteractionNotAllowed
        || status == errSecUserCanceled || status == errSecMissingEntitlement
            || status == errSecNotAvailable {
            return .denied
        }
        if status == errSecDuplicateItem { return .duplicate }
        guard status == errSecSuccess else { return .failed }
        if let references = result as? [Data] {
            guard references.count == 1, let reference = references.first, !reference.isEmpty else {
                return .duplicate
            }
            return .found(reference)
        }
        if let reference = result as? Data, !reference.isEmpty {
            return .found(reference)
        }
        return .failed
    }

    static func persistentReferenceReadbackMatches(
        expectedValue: String,
        expectedReference: Data,
        actualValue: KeychainReadResult,
        firstReference: KeychainPersistentReferenceResult,
        secondReference: KeychainPersistentReferenceResult
    ) -> Bool {
        guard !expectedReference.isEmpty,
              case .found(let value) = actualValue, value == expectedValue,
              case .found(let firstReferenceValue) = firstReference,
              firstReferenceValue == expectedReference,
              case .found(let secondReferenceValue) = secondReference,
              secondReferenceValue == expectedReference else {
            return false
        }
        return true
    }

    static func persistentReferenceReadbackResult(
        expectedReference: Data,
        actualValue: KeychainReadResult,
        firstReference: KeychainPersistentReferenceResult,
        secondReference: KeychainPersistentReferenceResult
    ) -> KeychainReadResult {
        guard !expectedReference.isEmpty,
              case .found(let firstReferenceValue) = firstReference,
              firstReferenceValue == expectedReference,
              case .found(let secondReferenceValue) = secondReference,
              secondReferenceValue == expectedReference else {
            return .failed
        }
        return actualValue
    }

    static func deleteReadbackConfirmsRemoval(
        _ firstReference: KeychainPersistentReferenceResult,
        _ secondReference: KeychainPersistentReferenceResult
    ) -> Bool {
        firstReference == .missing && secondReference == .missing
    }

    public func readResult(forKey key: String) -> KeychainReadResult {
        let reference: Data
        switch persistentReferenceResult(forKey: key) {
        case .missing:
            return .missing
        case .denied:
            return .denied
        case .failed, .duplicate:
            return .failed
        case .found(let value):
            reference = value
        }

        let query: [String: Any] = [
            kSecValuePersistentRef as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never ask Security.framework to present an authorization UI
            // while resolving an old credential. A denied/failed read must
            // remain a typed, actionable result for the settings UI.
            kSecUseAuthenticationContext as String: Self.failClosedAuthenticationContext(),
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled || status == errSecMissingEntitlement
            || status == errSecNotAvailable {
            return .denied
        }
        let actualValue: KeychainReadResult
        if status == errSecItemNotFound {
            actualValue = .missing
        } else if status == errSecSuccess, let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) {
            actualValue = .found(value)
        } else {
            actualValue = .failed
        }
        return Self.persistentReferenceReadbackResult(
            expectedReference: reference,
            actualValue: actualValue,
            firstReference: persistentReferenceResult(forKey: key),
            secondReference: persistentReferenceResult(forKey: key)
        )
    }

    public func get(_ key: String) -> String? {
        guard case .found(let value) = readResult(forKey: key) else { return nil }
        return value
    }

    public func delete(_ key: String) -> Bool {
        let reference: Data
        switch persistentReferenceResult(forKey: key) {
        case .missing:
            return true
        case .found(let value):
            reference = value
        case .denied, .failed, .duplicate:
            return false
        }

        let query: [String: Any] = [
            kSecValuePersistentRef as String: reference,
            kSecUseAuthenticationContext as String: Self.failClosedAuthenticationContext(),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return false
        }
        return Self.deleteReadbackConfirmsRemoval(
            persistentReferenceResult(forKey: key),
            persistentReferenceResult(forKey: key)
        )
    }
}

/// A process-local capability identifying a trusted credential consistency domain.
/// Share the same instance when injected facades address the same backing. It
/// contains no credential data. Production facades share by fixed service name.
public final class KeychainConsistencyDomain: @unchecked Sendable {
    private struct State { let identity = UUID().uuidString; var generation: UInt64 = 0; var writers: Int = 0 }
    private let identity = UUID().uuidString
    private let lock = NSLock()
    private var states: [String: State] = [:]
    private static let registryLock = NSLock()
    private static nonisolated(unsafe) var services: [String: KeychainConsistencyDomain] = [:]
    private static nonisolated(unsafe) var metadataFiles: [String: KeychainConsistencyDomain] = [:]
    private final class InjectedEntry {
        weak var object: AnyObject?
        let domain: KeychainConsistencyDomain
        init(object: AnyObject, domain: KeychainConsistencyDomain) { self.object = object; self.domain = domain }
    }
    private static nonisolated(unsafe) var injectedObjects: [ObjectIdentifier: InjectedEntry] = [:]
    static let inMemory = KeychainConsistencyDomain()

    public init() {}

    static func service(_ name: String) -> KeychainConsistencyDomain {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = services[name] { return existing }
        let domain = KeychainConsistencyDomain()
        services[name] = domain
        return domain
    }

    static func metadataFile(_ path: String) -> KeychainConsistencyDomain {
        registryLock.lock(); defer { registryLock.unlock() }
        if let domain = metadataFiles[path] { return domain }
        let domain = KeychainConsistencyDomain()
        metadataFiles[path] = domain
        return domain
    }

    /// Known production/in-memory namespaces cannot be split by an injected
    /// override. Existing class-backed injection shares its actual object
    /// identity; value-backed facades may explicitly share a trusted capability.
    static func injected(_ backing: any KeychainBacking, supplied: KeychainConsistencyDomain? = nil) -> KeychainConsistencyDomain {
        if let secItem = backing as? SecItemKeychainBacking { return service(secItem.service) }
        if backing is InMemoryKeychainBacking { return inMemory }
        if let supplied { return supplied }
        guard Mirror(reflecting: backing).displayStyle == .class else { return KeychainConsistencyDomain() }
        let object = backing as AnyObject
        let key = ObjectIdentifier(object)
        registryLock.lock(); defer { registryLock.unlock() }
        if let entry = injectedObjects[key], entry.object === object { return entry.domain }
        let domain = KeychainConsistencyDomain()
        injectedObjects[key] = InjectedEntry(object: object, domain: domain)
        return domain
    }

    public struct Token: Equatable, Hashable, Sendable {
        public let opaqueValue: String
        fileprivate let generation: UInt64
    }

    func snapshot(_ key: String) -> Token? {
        lock.lock(); defer { lock.unlock() }
        let state = states[key] ?? State()
        states[key] = state
        guard state.writers == 0 else { return nil }
        return Token(opaqueValue: "\(identity):\(state.identity):\(state.generation)", generation: state.generation)
    }

    /// Bookkeeping only: never hold this mutex during backing IO, callbacks,
    /// instance-lock acquisition or an await. Both edges invalidate old reads,
    /// including a backing which changes data then returns failure.
    func begin(_ key: String, expected: Token? = nil) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        var state = states[key] ?? State()
        if let expected {
            guard state.writers == 0,
                  expected.opaqueValue == "\(identity):\(state.identity):\(state.generation)" else { return nil }
        }
        state.generation &+= 1
        state.writers += 1
        states[key] = state
        return state.generation
    }

    func end(_ key: String, began: UInt64) -> Token? {
        lock.lock(); defer { lock.unlock() }
        var state = states[key] ?? State()
        let uncontested = state.writers == 1 && state.generation == began
        state.generation &+= 1
        state.writers -= 1
        states[key] = state
        guard uncontested else { return nil }
        return Token(opaqueValue: "\(identity):\(state.identity):\(state.generation)", generation: state.generation)
    }
}

/// Thread-safe facade over a `KeychainBacking` for storing/retrieving secret
/// values by a stable string key (typically an env-var name).
///
/// `EnvVarStore` uses this to keep `*_API_KEY`-class values out of the
/// plaintext `envvars.json` file and inside the macOS Keychain instead.
/// Process-window storage-fetch admission, not a count of String copies or HTTP.
/// No key/service/value is accepted or retained by this policy.
final class OwnedMMCredentialReadPolicy: @unchecked Sendable {
    struct Snapshot: Sendable {
        let installed: Bool
        let limit: Int
        let reserved: Int
        let refused: Int
    }
    private enum State { case uninstalled, arming, active, blocked }
    private let lock = NSLock()
    private let requiresPlan: Bool
    private var state = State.uninstalled
    private var nonce: String?
    private var deadline = Date.distantPast
    private var limit = 0
    private var reserved = 0
    private var refused = 0

    init(requiresPlan: Bool) { self.requiresPlan = requiresPlan }

    func arm() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard requiresPlan, case .uninstalled = state else { return false }
        state = .arming
        return true
    }

    func install(nonce: String, limit: Int, deadline: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .arming = state, limit > 0, deadline > Date(), nonce.count == 32,
              nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            if case .arming = state { state = .blocked }
            return false
        }
        self.nonce = nonce
        self.deadline = deadline
        self.limit = limit
        state = .active
        return true
    }

    func rejectPlan() {
        lock.lock(); defer { lock.unlock() }
        // Never reset/replenish an already installed window.
        if case .active = state { return }
        state = .blocked
    }

    func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !requiresPlan { return true }
        guard case .active = state, Date() < deadline, reserved < limit else {
            refused += 1
            return false
        }
        reserved += 1 // Atomic reservation before entering any backing.
        return true
    }

    // The immutable real-process requirement, not caller-supplied fixture argv.
    var requiresOwnedWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return requiresPlan
    }

    // Secret-free metadata of the already installed window, never a new read.
    var activeWindow: (nonce: String, deadline: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard case .active = state, let nonce, Date() < deadline else { return nil }
        return (nonce, deadline)
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        let installed: Bool
        if case .active = state { installed = true } else { installed = false }
        return Snapshot(installed: installed, limit: limit, reserved: reserved, refused: refused)
    }
}

public final class KeychainStore: @unchecked Sendable {
    // A dedicated MM process denies storage reads even before App.init can
    // validate its plan. Ordinary processes keep the original backing logic.
    private static let ownedMMReadPolicy = OwnedMMCredentialReadPolicy(
        requiresPlan: ProcessInfo.processInfo.arguments.contains("--mm01-deepseek-flash-visual"))

    public static func armOwnedMMCredentialReadBudget() -> Bool { ownedMMReadPolicy.arm() }
    public static func installOwnedMMCredentialReadBudget(nonce: String, limit: Int, deadline: Date) -> Bool {
        ownedMMReadPolicy.install(nonce: nonce, limit: limit, deadline: deadline)
    }
    public static func rejectOwnedMMCredentialReadBudgetPlan() { ownedMMReadPolicy.rejectPlan() }
    public static var ownedMMCredentialReadBudgetRequired: Bool {
        ownedMMReadPolicy.requiresOwnedWindow
    }
    public static var ownedMMCredentialReadWindow: (nonce: String, deadline: Date)? {
        ownedMMReadPolicy.activeWindow
    }
    public static var ownedMMCredentialReadCounts: (installed: Bool, limit: Int, reserved: Int, refused: Int) {
        let s = ownedMMReadPolicy.snapshot
        return (s.installed, s.limit, s.reserved, s.refused)
    }
    /// Describes the backing selected by a store without touching it. This is
    /// intentionally observable so composition tests can prove production
    /// wiring without invoking any `SecItem` operation.
    public enum BackingKind: Equatable, Sendable {
        case injected
        case secItem(service: String)
        case inMemory
    }

    /// Default Keychain service namespace for MinisCore env-var secrets.
    public static let defaultService = "com.miniscanvas.miniscore.envvars"

    private let backing: KeychainBacking
    private let isolatedReadPolicyForTests: OwnedMMCredentialReadPolicy?
    /// Optional, explicitly configured legacy read-only backings. These are
    /// consulted only after the current backing reports `.missing`; writes and
    /// deletes always use `backing`.
    private let legacyBackings: [KeychainBacking]
    public let backingKind: BackingKind
    private let consistencyDomain: KeychainConsistencyDomain

    /// 是否运行在测试进程（swiftpm-testing-helper / XCTest）。
    /// 用进程名 + 命令行特征检测（不依赖环境变量，环境变量检测不可靠）：
    /// 测试环境默认用内存 backing，避免触发真实钥匙串授权弹窗（用户铁律：严禁弹窗打扰）。
    public static var isTesting: Bool {
        let args = ProcessInfo.processInfo.arguments.joined(separator: " ")
        let env = ProcessInfo.processInfo.environment
        return args.contains(".xctest")
            || args.contains("swiftpm-testing-helper")
            || args.contains("-XCTest")
            || env["XCTestConfigurationFilePath"] != nil
            || env["SWIFT_TESTING_ENABLED"] != nil
    }

    /// Create a store backed by the real Keychain (`SecItem`), or inject a
    /// mock `KeychainBacking` for tests. 测试环境（未显式注入）默认用内存实现，
    /// 生产用真实 SecItem 钥匙串。
    public init(backing: KeychainBacking? = nil, consistencyDomain: KeychainConsistencyDomain? = nil) {
        isolatedReadPolicyForTests = nil
        if let backing {
            self.backing = backing
            self.backingKind = .injected
            self.consistencyDomain = .injected(backing, supplied: consistencyDomain)
        } else if KeychainStore.isTesting {
            self.backing = InMemoryKeychainBacking()
            self.backingKind = .inMemory
            self.consistencyDomain = .inMemory
        } else {
            self.backing = SecItemKeychainBacking(service: KeychainStore.defaultService)
            self.backingKind = .secItem(service: KeychainStore.defaultService)
            self.consistencyDomain = .service(KeychainStore.defaultService)
        }
        self.legacyBackings = []
    }

    /// Internal-only injection seam for deterministic tests. Production
    /// callers can configure legacy services only through the fixed service
    /// whitelist below; arbitrary backing aliases must never be public API.
    init(backing: KeychainBacking, legacyBackings: [KeychainBacking]) {
        isolatedReadPolicyForTests = nil
        self.backing = backing
        self.backingKind = .injected
        self.consistencyDomain = .injected(backing)
        self.legacyBackings = legacyBackings
    }

    /// Explicit production composition. Construction is side-effect free;
    /// `SecItem` is not touched until a caller invokes set/get/delete. Legacy
    /// services are intersected with the fixed whitelist and the current
    /// service is always excluded; callers cannot turn this into an arbitrary
    /// Keychain probe.
    public init(secItemService service: String, legacyServices: [String] = []) {
        isolatedReadPolicyForTests = nil
        self.backing = SecItemKeychainBacking(service: service)
        self.backingKind = .secItem(service: service)
        self.consistencyDomain = .service(service)
        self.legacyBackings = Self.allowedLegacyServices(
            legacyServices,
            excluding: service
        ).map { SecItemKeychainBacking(service: $0) }
    }

    /// Tests exercise real facade reads without installing/resetting the process policy.
    init(backing: KeychainBacking, ownedMMReadPolicy: OwnedMMCredentialReadPolicy) {
        self.backing = backing
        self.backingKind = .injected
        self.consistencyDomain = .injected(backing)
        self.legacyBackings = []
        self.isolatedReadPolicyForTests = ownedMMReadPolicy
    }

    private static func allowedLegacyServices(
        _ services: [String],
        excluding current: String
    ) -> [String] {
        var seen = Set<String>()
        return services.filter { service in
            service != current
                && service == defaultService
                && seen.insert(service).inserted
        }
    }

    @discardableResult
    public func set(_ value: String, forKey key: String) -> Bool {
        let began = consistencyDomain.begin(key)!
        defer { _ = consistencyDomain.end(key, began: began) }
        return backing.set(value, forKey: key)
    }

    /// An admission token, never a persistent credential revision. Nil means
    /// a supported write is in flight in this exact process domain.
    public func consistencyToken(forKey key: String) -> KeychainConsistencyDomain.Token? {
        consistencyDomain.snapshot(key)
    }

    public func get(_ key: String) -> String? {
        guard Self.ownedMMReadPolicy.admit(), isolatedReadPolicyForTests?.admit() != false else { return nil }
        return backing.get(key)
    }

    /// Read with a typed, secret-free outcome.  This is the only path used by
    /// metadata-only provider edits that need to explain why an old secret
    /// cannot be retained.  A replacement credential intentionally does not
    /// call this method.
    public func readResult(forKey key: String) -> KeychainReadResult {
        readResultTracked(forKey: key, expected: nil).result
    }

    private func readResultTracked(
        forKey key: String,
        expected: KeychainConsistencyDomain.Token?
    ) -> (result: KeychainReadResult, migration: KeychainConsistencyDomain.Token?) {
        guard let baseline = expected ?? consistencyToken(forKey: key) else { return (.failed, nil) }
        let canonicalAccount = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let lookupKey = KeychainCredentialAlias(rawValue: canonicalAccount) != nil ? canonicalAccount : key
        let currentResult = readResult(from: backing, forKey: lookupKey)
        guard consistencyToken(forKey: key) == baseline else { return (.failed, nil) }
        guard case .missing = currentResult else { return (currentResult, nil) }
        guard let alias = KeychainCredentialAlias(rawValue: canonicalAccount),
              KeychainScopeResolver.resolve(providerID: alias.providerID, account: canonicalAccount,
                  canonicalService: currentServiceName, legacyServices: configuredLegacyServiceNames) != nil else {
            return (.missing, nil)
        }
        for legacy in legacyBackings {
            let legacyDomain = KeychainConsistencyDomain.injected(legacy)
            guard let legacyStamp = legacyDomain.snapshot(lookupKey) else { return (.failed, nil) }
            let legacyResult = readResult(from: legacy, forKey: lookupKey)
            guard legacyDomain.snapshot(lookupKey) == legacyStamp else { return (.failed, nil) }
            switch legacyResult {
            case .missing: continue
            case .denied: return (.denied, nil)
            case .failed: return (.failed, nil)
            case .found(let value):
                guard !value.isEmpty,
                      let began = consistencyDomain.begin(key, expected: baseline) else { return (.failed, nil) }
                // The current namespace is invalidated before copy-only rebind,
                // including a partially failed backing write. A successful
                // uncontested copy supplies its new stamp to this read only.
                let copied = backing.set(value, forKey: lookupKey)
                let stamp = consistencyDomain.end(key, began: began)
                guard copied, let stamp else { return (.failed, nil) }
                return (.found(value), stamp)
            }
        }
        return (.missing, nil)
    }

    /// Resolve a credential without running Security.framework on the caller's
    /// executor.  In particular, callers on the main actor must await this
    /// boundary rather than invoke the synchronous read path: SecItemCopyMatching
    /// can block in Security.framework while decrypting an item.
    public struct ConsistentRead: Sendable {
        public let result: KeychainReadResult
        public let token: KeychainConsistencyDomain.Token?
    }

    public func readResultAsync(forKey key: String) async -> KeychainReadResult {
        await readResultWithConsistencyAsync(forKey: key).result
    }

    public func readResultWithConsistencyAsync(
        forKey key: String,
        expected: KeychainConsistencyDomain.Token? = nil
    ) async -> ConsistentRead {
        guard !Task.isCancelled, let captured = consistencyToken(forKey: key),
              expected == nil || expected == captured else { return ConsistentRead(result: .failed, token: nil) }
        let read = await Task.detached(priority: .userInitiated) { [self] in
            readResultTracked(forKey: key, expected: captured)
        }.value
        let stamp = read.migration ?? captured
        guard !Task.isCancelled, consistencyToken(forKey: key) == stamp else {
            return ConsistentRead(result: .failed, token: nil)
        }
        return ConsistentRead(result: read.result, token: stamp)
    }

    private var currentServiceName: String {
        (backing as? SecItemKeychainBacking)?.service
            ?? KeychainScopeResolver.legacyService
    }

    private func readResult(
        from backing: KeychainBacking,
        forKey key: String
    ) -> KeychainReadResult {
        guard Self.ownedMMReadPolicy.admit(), isolatedReadPolicyForTests?.admit() != false else { return .failed }
        if let reporting = backing as? any KeychainReadReporting {
            return reporting.readResult(forKey: key)
        }
        guard let value = backing.get(key) else { return .missing }
        return .found(value)
    }

    /// Test-only configuration evidence; no secret or Keychain value crosses
    /// this projection.
    var configuredLegacyServiceNames: [String] {
        legacyBackings.compactMap { ($0 as? SecItemKeychainBacking)?.service }
    }

    @discardableResult
    public func delete(_ key: String) -> Bool {
        let began = consistencyDomain.begin(key)!
        defer { _ = consistencyDomain.end(key, began: began) }
        return backing.delete(key)
    }
}

/// 内存 Keychain backing（测试隔离）：不触碰真实钥匙串，进程内字典存储。
/// 用静态共享存储模拟真实 Keychain 的跨实例语义（同一进程内多个 KeychainStore
/// 实例可见同一份数据），规避测试环境访问真实钥匙串触发系统授权弹窗。
public final class InMemoryKeychainBacking: KeychainBacking, @unchecked Sendable {
    // 静态共享：模拟真实 Keychain 跨实例共享（round-trip 测试需新建实例读回同一值）。
    // 被 NSLock 保护，标注 nonisolated(unsafe) 规避 Swift 6 可变全局变量诊断。
    private static let lock = NSLock()
    private static nonisolated(unsafe) var sharedStore: [String: String] = [:]

    private let lock = InMemoryKeychainBacking.lock

    public init() {}

    @discardableResult
    public func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        Self.sharedStore[key] = value
        return true
    }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return Self.sharedStore[key]
    }

    @discardableResult
    public func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        Self.sharedStore.removeValue(forKey: key)
        return true
    }
}
