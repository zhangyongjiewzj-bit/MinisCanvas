import Foundation
import Observation
import Darwin
import MinisCore

@inline(__always)
private func checkedUsageAdd(_ lhs: Int, _ rhs: Int) -> Int? {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : result
}

@inline(__always)
private func saturatingUsageAdd(_ lhs: Int, _ rhs: Int) -> Int {
    checkedUsageAdd(lhs, rhs) ?? Int.max
}

// MARK: - 用量统计（波4）UsageStore
//
// 记录 LLM 调用用量：token 消耗（in/out/total）+ API 调用次数 +
// 分模型/供应商聚合 + 近期调用明细。UserDefaults 持久化（自恢复）。
//
// 只做加法：不修改 MinisCore 既有 API 行为。挂到 SettingsCenter 供设置页展示，
// 由 ChatStore 在流式回复的 usage 事件处调用 recordCall 写入。

// MARK: - 单次调用记录

/// 一次 LLM API 调用记录（内存 + 持久化）。
struct UsageRecord: Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let provider: String
    /// Stable provider record identity; nil for legacy records.
    let providerRecordID: String?
    /// Provider display name captured at call time.
    let providerDisplaySnapshot: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// 本次调用命中缓存的输入 token（读取旧缓存）。nil = 旧数据无该字段。
    let cacheReadTokens: Int?
    /// 本次调用写入缓存的输入 token（首次建缓存）。nil = 旧数据无该字段。
    let cacheCreationTokens: Int?

    /// Producer-established all-input denominator. Absent in legacy records.
    let cacheHitInputTokens: Int?
    let attribution: UsageAttribution?
    /// Producer-bound conversation identity. Legacy nil remains unassociated.
    let sessionID: String?

    var totalTokens: Int { saturatingUsageAdd(inputTokens, outputTokens) }

    /// C9：总输入 = 未缓存 + 缓存读 + 缓存写。与 `LLMUsage.totalInputTokens`（C-L1）同口径：
    /// 取各 Provider 已校验的“全部输入”事实 `cacheHitInputTokens`，缺失（旧记录）时退回 `inputTokens`。
    var totalInputTokens: Int { cacheHitInputTokens ?? inputTokens }
    /// 总输入口径下的单条合计（总输入 + 输出）。`totalTokens` 保持新鲜输入口径供持久化校验使用。
    var totalTokensIncludingCache: Int { saturatingUsageAdd(totalInputTokens, outputTokens) }

    init(id: UUID = UUID(), timestamp: Date = Date(), provider: String,
         providerRecordID: String? = nil, providerDisplaySnapshot: String? = nil,
         model: String,
         inputTokens: Int, outputTokens: Int,
         cacheReadTokens: Int? = nil, cacheCreationTokens: Int? = nil, cacheHitInputTokens: Int? = nil, attribution: UsageAttribution? = nil, sessionID: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.providerRecordID = providerRecordID
        self.providerDisplaySnapshot = providerDisplaySnapshot ?? provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheHitInputTokens = cacheHitInputTokens
        self.attribution = attribution
        self.sessionID = sessionID
    }
}

/// A projection of the existing call records, shared by full and filtered UI.
/// Unknown records and overflow keep the whole selected rate unknown; no clamp.
struct UsageCacheHitProjection: Equatable, Sendable {
    let rate: Double?

    init(records: [UsageRecord], expectedCallCount: Int? = nil) {
        guard expectedCallCount == nil || expectedCallCount == records.count else {
            rate = nil
            return
        }
        var readTotal = 0
        var inputTotal = 0
        for record in records {
            guard let input = record.cacheHitInputTokens, input >= 0,
                  let read = record.cacheReadTokens, read >= 0, read <= input,
                  let nextRead = checkedUsageAdd(readTotal, read),
                  let nextInput = checkedUsageAdd(inputTotal, input) else {
                rate = nil
                return
            }
            readTotal = nextRead
            inputTotal = nextInput
        }
        rate = inputTotal > 0 ? Double(readTotal) / Double(inputTotal) : nil
    }

    var text: String {
        guard let rate else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }
}

// MARK: - 分模型聚合

/// 分模型聚合统计（provider + model 维度）。
struct ModelUsageStats: Codable, Equatable, Sendable {
    let provider: String
    let providerRecordID: String?
    let providerDisplaySnapshot: String?
    let model: String
    var callCount: Int
    var inputTokens: Int
    var outputTokens: Int
    /// 累计命中缓存读取的输入 token。nil = 旧数据无该字段（按 0 处理）。
    var cacheReadTokens: Int?
    /// 累计写入缓存的输入 token。nil = 旧数据无该字段（按 0 处理）。
    var cacheCreationTokens: Int?

    var totalTokens: Int { saturatingUsageAdd(inputTokens, outputTokens) }
    /// 下游统一读取入口（nil → 0）。
    var cacheRead: Int { cacheReadTokens ?? 0 }
    var cacheCreation: Int { cacheCreationTokens ?? 0 }
}

enum UsageProviderLifecycle: String, Codable, Equatable, Sendable {
    case renamed
    case deleted
}

struct UsageProviderHistoryEvent: Codable, Equatable, Sendable {
    let kind: UsageProviderLifecycle
    let displaySnapshot: String?
    let timestamp: Date
}

struct UsageProviderHistory: Codable, Equatable, Sendable {
    let recordID: String
    var displaySnapshots: [String]
    var events: [UsageProviderHistoryEvent]
    var isDeleted: Bool
}

/// Provider identity state exposed to Settings and Chat consumers.  The
/// projection deliberately contains no credential, endpoint, or raw response
/// data; it is derived from usage aggregates plus the persisted provider
/// lifecycle history.
enum UsageProviderProjectionStatus: String, Codable, Equatable, Sendable {
    case active
    case deleted
}

/// A provider/model usage row with a current provider identity.  Historical
/// call records retain their original display snapshots, while this projection
/// follows a rename and marks a deleted provider without rewriting history.
struct UsageProviderModelProjection: Codable, Equatable, Sendable, Identifiable {
    let providerRecordID: String?
    let providerDisplayName: String
    let status: UsageProviderProjectionStatus
    let model: String
    let callCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    var id: String {
        "\(providerRecordID ?? "legacy:\(providerDisplayName)")|\(model)"
    }

    var totalTokens: Int { saturatingUsageAdd(inputTokens, outputTokens) }
}

enum UsageQueryAvailability: String, Codable, Equatable, Sendable {
    case known
    case unknown
}

/// Durable consumer state for Settings/Chat usage queries.  `empty` is only
/// emitted after a validated snapshot has been loaded (or a clear has been
/// durably committed), so the UI never mistakes startup hydration for zero
/// usage. Persistence failures reduce to a safe error state without exposing
/// lock paths, errno values, credentials, or raw provider responses.
enum UsageQueryConsumerState: String, Codable, Equatable, Sendable {
    case loading
    case empty
    case ready
    case error

    var isDurable: Bool {
        self != .loading
    }
}

struct UsageQueryResult: Equatable, Sendable {
    let availability: UsageQueryAvailability
    let records: [UsageRecord]

    var isKnown: Bool { availability == .known }
    var totalCalls: Int { records.count }
    var totalInputTokens: Int { records.reduce(0) { saturatingUsageAdd($0, $1.totalInputTokens) } }
    var totalOutputTokens: Int { records.reduce(0) { saturatingUsageAdd($0, $1.outputTokens) } }
    var totalTokens: Int { saturatingUsageAdd(totalInputTokens, totalOutputTokens) }

    /// Distinct model IDs in the result, suitable for a deterministic model
    /// filter state without exposing a provider's credentials or response.
    var modelIDs: [String] {
        Array(Set(records.map(\.model))).sorted()
    }

    /// Distinct local day buckets in the result, newest first.
    var dayBuckets: [String] {
        Array(Set(records.map { UsageStore.dayBucket(for: $0.timestamp) })).sorted(by: >)
    }

    /// Distinct display snapshots in deterministic lexical order.
    var providerDisplaySnapshots: [String] {
        Array(Set(records.map { $0.providerDisplaySnapshot ?? $0.provider })).sorted()
    }
}

// MARK: - 持久化快照

/// UsageStore 持久化快照（UserDefaults JSON 载荷）。
struct UsageSnapshot: Codable, Equatable, Sendable {
    var totalCalls: Int
    var totalInputTokens: Int
    var totalOutputTokens: Int
    /// 累计命中缓存读取的输入 token。nil = 旧数据无该字段（load 时按 0 处理）。
    var totalCacheReadTokens: Int?
    /// 累计写入缓存的输入 token。nil = 旧数据无该字段（load 时按 0 处理）。
    var totalCacheCreationTokens: Int?
    var modelUsage: [String: ModelUsageStats]
    var recentCalls: [UsageRecord]
    /// Full call history used by date/provider queries; nil in legacy snapshots.
    var callHistory: [UsageRecord]?
    /// Stable provider lifecycle metadata; nil in legacy snapshots.
    var providerHistory: [String: UsageProviderHistory]?
    var modelPricing: [String: UsageModelPricing]? = nil
    var mcpCalls: [UsageMCPCallRecord]? = nil
}

/// Failures from the cross-process persistence transaction are deliberately
/// typed and observable.  A failed lock must never look like a successful
/// (but silently dropped) usage event.
enum UsagePersistenceError: Error, Equatable, Sendable, CustomStringConvertible {
    case lockDirectoryUnavailable(Int32)
    case lockPathOutsideTemporaryDirectory
    case lockDirectoryIdentityChanged
    case lockFileOpenFailed(Int32)
    case lockFileNotRegularOrOwned
    case lockPathReplaced
    case lockAcquireFailed(Int32)
    case lockAcquireTimedOut
    case primaryAndBackupCorrupt
    case selfHealVerificationFailed
    case backupVerificationFailed
    case persistenceEncodingFailed
    case persistenceVerificationFailed
    case numericOverflow
    case cancelled

    var description: String {
        switch self {
        case let .lockDirectoryUnavailable(code): return "lock directory unavailable (errno \(code))"
        case .lockPathOutsideTemporaryDirectory: return "lock path escaped temporary directory"
        case .lockDirectoryIdentityChanged: return "lock directory identity changed"
        case let .lockFileOpenFailed(code): return "lock file open failed (errno \(code))"
        case .lockFileNotRegularOrOwned: return "lock file is not a regular file owned by this user"
        case .lockPathReplaced: return "lock path was replaced while acquiring the lock"
        case let .lockAcquireFailed(code): return "lock acquire failed (errno \(code))"
        case .lockAcquireTimedOut: return "lock acquire timed out"
        case .primaryAndBackupCorrupt: return "primary and backup usage snapshots are corrupt"
        case .selfHealVerificationFailed: return "self-healed primary snapshot failed verification"
        case .backupVerificationFailed: return "backup snapshot failed verification"
        case .persistenceEncodingFailed: return "usage snapshot encoding failed"
        case .persistenceVerificationFailed: return "usage snapshot verification failed"
        case .numericOverflow: return "usage counter overflow"
        case .cancelled: return "usage persistence cancelled"
        }
    }
}

fileprivate enum UsageMutation: Sendable {
    case record(UsageRecord)
    case setPricing(key: String, pricing: UsageModelPricing?)
    case recordMCP(UsageMCPCallRecord)
    case clear
    case rename(recordID: String, displayName: String, timestamp: Date)
    case delete(recordID: String, timestamp: Date)
}

fileprivate enum UsagePersistenceOperation: Sendable {
    case mutation(UsageMutation)
    case selfHeal
}

private let usageStoreMaxRecentCalls = 50

/// Stable, Sendable description of the UserDefaults domain owned by a
/// UsagePersistenceExecutor. Passing a domain instead of a UserDefaults
/// instance prevents composition from aliasing the same mutable defaults
/// object across UsageStore and other stores.
enum UsageDefaultsDomain: Sendable, Equatable {
    case standard
    case suite(String)
}

/// All lock acquisition, disk read-modify-write, and primary+backup commit
/// work lives on this actor.  The UsageStore facade is MainActor-isolated for
/// UI reads, but never blocks that actor on flock or filesystem I/O.
private actor UsagePersistenceExecutor {
    // Only the stable descriptor crosses the actor boundary. Each transaction
    // creates one fresh facade inside this actor and uses it consistently.
    private let domain: UsageDefaultsDomain
    private let storageKey: String
    private let backupStorageKey: String
    private let lockTimeout: Duration

    init(domain: UsageDefaultsDomain, storageKey: String, lockTimeout: Duration) {
        self.domain = domain
        self.storageKey = storageKey
        self.backupStorageKey = "\(storageKey).backup"
        self.lockTimeout = lockTimeout
    }

    func perform(_ operation: UsagePersistenceOperation) async -> Result<UsageSnapshot, UsagePersistenceError> {
        do {
            guard !Task.isCancelled else { throw UsagePersistenceError.cancelled }
            let lock = try await acquireLock()
            defer { release(lock) }
            try validateHeld(lock)
            guard let defaults = makeDefaults() else {
                throw UsagePersistenceError.persistenceVerificationFailed
            }

            let primaryData = defaults.data(forKey: storageKey)
            let backupData = defaults.data(forKey: backupStorageKey)
            let current: UsageSnapshot
            if let primaryData, let primary = UsageStore.decodeValidSnapshot(primaryData) {
                current = primary
            } else if let backupData, let backup = UsageStore.decodeValidSnapshot(backupData) {
                current = backup
                // Self-heal is transactional with the mutation while the
                // same validated lock is held; leave backup intact.
                defaults.set(backupData, forKey: storageKey)
                guard let healedData = defaults.data(forKey: storageKey),
                      UsageStore.decodeValidSnapshot(healedData) == backup else {
                    throw UsagePersistenceError.selfHealVerificationFailed
                }
            } else if primaryData != nil || backupData != nil {
                throw UsagePersistenceError.primaryAndBackupCorrupt
            } else {
                current = UsageSnapshot.empty
            }

            switch operation {
            case .selfHeal:
                // The self-heal write must finish while the same lock and
                // inode identity are still held; replacement is fail-closed.
                try validateHeld(lock)
                return .success(current)
            case let .mutation(mutation):
                guard let next = UsageStore.applying(mutation, to: current) else {
                    throw UsagePersistenceError.numericOverflow
                }
                try validateHeld(lock)
                try persist(next, defaults: defaults)
                try validateHeld(lock)
                return .success(next)
            }
        } catch let error as UsagePersistenceError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.persistenceVerificationFailed)
        }
    }

    private func persist(_ snapshot: UsageSnapshot, defaults: UserDefaults) throws {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            throw UsagePersistenceError.persistenceEncodingFailed
        }
        // Commit the last valid primary to backup first, then publish the new
        // primary. A crash between these writes leaves a recoverable pair.
        if let currentData = defaults.data(forKey: storageKey),
           UsageStore.decodeValidSnapshot(currentData) != nil {
            defaults.set(currentData, forKey: backupStorageKey)
            guard let verifiedBackup = defaults.data(forKey: backupStorageKey),
                  UsageStore.decodeValidSnapshot(verifiedBackup) ==
                    UsageStore.decodeValidSnapshot(currentData) else {
                throw UsagePersistenceError.backupVerificationFailed
            }
        }
        defaults.set(data, forKey: storageKey)
        guard let verified = defaults.data(forKey: storageKey),
              UsageStore.decodeValidSnapshot(verified) == snapshot else {
            throw UsagePersistenceError.persistenceVerificationFailed
        }
    }

    private func makeDefaults() -> UserDefaults? {
        switch domain {
        case .standard:
            return .standard
        case let .suite(name):
            return UserDefaults(suiteName: name)
        }
    }

    private struct LockHandle {
        let lockFD: Int32
        let directoryFD: Int32
        let filename: String
        let directoryDevice: dev_t
        let directoryInode: ino_t
        let lockDevice: dev_t
        let lockInode: ino_t
    }

    private func acquireLock() async throws -> LockHandle {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let resolvedTemporaryPath = try Self.realPath(temporaryDirectory.path)
        let lockDirectoryPath = URL(fileURLWithPath: resolvedTemporaryPath)
            .appendingPathComponent("MinisCanvasApp-UsageStoreLocks", isDirectory: true).path
        guard Self.isContained(lockDirectoryPath, within: resolvedTemporaryPath) else {
            throw UsagePersistenceError.lockPathOutsideTemporaryDirectory
        }
        let temporaryFD = try Self.openDirectoryByComponents(resolvedTemporaryPath)
        defer { close(temporaryFD) }

        var temporaryStat = stat()
        guard fstat(temporaryFD, &temporaryStat) == 0,
              (temporaryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw UsagePersistenceError.lockDirectoryUnavailable(errno)
        }

        let lockDirectoryName = URL(fileURLWithPath: lockDirectoryPath).lastPathComponent
        var lockDirectoryFD = openat(
            temporaryFD, lockDirectoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if lockDirectoryFD < 0, errno == ENOENT {
            guard mkdirat(temporaryFD, lockDirectoryName, 0o700) == 0 || errno == EEXIST else {
                throw UsagePersistenceError.lockDirectoryUnavailable(errno)
            }
            lockDirectoryFD = openat(
                temporaryFD, lockDirectoryName,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard lockDirectoryFD >= 0 else {
            throw UsagePersistenceError.lockDirectoryUnavailable(errno)
        }
        var lockDirectoryStat = stat()
        guard fstat(lockDirectoryFD, &lockDirectoryStat) == 0 else {
            let code = errno
            close(lockDirectoryFD)
            throw UsagePersistenceError.lockDirectoryUnavailable(code)
        }
        guard (lockDirectoryStat.st_mode & S_IFMT) == S_IFDIR,
              lockDirectoryStat.st_uid == getuid() else {
            close(lockDirectoryFD)
            throw UsagePersistenceError.lockDirectoryUnavailable(EACCES)
        }
        // Tighten an owner-owned directory left by an older version or a
        // permissive umask; never accept a shared writable lock directory.
        if (lockDirectoryStat.st_mode & 0o777) != 0o700 {
            guard fchmod(lockDirectoryFD, 0o700) == 0 else {
                let code = errno
                close(lockDirectoryFD)
                throw UsagePersistenceError.lockDirectoryUnavailable(code)
            }
            guard fstat(lockDirectoryFD, &lockDirectoryStat) == 0,
                  (lockDirectoryStat.st_mode & 0o777) == 0o700 else {
                let code = errno
                close(lockDirectoryFD)
                throw UsagePersistenceError.lockDirectoryUnavailable(code)
            }
        }

        let filename = "usage-\(UsageStore.lockToken(for: storageKey)).lock"
        let lockFD = openat(
            lockDirectoryFD, filename,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        guard lockFD >= 0 else {
            close(lockDirectoryFD)
            throw UsagePersistenceError.lockFileOpenFailed(errno)
        }
        var openedStat = stat()
        guard fstat(lockFD, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_uid == getuid(),
              (openedStat.st_mode & 0o777) <= 0o600 else {
            close(lockFD)
            close(lockDirectoryFD)
            throw UsagePersistenceError.lockFileNotRegularOrOwned
        }
        guard try Self.pathIdentityMatches(
            directoryFD: lockDirectoryFD, filename: filename, expected: openedStat
        ) else {
            close(lockFD)
            close(lockDirectoryFD)
            throw UsagePersistenceError.lockPathReplaced
        }

        let deadline = ContinuousClock.now + lockTimeout
        while true {
            guard !Task.isCancelled else {
                close(lockFD); close(lockDirectoryFD)
                throw UsagePersistenceError.cancelled
            }
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { break }
            let code = errno
            if code != EWOULDBLOCK && code != EAGAIN {
                close(lockFD); close(lockDirectoryFD)
                throw UsagePersistenceError.lockAcquireFailed(code)
            }
            guard ContinuousClock.now < deadline else {
                close(lockFD); close(lockDirectoryFD)
                throw UsagePersistenceError.lockAcquireTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        var heldDirectoryStat = stat()
        guard fstat(lockDirectoryFD, &heldDirectoryStat) == 0,
              heldDirectoryStat.st_dev == lockDirectoryStat.st_dev,
              heldDirectoryStat.st_ino == lockDirectoryStat.st_ino,
              try Self.pathIdentityMatches(
                  directoryFD: lockDirectoryFD, filename: filename, expected: openedStat
              ) else {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD); close(lockDirectoryFD)
            throw UsagePersistenceError.lockPathReplaced
        }
        let handle = LockHandle(
            lockFD: lockFD,
            directoryFD: lockDirectoryFD,
            filename: filename,
            directoryDevice: heldDirectoryStat.st_dev,
            directoryInode: heldDirectoryStat.st_ino,
            lockDevice: openedStat.st_dev,
            lockInode: openedStat.st_ino
        )
        try validateHeld(handle)
        return handle
    }

    private func release(_ lock: LockHandle) {
        // Callers validate the directory and lock inode before returning a
        // result. Release itself only unlocks and closes the already-validated
        // descriptors; it has no silent success path for a failed validation.
        _ = flock(lock.lockFD, LOCK_UN)
        close(lock.lockFD)
        close(lock.directoryFD)
    }

    private func validateHeld(_ lock: LockHandle) throws {
        var directoryStat = stat()
        var lockStat = stat()
        guard fstat(lock.directoryFD, &directoryStat) == 0,
              fstat(lock.lockFD, &lockStat) == 0,
              directoryStat.st_dev == lock.directoryDevice,
              directoryStat.st_ino == lock.directoryInode,
              lockStat.st_dev == lock.lockDevice,
              lockStat.st_ino == lock.lockInode,
              try Self.pathIdentityMatches(
                  directoryFD: lock.directoryFD,
                  filename: lock.filename,
                  expected: lockStat
              ) else {
            throw UsagePersistenceError.lockPathReplaced
        }
    }

    private static func realPath(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved: String? = path.withCString { pointer in
            guard realpath(pointer, &buffer) != nil else { return nil }
            // P3-CONC-01(250): deprecated String(cString:) stopped decoding at the first
            // nul byte and decoded the remaining bytes as lossy UTF-8. realpath()
            // guarantees a nul-terminated pathname inside the PATH_MAX buffer, so
            // truncating at that same nul and decoding with String(decoding:as:) is the
            // length- and error-behaviour-identical replacement named by the
            // deprecation message; the empty-result and error paths below are untouched.
            let terminator = buffer.firstIndex(of: 0) ?? buffer.count
            return String(
                decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        guard let resolved else {
            throw UsagePersistenceError.lockDirectoryUnavailable(errno)
        }
        guard !resolved.isEmpty else {
            throw UsagePersistenceError.lockPathOutsideTemporaryDirectory
        }
        var checked = stat()
        guard lstat(resolved, &checked) == 0,
              (checked.st_mode & S_IFMT) == S_IFDIR else {
            throw UsagePersistenceError.lockDirectoryUnavailable(errno)
        }
        return resolved
    }

    private static func isContained(_ path: String, within root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func openDirectoryByComponents(_ path: String) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw UsagePersistenceError.lockDirectoryUnavailable(errno)
        }
        for component in path.split(separator: "/") {
            let next = openat(
                descriptor, String(component),
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard next >= 0 else {
                let code = errno
                close(descriptor)
                throw UsagePersistenceError.lockDirectoryUnavailable(code)
            }
            var componentStat = stat()
            guard fstat(next, &componentStat) == 0,
                  (componentStat.st_mode & S_IFMT) == S_IFDIR else {
                close(next); close(descriptor)
                throw UsagePersistenceError.lockDirectoryUnavailable(errno)
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func pathIdentityMatches(
        directoryFD: Int32, filename: String, expected: stat
    ) throws -> Bool {
        var named = stat()
        guard fstatat(directoryFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw UsagePersistenceError.lockPathReplaced
        }
        return named.st_dev == expected.st_dev && named.st_ino == expected.st_ino
    }
}

fileprivate extension UsageSnapshot {
    static let empty = UsageSnapshot(
        totalCalls: 0, totalInputTokens: 0, totalOutputTokens: 0,
        totalCacheReadTokens: 0, totalCacheCreationTokens: 0,
        modelUsage: [:], recentCalls: [], callHistory: [], providerHistory: [:]
    )
}

// MARK: - UsageStore

/// UserDefaults 持久化的用量统计存储。
@MainActor
@Observable
final class UsageStore {
    /// 保留的近期调用明细条数上限。
    static let maxRecentCalls = usageStoreMaxRecentCalls
    /// 默认持久化 key（UserDefaults）。
    static let defaultStorageKey = "usagestore.snapshot"
    /// The actor's bounded lock wait. Tests use this same value when
    /// asserting a timeout, so no test-specific production path is involved.
    static let persistenceLockTimeout: Duration = .milliseconds(750)

    /// Stable test/helper seam; the production implementation still opens
    /// every component relative to a trusted directory fd.
    nonisolated static var persistenceLockDirectoryPath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCanvasApp-UsageStoreLocks", isDirectory: true).path
    }

    nonisolated static func persistenceLockPath(for storageKey: String) -> String {
        URL(fileURLWithPath: persistenceLockDirectoryPath)
            .appendingPathComponent("usage-\(lockToken(for: storageKey)).lock").path
    }

    private(set) var totalCalls = 0
    private(set) var totalInputTokens = 0
    private(set) var totalOutputTokens = 0
    /// 累计命中缓存读取的输入 token（缓存命中量）。
    private(set) var totalCacheReadTokens = 0
    /// 累计写入缓存的输入 token（缓存建立量）。
    private(set) var totalCacheCreationTokens = 0
    /// 分模型聚合（key = `provider|model`）。
    private(set) var modelUsage: [String: ModelUsageStats] = [:]
    /// 近期调用明细（最新在前）。
    private(set) var recentCalls: [UsageRecord] = []
    /// 完整调用历史，供持久化查询使用。
    private(set) var callHistory: [UsageRecord] = []
    /// 稳定 provider ID 对应的显示名与 rename/delete 历史。
    private(set) var providerHistory: [String: UsageProviderHistory] = [:]
    private(set) var modelPricing: [String: UsageModelPricing] = [:]
    private(set) var mcpCalls: [UsageMCPCallRecord] = []

    func recordMCPCall(_ record: UsageMCPCallRecord) { enqueue(.mutation(.recordMCP(record))) }

    func setModelPricing(_ pricing: UsageModelPricing?, for key: String) {
        guard !key.isEmpty, pricing?.isValid ?? true else { return }
        enqueue(.mutation(.setPricing(key: key, pricing: pricing)))
    }
    /// A validated snapshot has been applied to this in-memory projection.
    /// This prevents startup's temporary empty arrays from becoming a false
    /// "no usage" state in bound Settings/Chat consumers.
    private(set) var hasLoadedSnapshot = false

    private let persistenceExecutor: UsagePersistenceExecutor
    let defaultsDomain: UsageDefaultsDomain
    private var persistenceTail: Task<Void, Never>?

    /// Latest asynchronous persistence diagnostic. The in-memory projection
    /// remains available, while callers can await `waitForPersistence()` to
    /// obtain a durable success/failure result.
    private(set) var lastPersistenceError: UsagePersistenceError?
    private(set) var persistenceFailureCount = 0

    /// - Parameters:
    ///   - domain: 持久化域描述（测试注入 suite 名称，避免污染真实用户数据）。
    ///   - storageKey: 持久化 key。
    init(
        domain: UsageDefaultsDomain? = nil,
        storageKey: String = UsageStore.defaultStorageKey,
        persistenceLockTimeout: Duration = UsageStore.persistenceLockTimeout
    ) {
        let resolvedDomain: UsageDefaultsDomain
        if let domain {
            resolvedDomain = domain
        } else {
            do {
                resolvedDomain = try FormalTestIsolationPaths.resolveCurrentProcess()
                    .map { .suite($0.userDefaultsSuiteName) } ?? .standard
            } catch {
                preconditionFailure("Invalid formal test preferences contract")
            }
        }
        self.defaultsDomain = resolvedDomain
        self.persistenceExecutor = UsagePersistenceExecutor(
            domain: resolvedDomain, storageKey: storageKey,
            lockTimeout: persistenceLockTimeout
        )

        // Initialization reads and any self-heal write are performed by the
        // persistence actor. The MainActor starts with an empty projection and
        // receives the validated snapshot asynchronously, so it never touches
        // UserDefaults during construction.
        enqueue(.selfHeal)
    }

    /// Await all queued persistence work. This is the deterministic test and
    /// recovery boundary; ordinary UI call sites keep using the legacy
    /// synchronous facade and receive failures through diagnostics.
    @discardableResult
    func waitForPersistence() async -> Bool {
        if let tail = persistenceTail {
            await tail.value
        }
        return lastPersistenceError == nil
    }

    /// 总 token 消耗（in + out）。
    var totalTokens: Int { saturatingUsageAdd(totalInputTokens, totalOutputTokens) }

    /// The same record projection used by the filtered settings consumer.
    var cacheHitProjection: UsageCacheHitProjection {
        // Legacy snapshots can retain recent calls without the full call history.
        UsageCacheHitProjection(records: callHistory, expectedCallCount: totalCalls)
    }

    /// Numeric compatibility accessor; unknown rates remain explicit in UI text.
    var cacheHitRate: Double { cacheHitProjection.rate ?? 0 }
    var cacheHitRateText: String { cacheHitProjection.text }

    /// Observable production state for usage query consumers.  It is derived
    /// from the same UsageStore instance already bound to SettingsCenter and
    /// ChatStore, so consumers cannot drift to a second in-memory source.
    var usageQueryState: UsageQueryConsumerState {
        if lastPersistenceError != nil { return .error }
        if !hasLoadedSnapshot { return .loading }
        return callHistory.isEmpty ? .empty : .ready
    }

    /// 分模型聚合（按 totalTokens 降序，供 UI 展示）。
    var sortedModelUsage: [ModelUsageStats] {
        modelUsage.values.sorted {
            if $0.totalTokens != $1.totalTokens {
                return $0.totalTokens > $1.totalTokens
            }
            // Dictionary.values has no ordering guarantee. Keep equal-total
            // provider/model rows stable for the production usage projection.
            let lhsProvider = $0.providerRecordID ?? $0.provider
            let rhsProvider = $1.providerRecordID ?? $1.provider
            if lhsProvider != rhsProvider {
                return lhsProvider < rhsProvider
            }
            if $0.model != $1.model {
                return $0.model < $1.model
            }
            let lhsDisplay = $0.providerDisplaySnapshot ?? $0.provider
            let rhsDisplay = $1.providerDisplaySnapshot ?? $1.provider
            return lhsDisplay < rhsDisplay
        }
    }

    /// Current provider identity projection for Settings/Chat consumers.
    ///
    /// The aggregate remains keyed by stable provider ID, so a rename updates
    /// the display name for all model rows while preserving historical call
    /// snapshots. A deleted provider remains visible with an explicit status,
    /// allowing consumers to offer recovery instead of silently showing zero.
    var providerUsageProjection: [UsageProviderModelProjection] {
        sortedModelUsage.map { stats in
            let history = stats.providerRecordID.flatMap { providerHistory[$0] }
            let displayName = (history?.displaySnapshots.last
                ?? stats.providerDisplaySnapshot
                ?? stats.provider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return UsageProviderModelProjection(
                providerRecordID: stats.providerRecordID,
                providerDisplayName: displayName.isEmpty ? stats.provider : displayName,
                status: history?.isDeleted == true ? .deleted : .active,
                model: stats.model,
                callCount: stats.callCount,
                inputTokens: stats.inputTokens,
                outputTokens: stats.outputTokens,
                cacheReadTokens: stats.cacheRead,
                cacheCreationTokens: stats.cacheCreation
            )
        }
    }

    /// 记录一次 LLM API 调用（此整数 API 的输入包含缓存；token 用量非负钳制）。
    /// - Parameters:
    ///   - cacheReadTokens: 本次命中缓存读取的输入 token（默认 0 = 无缓存命中）。
    ///   - cacheCreationTokens: 本次首次写入缓存的输入 token（默认 0）。
    func recordCall(provider: String, model: String, inputTokens: Int, outputTokens: Int,
                    cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0,
                    providerRecordID: String? = nil, providerDisplaySnapshot: String? = nil,
                    timestamp: Date = Date(), sessionID: String? = nil) {
        enqueueUsageRecord(provider: provider, model: model, inputTokens: inputTokens,
            outputTokens: outputTokens, cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens, cacheHitInputTokens: max(0, inputTokens),
            providerRecordID: providerRecordID, providerDisplaySnapshot: providerDisplaySnapshot,
            timestamp: timestamp, sessionID: sessionID)
    }

    /// Typed production usage keeps the producer's denominator and unknown cache fields.
    func recordCall(provider: String, model: String, usage: LLMUsage,
                    providerRecordID: String? = nil, providerDisplaySnapshot: String? = nil,
                    timestamp: Date = Date(), attribution: UsageAttribution? = nil, sessionID: String? = nil) {
        enqueueUsageRecord(provider: provider, model: model, inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens, cacheReadTokens: usage.cacheReadInputTokens,
            cacheCreationTokens: usage.cacheCreationInputTokens, cacheHitInputTokens: usage.cacheHitInputTokens,
            providerRecordID: providerRecordID, providerDisplaySnapshot: providerDisplaySnapshot,
            timestamp: timestamp, attribution: attribution, sessionID: sessionID)
    }

    private func enqueueUsageRecord(provider: String, model: String, inputTokens: Int, outputTokens: Int,
                                    cacheReadTokens: Int?, cacheCreationTokens: Int?, cacheHitInputTokens: Int?,
                                    providerRecordID: String?, providerDisplaySnapshot: String?, timestamp: Date,
                                    attribution: UsageAttribution? = nil, sessionID: String? = nil) {
        let record = UsageRecord(
            timestamp: timestamp,
            provider: provider,
            providerRecordID: Self.normalizedProviderRecordID(providerRecordID),
            providerDisplaySnapshot: providerDisplaySnapshot,
            model: model,
            inputTokens: max(0, inputTokens), outputTokens: max(0, outputTokens),
            cacheReadTokens: cacheReadTokens.map { max(0, $0) },
            cacheCreationTokens: cacheCreationTokens.map { max(0, $0) },
            cacheHitInputTokens: cacheHitInputTokens.flatMap { $0 >= 0 ? $0 : nil },
            attribution: attribution, sessionID: sessionID
        )
        enqueue(.mutation(.record(record)))
    }

    /// Async durable boundary for tests, helper processes, and callers that
    /// need an explicit success/failure result. The legacy synchronous API
    /// above remains non-blocking and exposes any failure via diagnostics.
    @discardableResult
    func recordCallAndWait(
        provider: String, model: String, inputTokens: Int, outputTokens: Int,
        cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0,
        providerRecordID: String? = nil, providerDisplaySnapshot: String? = nil,
        timestamp: Date = Date()
    ) async -> Bool {
        recordCall(
            provider: provider, model: model, inputTokens: inputTokens,
            outputTokens: outputTokens, cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens, providerRecordID: providerRecordID,
            providerDisplaySnapshot: providerDisplaySnapshot, timestamp: timestamp
        )
        return await waitForPersistence()
    }

    /// 清空全部用量统计。
    func clear() {
        enqueue(.mutation(.clear))
    }

    @discardableResult
    func clearAndWait() async -> Bool {
        clear()
        return await waitForPersistence()
    }

    /// 聚合 key（provider + model 维度）。
    nonisolated static func key(provider: String, model: String) -> String {
        key(provider: provider, model: model, providerRecordID: nil)
    }

    /// Stable aggregation key when a provider record ID is available.
    nonisolated static func key(provider: String, model: String, providerRecordID: String?) -> String {
        "\(providerRecordID ?? provider)|\(model)"
    }

    /// Local day bucket; persisted timestamps are never rewritten.
    nonisolated static func dayBucket(for date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Query the existing call history without creating a second store.
    ///
    /// An empty match is `.unknown`; a matching record whose totals are zero
    /// remains `.known`, which keeps unavailable data distinct from zero use.
    func query(
        providerRecordID: String? = nil,
        dateInterval: DateInterval? = nil,
        dayBucket: String? = nil,
        models: Set<String> = []
    ) -> UsageQueryResult {
        let normalizedProviderID = Self.normalizedProviderRecordID(providerRecordID)
        let normalizedModels = Set(models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
        if let dateInterval,
           (!dateInterval.start.timeIntervalSince1970.isFinite
                || !dateInterval.end.timeIntervalSince1970.isFinite
                || dateInterval.start > dateInterval.end) {
            return UsageQueryResult(availability: .unknown, records: [])
        }
        let matches = callHistory.filter { record in
            if let normalizedProviderID, record.providerRecordID != normalizedProviderID {
                return false
            }
            if let dateInterval,
               !(record.timestamp >= dateInterval.start && record.timestamp < dateInterval.end) {
                return false
            }
            if let dayBucket, Self.dayBucket(for: record.timestamp) != dayBucket {
                return false
            }
            if !normalizedModels.isEmpty && !normalizedModels.contains(record.model) {
                return false
            }
            return true
        }
        .sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        return UsageQueryResult(
            availability: matches.isEmpty ? .unknown : .known,
            records: matches
        )
    }

    /// Query by raw date bounds, validating the range before Foundation's
    /// `DateInterval` initializer can trap on an inverted interval.
    func query(
        providerRecordID: String? = nil,
        startDate: Date,
        endDate: Date,
        dayBucket: String? = nil,
        models: Set<String> = []
    ) -> UsageQueryResult {
        guard startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite,
              startDate <= endDate else {
            return UsageQueryResult(availability: .unknown, records: [])
        }
        return query(
            providerRecordID: providerRecordID,
            dateInterval: DateInterval(start: startDate, end: endDate),
            dayBucket: dayBucket,
            models: models
        )
    }

    /// Record a provider rename without rewriting historical call snapshots.
    func renameProvider(recordID: String, displayName: String, at timestamp: Date = Date()) {
        let id = Self.normalizedProviderRecordID(recordID)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !name.isEmpty else { return }
        let mutation = UsageMutation.rename(recordID: id, displayName: name, timestamp: timestamp)
        enqueue(.mutation(mutation))
    }

    /// Mark a provider deleted while retaining its usage history.
    func deleteProvider(recordID: String, at timestamp: Date = Date()) {
        guard let id = Self.normalizedProviderRecordID(recordID) else { return }
        let mutation = UsageMutation.delete(recordID: id, timestamp: timestamp)
        enqueue(.mutation(mutation))
    }

    // MARK: - 持久化

    /// A second copy lets a torn/corrupt primary write recover the last
    /// structurally valid snapshot without manufacturing a zeroed history.
    nonisolated fileprivate static func decodeValidSnapshot(_ data: Data) -> UsageSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data),
              snapshot.totalCalls >= 0,
              snapshot.totalInputTokens >= 0,
              snapshot.totalOutputTokens >= 0,
              (snapshot.totalCacheReadTokens ?? 0) >= 0,
              (snapshot.totalCacheCreationTokens ?? 0) >= 0,
              snapshot.recentCalls.count <= usageStoreMaxRecentCalls,
              snapshot.recentCalls.count <= snapshot.totalCalls,
              checkedUsageAdd(snapshot.totalInputTokens, snapshot.totalOutputTokens) != nil,
              snapshot.recentCalls.allSatisfy(Self.isValidRecord),
              snapshot.callHistory?.allSatisfy(Self.isValidRecord) ?? true,
              snapshot.modelUsage.values.allSatisfy(Self.isValidStats),
              snapshot.providerHistory?.values.allSatisfy(Self.isValidProviderHistory) ?? true,
              snapshot.modelPricing?.values.allSatisfy({ $0.isValid }) ?? true,
              snapshot.mcpCalls?.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite }) ?? true else {
            return nil
        }
        if let callHistory = snapshot.callHistory {
            guard callHistory.count <= snapshot.totalCalls else {
                return nil
            }
            // Some legacy payloads retained only a bounded/truncated history.
            // Aggregate totals and model stats remain authoritative in that
            // case; verify history sums only when the history is complete.
            if callHistory.count == snapshot.totalCalls {
                guard let inputTotal = safeSum(callHistory.map(\.inputTokens)),
                      let outputTotal = safeSum(callHistory.map(\.outputTokens)),
                      let cacheReadTotal = safeSum(callHistory.map { $0.cacheReadTokens ?? 0 }),
                      let cacheCreationTotal = safeSum(callHistory.map { $0.cacheCreationTokens ?? 0 }),
                      inputTotal == snapshot.totalInputTokens,
                      outputTotal == snapshot.totalOutputTokens,
                      cacheReadTotal == (snapshot.totalCacheReadTokens ?? 0),
                      cacheCreationTotal == (snapshot.totalCacheCreationTokens ?? 0) else {
                    return nil
                }
            }
        }
        let stats = snapshot.modelUsage.values
        guard let callTotal = safeSum(stats.map(\.callCount)),
              let inputTotal = safeSum(stats.map(\.inputTokens)),
              let outputTotal = safeSum(stats.map(\.outputTokens)),
              let cacheReadTotal = safeSum(stats.map { $0.cacheReadTokens ?? 0 }),
              let cacheCreationTotal = safeSum(stats.map { $0.cacheCreationTokens ?? 0 }),
              callTotal == snapshot.totalCalls,
              inputTotal == snapshot.totalInputTokens,
              outputTotal == snapshot.totalOutputTokens,
              cacheReadTotal == (snapshot.totalCacheReadTokens ?? 0),
              cacheCreationTotal == (snapshot.totalCacheCreationTokens ?? 0) else {
            return nil
        }
        return snapshot
    }

    nonisolated private static func safeSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    nonisolated private static func isValidRecord(_ record: UsageRecord) -> Bool {
        record.timestamp.timeIntervalSince1970.isFinite
            && record.inputTokens >= 0
            && record.outputTokens >= 0
            && checkedUsageAdd(record.inputTokens, record.outputTokens) != nil
            && (record.cacheReadTokens ?? 0) >= 0
            && (record.cacheCreationTokens ?? 0) >= 0
    }

    nonisolated private static func isValidStats(_ stats: ModelUsageStats) -> Bool {
        stats.callCount >= 0
            && stats.inputTokens >= 0
            && stats.outputTokens >= 0
            && checkedUsageAdd(stats.inputTokens, stats.outputTokens) != nil
            && (stats.cacheReadTokens ?? 0) >= 0
            && (stats.cacheCreationTokens ?? 0) >= 0
    }

    nonisolated private static func isValidProviderHistory(_ history: UsageProviderHistory) -> Bool {
        history.events.allSatisfy { $0.timestamp.timeIntervalSince1970.isFinite }
    }

    /// Stable across processes (unlike Swift's randomized Hasher). Different
    /// suites may contend when they use the same key, which is safe and rare.
    nonisolated fileprivate static func lockToken(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func apply(_ snapshot: UsageSnapshot) {
        totalCalls = snapshot.totalCalls
        totalInputTokens = snapshot.totalInputTokens
        totalOutputTokens = snapshot.totalOutputTokens
        totalCacheReadTokens = snapshot.totalCacheReadTokens ?? 0
        totalCacheCreationTokens = snapshot.totalCacheCreationTokens ?? 0
        modelUsage = snapshot.modelUsage
        recentCalls = snapshot.recentCalls
        callHistory = snapshot.callHistory ?? snapshot.recentCalls
        providerHistory = snapshot.providerHistory ?? [:]
        modelPricing = snapshot.modelPricing ?? [:]
        mcpCalls = Array((snapshot.mcpCalls ?? []).suffix(usageStoreMaxRecentCalls))
        if providerHistory.isEmpty {
            callHistory.forEach(observeProvider)
        }
        hasLoadedSnapshot = true
    }


    private func enqueue(_ operation: UsagePersistenceOperation) {
        let previous = persistenceTail
        let executor = persistenceExecutor
        persistenceTail = Task { [weak self] in
            if let previous { await previous.value }
            let result = await executor.perform(operation)
            guard let self else { return }
            switch result {
            case let .success(snapshot):
                // This is a projection of the actor's committed result, not
                // a MainActor read-modify-write operation.
                self.apply(snapshot)
                self.lastPersistenceError = nil
            case let .failure(error):
                self.lastPersistenceError = error
                self.persistenceFailureCount += 1
            }
        }
    }

    fileprivate nonisolated static func applying(
        _ mutation: UsageMutation, to input: UsageSnapshot
    ) -> UsageSnapshot? {
        var snapshot = input
        switch mutation {
        case .clear:
            var empty = UsageSnapshot.empty
            empty.modelPricing = input.modelPricing
            return empty
        case let .recordMCP(record):
            guard record.timestamp.timeIntervalSince1970.isFinite else { return nil }
            var calls = snapshot.mcpCalls ?? []
            calls.append(record)
            snapshot.mcpCalls = Array(calls.suffix(usageStoreMaxRecentCalls))
        case let .setPricing(key, pricing):
            guard !key.isEmpty, pricing?.isValid ?? true else { return nil }
            var prices = snapshot.modelPricing ?? [:]
            prices[key] = pricing
            snapshot.modelPricing = prices
        case let .record(record):
            let key = key(
                provider: record.provider, model: record.model,
                providerRecordID: record.providerRecordID
            )
            var stats = snapshot.modelUsage[key] ?? ModelUsageStats(
                provider: record.provider,
                providerRecordID: record.providerRecordID,
                providerDisplaySnapshot: record.providerDisplaySnapshot,
                model: record.model,
                callCount: 0, inputTokens: 0, outputTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0
            )
            guard let totalCalls = checkedUsageAdd(snapshot.totalCalls, 1),
                  let totalInput = checkedUsageAdd(snapshot.totalInputTokens, record.inputTokens),
                  let totalOutput = checkedUsageAdd(snapshot.totalOutputTokens, record.outputTokens),
                  let totalRead = checkedUsageAdd(snapshot.totalCacheReadTokens ?? 0, record.cacheReadTokens ?? 0),
                  let totalCreation = checkedUsageAdd(snapshot.totalCacheCreationTokens ?? 0, record.cacheCreationTokens ?? 0),
                  let calls = checkedUsageAdd(stats.callCount, 1),
                  let input = checkedUsageAdd(stats.inputTokens, record.inputTokens),
                  let output = checkedUsageAdd(stats.outputTokens, record.outputTokens),
                  let read = checkedUsageAdd(stats.cacheReadTokens ?? 0, record.cacheReadTokens ?? 0),
                  let creation = checkedUsageAdd(stats.cacheCreationTokens ?? 0, record.cacheCreationTokens ?? 0) else {
                return nil
            }
            snapshot.totalCalls = totalCalls
            snapshot.totalInputTokens = totalInput
            snapshot.totalOutputTokens = totalOutput
            snapshot.totalCacheReadTokens = totalRead
            snapshot.totalCacheCreationTokens = totalCreation
            var history = snapshot.callHistory ?? snapshot.recentCalls
            history.append(record)
            snapshot.callHistory = history
            snapshot.recentCalls.insert(record, at: 0)
            if snapshot.recentCalls.count > usageStoreMaxRecentCalls {
                snapshot.recentCalls.removeLast(snapshot.recentCalls.count - usageStoreMaxRecentCalls)
            }
            stats.callCount = calls
            stats.inputTokens = input
            stats.outputTokens = output
            stats.cacheReadTokens = read
            stats.cacheCreationTokens = creation
            snapshot.modelUsage[key] = stats
            if let id = record.providerRecordID {
                let display = (record.providerDisplaySnapshot ?? record.provider)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !display.isEmpty {
                    var providerHistory = snapshot.providerHistory ?? [:]
                    var provider = providerHistory[id] ?? UsageProviderHistory(
                        recordID: id, displaySnapshots: [], events: [], isDeleted: false
                    )
                    if provider.displaySnapshots.last != display {
                        provider.displaySnapshots.append(display)
                    }
                    providerHistory[id] = provider
                    snapshot.providerHistory = providerHistory
                }
            }
        case let .rename(recordID, displayName, timestamp):
            var providerHistory = snapshot.providerHistory ?? [:]
            var history = providerHistory[recordID] ?? UsageProviderHistory(
                recordID: recordID, displaySnapshots: [], events: [], isDeleted: false
            )
            if history.displaySnapshots.last != displayName {
                history.displaySnapshots.append(displayName)
            }
            history.events.append(UsageProviderHistoryEvent(
                kind: .renamed, displaySnapshot: displayName, timestamp: timestamp
            ))
            providerHistory[recordID] = history
            snapshot.providerHistory = providerHistory
        case let .delete(recordID, timestamp):
            var providerHistory = snapshot.providerHistory ?? [:]
            var history = providerHistory[recordID] ?? UsageProviderHistory(
                recordID: recordID, displaySnapshots: [], events: [], isDeleted: false
            )
            history.isDeleted = true
            history.events.append(UsageProviderHistoryEvent(
                kind: .deleted, displaySnapshot: history.displaySnapshots.last, timestamp: timestamp
            ))
            providerHistory[recordID] = history
            snapshot.providerHistory = providerHistory
        }
        return snapshot
    }

    private func observeProvider(_ record: UsageRecord) {
        guard let id = record.providerRecordID else { return }
        let display = (record.providerDisplaySnapshot ?? record.provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        var history = providerHistory[id] ?? UsageProviderHistory(
            recordID: id,
            displaySnapshots: [],
            events: [],
            isDeleted: false
        )
        if history.displaySnapshots.last != display {
            history.displaySnapshots.append(display)
        }
        providerHistory[id] = history
    }

    nonisolated private static func normalizedProviderRecordID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
