import Foundation
import CryptoKit
import Darwin

public enum SettingsPersistenceError: Error, Equatable, Sendable {
    case encodingFailed
    case directoryCreationFailed
    case writeFailed
    case transactionReopenRequired
    case transactionRecoveryRequired
}

public enum BL6SettingsReplayCommitError: Error, Equatable, Sendable {
    case persistence(SettingsPersistenceError)
    case conflict
    case staleRevision
}

/// Internal, redacted completion kept beside AppSettings in settings.json.
/// It is deliberately absent from AppSettings and its sync representation.
public struct BL6SettingsReplayRecord: Codable, Equatable, Sendable {
    public let requestID: String
    public let payloadDigest: String
    public let frozenInput: BL6SettingsApprovedInput
    public let approvalBindingDigest: String
    public let profileID: String
    public let scope: String
    public let sessionID: String
    public let policyRevision: String
    public let grantEpoch: String
    public let approvalExpiresAt: Date
    public let operation: BL6SettingsOperation
    public let receipt: BL6SettingsReceipt
    /// Owner-only rollback snapshot; never returned in the public receipt.
    public let rollbackValues: [String: BL6SettingValue]

    public init(requestID: String, payloadDigest: String, frozenInput: BL6SettingsApprovedInput,
                approvalBindingDigest: String,
                profileID: String, scope: String, sessionID: String, policyRevision: String,
                grantEpoch: String, approvalExpiresAt: Date,
                operation: BL6SettingsOperation, receipt: BL6SettingsReceipt,
                rollbackValues: [String: BL6SettingValue]) {
        self.requestID = requestID
        self.payloadDigest = payloadDigest
        self.frozenInput = frozenInput
        self.approvalBindingDigest = approvalBindingDigest
        self.profileID = profileID
        self.scope = scope
        self.sessionID = sessionID
        self.policyRevision = policyRevision
        self.grantEpoch = grantEpoch
        self.approvalExpiresAt = approvalExpiresAt
        self.operation = operation
        self.receipt = receipt
        self.rollbackValues = rollbackValues
    }
}

public enum SettingsPersistenceResult: Equatable, Sendable {
    case persisted
}

public typealias SettingsUpdateResult = Result<SettingsPersistenceResult, SettingsPersistenceError>

/// 设置中心数据层：加载/保存 `settings.json`，变更自动持久化。
///
/// 设置能力参照 OpenMinis 手机端；本工程 macOS 数据层实现事务与恢复，路径可注入
/// （默认 `<Application Support>/MinisCore/settings.json`），每次
/// 变更（`update` / `resetToDefaults`）先候选写盘成功再提交内存；
/// 加载时经 `SettingsMigration` 做版本迁移。
///
/// 纯数据层，不含 SwiftUI UI（UI 由 MinisCanvasApp 设置中心消费）。
public final class SettingsStore: @unchecked Sendable {
    /// 持久化文件名。
    public static let fileName = "settings.json"

    private struct ReplayMetadata: Codable {
        let version: Int
        var records: [String: BL6SettingsReplayRecord]
        static var empty: Self { .init(version: 1, records: [:]) }
    }

    private static let replayKey = "_bl6Replay"

    private enum SettingsRecoveryPhase: String, Codable {
        case prepared
        case moved
        case committed
    }

    /// Identity-only marker for the corrupt/unsupported settings backup move.
    /// The original bytes stay in the source or backup file, never in this
    /// recovery metadata.
    private struct PendingSettingsRecovery: Codable, Equatable {
        let operationID: UUID
        let scopeID: String
        let sourceName: String
        let destinationName: String
        let payloadDigest: String
        let phase: SettingsRecoveryPhase

        func withPhase(_ phase: SettingsRecoveryPhase) -> PendingSettingsRecovery {
            PendingSettingsRecovery(
                operationID: operationID,
                scopeID: scopeID,
                sourceName: sourceName,
                destinationName: destinationName,
                payloadDigest: payloadDigest,
                phase: phase
            )
        }
    }

    private static let pendingRecoveryPrefix = ".settings-recovery-"
    private static let pendingRecoverySuffix = ".pending.json"

    /// 默认存储目录：`<Application Support>/MinisCore`。
    /// Application Support 不可用时回退系统临时目录（避免 `.first!` 强解包崩溃），
    /// 对齐 EnvVarStore / VideoTaskStore / SessionStore 的 D6 回退做法。
    public static func defaultDirectory() -> URL {
        if let formal = FormalTestIsolationPaths.currentOrFail() {
            try? FileManager.default.createDirectory(at: formal.settingsDirectory, withIntermediateDirectories: true)
            return formal.settingsDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MinisCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let persistenceURL: URL
    private let lock = NSRecursiveLock()
    private let onPersistError: ((Error) -> Void)?
    private var requiresBackupBeforePersist = false
    private var replayMetadataBlocked = false
    private var replayMetadata: ReplayMetadata = .empty

    /// 当前设置。仅在候选值成功原子写入后提交。
    private var storedSettings: AppSettings
    public var persistenceDomain: PersistenceTransactionFence.Domain { .settings(directory) }
    public private(set) var settings: AppSettings {
        get {
            PersistenceTransactionFence.withRead([persistenceDomain]) {
                if let captured = PersistenceTransactionFence.beforeView(persistenceDomain)?.settings {
                    return captured
                }
                lock.lock(); defer { lock.unlock() }
                return storedSettings
            }
        }
        set { storedSettings = newValue }
    }
    private let persistenceErrorLock = NSLock()
    private var persistenceError: SettingsPersistenceError?

    /// 最近一次持久化错误；成功写入后清除。
    public private(set) var lastPersistenceError: SettingsPersistenceError? {
        get {
            persistenceErrorLock.lock(); defer { persistenceErrorLock.unlock() }
            return persistenceError
        }
        set {
            persistenceErrorLock.lock(); defer { persistenceErrorLock.unlock() }
            persistenceError = newValue
        }
    }
    /// Provenance of the last decoded migration, if this store opened a
    /// persisted settings payload.  The store does not synthesize a second
    /// settings snapshot from this diagnostic.
    public private(set) var lastMigrationProvenance: SettingsMigrationProvenance? = nil

    /// - Parameters:
    ///   - directory: 持久化目录（可注入，测试传临时目录）。
    ///   - initial: 文件不存在或损坏时的初始设置，默认 `.defaults`。
    ///   - onPersistError: 落盘失败回调（默认 nil，静默降级）。
    public convenience init(
        directory: URL,
        initial: AppSettings = .defaults,
        onPersistError: ((Error) -> Void)? = nil
    ) {
        self.init(
            directory: directory,
            initial: initial,
            onPersistError: onPersistError,
            backupFileManager: .default
        )
    }

    /// Internal seam used by deterministic persistence tests to exercise a
    /// backup failure while leaving the production public initializer intact.
    init(
        directory: URL,
        initial: AppSettings = .defaults,
        onPersistError: ((Error) -> Void)? = nil,
        backupFileManager: FileManager
    ) {
        self.persistenceURL = directory.appendingPathComponent(Self.fileName)
        self.onPersistError = onPersistError
        self.storedSettings = initial
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        if PersistenceTransactionFence.requiresReopen(persistenceDomain) {
            // A fresh instance in this process cannot materialize caller-chosen
            // defaults over imported data, nor replace the shared BEFORE view.
            if let captured = PersistenceTransactionFence.beforeView(persistenceDomain)?.settings {
                self.storedSettings = captured
            }
            do { try admission.requireWritable() }
            catch { lastPersistenceError = (error as? PersistenceTransactionError) == .recoveryRequired ? .transactionRecoveryRequired : .transactionReopenRequired }
            return
        }

        do {
            let pending = try pendingSettingsRecoveries()
            if !pending.isEmpty {
                requiresBackupBeforePersist = true
                lastPersistenceError = .transactionRecoveryRequired
                return
            }
        } catch {
            requiresBackupBeforePersist = true
            lastPersistenceError = .transactionRecoveryRequired
            return
        }

        let fm = backupFileManager
        let existingData = try? Data(contentsOf: persistenceURL)
        if let data = existingData {
            do {
                // A relocated store retains completed request identities at their
                // original paths. Those records cannot authorize replay here.
                replayMetadata = try Self.decodeReplayMetadata(from: data)
            } catch {
                // A known replay history must never be backed up and replaced
                // by defaults merely because its schema is newer or damaged.
                // If user settings still decode, project those existing
                // values read-only rather than showing fabricated defaults.
                if let projected = try? SettingsMigration.migrate(data: data) {
                    storedSettings = projected.settings
                    lastMigrationProvenance = projected.provenance
                }
                replayMetadataBlocked = true
                lastPersistenceError = .transactionRecoveryRequired
                return
            }
        }
        let migrationResult: SettingsMigrationResult?
        do {
            migrationResult = try existingData.map { try SettingsMigration.migrate(data: $0) }
        } catch TerminalPolicyDecodingError.unsupportedProvenanceVersion {
            // Future provenance is not corrupt data: preserve the source and
            // surface the existing read-only recovery state instead of reset.
            replayMetadataBlocked = true
            lastPersistenceError = .transactionRecoveryRequired
            return
        } catch {
            migrationResult = nil
        }
        if let result = migrationResult {
            lastMigrationProvenance = result.provenance
            // 未来版本（由更新版本的 App 写入）：拒绝加载 + 隔离备份，避免「宽容解码
            // 丢弃未来字段 → 首次写设置静默降级」的永久数据丢失（Q8-r2 审计判定）。
            if result.settings.settingsVersion > AppSettings.currentVersion {
                if !replayMetadata.records.isEmpty {
                    storedSettings = result.settings
                    replayMetadataBlocked = true
                    lastPersistenceError = .transactionRecoveryRequired
                    return
                }
                settings = initial
                guard backupCorruptFileIfNeeded(at: persistenceURL, fileManager: fm) != nil else {
                    requiresBackupBeforePersist = true
                    _ = recordPersistenceFailure(.writeFailed)
                    return
                }
                _ = persist(settings)
                return
            }
            settings = result.settings
            // 迁移后立即落盘新版本，避免每次启动重复迁移。
            if result.migrated {
                _ = persist(settings)
            }
            return
        }
        if !replayMetadata.records.isEmpty {
            replayMetadataBlocked = true
            lastPersistenceError = .transactionRecoveryRequired
            return
        }
        settings = initial
        // 文件存在但解码失败 = 损坏：先备份损坏文件（避免静默残留，
        // 也防止每次启动都重复读取损坏内容并静默回退），再覆写为 initial。
        if fm.fileExists(atPath: persistenceURL.path) {
            settings = initial
            guard backupCorruptFileIfNeeded(at: persistenceURL, fileManager: fm) != nil else {
                requiresBackupBeforePersist = true
                _ = recordPersistenceFailure(.writeFailed)
                return
            }
            _ = persist(settings)
            return
        }
        // 首次启动或损坏恢复：物化默认设置文件。
        settings = initial
        _ = persist(settings)
    }

    /// The injected directory that owns this settings store.
    ///
    /// This is a read-only projection of the canonical persistence URL. It
    /// keeps settings UI and diagnostics on the same profile-scoped path used
    /// by the store instead of reconstructing the production default.
    public var directory: URL {
        persistenceURL.deletingLastPathComponent()
    }

    /// The canonical settings file URL used by this store.
    public var fileURL: URL {
        persistenceURL
    }

    /// D3：将损坏的 `settings.json` 重命名为 `<name>.corrupt-<ts>[-n]` 备份，
    /// 保留现场供排障；随后主文件被 `persist()` 覆写为有效默认值。
    /// 移动失败（目录只读等）时静默忽略 —— 下行原子写仍会覆盖损坏内容。
    /// 返回备份 URL（成功时）；失败返回 nil。
    @discardableResult
    private func backupCorruptFileIfNeeded(
        at fileURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ts = formatter.string(from: Date())
        let baseName = fileURL.lastPathComponent // e.g. settings.json
        var backup = directory.appendingPathComponent("\(baseName).corrupt-\(ts)")
        // 同一秒内重复损坏 → 追加序号，避免覆盖既有备份。
        var suffix = 1
        while fileManager.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("\(baseName).corrupt-\(ts)-\(suffix)")
            suffix += 1
        }
        guard let originalData = try? Data(contentsOf: fileURL) else { return nil }
        let transaction = PendingSettingsRecovery(
            operationID: UUID(),
            scopeID: "settings:\(Self.fileName)",
            sourceName: Self.fileName,
            destinationName: backup.lastPathComponent,
            payloadDigest: Self.fingerprint(originalData),
            phase: .prepared
        )
        var moved = false
        do {
            try persistPendingSettingsRecovery(transaction)
            try fileManager.moveItem(at: fileURL, to: backup)
            moved = true
            try fsyncDirectory(directory)
            try persistPendingSettingsRecovery(transaction.withPhase(.moved))
            try persistPendingSettingsRecovery(transaction.withPhase(.committed))
            try removePendingSettingsRecovery(transaction)
            return backup
        } catch {
            if !moved { try? removePendingSettingsRecovery(transaction) }
            return nil
        }
    }

    /// Remove only a provable settings backup marker. A prepared marker with
    /// the corrupt source still present is a no-op; a moved/committed marker
    /// requires the exact backup digest and an absent source. Ambiguous bytes
    /// remain untouched and keep subsequent writes fail closed.
    @discardableResult
    public func recoverPendingTransactions() throws -> Int {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            lock.lock(); defer { lock.unlock() }
            let pending = try pendingSettingsRecoveries()
            guard !pending.isEmpty else { return 0 }
            var removable: [PendingSettingsRecovery] = []
            for transaction in pending {
                let source = directory.appendingPathComponent(transaction.sourceName)
                let destination = directory.appendingPathComponent(transaction.destinationName)
                let sourceMatches = try matches(transaction.payloadDigest, at: source)
                let destinationMatches = try matches(transaction.payloadDigest, at: destination)
                switch transaction.phase {
                case .prepared where sourceMatches && !FileManager.default.fileExists(atPath: destination.path):
                    removable.append(transaction)
                case .moved where !FileManager.default.fileExists(atPath: source.path) && destinationMatches:
                    removable.append(transaction)
                case .committed where !FileManager.default.fileExists(atPath: source.path) && destinationMatches:
                    removable.append(transaction)
                default:
                    throw SettingsPersistenceError.transactionRecoveryRequired
                }
            }
            for transaction in removable {
                try removePendingSettingsRecovery(transaction)
            }
            requiresBackupBeforePersist = false
            return removable.count
        }
    }

    // MARK: - 更新

    /// 通过 keyPath 更新任意设置并自动保存，如
    /// `store.update(\.agent.maxLoopIterations, to: 25)`。
    @discardableResult
    public func update<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>,
        to value: Value
    ) -> SettingsUpdateResult {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return recordPersistenceFailure((error as? PersistenceTransactionError) == .recoveryRequired ? .transactionRecoveryRequired : .transactionReopenRequired) }
        lock.lock(); defer { lock.unlock() }
        var candidate = settings
        candidate[keyPath: keyPath] = value
        return commit(candidate)
    }

    /// 通过 keyPath + 闭包原地修改（便于组合更新同一子结构）。
    @discardableResult
    public func update<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>,
        _ transform: (inout Value) -> Void
    ) -> SettingsUpdateResult {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return recordPersistenceFailure((error as? PersistenceTransactionError) == .recoveryRequired ? .transactionRecoveryRequired : .transactionReopenRequired) }
        lock.lock(); defer { lock.unlock() }
        var candidate = settings
        transform(&candidate[keyPath: keyPath])
        return commit(candidate)
    }

    /// Atomically replace the complete settings snapshot.
    ///
    /// The candidate is written before `settings` is committed, so callers
    /// such as sync restore do not need to sequence multiple independent
    /// updates that can leave a partially restored snapshot.
    @discardableResult
    public func replace(with candidate: AppSettings) -> SettingsUpdateResult {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return recordPersistenceFailure((error as? PersistenceTransactionError) == .recoveryRequired ? .transactionRecoveryRequired : .transactionReopenRequired) }
        lock.lock(); defer { lock.unlock() }
        return commit(candidate)
    }

    /// Read the durable identity before planning a newly approved effect.
    public func bl6ReplayRecord(for requestID: String) -> Result<BL6SettingsReplayRecord?, SettingsPersistenceError> {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return .failure(.transactionRecoveryRequired) }
        lock.lock(); defer { lock.unlock() }
        guard !replayMetadataBlocked, !requiresBackupBeforePersist,
              (try? pendingSettingsRecoveries().isEmpty) == true else {
            return .failure(.transactionRecoveryRequired)
        }
        return .success(replayMetadata.records[requestID])
    }

    public func bl6ReplayRecord(receiptID: String) -> Result<BL6SettingsReplayRecord?, SettingsPersistenceError> {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return .failure(.transactionRecoveryRequired) }
        lock.lock(); defer { lock.unlock() }
        guard !replayMetadataBlocked, !requiresBackupBeforePersist,
              (try? pendingSettingsRecoveries().isEmpty) == true else {
            return .failure(.transactionRecoveryRequired)
        }
        return .success(replayMetadata.records.values.first { $0.receipt.receiptID == receiptID })
    }

    /// One settings.json candidate contains both changed settings and the
    /// completed receipt. A failed write publishes neither in memory.
    public func commitBL6Replay(
        expectedSettings: AppSettings,
        candidate: AppSettings,
        record: BL6SettingsReplayRecord
    ) -> Result<BL6SettingsReceipt, BL6SettingsReplayCommitError> {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return .failure(.persistence(.transactionRecoveryRequired)) }
        lock.lock(); defer { lock.unlock() }
        guard !replayMetadataBlocked, !requiresBackupBeforePersist,
              (try? pendingSettingsRecoveries().isEmpty) == true else {
            return .failure(.persistence(.transactionRecoveryRequired))
        }
        if let existing = replayMetadata.records[record.requestID] {
            guard existing.profileID == directory.standardizedFileURL.path,
                  Date() < existing.approvalExpiresAt else { return .failure(.conflict) }
            return existing == record ? .success(existing.receipt) : .failure(.conflict)
        }
        guard storedSettings == expectedSettings else { return .failure(.staleRevision) }
        guard Self.validReplayRecord(record),
              Date() < record.approvalExpiresAt,
              record.profileID == directory.standardizedFileURL.path,
              !replayMetadata.records.values.contains(where: {
                  $0.receipt.receiptID == record.receipt.receiptID
              }) else {
            return .failure(.conflict)
        }
        let policyKey = BL6SettingsApprovedInput.approvalPolicyKey
        if let policy = record.frozenInput.changes[policyKey] {
            guard case .text(let rawPolicy) = policy,
                  let nextPolicy = ApprovalPolicy(rawValue: rawPolicy) else { return .failure(.conflict) }
            var policyCandidate = expectedSettings
            policyCandidate.agent.approvalPolicy = nextPolicy
            policyCandidate.agent.legacyAutomaticApprovalCompatibilityActive = false
            let policyChanged = expectedSettings.agent.approvalPolicy != nextPolicy
            guard candidate == policyCandidate,
                  record.receipt.changedKeys == (policyChanged ? [policyKey] : []) else {
                return .failure(.conflict)
            }
        } else if candidate.agent.approvalPolicy != expectedSettings.agent.approvalPolicy
            || candidate.agent.legacyAutomaticApprovalCompatibilityActive
                != expectedSettings.agent.legacyAutomaticApprovalCompatibilityActive {
            return .failure(.conflict)
        }
        var next = replayMetadata
        next.records[record.requestID] = record
        switch persist(candidate, metadata: next) {
        case .failure(let error): return .failure(.persistence(error))
        case .success:
            replayMetadata = next
            settings = candidate
            return .success(record.receipt)
        }
    }

    /// 恢复全部默认值并持久化。
    @discardableResult
    public func resetToDefaults() -> SettingsUpdateResult {
        let admission = PersistenceTransactionFence.read([persistenceDomain])
        defer { admission.release() }
        do { try admission.requireWritable() }
        catch { return recordPersistenceFailure((error as? PersistenceTransactionError) == .recoveryRequired ? .transactionRecoveryRequired : .transactionReopenRequired) }
        lock.lock(); defer { lock.unlock() }
        if (try? pendingSettingsRecoveries().isEmpty) != true {
            return recordPersistenceFailure(.transactionRecoveryRequired)
        }
        if replayMetadataBlocked { return recordPersistenceFailure(.transactionRecoveryRequired) }
        if requiresBackupBeforePersist {
            if FileManager.default.fileExists(atPath: persistenceURL.path) {
                guard backupCorruptFileIfNeeded(
                    at: persistenceURL,
                    fileManager: .default
                ) != nil else {
                    return recordPersistenceFailure(.writeFailed)
                }
            }
            requiresBackupBeforePersist = false
        }
        var defaults = AppSettings.defaults
        defaults.agent.legacyApprovalPolicyOriginal = settings.agent.legacyApprovalPolicyOriginal
        return commit(defaults)
    }

    /// 当前 schema 版本（便捷读取）。
    public var settingsVersion: Int {
        settings.settingsVersion
    }

    // MARK: - 持久化

    private func commit(_ candidate: AppSettings) -> SettingsUpdateResult {
        switch persist(candidate) {
        case .success(let result):
            settings = candidate
            return .success(result)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func persist(_ candidate: AppSettings, metadata: ReplayMetadata? = nil) -> SettingsUpdateResult {
        guard !replayMetadataBlocked else {
            return recordPersistenceFailure(.transactionRecoveryRequired)
        }
        guard !requiresBackupBeforePersist else {
            return recordPersistenceFailure(.writeFailed)
        }
        if (try? pendingSettingsRecoveries().isEmpty) != true {
            return recordPersistenceFailure(.transactionRecoveryRequired)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            let settingsData = try encoder.encode(candidate)
            guard var object = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
                return recordPersistenceFailure(.encodingFailed)
            }
            let metadataData = try encoder.encode(metadata ?? replayMetadata)
            object[Self.replayKey] = try JSONSerialization.jsonObject(with: metadataData)
            data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } catch {
            return recordPersistenceFailure(.encodingFailed)
        }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return recordPersistenceFailure(.directoryCreationFailed)
        }
        do {
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            return recordPersistenceFailure(.writeFailed)
        }
        lastPersistenceError = nil
        return .success(.persisted)
    }

    private static func validReplayRecord(_ record: BL6SettingsReplayRecord) -> Bool {
        let policyKey = BL6SettingsApprovedInput.approvalPolicyKey
        if record.receipt.changedKeys.contains(policyKey) || record.frozenInput.changes[policyKey] != nil {
            guard record.operation == .apply,
                  Set(record.frozenInput.changes.keys) == [policyKey],
                  record.receipt.changedKeys.isEmpty || record.receipt.changedKeys == [policyKey] else { return false }
        }
        guard !record.requestID.isEmpty, !record.payloadDigest.isEmpty,
              !record.approvalBindingDigest.isEmpty,
              record.profileID.hasPrefix("/"),
              URL(fileURLWithPath: record.profileID, isDirectory: true).standardizedFileURL.path == record.profileID,
              !record.scope.isEmpty, !record.sessionID.isEmpty,
              !record.policyRevision.isEmpty, !record.grantEpoch.isEmpty,
              record.approvalExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              record.receipt.requestID == record.requestID,
              record.receipt.operation == record.operation,
              record.frozenInput.operation == record.operation,
              record.frozenInput.expectedRevision == record.receipt.previousRevision,
              record.operation != .configureProvider,
              !record.receipt.secretValuesExposed,
              record.receipt.rollbackValues.isEmpty,
              !record.receipt.receiptID.isEmpty,
              !record.receipt.previousRevision.isEmpty,
              !record.receipt.effectiveRevision.isEmpty,
              !record.rollbackValues.keys.contains("context_length"),
              !record.rollbackValues.keys.contains("history_rounds") else { return false }
        guard let secretValue = record.rollbackValues["credential.provider-api-key"],
              case .redactedSecret(_) = secretValue else { return false }
        guard (try? record.frozenInput.validateForApprovedEffect()) != nil,
              (try? BL6SettingsCatalog.production.validateApprovedMutation(
                  changedKeys: Array(record.frozenInput.changes.keys)
              )) != nil else { return false }
        guard (try? BL6SettingsCatalog.production.effectiveSnapshot(
            revision: "rollback", values: record.rollbackValues
        )) != nil,
              (try? BL6SettingsCatalog.production.validateApprovedMutation(
                  changedKeys: record.receipt.changedKeys
              )) != nil else { return false }
        return true
    }

    private static func decodeReplayMetadata(from data: Data) throws -> ReplayMetadata {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Retain legacy corrupt-file recovery for payloads that contain
            // no replay marker at all. If the marker is present in damaged
            // bytes, there may be completed effects to protect.
            if data.range(of: Data("\"_bl6Replay\"".utf8)) != nil {
                throw SettingsPersistenceError.transactionRecoveryRequired
            }
            return .empty
        }
        guard !object.keys.contains(where: { $0.hasPrefix("_bl6") && $0 != replayKey }) else {
            throw SettingsPersistenceError.transactionRecoveryRequired
        }
        guard let raw = object[replayKey] else { return .empty }
        guard let envelope = raw as? [String: Any],
              Set(envelope.keys) == Set(["version", "records"]),
              let rawRecords = envelope["records"] as? [String: Any],
              rawRecords.values.allSatisfy({ value in
                  guard let fields = value as? [String: Any],
                        Set(fields.keys) == Set([
                            "requestID", "payloadDigest", "frozenInput", "approvalBindingDigest", "profileID",
                            "scope", "sessionID", "policyRevision", "grantEpoch",
                            "approvalExpiresAt", "operation", "receipt", "rollbackValues"
                        ]),
                        let receipt = fields["receipt"] as? [String: Any],
                        Set(receipt.keys) == Set([
                            "receiptID", "requestID", "operation", "previousRevision",
                            "effectiveRevision", "changedKeys", "rollbackValues",
                            "visibleOnNextTurn", "secretValuesExposed"
                        ]) else { return false }
                  return true
              }),
              let encoded = try? JSONSerialization.data(withJSONObject: envelope),
              let metadata = try? JSONDecoder().decode(ReplayMetadata.self, from: encoded),
              let roundTrip = try? JSONEncoder().encode(metadata),
              let canonicalObject = try? JSONSerialization.jsonObject(with: roundTrip),
              (envelope as NSDictionary).isEqual(canonicalObject),
              metadata.version == 1,
              metadata.records.allSatisfy({ $0.key == $0.value.requestID && validReplayRecord($0.value) }),
              Set(metadata.records.values.map { $0.receipt.receiptID }).count == metadata.records.count else {
            throw SettingsPersistenceError.transactionRecoveryRequired
        }
        return metadata
    }

    private var pendingSettingsRecoveryDirectory: URL {
        persistenceURL.deletingLastPathComponent()
    }

    private func pendingURL(for operationID: UUID) -> URL {
        pendingSettingsRecoveryDirectory.appendingPathComponent(
            "\(Self.pendingRecoveryPrefix)\(operationID.uuidString)\(Self.pendingRecoverySuffix)"
        )
    }

    private func pendingSettingsRecoveries() throws -> [PendingSettingsRecovery] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: pendingSettingsRecoveryDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: pendingSettingsRecoveryDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        var result: [PendingSettingsRecovery] = []
        for file in files where file.lastPathComponent.hasPrefix(Self.pendingRecoveryPrefix) {
            guard file.lastPathComponent.hasSuffix(Self.pendingRecoverySuffix) else {
                throw SettingsPersistenceError.transactionRecoveryRequired
            }
            let idStart = file.lastPathComponent.index(
                file.lastPathComponent.startIndex,
                offsetBy: Self.pendingRecoveryPrefix.count
            )
            let idEnd = file.lastPathComponent.index(
                file.lastPathComponent.endIndex,
                offsetBy: -Self.pendingRecoverySuffix.count
            )
            guard let operationID = UUID(uuidString: String(file.lastPathComponent[idStart..<idEnd])),
                  let data = try? Data(contentsOf: file),
                  let transaction = try? JSONDecoder().decode(PendingSettingsRecovery.self, from: data),
                  markerKeysAreCanonical(data),
                  transaction.operationID == operationID,
                  transaction.scopeID == "settings:\(Self.fileName)",
                  transaction.sourceName == Self.fileName,
                  isSafeFileName(transaction.destinationName),
                  transaction.destinationName.hasPrefix(Self.fileName + ".corrupt-"),
                  transaction.payloadDigest.count == 64,
                  transaction.payloadDigest.allSatisfy({ $0.isHexDigit && ($0.isLowercase || $0.isNumber) }) else {
                throw SettingsPersistenceError.transactionRecoveryRequired
            }
            result.append(transaction)
        }
        return result.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }

    private func persistPendingSettingsRecovery(_ transaction: PendingSettingsRecovery) throws {
        let file = pendingURL(for: transaction.operationID)
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: file, options: .atomic)
        guard fsyncFile(file) else { throw SettingsPersistenceError.transactionRecoveryRequired }
        try fsyncDirectory(pendingSettingsRecoveryDirectory)
    }

    private func removePendingSettingsRecovery(_ transaction: PendingSettingsRecovery) throws {
        let file = pendingURL(for: transaction.operationID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try fsyncDirectory(pendingSettingsRecoveryDirectory)
    }

    private func matches(_ digest: String, at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return false }
        return Self.fingerprint(data) == digest
    }

    private func markerKeysAreCanonical(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return Set(object.keys) == [
            "operationID", "scopeID", "sourceName", "destinationName", "payloadDigest", "phase"
        ]
    }

    private func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fsyncFile(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        return Darwin.fsync(descriptor) == 0
    }

    private func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SettingsPersistenceError.transactionRecoveryRequired }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SettingsPersistenceError.transactionRecoveryRequired
        }
    }

    private func recordPersistenceFailure(_ error: SettingsPersistenceError) -> SettingsUpdateResult {
        lastPersistenceError = error
        onPersistError?(error)
        return .failure(error)
    }
}
