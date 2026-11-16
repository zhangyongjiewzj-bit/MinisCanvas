import Foundation

/// U5：模型供应商 URL 支持的线路协议类型。
///
/// 参照 Codex / Hermes 的 provider 配置模型（base_url + api_key + 模型列表 +
/// wire API 类型）：同一个 baseURL 可能讲 OpenAI Chat Completions 协议、
/// Anthropic Messages 协议或其他私有协议，由用户在新增供应商时显式选择。
public enum ProviderWireProtocol: String, Codable, CaseIterable, Sendable {
    /// OpenAI 兼容协议（`/v1/chat/completions` 等），默认值。
    case openaiCompatible = "openai_compatible"
    /// OpenAI Responses API (`/v1/responses`), distinct from Chat Completions.
    case openaiResponses = "openai_responses"
    /// Anthropic Messages 协议。
    case anthropic = "anthropic"
    /// 其他/私有协议。
    case other = "other"

    /// 设置界面显示名。
    public var displayName: String {
        switch self {
        case .openaiCompatible: return "OpenAI 兼容"
        case .openaiResponses: return "OpenAI Responses"
        case .anthropic: return "Anthropic"
        case .other: return "其他"
        }
    }

    /// 向后兼容：未知未来协议保持可解码，但不得降格为 Chat Completions。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderWireProtocol(rawValue: raw) ?? .other
    }
}

/// One stored environment variable.
///
/// Values live in the JSON metadata file next to the entry **unless** the
/// entry is a secret (`isSecret`, e.g. `*_API_KEY`): in that case the real
/// value is stored in the macOS Keychain (`KeychainStore`) and `envvars.json`
/// only carries non-secret metadata, so API keys never sit in plaintext on
/// disk. `EnvVarPrivacyStore` + `EnvVarRedactor` still layer on top so
/// secrets never reach logs or model context.
///
/// U5：条目同时承载「模型供应商」元数据（baseURL / modelNames /
/// protocolType）。普通环境变量这三个字段保持缺省（nil / [] /
/// .openaiCompatible），既有 key 读取路径完全不变；旧版本写出的
/// envvars.json 缺少这些字段时按缺省值解码（见自定义 `init(from:)`）。
public struct EnvVarEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    /// Canonical (uppercased) variable name, e.g. `OPENAI_API_KEY`.
    public var name: String
    /// Presentation metadata only; never used for credential or history identity.
    public var displayName: String?

    public var providerDisplayName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return EnvVarStore.providerSuggestion(for: name)?.providerLabel
            ?? name.replacingOccurrences(of: "_API_KEY", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
    public var value: String
    /// Whether this value must be treated as a secret (masked in logs/output).
    public var isSecret: Bool
    /// Whether this entry's real `value` lives in the macOS Keychain rather
    /// than in `envvars.json` (Keychain 迁移：`*_API_KEY` 类 secret 值不落明文
    /// JSON；`envvars.json` 只存元数据，真实值从 Keychain 读取）。
    ///
    /// When true, the value persisted to JSON is a placeholder (empty string);
    /// the in-memory `value` always holds the real value (fetched from Keychain
    /// on load). Old `envvars.json` files written before this feature keep the
    /// plaintext in `value` with `valueInKeychain == false` and are auto-migrated
    /// on first load.
    public var valueInKeychain: Bool
    public var createdAt: Date

    // MARK: U5 模型供应商元数据（普通变量保持缺省）

    /// 供应商 Base URL（可选），如 `https://api.openai.com/v1`。
    public var baseURL: String?
    /// 该供应商提供的模型名列表（可增删多个；普通变量为空数组）。
    public var modelNames: [String]
    /// baseURL 所支持的线路协议类型（默认 OpenAI 兼容）。
    public var protocolType: ProviderWireProtocol
    /// 自定义模型的上下文窗口（tokens），键为 `modelNames` 中的模型名；
    /// nil/缺省 = 全部按目录或启发式取值。旧版 envvars.json 无此键。
    public var modelContextWindows: [String: Int]?

    /// 是否承载供应商配置（区分「模型供应商」与「普通环境变量」）。
    public var isProviderRecord: Bool {
        baseURL != nil || !modelNames.isEmpty
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        value: String,
        displayName: String? = nil,
        isSecret: Bool = false,
        valueInKeychain: Bool = false,
        createdAt: Date = Date(),
        baseURL: String? = nil,
        modelNames: [String] = [],
        protocolType: ProviderWireProtocol = .openaiCompatible,
        modelContextWindows: [String: Int]? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.value = value
        self.isSecret = isSecret
        self.valueInKeychain = valueInKeychain
        self.createdAt = createdAt
        self.baseURL = baseURL
        self.modelNames = modelNames
        self.protocolType = protocolType
        self.modelContextWindows = modelContextWindows
    }

    // MARK: Codable（U5 向后兼容：旧数据缺省字段用默认值解码）

    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, value, isSecret, createdAt
        case valueInKeychain
        case baseURL, modelNames, protocolType, modelContextWindows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        value = try container.decode(String.self, forKey: .value)
        isSecret = try container.decode(Bool.self, forKey: .isSecret)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // 旧版本 envvars.json 没有以下字段 → 缺省默认值。
        valueInKeychain = try container.decodeIfPresent(Bool.self, forKey: .valueInKeychain) ?? false
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        modelNames = try container.decodeIfPresent([String].self, forKey: .modelNames) ?? []
        protocolType = try container.decodeIfPresent(ProviderWireProtocol.self, forKey: .protocolType)
            ?? .openaiCompatible
        modelContextWindows = try container.decodeIfPresent([String: Int].self, forKey: .modelContextWindows)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        // Defense in depth: a secret is never serialized, even when Keychain
        // persistence failed or legacy metadata has an inconsistent flag.
        try container.encode(isSecret ? "" : value, forKey: .value)
        try container.encode(isSecret, forKey: .isSecret)
        try container.encode(valueInKeychain, forKey: .valueInKeychain)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encode(modelNames, forKey: .modelNames)
        try container.encode(protocolType, forKey: .protocolType)
        try container.encodeIfPresent(modelContextWindows, forKey: .modelContextWindows)
    }
}

/// AJ-39：把旧 key（U-5 之前配置、无 baseURL/modelNames 的普通环境变量）转成
/// 模型供应商时的自动建议。已知供应商 key 模式（如 DASHSCOPE_API_KEY）命中时
/// 给出默认 Base URL / 模型 / 协议，供 ProviderEditSheet 预填；普通 `*_API_KEY`
/// 也给出「自定义 OpenAI 兼容」的空建议，让用户无需从零填写供应商名。
public struct ProviderSuggestion: Equatable, Sendable {
    /// 建议的 Base URL（nil = 未填，用户需自行填写或使用供应商默认）。
    public var baseURL: String?
    /// 建议的模型名列表（可空）。
    public var modelNames: [String]
    /// 建议的线路协议类型。
    public var protocolType: ProviderWireProtocol
    /// 供应商识别名（仅用于 UI 提示，不做持久化）。
    public var providerLabel: String

    public init(
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        providerLabel: String
    ) {
        self.baseURL = baseURL
        self.modelNames = modelNames
        self.protocolType = protocolType
        self.providerLabel = providerLabel
    }
}

/// Typed credential intent for provider metadata edits.
///
/// `keepExisting` changes only non-secret provider metadata. `replace` requires
/// a non-empty new secret. `missing` is an explicit fail-closed absence.
public enum ProviderCredentialUpdate: Equatable, Sendable {
    case keepExisting
    case replace(String)
    case missing
}

/// Non-sensitive persistence failures exposed to the existing Bool-returning
/// settings boundary.  No case carries a path, provider label, or credential.
public enum EnvVarPersistenceError: Error, Equatable, Sendable {
    case invalidName
    case missingCredential
    /// The metadata says a secret is Keychain-backed, but no item exists.
    case keychainReadMissing
    /// The Keychain declined access. This is not equivalent to a missing item.
    case keychainReadDenied
    /// The Keychain returned an operational/decoding failure.
    case keychainReadFailed
    case keychainWriteFailed
    case keychainDeleteFailed
    case metadataWriteFailed
    case keychainRollbackFailed
}

/// Environment-variable management for MinisCore: CRUD + persistence.
///
/// Ported from OpenMinis `Shared/EnvVarStore.swift` with the iOS
/// Keychain/CloudKit machinery stripped out and re-implemented against the
/// macOS Keychain: secret values (`isSecret`, e.g. `*_API_KEY`) are stored in
/// the Keychain via `KeychainStore`; `envvars.json` only holds non-secret
/// metadata. Old `envvars.json` files that still hold plaintext keys are
/// auto-migrated to the Keychain on first load. Non-secret values remain
/// alongside the entry metadata in the JSON file (`envvars.json`) inside an
/// injectable directory (default: Application Support). `isSecret` marks a
/// value as sensitive so callers can route it through `EnvVarRedactor` before
/// it reaches logs or model context.
public struct EnvVarCredentialBinding: Equatable, Sendable {
    public let recordID: String
    public let name: String
    public let revision: String
}

public final class EnvVarStore: @unchecked Sendable {
    /// File name of the persistence JSON inside the store directory.
    public static let fileName = "envvars.json"

    /// Default store directory: `<Application Support>/MinisCore`.
    /// Application Support 不可用时回退系统临时目录（避免 `.first!` 强解包崩溃）。
    public static func defaultDirectory() -> URL {
        if let formal = FormalTestIsolationPaths.currentOrFail() {
            return formal.minisCoreDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MinisCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Valid env var name: starts with a letter, then letters/digits/underscores.
    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /^[A-Za-z][A-Za-z0-9_]*$/) != nil
    }

    /// Canonical form: trimmed + uppercased (matches OpenMinis behaviour).
    public static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private let credentialLifecycle = UUID().uuidString
    private let metadataConsistency: KeychainConsistencyDomain
    private let fileURL: URL
    /// Path identity only, for binding the existing atomic importer to the
    /// same profile. This accessor never reads the metadata file.
    public var metadataDirectory: URL { fileURL.deletingLastPathComponent() }
    private let lock = NSLock()
    private let keychain: KeychainStore
    /// Optional executor probe at the real metadata-only identity read.
    /// It receives no file path, record identity or credential value.
    private let credentialBindingMetadataReadObserver: (@Sendable () -> Void)?
    private let privacyStore: EnvVarPrivacyStore
    private var entries: [String: EnvVarEntry] = [:]  // keyed by canonical name
    private final class LogRedactionSink {
        weak var logger: LogManager?
        init(_ logger: LogManager) { self.logger = logger }
    }
    private var logRedactionSinks: [LogRedactionSink] = []
    /// Most recent non-sensitive failure, for diagnostics at the existing
    /// SettingsCenter/Provider runtime boundary.
    private let persistenceErrorLock = NSLock()
    private var persistenceError: EnvVarPersistenceError?

    public private(set) var lastPersistenceError: EnvVarPersistenceError? {
        get {
            persistenceErrorLock.lock(); defer { persistenceErrorLock.unlock() }
            return persistenceError
        }
        set {
            persistenceErrorLock.lock(); defer { persistenceErrorLock.unlock() }
            persistenceError = newValue
        }
    }
    /// Typed startup cleanup failure.  The formal metadata remains loadable;
    /// callers can surface this diagnostic without terminating the app.
    public private(set) var lastMetadataRecoveryFailure: CredentialMetadataRecovery.Failure?

    /// NSLock 的 lock/unlock 在 Swift 6 中不可直接从 async 上下文调用，
    /// 统一通过同步作用域辅助函数进入临界区。
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public init(
        directory: URL,
        keychain: KeychainStore = KeychainStore(),
        privacyStore: EnvVarPrivacyStore = .shared,
        metadataRecoveryFileSystem: any CredentialMetadataRecoveryFileSystem = LiveCredentialMetadataRecoveryFileSystem(),
        credentialBindingMetadataReadObserver: (@Sendable () -> Void)? = nil
    ) {
        let metadataConsistency = KeychainConsistencyDomain.metadataFile(
            directory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(Self.fileName).path)
        let recoveryMutation = metadataConsistency.begin("metadata")!
        let recovery = Self.recoverCredentialMetadataAtStartup(
            in: directory,
            fileSystem: metadataRecoveryFileSystem
        )
        _ = metadataConsistency.end("metadata", began: recoveryMutation)
        self.metadataConsistency = metadataConsistency
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.keychain = keychain
        self.credentialBindingMetadataReadObserver = credentialBindingMetadataReadObserver
        self.privacyStore = privacyStore
        let (loaded, migrated) = Self.load(from: fileURL, keychain: keychain)
        self.entries = loaded
        if case .failure(let failure) = recovery {
            self.lastMetadataRecoveryFailure = failure
        } else {
            self.lastMetadataRecoveryFailure = nil
        }
        // 旧 envvars.json 中的明文 secret 已迁移到 Keychain → 立即重写 JSON，
        // 把明文从元数据文件里剥离。
        if migrated { saveLocked() }
    }

    // MARK: - CRUD

    /// Attach the composition's log sink without reading any deferred value.
    /// Values are registered only when already in memory or resolved by an
    /// existing credential operation. The logger never calls back into us.
    public func attachLogRedaction(to logger: LogManager) {
        withLock {
            logRedactionSinks.removeAll { $0.logger == nil }
            if !logRedactionSinks.contains(where: { $0.logger === logger }) {
                logRedactionSinks.append(LogRedactionSink(logger))
            }
            logger.registerKnownSecrets(entries.values.filter(\.isSecret).map(\.value))
        }
    }

    private func registerLogSecretLocked(_ value: String) {
        guard !value.isEmpty else { return }
        logRedactionSinks.removeAll { $0.logger == nil }
        for sink in logRedactionSinks {
            sink.logger?.registerKnownSecrets([value])
        }
    }

    /// Set (create or update) an env var. Names are canonicalized to
    /// uppercase. When creating, `isSecret` defaults to
    /// `EnvVarPrivacyStore.isSecret(name:)` so the default sensitive list
    /// applies automatically; pass `isSecret` explicitly to override.
    @discardableResult
    public func setEnvVar(name: String, value: String, isSecret: Bool? = nil) -> Bool {
        let canonical = Self.canonicalName(name)
        guard !canonical.isEmpty, Self.isValidName(canonical) else {
            lastPersistenceError = .invalidName
            return false
        }

        lock.lock(); defer { lock.unlock() }
        let previousEntry = entries[canonical]
        var entry: EnvVarEntry
        if var existing = entries[canonical] {
            existing.value = value
            if let isSecret { existing.isSecret = isSecret }
            entry = existing
        } else {
            entry = EnvVarEntry(
                name: canonical,
                value: value,
                isSecret: isSecret ?? privacyStore.isSecret(name: canonical)
            )
        }
        if entry.isSecret { registerLogSecretLocked(value) }
        // Explicit setEnvVar input is a replacement intent. For Keychain-backed
        // changes, stage the secret-free metadata first, then upsert/delete the
        // Keychain item, and publish metadata only after that operation succeeds.
        // This keeps a failed secret mutation from changing either the formal
        // metadata bytes or the in-memory committed state, without reading the
        // old item (which may be absent or denied and must never trigger an
        // authorization prompt).
        let storesInKeychain = entry.isSecret && !entry.value.isEmpty
        entry.valueInKeychain = storesInKeychain
        if storesInKeychain {
            var candidateEntries = entries
            candidateEntries[canonical] = entry
            guard let stagedURL = stageMetadataLocked(candidateEntries) else {
                return false
            }
            guard keychain.set(entry.value, forKey: canonical) else {
                try? FileManager.default.removeItem(at: stagedURL)
                lastPersistenceError = .keychainWriteFailed
                return false
            }
            guard commitStagedMetadataLocked(stagedURL) else {
                // A metadata commit failure happens after the Keychain write;
                // restore a known old value when available, or remove a newly
                // created item. If the old value was deferred, fail closed.
                let rolledBack: Bool
                if let previousEntry,
                   previousEntry.valueInKeychain,
                   !previousEntry.value.isEmpty {
                    rolledBack = keychain.set(previousEntry.value, forKey: canonical)
                } else if previousEntry == nil {
                    rolledBack = keychain.delete(canonical)
                } else {
                    rolledBack = false
                }
                lastPersistenceError = rolledBack
                    ? .metadataWriteFailed
                    : .keychainRollbackFailed
                return false
            }
            entries[canonical] = entry
        } else if previousEntry?.valueInKeychain == true {
            var candidateEntries = entries
            candidateEntries[canonical] = entry
            guard let stagedURL = stageMetadataLocked(candidateEntries) else {
                return false
            }
            guard keychain.delete(canonical) else {
                try? FileManager.default.removeItem(at: stagedURL)
                lastPersistenceError = .keychainDeleteFailed
                return false
            }
            guard commitStagedMetadataLocked(stagedURL) else {
                // The old Keychain value is restored only when it is available
                // in memory; deferred credentials cannot be guessed safely.
                let rolledBack: Bool
                if let previousEntry, !previousEntry.value.isEmpty {
                    rolledBack = keychain.set(previousEntry.value, forKey: canonical)
                } else {
                    rolledBack = false
                }
                lastPersistenceError = rolledBack
                    ? .metadataWriteFailed
                    : .keychainRollbackFailed
                return false
            }
            entries[canonical] = entry
        } else {
            entries[canonical] = entry
            guard saveLocked() else {
                entries[canonical] = previousEntry
                return false
            }
        }
        lastPersistenceError = nil
        return true
    }

    /// Save a user's explicitly labelled privacy choice from the environment editor.
    /// Generic writes and imports must keep using their existing entry points.
    /// Classification uses this store's injected privacy owner and changes only
    /// after the original value persistence succeeds.
    @discardableResult
    public func setEnvVarWithExplicitPrivacyClassification(
        name: String, value: String, isSecret: Bool
    ) -> Bool {
        guard setEnvVar(name: name, value: value, isSecret: isSecret) else { return false }
        if isSecret {
            privacyStore.markSecret(name: name)
        } else {
            privacyStore.unmarkSecret(name: name)
        }
        return true
    }

    /// Return the value for `name` (case-insensitive), or nil when unset.
    public func getEnvVar(name: String) -> String? {
        lock.lock()
        let canonical = Self.canonicalName(name)
        // A reloaded Keychain-backed entry is only a reference until its
        // credential is resolved. Never synchronously enter Security.framework
        // from the main thread; use getEnvVarAsync at an async boundary.
        if Thread.isMainThread,
           let entry = entries[canonical],
           entry.valueInKeychain,
           entry.value.isEmpty {
            // The real SecItem backing may block in Security.framework. Keep
            // every synchronous main-thread caller fail-closed. Tests and
            // other deterministic consumers use the async boundary below to
            // preserve missing/denied/failed classifications without making
            // the safety rule depend on the selected backing.
            lock.unlock()
            return nil
        }
        switch readEnvVarResultLocked(name: name) {
        case .success(let value):
            lock.unlock()
            return value
        case .failure:
            lock.unlock()
            return nil
        }
    }

    /// Read a credential with a secret-free failure classification. Metadata
    /// edits deliberately do not call it; consumers that need the credential
    /// resolve it separately through this boundary or its async counterpart.
    public func readEnvVarResult(name: String) -> Result<String?, EnvVarPersistenceError> {
        lock.lock()
        let canonical = Self.canonicalName(name)
        // Keep this synchronous compatibility API fail-closed on the main
        // thread. A caller that needs the actual credential must await the
        // async API below, which performs the Keychain read off-main.
        if Thread.isMainThread,
           let entry = entries[canonical],
           entry.valueInKeychain,
           entry.value.isEmpty {
            // Do not synchronously enter Security.framework from the main
            // actor. Callers that need a typed Keychain outcome use the async
            // boundary, irrespective of the selected backing.
            lastPersistenceError = .keychainReadFailed
            lock.unlock()
            return .failure(.keychainReadFailed)
        }
        let result = readEnvVarResultLocked(name: name)
        lock.unlock()
        return result
    }

    /// Resolve a Keychain-backed credential without blocking the caller's
    /// executor. Metadata-only entries are inspected under the lock, then the
    /// potentially blocking Security.framework operation runs in
    /// `KeychainStore.readResultAsync`. A replacement racing this read is not
    /// overwritten by a stale result.
    public func credentialBinding(name: String) -> EnvVarCredentialBinding? {
        withLock { credentialBindingLocked(name: name) }
    }

    /// The same identity/token/metadata admission as the synchronous channel,
    /// with its physical JSON read on a worker rather than the caller's actor.
    public func credentialBindingAsync(name: String) async -> EnvVarCredentialBinding? {
        let worker = Task.detached(priority: .userInitiated) { [self] in
            guard !Task.isCancelled else { return nil as EnvVarCredentialBinding? }
            let binding = credentialBinding(name: name)
            return Task.isCancelled ? nil : binding
        }
        return await withTaskCancellationHandler {
            let binding = await worker.value
            return Task.isCancelled ? nil : binding
        } onCancel: {
            worker.cancel()
        }
    }

    private func credentialBindingLocked(name: String) -> EnvVarCredentialBinding? {
        let canonical = Self.canonicalName(name)
        guard let entry = entries[canonical],
              // A settings restore imports provider metadata cold. An old
              // target Keychain item with the same name must not become an
              // authority merely because its orphan token still exists.
              (!entry.isProviderRecord || (entry.isSecret && entry.valueInKeychain)),
              let metadataToken = metadataConsistency.snapshot("metadata"),
              let token = keychain.consistencyToken(forKey: canonical) else { return nil }
        // Read only identity fields from the atomically published metadata.
        // Another store instance may have deleted/recreated this record while
        // this instance still retains its old in-memory entry.
        struct Identity: Decodable { let id: String; let name: String }
        credentialBindingMetadataReadObserver?()
        guard let data = try? Data(contentsOf: fileURL),
              let identities = try? JSONDecoder().decode([Identity].self, from: data),
              identities.contains(where: { $0.id == entry.id && $0.name == entry.name }),
              keychain.consistencyToken(forKey: canonical) == token,
              metadataConsistency.snapshot("metadata") == metadataToken else { return nil }
        return EnvVarCredentialBinding(recordID: entry.id, name: canonical,
            revision: credentialLifecycle + ":" + token.opaqueValue + ":" + metadataToken.opaqueValue)
    }

    public func readEnvVarResultAsync(name: String) async -> Result<String?, EnvVarPersistenceError> {
        let canonical = Self.canonicalName(name)
        let snapshot: (binding: EnvVarCredentialBinding?, key: KeychainConsistencyDomain.Token?,
                       metadata: KeychainConsistencyDomain.Token?, immediate: Result<String?, EnvVarPersistenceError>?) = withLock {
            guard let entry = entries[canonical] else { return (nil, nil, nil, .success(nil)) }
            guard let binding = credentialBindingLocked(name: canonical),
                  let key = keychain.consistencyToken(forKey: canonical),
                  let metadata = metadataConsistency.snapshot("metadata") else {
                return (nil, nil, nil, .failure(.keychainReadFailed))
            }
            if entry.isSecret { registerLogSecretLocked(entry.value) }
            return (binding, key, metadata, entry.valueInKeychain ? nil : .success(entry.value))
        }
        if let immediate = snapshot.immediate { return immediate }
        guard !Task.isCancelled, let binding = snapshot.binding else { return .failure(.keychainReadFailed) }
        // The facade rejects any external writer after this exact admission.
        // Its own successful legacy copy may advance the returned stamp;
        // preserve that existing read/rebind behavior without accepting a
        // replacement made by another request or facade.
        let read = await keychain.readResultWithConsistencyAsync(forKey: canonical, expected: snapshot.key)
        return withLock {
            guard !Task.isCancelled, let stamp = read.token,
                  keychain.consistencyToken(forKey: canonical) == stamp,
                  metadataConsistency.snapshot("metadata") == snapshot.metadata,
                  let currentBinding = credentialBindingLocked(name: canonical),
                  currentBinding.recordID == binding.recordID, currentBinding.name == binding.name,
                  var entry = entries[canonical] else { return .failure(.keychainReadFailed) }
            switch read.result {
            case .found(let stored) where !stored.isEmpty:
                entry.value = stored
                entries[canonical] = entry
                if entry.isSecret { registerLogSecretLocked(stored) }
                return .success(stored)
            default:
                let mapped = Self.mapKeychainReadResult(read.result)
                if case .failure(let error) = mapped { lastPersistenceError = error }
                return mapped
            }
        }
    }

    /// Async counterpart of `getEnvVar`; safe for main-actor readiness and
    /// other UI consumers that need the actual credential value.
    public func getEnvVarAsync(name: String) async -> String? {
        switch await readEnvVarResultAsync(name: name) {
        case .success(let value): return value
        case .failure: return nil
        }
    }

    private static func mapKeychainReadResult(
        _ result: KeychainReadResult
    ) -> Result<String?, EnvVarPersistenceError> {
        switch result {
        case .found(let stored) where !stored.isEmpty:
            return .success(stored)
        case .missing:
            return .failure(.keychainReadMissing)
        case .denied:
            return .failure(.keychainReadDenied)
        case .failed, .found:
            return .failure(.keychainReadFailed)
        }
    }

    private func readEnvVarResultLocked(name: String) -> Result<String?, EnvVarPersistenceError> {
        let canonical = Self.canonicalName(name)
        guard var entry = entries[canonical] else { return .success(nil) }
        // 惰性读取：Keychain 托管的值，首次真正使用时才从 Keychain 取回
        // （避免启动时触发系统钥匙串授权弹窗，用户铁律：严禁弹窗打扰）。
        if entry.valueInKeychain, entry.value.isEmpty {
            switch keychain.readResult(forKey: canonical) {
            case .found(let stored) where !stored.isEmpty:
                entry.value = stored
                entries[canonical] = entry
                if entry.isSecret { registerLogSecretLocked(stored) }
                return .success(stored)
            case .missing:
                lastPersistenceError = .keychainReadMissing
            case .denied:
                lastPersistenceError = .keychainReadDenied
            case .failed, .found:
                lastPersistenceError = .keychainReadFailed
            }
            return .failure(lastPersistenceError ?? .keychainReadFailed)
        }
        guard !entry.value.isEmpty else {
            lastPersistenceError = .missingCredential
            return .failure(.missingCredential)
        }
        if entry.isSecret { registerLogSecretLocked(entry.value) }
        return .success(entry.value)
    }

    /// Return the full entry for `name`, or nil when unset.
    public func entry(name: String) -> EnvVarEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[Self.canonicalName(name)]
    }

    /// Delete `name`; returns false when it was not present.
    @discardableResult
    public func deleteEnvVar(name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let canonical = Self.canonicalName(name)
        guard let removed = entries[canonical] else { return false }
        entries.removeValue(forKey: canonical)
        guard saveLocked() else {
            entries[canonical] = removed
            return false
        }

        // Remove the old item only after metadata commits. A delete failure
        // restores metadata without probing the old secret, so denied access
        // cannot trigger a prompt or leak the credential into diagnostics.
        if removed.valueInKeychain, !keychain.delete(canonical) {
            entries[canonical] = removed
            guard saveLocked() else {
                lastPersistenceError = .keychainRollbackFailed
                return false
            }
            lastPersistenceError = .keychainDeleteFailed
            return false
        }
        lastPersistenceError = nil
        return true
    }

    /// All entries, sorted by name (deterministic order).
    public var allEnvVars: [EnvVarEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.name < $1.name }
    }

    /// A list command has no secret-view authorization. Only a name the user
    /// explicitly classified as non-secret may contribute its value to chat.
    /// Stored flags still take precedence, including deferred Keychain values.
    public func mayDisplayValueInList(_ entry: EnvVarEntry) -> Bool {
        !entry.isSecret && !entry.valueInKeychain
            && privacyStore.provenance(name: entry.name) == .explicitNonSecret
    }

    // MARK: - Provider conversion suggestions (AJ-39)

    /// AJ-39：识别已知供应商 key 模式，返回「转为模型供应商」的建议（供编辑
    /// 弹窗预填 Base URL / 模型 / 协议）。命中规则：
    /// - 阿里云百炼 DashScope 系列（DASHSCOPE_API_KEY / BAILIAN_*_API_KEY /
    ///   HERMES_CUSTOM_QWEN38_API_KEY）→ DashScope 默认端点 + qwen 模型；
    /// - DeepSeek 系列（DEEPSEEK_API_KEY / HERMES_CUSTOM_DEEPSEEK_API_KEY）
    ///   → DeepSeek 官方端点 + deepseek-chat；
    /// - 其余 `*_API_KEY` → 自定义 OpenAI 兼容（Base URL / 模型留空，用户自填）。
    /// 非 API key 名称（如 DATABASE_URL / HOME）返回 nil → 不提供转换建议。
    /// 注意：这只是「建议」，不改变任何存储；转换仍需用户确认后走 `saveProvider`。
    public static func providerSuggestion(for name: String) -> ProviderSuggestion? {
        let n = canonicalName(name)
        if n.hasPrefix("BAILIAN_") && n.hasSuffix("_API_KEY") {
            return ProviderPreset.dashScope.suggestion
        }
        switch n {
        case "DASHSCOPE_API_KEY", "HERMES_CUSTOM_QWEN38_API_KEY":
            return ProviderPreset.dashScope.suggestion
        case "DEEPSEEK_API_KEY", "HERMES_CUSTOM_DEEPSEEK_API_KEY":
            return ProviderPreset.deepSeek.suggestion
        case "HERMES_CUSTOM_NEW_API_KEY":
            return ProviderPreset.newAPI.suggestion
        default:
            if n.hasSuffix("_API_KEY") {
                return ProviderSuggestion(
                    baseURL: nil,
                    modelNames: [],
                    protocolType: .openaiCompatible,
                    providerLabel: "自定义 OpenAI 兼容"
                )
            }
            return nil
        }
    }

    // MARK: - Model providers (U5)

    /// U5：全部「模型供应商」记录（携带 baseURL/模型名等供应商元数据的条目），
    /// 按名称排序。普通环境变量（无元数据）不包含在内。
    public var providerRecords: [EnvVarEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter(\.isProviderRecord).sorted { $0.name < $1.name }
    }

    /// Backup projection of provider configuration only. This reads the
    /// already-loaded metadata under the Store lock; it never asks Keychain
    /// for a deferred value and its return type cannot carry `EnvVarEntry`
    /// value, secret flags, credential linkage or readiness evidence.
    public func providerRecoveryMetadata() throws -> [ProviderRecoveryMetadata] {
        try withLock {
            try entries.values.filter(\.isProviderRecord)
                .sorted { $0.name < $1.name }
                .map { entry in
                    try ProviderRecoveryMetadata(
                        id: entry.id, name: entry.name, createdAt: entry.createdAt,
                        baseURL: entry.baseURL, modelNames: entry.modelNames,
                        protocolType: entry.protocolType,
                        modelContextWindows: entry.modelContextWindows
                    )
                }
        }
    }

    /// U5：新增/更新一个模型供应商记录（参照 Codex/Hermes 的 provider 配置：
    /// name + api_key + base_url + 模型列表 + wire 协议类型）。
    ///
    /// - 供应商的 API key 存在 `value` 字段（新建时强制 `isSecret = true`，
    ///   避免 key 落入日志/模型上下文）；既有 key 读取路径
    ///   （`getEnvVar` / `EnvCredentials.supplementarySource`）不变。
    /// - `baseURL` 允许为空/空白（视为未填写）；`modelNames` 逐项 trim，
    ///   过滤空串，支持多个模型名。
    /// - 更新既有记录时整体覆盖供应商元数据（编辑表单即全量提交）。
    /// - 名称不合法时返回 false（同 `setEnvVar`）。
    @discardableResult
    public func saveProvider(
        name: String,
        apiKey: String,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        modelContextWindows: [String: Int]? = nil
    ) -> Bool {
        let canonical = Self.canonicalName(name)
        let credential: ProviderCredentialUpdate
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lock.lock()
            let exists = entries[canonical] != nil
            lock.unlock()
            credential = exists ? .keepExisting : .missing
        } else {
            credential = .replace(apiKey)
        }
        return saveProvider(
            name: name,
            credential: credential,
            baseURL: baseURL,
            modelNames: modelNames,
            protocolType: protocolType,
            modelContextWindows: modelContextWindows
        )
    }

    /// Save provider metadata with an explicit credential lifecycle intent.
    ///
    /// Metadata-only edits never touch the existing Keychain item. A missing
    /// credential is rejected for new providers and replacement credentials
    /// must be non-empty after trimming.
    @discardableResult
    public func saveProvider(
        name: String,
        credential: ProviderCredentialUpdate,
        baseURL: String?,
        modelNames: [String],
        protocolType: ProviderWireProtocol,
        displayName: String? = nil,
        modelContextWindows: [String: Int]? = nil
    ) -> Bool {
        let canonical = Self.canonicalName(name)
        guard !canonical.isEmpty, Self.isValidName(canonical) else {
            lastPersistenceError = .invalidName
            return false
        }

        let trimmedBase = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBase = (trimmedBase?.isEmpty ?? true) ? nil : trimmedBase
        let finalModels = modelNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        lock.lock(); defer { lock.unlock() }
        // nil = 保持该记录现有窗口；非 nil = 整体替换（空字典 = 清空）。
        // 只保留仍在模型列表里的正整数窗口，删模型名即同步删窗口。
        let finalWindows: [String: Int]? = {
            let source = modelContextWindows ?? entries[canonical]?.modelContextWindows ?? [:]
            let kept = source.filter { finalModels.contains($0.key) && $0.value > 0 }
            return kept.isEmpty ? nil : kept
        }()
        // A reloaded Keychain-backed entry intentionally keeps its secret
        // deferred until a real credential read. Preserve that boundary when
        // replacing it: the new value is committed to Keychain, while the
        // in-memory metadata projection remains secret-free until requested.
        let existingCredentialWasDeferred = entries[canonical].map {
            $0.valueInKeychain && $0.value.isEmpty
        } ?? false
        var entry: EnvVarEntry
        var replacesCredential = false
        switch credential {
        case .missing:
            lastPersistenceError = .missingCredential
            return false
        case .keepExisting:
            guard let existing = entries[canonical] else {
                lastPersistenceError = .missingCredential
                return false
            }
            // A metadata-only edit preserves the existing credential state as
            // an opaque reference/value. It must not read, validate, rewrite,
            // or delete Keychain; a later real read classifies missing/denied/
            // failed references and prompts re-entry at that consumer boundary.
            if !existing.valueInKeychain, existing.value.isEmpty {
                lastPersistenceError = .missingCredential
                return false
            }
            entry = existing
        case .replace(let apiKey):
            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAPIKey.isEmpty else {
                lastPersistenceError = .missingCredential
                return false
            }
            registerLogSecretLocked(trimmedAPIKey)
            if case .replace = credential {
                replacesCredential = true
            }
            if var existing = entries[canonical] {
                existing.value = existingCredentialWasDeferred ? "" : trimmedAPIKey
                existing.isSecret = true
                existing.baseURL = finalBase
                existing.modelNames = finalModels
                existing.protocolType = protocolType
                entry = existing
            } else {
                entry = EnvVarEntry(
                    name: canonical,
                    value: trimmedAPIKey,
                    isSecret: true,  // 供应商记录 value 即 API key，恒按密钥处理
                    baseURL: finalBase,
                    modelNames: finalModels,
                    protocolType: protocolType
                )
            }
        }
        entry.modelContextWindows = finalWindows
        let previousEntry = entries[canonical]
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.displayName = trimmed.isEmpty ? nil : trimmed
        }
        if replacesCredential {
            // API key 恒为 secret → JSON 只先写占位。关键顺序：先提交
            // 到同目录临时文件，再执行 Keychain create/update；Keychain
            // 失败时正式 metadata 文件和内存均保持旧状态。显式新 Key
            // 不需要先读取一个可能已经不存在或不可读的旧 item。
            entry.isSecret = true
            entry.valueInKeychain = true
        } else {
            entry.baseURL = finalBase
            entry.modelNames = finalModels
            entry.protocolType = protocolType
        }
        if replacesCredential {
            var candidateEntries = entries
            candidateEntries[canonical] = entry
            guard let stagedURL = stageMetadataLocked(candidateEntries) else {
                return false
            }
            var metadataWasDirectory = ObjCBool(false)
            let metadataExisted = FileManager.default.fileExists(
                atPath: fileURL.path,
                isDirectory: &metadataWasDirectory
            )
            let trimmedAPIKey: String
            if case .replace(let apiKey) = credential {
                trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                trimmedAPIKey = ""
            }
            guard keychain.set(trimmedAPIKey, forKey: canonical) else {
                // The failed Keychain write normally leaves the staged file
                // disposable and the committed metadata untouched.  If a
                // concurrent/file-system failure has already disturbed the
                // metadata path, however, the transaction can no longer be
                // described as a plain write failure: callers must fence the
                // settings boundary until an explicit reconciliation.
                let stagedRemoved: Bool
                do {
                    try FileManager.default.removeItem(at: stagedURL)
                    stagedRemoved = true
                } catch {
                    stagedRemoved = false
                }
                var metadataIsDirectory = ObjCBool(false)
                let metadataExists = FileManager.default.fileExists(
                    atPath: fileURL.path,
                    isDirectory: &metadataIsDirectory
                )
                let metadataPathUnchanged = metadataExists == metadataExisted
                    && metadataIsDirectory.boolValue == metadataWasDirectory.boolValue
                lastPersistenceError = stagedRemoved && metadataPathUnchanged
                    ? .keychainWriteFailed
                    : .keychainRollbackFailed
                return false
            }
            guard commitStagedMetadataLocked(stagedURL) else {
                // A commit failure is exceptional: restore a known old value,
                // or remove a newly-created item. If the old value was not
                // available after reload, fail closed rather than guessing.
                let rolledBack: Bool
                if let previousEntry,
                   previousEntry.valueInKeychain,
                   !previousEntry.value.isEmpty {
                    rolledBack = keychain.set(previousEntry.value, forKey: canonical)
                } else if previousEntry == nil {
                    rolledBack = keychain.delete(canonical)
                } else {
                    rolledBack = false
                }
                lastPersistenceError = rolledBack
                    ? .metadataWriteFailed
                    : .keychainRollbackFailed
                return false
            }
            entries[canonical] = entry
            lastPersistenceError = nil
            return true
        }
        entries[canonical] = entry
        guard saveLocked() else {
            entries[canonical] = previousEntry
            return false
        }

        lastPersistenceError = nil
        return true
    }

    /// Number of stored variables.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Process environment import

    /// Import the current process environment. A caller may supply a fixed
    /// source for an isolated test without enumerating the host environment.
    /// Only previously-unknown, non-empty names are added; existing entries
    /// keep their stored value and secret flag. Returns the number imported.
    @discardableResult
    public func loadFromProcessEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        var imported = 0
        lock.lock(); defer { lock.unlock() }
        for (name, value) in source
        where !value.isEmpty && entries[Self.canonicalName(name)] == nil {
            let canonical = Self.canonicalName(name)
            guard Self.isValidName(canonical) else { continue }
            let entry = EnvVarEntry(
                name: canonical,
                value: value,
                isSecret: privacyStore.isSecret(name: canonical)
            )
            guard let storedEntry = applySecretStorage(entry) else { continue }
            entries[canonical] = storedEntry
            imported += 1
        }
        if imported > 0 { saveLocked() }
        return imported
    }

    // MARK: - Process environment import preview & selective apply (SETTINGS-25)

    /// SETTINGS-25：单个进程环境变量候选在「脱敏差异预览」中的分类。
    ///
    /// 预览完全无持久化副作用：只读取当前已存条目的元数据快照与调用方
    /// 提供的（默认取进程环境的）候选值，逐条产出可勾选记录。secret
    /// 类名称的值在预览结果中只以占位符出现，原始明文永不物化。
    public enum EnvVarProcessImportChangeKind: String, Codable, Equatable, Sendable {
        /// 名称尚未存储：可选中，apply 时按 add-only 语义新增。
        case add
        /// 名称已存储且非 secret 值不同：仅供差异展示；apply 不覆盖
        /// 既有条目（保持 add-only 语义），因此不可勾选导入。
        case update
        /// 不可作为新增导入：已存储（值相同或 secret/Keychain 托管无法
        /// 比对）、进程值为空、或名称非法。
        case skip
    }

    /// `changeKind == .skip` 时的原因（其余分类为 nil）。
    public enum EnvVarProcessImportSkipReason: String, Codable, Equatable, Sendable {
        case alreadyStored
        case emptyValue
        case invalidName
    }

    /// apply 阶段单个被选名称的持久化结果。
    public enum EnvVarProcessImportApplyOutcome: String, Codable, Equatable, Sendable {
        case imported
        case skippedAlreadyStored
        case skippedEmptyValue
        case skippedInvalidName
        /// secret 值写入 Keychain 失败 → 整条放弃（与既有 applySecretStorage
        /// fail-closed 语义一致）。
        case failedSecretStorage
    }

    /// 预览记录：调用方 UI 用它渲染脱敏差异清单并允许逐项勾选。
    public struct EnvVarProcessImportPreviewItem: Equatable, Sendable {
        /// secret 类条目在预览中的固定占位符；永不携带任何真实值片段。
        public static let redactedValuePlaceholder = "<redacted>"

        /// 规范名（canonicalized，大写）。
        public let name: String
        public let changeKind: EnvVarProcessImportChangeKind
        /// 仅当 `changeKind == .skip` 时非 nil。
        public let skipReason: EnvVarProcessImportSkipReason?
        /// 是否被名称隐私规则或已有条目的 secret/Keychain 归属判定为 secret 类。
        public let isSecretClassified: Bool
        /// 脱敏值表示：仅显式标记非敏感且无既存 secret 归属的名称
        /// 可显示进程侧原值；其他名称为固定占位符。
        public let valueDisplay: String

        /// 仅 add 类可勾选导入；update/skip 不进入 apply。
        public var isSelectableForImport: Bool { changeKind == .add }

        public init(
            name: String,
            changeKind: EnvVarProcessImportChangeKind,
            skipReason: EnvVarProcessImportSkipReason?,
            isSecretClassified: Bool,
            valueDisplay: String
        ) {
            self.name = name
            self.changeKind = changeKind
            self.skipReason = skipReason
            self.isSecretClassified = isSecretClassified
            self.valueDisplay = valueDisplay
        }
    }

    /// 「从进程导入」预览表的勾选状态。只有 `isSelectableForImport` 的项可选；
    /// 默认选中 = 可选且非凭据类。全选/全不选只作用于可选项。
    public struct EnvVarProcessImportSelection: Equatable, Sendable {
        public private(set) var selectedNames: Set<String>
        private let selectableNames: Set<String>

        public init(items: [EnvVarProcessImportPreviewItem]) {
            let selectable = items.filter(\.isSelectableForImport)
            selectableNames = Set(selectable.map(\.name))
            selectedNames = Set(
                selectable.filter { !Self.isCredentialLike($0) }.map(\.name)
            )
        }

        public mutating func selectAll() { selectedNames = selectableNames }
        public mutating func selectNone() { selectedNames = [] }

        public mutating func set(_ name: String, selected: Bool) {
            guard selectableNames.contains(name) else { return }
            if selected { selectedNames.insert(name) } else { selectedNames.remove(name) }
        }

        // 附加名称分段规则只用于导入预览的默认勾选：EnvVarPrivacyStore 的敏感名单
        // 同时驱动脱敏与 isSecret 存储推断，扩充它影响面过大，故不改全局名单。
        private static let credentialSegments: Set<String> =
            ["OAUTH", "PASSWD", "COOKIE", "SESSION", "PRIVATE"]

        private static func isCredentialLike(_ item: EnvVarProcessImportPreviewItem) -> Bool {
            if item.isSecretClassified { return true }
            let segments = item.name.uppercased()
                .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
                .map(String.init)
            return segments.contains { credentialSegments.contains($0) }
        }
    }

    /// SETTINGS-25 只读预览：枚举候选进程变量，逐条产出
    /// add/update/skip 分类与脱敏值表示。无任何写副作用：
    /// 不落盘、不写 Keychain、不改动内存条目。
    ///
    /// - Parameter source: 候选来源，默认取当前进程环境；测试可注入
    ///   确定性的字典。键按 `canonicalName` 规范化，同名后者不覆盖前者。
    public func processEnvironmentImportPreview(
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [EnvVarProcessImportPreviewItem] {
        lock.lock()
        // 快照读，避免与并发 set/delete 交错；预览本身不持锁执行隐私查询。
        let storedSnapshot = entries
        lock.unlock()
        var canonicalSource: [String: String] = [:]
        for (rawName, value) in source {
            let canonical = Self.canonicalName(rawName)
            if canonicalSource[canonical] == nil { canonicalSource[canonical] = value }
        }
        return canonicalSource.map { canonical, value in
            // An explicit stored secret can have an ordinary name (including
            // a provider name). Its process-side value is still unauthorized
            // for display even though add-only import will skip this item.
            let existing = storedSnapshot[canonical]
            let provenance = privacyStore.provenance(name: canonical)
            let secret = existing?.isSecret == true || existing?.valueInKeychain == true
                || provenance.isSecret
            let mayDisplay = !secret && provenance == .explicitNonSecret
            let display = mayDisplay ? value
                : EnvVarProcessImportPreviewItem.redactedValuePlaceholder
            guard !value.isEmpty else {
                return EnvVarProcessImportPreviewItem(
                    name: canonical,
                    changeKind: .skip,
                    skipReason: .emptyValue,
                    isSecretClassified: secret,
                    valueDisplay: display
                )
            }
            guard Self.isValidName(canonical) else {
                return EnvVarProcessImportPreviewItem(
                    name: canonical,
                    changeKind: .skip,
                    skipReason: .invalidName,
                    isSecretClassified: secret,
                    valueDisplay: display
                )
            }
            guard let existing = storedSnapshot[canonical] else {
                return EnvVarProcessImportPreviewItem(
                    name: canonical,
                    changeKind: .add,
                    skipReason: nil,
                    isSecretClassified: secret,
                    valueDisplay: display
                )
            }
            // add-only：既有条目永不覆盖。非 secret 且内存中可比对时，
            // 值不同按 update 展示差异；其余一律 skip。
            if !existing.isSecret,
               !existing.valueInKeychain,
               existing.value != value {
                return EnvVarProcessImportPreviewItem(
                    name: canonical,
                    changeKind: .update,
                    skipReason: nil,
                    isSecretClassified: secret,
                    valueDisplay: display
                )
            }
            return EnvVarProcessImportPreviewItem(
                name: canonical,
                changeKind: .skip,
                skipReason: .alreadyStored,
                isSecretClassified: secret,
                valueDisplay: display
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// SETTINGS-25 显式应用：只持久化调用方逐项选中的名称，语义与
    /// `loadFromProcessEnvironment()` 完全一致 —— add-only（绝不覆盖既有
    /// 条目）、名称合法性守卫、secret 类值经 `applySecretStorage` 走
    /// Keychain。预览与 apply 之间进程环境可能变化，这里按当前 `source`
    /// 重新校验，宁可不写也不写错。
    ///
    /// - Parameters:
    ///   - selectedNames: 用户在预览清单上勾选的名称（大小写不敏感）。
    ///   - source: 候选来源，默认取当前进程环境。
    /// - Returns: 以规范名为键的逐条结果；未选中的候选不会出现在返回值中。
    @discardableResult
    public func applyProcessEnvironmentImport(
        selectedNames: [String],
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: EnvVarProcessImportApplyOutcome] {
        var outcomes: [String: EnvVarProcessImportApplyOutcome] = [:]
        var changed = false
        var canonicalSource: [String: String] = [:]
        for (rawName, value) in source {
            let canonical = Self.canonicalName(rawName)
            if canonicalSource[canonical] == nil { canonicalSource[canonical] = value }
        }
        lock.lock(); defer { lock.unlock() }
        for rawName in selectedNames {
            let canonical = Self.canonicalName(rawName)
            guard !canonical.isEmpty, Self.isValidName(canonical) else {
                outcomes[canonical] = .skippedInvalidName
                continue
            }
            guard let value = canonicalSource[canonical], !value.isEmpty else {
                outcomes[canonical] = .skippedEmptyValue
                continue
            }
            guard entries[canonical] == nil else {
                outcomes[canonical] = .skippedAlreadyStored
                continue
            }
            let entry = EnvVarEntry(
                name: canonical,
                value: value,
                isSecret: privacyStore.isSecret(name: canonical)
            )
            guard let storedEntry = applySecretStorage(entry) else {
                outcomes[canonical] = .failedSecretStorage
                continue
            }
            entries[canonical] = storedEntry
            outcomes[canonical] = .imported
            changed = true
        }
        if changed { saveLocked() }
        return outcomes
    }

    // MARK: - Persistence

    private static func load(from url: URL, keychain: KeychainStore) -> ([String: EnvVarEntry], Bool) {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([EnvVarEntry].self, from: data) else {
            return ([:], false)
        }
        var requiresRewrite = false
        var result: [String: EnvVarEntry] = [:]
        for var entry in list {
            if entry.valueInKeychain {
                // 已是 Keychain 托管：启动时不主动读 keychain（避免触发系统钥匙串授权弹窗，
                // 用户铁律：严禁弹窗打扰）。真实值在 getEnvVar 惰性读取。
                entry.value = ""
            } else if entry.isSecret, !entry.value.isEmpty {
                // 向后兼容：旧 envvars.json 的明文 secret 首次读取时自动迁入
                // Keychain，随后重写 JSON 剥离明文。
                requiresRewrite = true
                if keychain.set(entry.value, forKey: entry.name) {
                    entry.valueInKeychain = true
                } else {
                    // Fail closed: an unpersisted legacy credential is disabled
                    // in memory and scrubbed from metadata on the forced rewrite.
                    entry.value = ""
                    entry.valueInKeychain = false
                }
            }
            result[entry.name] = entry
        }
        return (result, requiresRewrite)
    }

    /// 按 secret 状态决定值存哪：secret 值写入 Keychain（`valueInKeychain = true`，
    /// JSON 只存占位）；非 secret 值留在 JSON。调用方须持有 `lock`。
    private func applySecretStorage(_ entry: EnvVarEntry) -> EnvVarEntry? {
        var e = entry
        if e.isSecret {
            registerLogSecretLocked(e.value)
            if e.value.isEmpty {
                // 空 secret 无内容可存 → 清理 Keychain 副本。
                keychain.delete(e.name)
                e.valueInKeychain = false
            } else if keychain.set(e.value, forKey: e.name) {
                e.valueInKeychain = true
            } else {
                return nil
            }
        } else {
            // 不再是 secret → 丢弃 Keychain 副本，值回到 JSON。
            if e.valueInKeychain {
                keychain.delete(e.name)
            }
            e.valueInKeychain = false
        }
        return e
    }

    @discardableResult
    private func saveLocked() -> Bool {
        let mutation = metadataConsistency.begin("metadata")!
        defer { _ = metadataConsistency.end("metadata", began: mutation) }
        let list = entries.values.sorted { $0.name < $1.name }
        do {
            let data = try JSONEncoder().encode(list)
            // Injectable stores (including the production profile on a first
            // launch) may not have materialized their parent yet.  Create it
            // at the same commit boundary as the metadata write so an atomic
            // provider save cannot fail merely because the store is new.
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            lastPersistenceError = .metadataWriteFailed
            return false
        }
    }

    /// Encode a candidate metadata snapshot to a same-directory temporary
    /// file. The final path is untouched until the Keychain upsert succeeds.
    /// Callers must hold the lock.
    private func stageMetadataLocked(_ snapshot: [String: EnvVarEntry]) -> URL? {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(
                atPath: fileURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                throw CocoaError(.fileWriteFileExists)
            }
            let data = try JSONEncoder().encode(
                snapshot.values.sorted { $0.name < $1.name }
            )
            let stagedURL = parent.appendingPathComponent(
                ".\(Self.fileName).pending-\(UUID().uuidString)",
                isDirectory: false
            )
            try data.write(to: stagedURL, options: .atomic)
            return stagedURL
        } catch {
            lastPersistenceError = .metadataWriteFailed
            return nil
        }
    }

    /// Atomically publish a staged metadata file. The staged path is always
    /// in the same directory as fileURL, so replacement cannot cross a
    /// filesystem boundary.
    private func commitStagedMetadataLocked(_ stagedURL: URL) -> Bool {
        let mutation = metadataConsistency.begin("metadata")!
        defer { _ = metadataConsistency.end("metadata", began: mutation) }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    fileURL,
                    withItemAt: stagedURL
                )
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: fileURL)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            lastPersistenceError = .metadataWriteFailed
            return false
        }
    }

}
