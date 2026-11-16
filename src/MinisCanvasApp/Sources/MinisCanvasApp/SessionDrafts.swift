import Foundation
import CryptoKit
import Darwin
import Observation
import SwiftUI
import CanvasCore
import MinisCore

// MARK: - C3-3 会话自动保存 + Agent 可撤销（ComfyUI 工作流持久化 V2 模式）
//
// 借鉴 comfyui_frontend `useWorkflowAutoSave`（512ms 防抖落盘 / 按 tab draft /
// 会话指针 / V1→V2 迁移 / 卸载前 flush）：
//   1. DraftStore        —— 通用防抖草稿存储（key → 内容 → 512ms 防抖落盘，flush 兜底）
//   2. CanvasDraft       —— 画布图（节点/连线/位置/内容/模型配置）的 Codable 快照 DTO
//   3. ActionRecord      —— Agent 工具调用历史栈条目（工具名/参数摘要/时间/结果摘要）
//   4. RecordingToolExecutor —— 包住真实 ToolExecutor，每次调用记录 ActionRecord
//   5. ActionHistoryView —— 历史展示视图（可挂接到侧栏；当前经聊天命令「工具历史」可见）

// MARK: - 通用防抖草稿存储

/// 磁盘草稿信封：payload + schemaVersion + 保存时间。
/// payload 为调用方编码后的 JSON（Data 经 JSONEncoder 以 base64 落盘）。
struct DraftEnvelope: Codable, Equatable {
    var schemaVersion: Int
    var savedAt: Date
    var payload: Data
    /// SHA-256 of the decoded payload. Optional for compatibility with
    /// envelopes written before integrity protection was added.
    var payloadSHA256: String?

    init(
        schemaVersion: Int,
        savedAt: Date,
        payload: Data,
        payloadSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case savedAt
        case payload
        case payloadSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        payload = try container.decode(Data.self, forKey: .payload)
        // Missing checksum is an old, still-readable envelope. New writes
        // always include one via DraftStore.persist(_:payload:generation:).
        payloadSHA256 = try container.decodeIfPresent(String.self, forKey: .payloadSHA256)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(payloadSHA256, forKey: .payloadSHA256)
    }
}

/// 草稿加载失败原因（F4：版本安全 —— 旧版无迁移不静默接受 / 未来版拒绝加载 / 损坏隔离）。
/// `load(key:)` 返回 nil 时可读 `DraftStore.lastLoadError` 获取具体原因。
enum DraftLoadError: Error, Equatable {
    /// 文件内容无法解码为 DraftEnvelope（损坏 / 非草稿文件）
    case decodeFailed
    /// 草稿键不是单一安全文件名，拒绝任何路径逃逸或特殊组件
    case invalidKey
    /// 旧版本草稿且未装配 migration 钩子 —— 不静默接受，已隔离备份（quarantine 目录）
    case unmigratableVersion(found: Int, current: Int)
    /// 未来版本草稿（由更新版本的 App 写入）—— 当前版本拒绝加载，已隔离备份
    case futureVersion(found: Int, current: Int)
}

/// 可观测的磁盘操作失败；调用方无需解析 POSIX errno 或敏感原文。
enum DraftStoreIOError: Error, Equatable {
    case invalidKey
    case missing
    case unsafe
    case io
    case cancelled
}

/// 通用防抖草稿存储（ComfyUI 工作流持久化 V2 模式）：
/// - `scheduleSave`：立即记录最新 payload（内存），`debounceInterval`（默认 512ms）后落盘；
///   防抖窗口内再次调用会取消前一次写入 —— 连续改动只落盘最后一次，不丢数据。
/// - `flushNow` / `flushAll`：App 退出 / 切会话 / 测试时强制落盘（等价 ComfyUI beforeunload flush）。
/// - 按 key 隔离：`canvas`（画布图）/ `chatDraft.<sessionID>`（会话输入草稿）。
/// - 版本安全（F4）：
///   · schemaVersion < current 且装配 `migration` 钩子 → 逐级升级后返回；
///   · schemaVersion < current 且无钩子（或钩子拒绝）→ 明确报错 + 隔离备份，不静默接受旧格式；
///   · schemaVersion > current（更新版 App 写入）→ 拒绝加载 + 隔离备份，给出可读错误；
///   · 损坏 JSON → 隔离备份。失败原因见 `lastLoadError`，被拒草稿保留在 `quarantineDirectory`。
final class DraftStore: @unchecked Sendable {
    /// 画布图草稿 key
    static let canvasKey = "canvas"
    /// 会话输入草稿 key（按会话隔离，等价 ComfyUI 按 tab draft）
    static func chatDraftKey(sessionID: UUID) -> String { "chatDraft.\(sessionID.uuidString)" }

    /// 当前草稿版本号（升级时 +1 并配 migration 钩子）
    static let currentSchemaVersion = 1

    /// 根目录（草稿落 `<root>/drafts/<key>.json`）
    let directory: URL
    /// 防抖间隔（测试可调小加速；默认 512ms 对齐 ComfyUI）
    var debounceInterval: Duration = .milliseconds(512)
    /// 版本迁移钩子：(payload, 旧版本号) → 新版本 payload；返回 nil = 拒绝该草稿
    var migration: (@Sendable (Data, Int) -> Data?)?
    /// Focused recovery test seam; invoked once immediately before the final
    /// inode re-open, never used by production call sites.
    var quarantineRecheckHook: (@Sendable () -> Void)?

    var draftsDirectory: URL { directory.appendingPathComponent("drafts", isDirectory: true) }
    /// 隔离备份目录（F4：被拒草稿原文移到这里，不静默丢弃 —— `<root>/drafts/quarantine/`）
    var quarantineDirectory: URL { draftsDirectory.appendingPathComponent("quarantine", isDirectory: true) }

    private let lock = NSLock()
    private let ioLock = NSLock()
    private var latestPayloads: [String: Data] = [:]
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UInt64] = [:]
    /// 最近一次加载失败原因（key → 错误；加载成功后清除）
    private var loadErrors: [String: DraftLoadError] = [:]
    private var ioErrors: [String: DraftStoreIOError] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        if draftsFD >= 0 { Darwin.close(draftsFD) }
        if quarantineFD >= 0 { Darwin.close(quarantineFD) }
        if rootFD >= 0 { Darwin.close(rootFD) }
    }

    // These descriptors are opened once and then used for every operation.
    // A later rename of the URL cannot redirect an already-open descriptor.
    private var rootFD: Int32 = -1
    private var draftsFD: Int32 = -1
    private var quarantineFD: Int32 = -1

    private typealias DraftIOError = DraftStoreIOError

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct RegularFileRead {
        let data: Data
        let identity: FileIdentity
    }

    // MARK: 写入（防抖）

    /// 防抖落盘：立即记录最新 payload（内存可读），debounceInterval 后写盘。
    /// 防抖窗口内再次调用会取消前一次任务 —— 连续改动只落盘最后一次。
    func scheduleSave(key: String, payload: Data, onCompletion: (@Sendable (Bool) -> Void)? = nil) {
        lock.lock()
        guard Self.isSafeKey(key) else {
            loadErrors[key] = .invalidKey
            ioErrors[key] = .invalidKey
            lock.unlock()
            return
        }
        latestPayloads[key] = payload
        let generation = (generations[key] ?? 0) &+ 1
        generations[key] = generation
        pendingTasks[key]?.cancel()
        let interval = debounceInterval
        let task = Task {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            if let result = self.writeToDisk(key: key, generation: generation) {
                onCompletion?(result)
            }
        }
        pendingTasks[key] = task
        lock.unlock()
    }

    /// 立即落盘（取消待写任务）：App 退出 / 切会话 / 测试断言
    @discardableResult
    func flushNow(key: String) -> Bool {
        lock.lock()
        guard Self.isSafeKey(key) else {
            loadErrors[key] = .invalidKey
            ioErrors[key] = .invalidKey
            lock.unlock()
            return false
        }
        pendingTasks[key]?.cancel()
        pendingTasks[key] = nil
        let hasPayload = latestPayloads[key] != nil && generations[key] != nil
        lock.unlock()
        guard hasPayload else {
            setIOError(nil, for: key)
            return true
        }
        return flushLatest(key: key)
    }

    /// 全部草稿立即落盘（App 退出前统一 flush）
    @discardableResult
    func flushAll() -> Bool {
        lock.lock()
        let keys = Array(latestPayloads.keys)
        lock.unlock()
        return keys.allSatisfy { flushNow(key: $0) }
    }

    /// 取消待写任务且不落盘（如发送后清空草稿）
    func cancelPending(key: String) {
        lock.lock()
        guard Self.isSafeKey(key) else {
            loadErrors[key] = .invalidKey
            ioErrors[key] = .invalidKey
            lock.unlock()
            return
        }
        pendingTasks[key]?.cancel()
        pendingTasks[key] = nil
        generations[key] = (generations[key] ?? 0) &+ 1
        ioErrors[key] = .cancelled
        lock.unlock()
    }

    /// 内存中最新 payload（防抖窗口内尚未落盘也可读；测试断言防抖语义用）
    func latestPayload(for key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return latestPayloads[key]
    }

    /// 最近一次 `load(key:)` 失败原因（F4 版本安全诊断；加载成功/无文件时为 nil）
    func lastLoadError(for key: String) -> DraftLoadError? {
        lock.lock(); defer { lock.unlock() }
        return loadErrors[key]
    }

    /// 最近一次写入 / 清理 / 隔离的粗粒度错误；不暴露路径、payload 或 errno。
    func lastIOError(for key: String) -> DraftStoreIOError? {
        lock.lock(); defer { lock.unlock() }
        return ioErrors[key]
    }

    // MARK: 读取 / 恢复

    /// 磁盘 payload（经过版本迁移）；不存在 / 不可解返回 nil
    func load(key: String) -> Data? {
        guard Self.isSafeKey(key) else {
            setLoadError(.invalidKey, for: key)
            return nil
        }
        ioLock.lock()
        defer { ioLock.unlock() }
        return loadUnlocked(key: key)
    }

    /// 磁盘上是否存在该草稿（崩溃恢复检测用）
    func hasDraft(key: String) -> Bool {
        load(key: key) != nil
    }

    /// 磁盘草稿键列表
    func draftKeys() -> [String] {
        ioLock.lock()
        defer { ioLock.unlock() }
        let fd: Int32
        do { fd = try openDraftsDirectory(createIfMissing: false) }
        catch { return [] }
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return []
        }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", name != "quarantine",
                  name.hasSuffix(".json") else { continue }
            let key = String(name.dropLast(5))
            guard Self.isSafeKey(key), regularFileExists(name: name, in: fd) else { continue }
            result.append(key)
        }
        return result.sorted()
    }

    /// 清除草稿（取消待写 + 删磁盘文件）：用户选择丢弃 / 发送后清理
    @discardableResult
    func clear(key: String) -> Bool {
        lock.lock()
        guard Self.isSafeKey(key) else {
            loadErrors[key] = .invalidKey
            ioErrors[key] = .invalidKey
            lock.unlock()
            return false
        }
        pendingTasks[key]?.cancel()
        pendingTasks[key] = nil
        latestPayloads[key] = nil
        let generation = (generations[key] ?? 0) &+ 1
        generations[key] = generation
        lock.unlock()

        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock()
        let stillCurrent = generations[key] == generation && latestPayloads[key] == nil
        lock.unlock()
        guard stillCurrent else {
            setIOError(.cancelled, for: key)
            return false
        }
        let fd: Int32
        do {
            fd = try openDraftsDirectory(createIfMissing: false, forMutation: true)
        } catch DraftStoreIOError.missing {
            setIOError(nil, for: key)
            return true
        } catch let error as DraftStoreIOError {
            setIOError(error, for: key)
            return false
        } catch {
            setIOError(.io, for: key)
            return false
        }
        let name = "\(key).json"
        let file: Int32
        do {
            file = try openRegularFile(name: name, in: fd)
        } catch DraftStoreIOError.missing {
            setIOError(nil, for: key)
            return true
        } catch let error as DraftStoreIOError {
            setIOError(error, for: key)
            return false
        } catch {
            setIOError(.io, for: key)
            return false
        }
        Darwin.close(file)
        guard name.withCString({ unlinkat(fd, $0, 0) }) == 0 else {
            let error: DraftStoreIOError = errno == ENOENT ? .missing : .io
            setIOError(error, for: key)
            return error == .missing
        }
        guard fsync(fd) == 0 else {
            setIOError(.io, for: key)
            return false
        }
        setIOError(nil, for: key)
        return true
    }

    // MARK: 内部

    private func writeToDisk(key: String, generation: UInt64) -> Bool? {
        lock.lock()
        guard generations[key] == generation else { lock.unlock(); return nil }
        pendingTasks[key] = nil
        let payload = latestPayloads[key]
        lock.unlock()
        guard let payload else { return nil }
        switch persistIfCurrent(key: key, payload: payload, generation: generation) {
        case .written: return true
        case .failed: return false
        case .skipped: return nil
        }
    }

    private enum PersistResult { case written, skipped, failed }

    private func flushLatest(key: String) -> Bool {
        while true {
            lock.lock()
            guard let payload = latestPayloads[key], let generation = generations[key] else {
                lock.unlock()
                return true
            }
            lock.unlock()
            switch persistIfCurrent(key: key, payload: payload, generation: generation) {
            case .failed: return false
            case .skipped: continue
            case .written:
                lock.lock()
                let unchanged = generations[key] == generation
                lock.unlock()
                if unchanged { return true }
            }
        }
    }

    private func persistIfCurrent(key: String, payload: Data, generation: UInt64) -> PersistResult {
        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock()
        let current = generations[key] == generation && latestPayloads[key] == payload
        lock.unlock()
        guard current else { return .skipped }
        do {
            try persist(key: key, payload: payload, generation: generation)
            setIOError(nil, for: key)
            return .written
        } catch let error as DraftStoreIOError {
            setIOError(error, for: key)
            return error == .cancelled ? .skipped : .failed
        } catch {
            setIOError(.io, for: key)
            return .failed
        }
    }

    private func persist(key: String, payload: Data, generation: UInt64) throws {
        let fd = try openDraftsDirectory(createIfMissing: true)
        let envelope = DraftEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            savedAt: Date(),
            payload: payload,
            payloadSHA256: Self.sha256Hex(payload)
        )
        let data = try encoder.encode(envelope)
        let finalName = "\(key).json"
        var temporaryName: String?
        var temporaryFD: Int32 = -1
        for _ in 0..<16 {
            let candidate = ".\(key).tmp-\(UUID().uuidString)"
            let opened = candidate.withCString {
                openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            }
            if opened >= 0 {
                temporaryName = candidate
                temporaryFD = opened
                break
            }
            if errno != EEXIST { throw DraftIOError.io }
        }
        guard let temporaryName else { throw DraftIOError.io }
        var renamed = false
        defer {
            if temporaryFD >= 0 { Darwin.close(temporaryFD) }
            if !renamed {
                let removed = temporaryName.withCString { unlinkat(fd, $0, 0) }
                if removed != 0, errno != ENOENT {
                    setIOError(.io, for: key)
                }
            }
        }
        try validateRegularFD(temporaryFD)
        try writeAll(data, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else { throw DraftIOError.io }
        guard Darwin.close(temporaryFD) == 0 else { temporaryFD = -1; throw DraftIOError.io }
        temporaryFD = -1
        // Hold the state lock across the final check and rename. A concurrent
        // cancelPending can therefore either invalidate this generation first
        // (and make the write fail), or observe the completed rename after it.
        lock.lock()
        guard generations[key] == generation,
              latestPayloads[key] == payload else {
            lock.unlock()
            throw DraftIOError.cancelled
        }
        guard renameat(fd, temporaryName, fd, finalName) == 0 else {
            lock.unlock()
            throw DraftIOError.io
        }
        renamed = true
        guard fsync(fd) == 0 else {
            lock.unlock()
            throw DraftIOError.io
        }
        lock.unlock()
    }

    private func loadUnlocked(key: String) -> Data? {
        let loaded: RegularFileRead
        do {
            loaded = try readRegularFile(key: key)
        } catch DraftIOError.missing {
            setLoadError(nil, for: key)
            setIOError(nil, for: key)
            return nil
        } catch let error as DraftStoreIOError {
            setLoadError(.decodeFailed, for: key)
            setIOError(error, for: key)
            return nil
        } catch {
            setLoadError(.decodeFailed, for: key)
            setIOError(.io, for: key)
            return nil
        }
        let data = loaded.data
        let sourceIdentity = loaded.identity
        // 损坏 / 不可解码：隔离备份原文 + 可读错误，不静默吞掉
        guard let envelope = try? decoder.decode(DraftEnvelope.self, from: data) else {
            setLoadError(.decodeFailed, for: key)
            quarantine(key: key, expectedIdentity: sourceIdentity)
            return nil
        }
        var payload = envelope.payload
        var version = envelope.schemaVersion

        // A checksum-bearing envelope whose payload was truncated or changed
        // must never reach a domain decoder. Keep the original bytes in
        // quarantine and expose only a coarse, non-sensitive error.
        if let expectedDigest = envelope.payloadSHA256,
           expectedDigest != Self.sha256Hex(payload) {
            setLoadError(.decodeFailed, for: key)
            quarantine(key: key, expectedIdentity: sourceIdentity)
            return nil
        }

        // 未来版本（更新版 App 写入）：拒绝加载 + 隔离备份，避免把新格式当旧数据误读
        if version > Self.currentSchemaVersion {
            setLoadError(.futureVersion(found: version, current: DraftStore.currentSchemaVersion), for: key)
            quarantine(key: key, expectedIdentity: sourceIdentity)
            return nil
        }

        // 旧版本：必须经 migration 钩子逐级升级；无钩子（或钩子拒绝）→ 明确报错 + 隔离备份，
        // 绝不把旧格式 payload 当当前版本静默返回（F4 修复点）
        if version < Self.currentSchemaVersion {
            guard let migrate = migration else {
                setLoadError(.unmigratableVersion(found: version, current: Self.currentSchemaVersion), for: key)
                quarantine(key: key, expectedIdentity: sourceIdentity)
                return nil
            }
            while version < Self.currentSchemaVersion {
                guard let next = migrate(payload, version) else {
                    setLoadError(.unmigratableVersion(found: envelope.schemaVersion, current: Self.currentSchemaVersion), for: key)
                    quarantine(key: key, expectedIdentity: sourceIdentity)
                    return nil
                }
                payload = next
                version += 1
            }
        }

        setLoadError(nil, for: key)
        return payload
    }

    /// 隔离备份（F4）：把被拒草稿原文移入 `quarantine/`，不删除、不静默丢弃，
    /// 供用户恢复 / 事后诊断。隔离失败不阻断主流程（load 已返回 nil + lastLoadError）。
    @discardableResult
    private func quarantine(key: String, expectedIdentity: FileIdentity) -> Bool {
        let drafts: Int32
        do {
            drafts = try openDraftsDirectory(createIfMissing: false)
        } catch let error as DraftStoreIOError {
            setIOError(error, for: key)
            return false
        } catch {
            setIOError(.io, for: key)
            return false
        }
        let sourceName = "\(key).json"
        let source: Int32
        do {
            source = try openRegularFile(name: sourceName, in: drafts)
        } catch let error as DraftStoreIOError {
            setIOError(error, for: key)
            return false
        } catch {
            setIOError(.io, for: key)
            return false
        }
        defer { Darwin.close(source) }
        guard let sourceIdentity = identity(of: source), sourceIdentity == expectedIdentity else {
            setIOError(.unsafe, for: key)
            return false
        }
        let quarantine: Int32
        do {
            quarantine = try openQuarantineDirectory(createIfMissing: true)
        } catch {
            setIOError(.io, for: key)
            return false
        }
        // Keep the historical first-quarantine name for compatibility. Once
        // it exists, use a unique name so every rejected snapshot survives.
        let preferredName = sourceName
        let destinationName = regularFileExists(name: preferredName, in: quarantine)
            ? "\(key)-\(UUID().uuidString).json"
            : preferredName
        // Re-open immediately before the rename and compare dev/inode while
        // holding the state lock. A replacement between the initial read and
        // this point is rejected rather than moving an unrelated file.
        lock.lock()
        let recheckHook = quarantineRecheckHook
        quarantineRecheckHook = nil
        recheckHook?()
        let confirmed: Int32
        do {
            confirmed = try openRegularFile(name: sourceName, in: drafts)
        } catch {
            lock.unlock()
            setIOError((error as? DraftStoreIOError) ?? .io, for: key)
            return false
        }
        let sameIdentity = identity(of: confirmed).map { $0 == expectedIdentity } == true
        Darwin.close(confirmed)
        guard sameIdentity else {
            lock.unlock()
            setIOError(.unsafe, for: key)
            return false
        }
        let renamed = sourceName.withCString { sourcePtr in
            destinationName.withCString { destinationPtr in
                renameat(drafts, sourcePtr, quarantine, destinationPtr)
            }
        }
        guard renamed == 0 else {
            lock.unlock()
            setIOError(.io, for: key)
            return false
        }
        lock.unlock()
        guard fsync(drafts) == 0, fsync(quarantine) == 0 else {
            setIOError(.io, for: key)
            return false
        }
        setIOError(nil, for: key)
        return true
    }

    private func setLoadError(_ error: DraftLoadError?, for key: String) {
        lock.lock(); loadErrors[key] = error; lock.unlock()
    }

    private func setIOError(_ error: DraftStoreIOError?, for key: String) {
        lock.lock()
        if let error {
            ioErrors[key] = error
        } else {
            ioErrors[key] = nil
        }
        lock.unlock()
    }

    private func openDraftsDirectory(createIfMissing: Bool, forMutation: Bool = false) throws -> Int32 {
        if draftsFD >= 0 { return draftsFD }
        let root = try openTrustedRoot(createIfMissing: createIfMissing, forMutation: forMutation)
        if createIfMissing {
            let made = "drafts".withCString { mkdirat(root, $0, mode_t(0o700)) }
            guard made == 0 || errno == EEXIST else { throw DraftIOError.io }
        }
        let drafts = "drafts".withCString {
            openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard drafts >= 0 else {
            if errno == ENOENT { throw DraftIOError.missing }
            throw DraftIOError.unsafe
        }
        do {
            if createIfMissing || forMutation {
                // Historical writers may have created this owned child with
                // 0755. Tighten the anchored descriptor before any write;
                // read-only access keeps the strict private-mode contract.
                try hardenOwnedDirectoryFD(drafts)
            } else {
                try validateDirectoryFD(drafts)
            }
            draftsFD = drafts
            return drafts
        } catch {
            Darwin.close(drafts)
            throw error
        }
    }

    /// Resolve the configured root from a trusted parent descriptor, one
    /// component at a time. No intermediate component is ever followed as a
    /// symlink, and the resulting root descriptor is retained for all I/O.
    private func openTrustedRoot(createIfMissing: Bool, forMutation: Bool = false) throws -> Int32 {
        if rootFD >= 0 { return rootFD }
        // `FileManager.temporaryDirectory` is `/var/...` on macOS, while
        // `/var` is a platform alias for `/private/var`. Normalize that
        // stable spelling lexically; every actual component, including
        // missing ones, is still opened or created below with O_NOFOLLOW.
        let path = try anchoredDirectoryPath()
        guard path.hasPrefix("/") else { throw DraftIOError.unsafe }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let rootName = components.last, rootName != ".", rootName != ".." else {
            throw DraftIOError.unsafe
        }
        var parent = "/".withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parent >= 0 else { throw DraftIOError.unsafe }
        do {
            for component in components.dropLast() {
                let name = String(component)
                guard name != ".", name != ".." else { throw DraftIOError.unsafe }
                if createIfMissing {
                    let made = name.withCString { mkdirat(parent, $0, mode_t(0o700)) }
                    guard made == 0 || errno == EEXIST else { throw DraftIOError.io }
                }
                let child = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else {
                    if errno == ENOENT { throw DraftIOError.missing }
                    throw DraftIOError.unsafe
                }
                do {
                    try validateDirectoryTypeFD(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(parent)
                parent = child
            }
            let name = String(rootName)
            if createIfMissing {
                let made = name.withCString { mkdirat(parent, $0, mode_t(0o700)) }
                guard made == 0 || errno == EEXIST else { throw DraftIOError.io }
            }
            let root = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard root >= 0 else {
                if errno == ENOENT { throw DraftIOError.missing }
                throw DraftIOError.unsafe
            }
            do {
                if createIfMissing || forMutation {
                    // SessionStore/other root-level persistence may have
                    // created this owner-owned directory with Foundation's
                    // default 0755 mode before DraftStore is attached.  The
                    // descriptor is already O_NOFOLLOW-anchored; tighten it
                    // in place and re-stat before accepting it.  Foreign
                    // owners and non-directories still fail closed.
                    try hardenOwnedDirectoryFD(root)
                } else {
                    try validateDirectoryFD(root)
                }
            } catch {
                Darwin.close(root)
                throw error
            }
            Darwin.close(parent)
            rootFD = root
            return root
        } catch {
            Darwin.close(parent)
            throw error
        }
    }

    private func anchoredDirectoryPath() throws -> String {
        try DarwinSystemPathResolver.resolve(directory)
    }

    private func openQuarantineDirectory(createIfMissing: Bool) throws -> Int32 {
        if quarantineFD >= 0 { return quarantineFD }
        let drafts = try openDraftsDirectory(createIfMissing: createIfMissing)
        if createIfMissing {
            let made = "quarantine".withCString { mkdirat(drafts, $0, mode_t(0o700)) }
            guard made == 0 || errno == EEXIST else { throw DraftIOError.io }
        }
        let quarantine = "quarantine".withCString {
            openat(drafts, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard quarantine >= 0 else {
            if errno == ENOENT { throw DraftIOError.missing }
            throw DraftIOError.unsafe
        }
        do {
            try validateDirectoryFD(quarantine)
            quarantineFD = quarantine
            return quarantine
        } catch {
            Darwin.close(quarantine)
            throw error
        }
    }

    private func readRegularFile(key: String) throws -> RegularFileRead {
        let drafts = try openDraftsDirectory(createIfMissing: false)
        let name = "\(key).json"
        let fd = try openRegularFile(name: name, in: drafts)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DraftIOError.io }
        return RegularFileRead(
            data: try readAll(from: fd, expectedSize: info.st_size),
            identity: FileIdentity(device: info.st_dev, inode: info.st_ino)
        )
    }

    private func openRegularFile(name: String, in directoryFD: Int32) throws -> Int32 {
        let fd = name.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ENOENT { throw DraftIOError.missing }
            if errno == ELOOP || errno == ENOTDIR { throw DraftIOError.unsafe }
            throw DraftIOError.io
        }
        do {
            try validateRegularFD(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func identity(of fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func regularFileExists(name: String, in directoryFD: Int32) -> Bool {
        let fd = name.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        do {
            try validateRegularFD(fd)
            return true
        } catch {
            return false
        }
    }

    private func validateDirectoryFD(_ fd: Int32) throws {
        try validateDirectoryTypeFD(fd)
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
            throw DraftIOError.unsafe
        }
    }

    private func hardenOwnedDirectoryFD(_ fd: Int32) throws {
        try validateDirectoryTypeFD(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid() else {
            throw DraftIOError.unsafe
        }
        if (info.st_mode & 0o077) != 0 {
            guard fchmod(fd, mode_t(0o700)) == 0 else { throw DraftIOError.io }
        }
        try validateDirectoryFD(fd)
    }

    private func validateDirectoryTypeFD(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { throw DraftIOError.unsafe }
    }

    private func validateRegularFD(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0,
              (info.st_mode & 0o700) <= 0o600 else { throw DraftIOError.unsafe }
    }

    private func readAll(from fd: Int32, expectedSize: off_t) throws -> Data {
        var data = Data()
        if expectedSize > 0, expectedSize <= off_t(Int.max) {
            data.reserveCapacity(Int(expectedSize))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw DraftIOError.io
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { rawBuffer in
                Darwin.write(fd, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw DraftIOError.io
            }
            guard written > 0 else { throw DraftIOError.io }
            offset += written
        }
    }

    private static func isSafeKey(_ key: String) -> Bool {
        guard !key.isEmpty, key != ".", key != ".." else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "/" && scalar != "\\"
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 非画布 transcript / draft 原子恢复

/// Durable consumer for chat transcript snapshots. It uses the existing
/// DraftStore's locked, atomic envelope while adding a typed stream fence;
/// this keeps late async responses from replacing a newer or terminal draft.
final class ChatTranscriptPersistence: @unchecked Sendable {
    struct Receipt: Equatable, Sendable {
        let identity: ChatTranscriptIdentity
        let sequence: UInt64
        let terminal: Bool
    }

    let draftStore: DraftStore
    let redactor: ChatTranscriptRedactor
    private let lock = NSLock()

    init(draftStore: DraftStore, redactor: ChatTranscriptRedactor = ChatTranscriptRedactor(secretValues: [])) {
        self.draftStore = draftStore
        self.redactor = redactor
    }

    static func draftKey(sessionID: String) -> String {
        "chatTranscript." + sessionID
    }

    /// Persist a full redacted transcript snapshot at one contiguous stream
    /// sequence. The final write uses the same atomic DraftStore path as chat
    /// drafts; duplicate and late writes are rejected before any I/O.
    @discardableResult
    func persist(
        identity: ChatTranscriptIdentity,
        sequence: UInt64,
        terminal: Bool,
        entries: [ChatTranscriptEntry]
    ) throws -> Receipt {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.draftKey(sessionID: identity.sessionID)
        let previous = try loadEnvelope(forKey: key)
        if let previous {
            guard previous.identity.sessionID == identity.sessionID else {
                throw ChatTranscriptPersistenceError.identityConflict
            }
            if previous.identity != identity {
                guard previous.terminal, sequence == 0 else {
                    throw ChatTranscriptPersistenceError.identityConflict
                }
            } else {
                guard !previous.terminal else { throw ChatTranscriptPersistenceError.lateWrite }
                if sequence == previous.sequence {
                    throw ChatTranscriptPersistenceError.duplicateWrite
                }
                guard sequence == previous.sequence &+ 1 else {
                    throw ChatTranscriptPersistenceError.lateWrite
                }
            }
        } else {
            guard sequence == 0 else { throw ChatTranscriptPersistenceError.lateWrite }
        }

        let safeEntries = entries.map(redactor.redact)
        let envelope = ChatTranscriptEnvelope(
            schemaVersion: ChatTranscriptEnvelope.currentSchemaVersion,
            identity: identity,
            sequence: sequence,
            terminal: terminal,
            entries: safeEntries,
            savedAt: Date()
        )
        guard let payload = try? JSONEncoder().encode(envelope) else {
            throw ChatTranscriptPersistenceError.writeFailed
        }
        draftStore.scheduleSave(key: key, payload: payload)
        guard draftStore.flushNow(key: key) else {
            throw ChatTranscriptPersistenceError.writeFailed
        }
        return Receipt(identity: identity, sequence: sequence, terminal: terminal)
    }

    /// UI-facing adapter: formatter strips attachment payload/path material
    /// and this consumer applies the final format-aware redaction before save.
    @discardableResult
    func persist(
        identity: ChatTranscriptIdentity,
        sequence: UInt64,
        terminal: Bool,
        messages: [ChatMessageUI]
    ) throws -> Receipt {
        try persist(
            identity: identity,
            sequence: sequence,
            terminal: terminal,
            entries: ChatTranscriptFormatter.persistedEntries(messages, redactor: redactor)
        )
    }

    /// Reopen reads the same durable envelope after process restart. A corrupt
    /// or quarantined draft becomes an actionable recovery error, never a
    /// silent empty transcript.
    func reopen(sessionID: String) throws -> ChatTranscriptEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.draftKey(sessionID: sessionID)
        guard let envelope = try loadEnvelope(forKey: key) else {
            return nil
        }
        // The filename is only a lookup hint: a moved or stale but otherwise
        // valid envelope must never be restored into a different session.
        guard envelope.identity.sessionID == sessionID else {
            throw ChatTranscriptPersistenceError.identityConflict
        }
        return envelope
    }

    /// Production consumer seam for restart recovery. The projection is
    /// non-throwing so a transcript view can always render a comprehensible
    /// state; persistence failures become an explicit reopen/discard action.
    /// Entries have already crossed the redaction boundary in `reopen`.
    func reopenProjection(sessionID: String) -> ChatTranscriptConsumerProjection {
        do {
            guard let envelope = try reopen(sessionID: sessionID) else {
                return .empty(sessionID: sessionID)
            }
            return .restored(sessionID: sessionID, envelope: envelope)
        } catch let error as ChatTranscriptPersistenceError {
            return .recoveryRequired(sessionID: sessionID, action: error.userAction)
        } catch {
            // `reopen` currently emits typed errors only, but keep this seam
            // fail-closed if its storage implementation gains another error.
            return .recoveryRequired(
                sessionID: sessionID,
                action: ChatTranscriptPersistenceError.recoveryRequired.userAction
            )
        }
    }

    @discardableResult
    func clear(sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return draftStore.clear(key: Self.draftKey(sessionID: sessionID))
    }

    private func loadEnvelope(forKey key: String) throws -> ChatTranscriptEnvelope? {
        guard let data = draftStore.load(key: key) else {
            if draftStore.lastLoadError(for: key) != nil {
                throw ChatTranscriptPersistenceError.recoveryRequired
            }
            return nil
        }
        guard let envelope = try? JSONDecoder().decode(ChatTranscriptEnvelope.self, from: data),
              envelope.schemaVersion == ChatTranscriptEnvelope.currentSchemaVersion else {
            throw ChatTranscriptPersistenceError.recoveryRequired
        }
        return envelope
    }
}

// MARK: - 画布草稿 DTO（NodeGraph 的 Codable 快照）
//
// CanvasCore 的 NodeGraph/CanvasNode 非 Codable（UI 线程模型），落盘用本 DTO：
// 节点（类型/标题/位置/端口/状态/模型配置/内容）+ 连线（两端端口）。内容存于
// backendConfig.params["content"]（E15/E16 单一事实来源约定），随模型配置一并序列化。

/// 画布图草稿（512ms 防抖落盘的内容载体）
struct CanvasDraft: Codable, Equatable {
    /// 画布草稿 payload 版本：v3 起把画布级恢复状态（资产引用、任务引用、视口、选择、预览）
    /// 与节点图放进同一快照。旧 v1/v2 数据无这些键，解码时回退到安全默认值。
    var schemaVersion: Int
    var savedAt: Date
    var nodes: [Node]
    var edges: [Edge]
    /// 画布组（AJ-21 分组），随草稿一并持久化，重启后恢复。
    /// v1 旧数据缺该键 → 解码为空数组。
    var groups: [Group]
    /// 资产事实源的引用集合；内容由 CanvasAssetStore 独立保存。
    var assetIDs: Set<UUID>
    /// 独立任务存储的画布归属投影。
    var tasks: [CanvasTaskReference]
    /// 画布级交互状态，不能依赖 SwiftUI View 的瞬时 @State。
    var viewport: CanvasViewportState
    var selection: Set<UUID>
    var selectionOrder: [UUID]
    var selectedGroupID: UUID?
    var previewNodeID: UUID?

    struct Node: Codable, Equatable {
        var id: UUID
        var type: String
        var title: String
        var positionX: Double
        var positionY: Double
        var status: String
        var inputs: [Port]
        var outputs: [Port]
        var backendID: String?
        var backendConfig: NodeBackendConfig?
    }

    struct Port: Codable, Equatable {
        var id: UUID
        var name: String
        var direction: String   // "input" / "output"
        var dataType: String
    }

    struct Edge: Codable, Equatable {
        var id: UUID
        var fromNode: UUID
        var fromPort: UUID
        var toNode: UUID
        var toPort: UUID
    }

    init(
        schemaVersion: Int = 3,
        savedAt: Date,
        nodes: [Node],
        edges: [Edge],
        groups: [Group],
        assetIDs: Set<UUID> = [],
        tasks: [CanvasTaskReference] = [],
        viewport: CanvasViewportState = CanvasViewportState(),
        selection: Set<UUID> = [],
        selectionOrder: [UUID] = [],
        selectedGroupID: UUID? = nil,
        previewNodeID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.nodes = nodes
        self.edges = edges
        self.groups = groups
        self.assetIDs = assetIDs
        self.tasks = tasks
        self.viewport = viewport
        self.selection = selection
        self.selectionOrder = selectionOrder
        self.selectedGroupID = selectedGroupID
        self.previewNodeID = previewNodeID
    }

    /// 兼容旧数据 + 稳定编码的显式 Codable 实现。
    /// - `decode`：旧 v1 草稿无 `groups` 键 → `decodeIfPresent` 兜底为空数组（迁移），
    ///   旧 `schemaVersion` 键缺失时兜底为 1。
    /// - `encode`：按当前字段写盘。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Self.CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.savedAt = try c.decode(Date.self, forKey: .savedAt)
        self.nodes = try c.decode([Node].self, forKey: .nodes)
        self.edges = try c.decode([Edge].self, forKey: .edges)
        self.groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
        self.assetIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .assetIDs) ?? []
        self.tasks = try c.decodeIfPresent([CanvasTaskReference].self, forKey: .tasks) ?? []
        self.viewport = try c.decodeIfPresent(CanvasViewportState.self, forKey: .viewport) ?? CanvasViewportState()
        self.selection = try c.decodeIfPresent(Set<UUID>.self, forKey: .selection) ?? []
        self.selectionOrder = try c.decodeIfPresent([UUID].self, forKey: .selectionOrder) ?? []
        self.selectedGroupID = try c.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        self.previewNodeID = try c.decodeIfPresent(UUID.self, forKey: .previewNodeID)
    }
}

extension CanvasDraft {
    /// 画布组持久化 DTO（AJ-21）。`color` 以 RGBA 分量直方存储，
    /// 缺失/异常时恢复端回退到 `CanvasGroup.defaultColor`。
    struct Group: Codable, Hashable {
        var id: UUID
        var title: String
        var originX: Double
        var originY: Double
        var width: Double
        var height: Double
        var nodeIDs: [UUID]
        var isCollapsed: Bool
        var colorRGBA: [Double]?   // [r, g, b, a]；可选，兼容 v1→v2 空组
    }
}

extension CanvasDraft {
    /// 当前图 → 草稿快照（savedAt 由调用方传入，便于恢复提示显示时间）
    init(graph: NodeGraph, savedAt: Date) {
        self.init(graph: graph, groups: [], savedAt: savedAt)
    }

    /// 当前图 + 画布组 → 草稿快照（AJ-21 分组随草稿一并持久化）
    init(
        graph: NodeGraph,
        groups: [CanvasDraft.Group],
        savedAt: Date,
        assetIDs: Set<UUID> = [],
        tasks: [CanvasTaskReference] = [],
        viewport: CanvasViewportState = CanvasViewportState(),
        selection: Set<UUID> = [],
        selectionOrder: [UUID] = [],
        selectedGroupID: UUID? = nil,
        previewNodeID: UUID? = nil
    ) {
        self.init(
            schemaVersion: 3,
            savedAt: savedAt,
            nodes: graph.nodes.map { node in
                Node(
                    id: node.id,
                    type: node.type,
                    title: node.title,
                    positionX: node.position.x,
                    positionY: node.position.y,
                    status: node.status.draftRawValue,
                    inputs: node.inputs.map { Port(id: $0.id, name: $0.name,
                                                   direction: $0.direction.draftRawValue,
                                                   dataType: $0.dataType) },
                    outputs: node.outputs.map { Port(id: $0.id, name: $0.name,
                                                     direction: $0.direction.draftRawValue,
                                                     dataType: $0.dataType) },
                    backendID: node.backendID,
                    backendConfig: node.backendConfig
                )
            },
            edges: graph.edges.map { edge in
                Edge(id: edge.id, fromNode: edge.fromNode, fromPort: edge.fromPort,
                     toNode: edge.toNode, toPort: edge.toPort)
            },
            groups: groups,
            assetIDs: assetIDs,
            tasks: tasks,
            viewport: viewport,
            selection: selection,
            selectionOrder: selectionOrder,
            selectedGroupID: selectedGroupID,
            previewNodeID: previewNodeID
        )
    }

    /// 草稿快照 → 节点图（崩溃恢复 / 草稿恢复）
    func toGraph() -> NodeGraph {
        var graph = NodeGraph()
        for node in nodes {
            graph.addNode(CanvasNode(
                id: node.id,
                type: node.type,
                title: node.title,
                position: Point(x: node.positionX, y: node.positionY),
                inputs: node.inputs.map { CanvasCore.Port(
                    id: $0.id, name: $0.name,
                    direction: PortDirection(draftRawValue: $0.direction),
                    dataType: $0.dataType
                ) },
                outputs: node.outputs.map { CanvasCore.Port(
                    id: $0.id, name: $0.name,
                    direction: PortDirection(draftRawValue: $0.direction),
                    dataType: $0.dataType
                ) },
                status: NodeStatus(draftRawValue: node.status),
                backendID: node.backendID,
                backendConfig: node.backendConfig
            ))
        }
        for edge in edges {
            graph.addEdge(CanvasCore.Edge(
                id: edge.id, fromNode: edge.fromNode, fromPort: edge.fromPort,
                toNode: edge.toNode, toPort: edge.toPort
            ))
        }
        return graph
    }

    /// 草稿中的组 → 画布组（`CanvasGroup`）。`colorRGBA` 缺失/异常时回退默认色。
    func toGroups() -> [CanvasGroup] {
        groups.map { g in
            var color = CanvasGroup.defaultColor
            if let rgba = g.colorRGBA, rgba.count >= 4 {
                color = Color(red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
            }
            return CanvasGroup(
                id: g.id,
                title: g.title,
                origin: Point(x: g.originX, y: g.originY),
                size: CGSize(width: g.width, height: g.height),
                nodeIDs: Set(g.nodeIDs),
                isCollapsed: g.isCollapsed,
                color: color
            )
        }
    }

    /// 画布组 → Group DTO（编码用）。RGBA 分量经 Color.Resolved 直方存储。
    static func encodeGroups(_ groups: [CanvasGroup]) -> [Group] {
        groups.map { g in
            Group(
                id: g.id,
                title: g.title,
                originX: g.origin.x,
                originY: g.origin.y,
                width: g.size.width,
                height: g.size.height,
                nodeIDs: Array(g.nodeIDs),
                isCollapsed: g.isCollapsed,
                colorRGBA: encodeCGColor(g.color)
            )
        }
    }

    /// SwiftUI Color → [r, g, b, a]（deviceRGB；失败返回 nil → 恢复端回退默认色）
    static func encodeCGColor(_ color: Color) -> [Double]? {
        #if os(macOS)
        let cg = NSColor(color).usingColorSpace(.deviceRGB)
        guard let cg else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        cg.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
        #else
        let resolved = color.resolve(in: EnvironmentValues())
        return [Double(resolved.red), Double(resolved.green), Double(resolved.blue), Double(resolved.opacity)]
        #endif
    }
}

// MARK: - 状态 / 端口方向 字符串映射（DTO 序列化辅助）

extension NodeStatus {
    var draftRawValue: String {
        switch self {
        case .pending: return "pending"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .cached: return "cached"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
    }

    init(draftRawValue: String) {
        switch draftRawValue {
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "cached": self = .cached
        case "failed": self = .failed
        case "skipped": self = .skipped
        default: self = .pending
        }
    }
}

extension PortDirection {
    var draftRawValue: String {
        switch self {
        case .input: return "input"
        case .output: return "output"
        }
    }

    init(draftRawValue: String) {
        self = draftRawValue == "output" ? .output : .input
    }
}

// MARK: - Agent 工具调用历史栈

/// 一次 Agent 工具调用记录（操作历史栈条目）：工具名 / 参数摘要 / 时间 / 结果摘要。
struct ActionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    /// 参数摘要（JSON 序列化截断，不存敏感原文）
    let argsSummary: String
    /// 结果摘要（单行截断；失败时为错误描述）
    let resultSummary: String
    let timestamp: Date
    /// 执行是否成功
    var succeeded: Bool
    /// 是否可撤销（撤销执行留接口：undoHandler 未装配时仅为记录模式）
    var undoable: Bool
    /// D-OUTPUT-02：file_write/file_edit 成功时派生的变更文件事实（含逐文件
    /// 有界脱敏 Diff）；其余工具与失败调用恒为 nil。可选字段向后兼容既有持久记录。
    var fileChange: AgentFileChangeRecord?
    /// Captured from the verified turn at execution time; absent for old or unbound records.
    let sourceSessionID: String?

    init(
        id: UUID = UUID(),
        toolName: String,
        argsSummary: String,
        resultSummary: String,
        timestamp: Date = Date(),
        succeeded: Bool = true,
        undoable: Bool = true,
        fileChange: AgentFileChangeRecord? = nil,
        sourceSessionID: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.argsSummary = argsSummary
        self.resultSummary = resultSummary
        self.timestamp = timestamp
        self.succeeded = succeeded
        self.undoable = undoable
        self.fileChange = fileChange
        self.sourceSessionID = sourceSessionID
    }
}

/// 工具调用历史栈（UI 展示 + 撤销入口）。
/// 撤销执行留接口：`undoHandler` 装配真实撤销逻辑（如文件写回 / 命令反转）；
/// 未装配时 `undoLatest()` 返回 false（纯记录模式，符合「先做记录+展示」）。
@MainActor
@Observable
final class ActionHistoryStore {
    private(set) var records: [ActionRecord] = []
    /// 历史栈上限（超出丢弃最旧）
    var maxRecords = 200
    /// 撤销执行接口（nil = 仅记录；由上层装配真实撤销）
    var undoHandler: ((ActionRecord) -> Bool)?

    /// 记录一次工具调用（Agent 每次实际执行的工具调用都会经此入栈）
    func record(_ record: ActionRecord) {
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
    }

    /// 最近一次工具调用记录
    var latest: ActionRecord? { records.last }

    /// 撤销最近一次工具调用：调用 undoHandler；成功则出栈。
    /// 未装配 undoHandler 时返回 false（记录模式，可撤销留接口）。
    @discardableResult
    func undoLatest() -> Bool {
        guard let latest, let handler = undoHandler else { return false }
        if handler(latest) {
            records.removeLast()
            return true
        }
        return false
    }

    func clear() {
        records.removeAll()
    }
}

// MARK: - 工具调用录制执行器

/// 包住真实 ToolExecutor，每次 execute 记录 ActionRecord（入操作历史栈）。
/// 只记录**真正执行**的调用：审批拒绝 / 循环拦截的调用不会到达底层 executor，天然不入栈。
/// S3：同时是 `SessionReadCapabilityAwareToolExecutor`，把类型化 capability 原样
/// 转发给底层（Policy → Builtin），并照常记录 `session_read` 调用；base 非
/// capability-aware 时 fail-closed（`capabilityRequired`），绝不落入旧的无类型入口。
struct RecordingToolExecutor: BrowserDestinationPolicyChecking, ToolCatalogValidatingExecutor, PolicyRuntimeBoundToolExecutor, SessionReadCapabilityAwareToolExecutor, BuiltinOwnerBoundToolExecutor {
    let base: any ToolExecutor
    func permitsBrowserDestination(host: String) -> Bool? {
        (base as? any BrowserDestinationPolicyChecking)?.permitsBrowserDestination(host: host)
    }

    var policyRuntimeBound: Bool {
        (base as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }
    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(tools)
    }
    /// 记录回调（AgentLoop 在后台任务执行，回调内自行 hop 到 MainActor 再入栈）
    let onRecorded: @Sendable (ActionRecord) -> Void
    /// 已知 secret 值（EnvVarStore 的 isSecret 条目，App 装配时注入）：在
    /// 参数/结果摘要与错误文本中按 EnvVarRedactor 规则打码；空 = 仅格式级
    /// 内嵌脱敏（Bearer / API-key / cookie / userinfo）。
    let knownSecretValues: [String]
    /// The production Safety gate admits this optional file read using its
    /// existing live composition/feature snapshot before old content opens.
    let fileChangePrecheckAdmission: (@Sendable (String) async throws -> Void)?

    init(
        base: any ToolExecutor,
        onRecorded: @escaping @Sendable (ActionRecord) -> Void,
        knownSecretValues: [String] = [],
        fileChangePrecheckAdmission: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.base = base
        self.onRecorded = onRecorded
        self.knownSecretValues = knownSecretValues
        self.fileChangePrecheckAdmission = fileChangePrecheckAdmission
    }

    private static func verifiedSourceSessionID(toolName: String) async -> String? {
        guard let context = AgentExecutionContext.current else { return nil }
        if context.hasVerifiedParentRuntime, let identity = context.parentRuntimeIdentity,
           identity.conversationID == context.currentConversationID {
            return identity.sessionID
        }
        if let binding = context.childToolRuntimeBinding {
            return await binding.verifiedParentSessionID(for: toolName, context: context)
        }
        return nil
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        try await execute(name: name, input: input, boundOwner: nil)
    }

    var currentBuiltinOwner: BuiltinToolExecutor? {
        (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard currentBuiltinOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        return try await execute(name: name, input: input, boundOwner: owner)
    }

    private func execute(
        name: String, input: [String: Any], boundOwner: BuiltinToolExecutor?
    ) async throws -> String {
        guard let receipt = ToolExecutionReceiptContext.current,
              ["file_write", "file_edit", "file_delete"].contains(name),
              let owner = boundOwner ?? currentBuiltinOwner,
              let checked = AgentFileChangeRecorder.authorizedPrecheckInput(toolName: name, input: input, owner: owner),
              let path = checked["path"] as? String else {
            return try await executeRecorded(name: name, input: input, boundOwner: boundOwner)
        }
        let frozen = try ComposerToolInput(checked)
        let target = URL(fileURLWithPath: path)
        if try await ToolFileMutationScope.borrowRecordingIfOwned(path: target, receipt: receipt) {
            return try await executeWithinFileLock(name: name, input: frozen, owner: owner, boundOwner: boundOwner)
        }
        // Non-Composer/non-AgentLoop consumers retain the same outer lock.
        // A sibling's different receipt cannot borrow an inherited resource.
        return try await ToolFileMutationScope.withLock(path: target, receipt: receipt) {
            guard try await ToolFileMutationScope.borrowRecordingIfOwned(path: target, receipt: receipt) else {
                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
            }
            return try await executeWithinFileLock(name: name, input: frozen, owner: owner, boundOwner: boundOwner)
        }
    }

    private func executeWithinFileLock(name: String, input: ComposerToolInput,
                                       owner: BuiltinToolExecutor, boundOwner: BuiltinToolExecutor?) async throws -> String {
        guard currentBuiltinOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        try Task.checkCancellation()
        guard await AgentExecutionContext.current?.parentAuthorityCheck?() != false else { throw CancellationError() }
        try await fileChangePrecheckAdmission?(name)
        try ApprovalFilePreviewContext.current?.validateCurrent()
        return try await executeRecorded(name: name, input: input.toolExecutionDictionary, boundOwner: boundOwner)
    }

    private func executeRecorded(
        name: String, input: [String: Any], boundOwner: BuiltinToolExecutor?
    ) async throws -> String {
        let sourceSessionID = await Self.verifiedSourceSessionID(toolName: name)
        let childReceipt = ToolExecutionReceiptContext.current.flatMap {
            $0.childTranscriptLocator == nil ? nil : $0
        }
        let args = Self.summarize(input, knownSecretValues: knownSecretValues)
        do {
            // The optional diff capture uses the forwarding chain's canonical
            // path authority and the same live Safety admission as execution.
            // A captured obsolete chain cannot open old content after rebind.
            let fileChangePrecheck: AgentFileChangeRecorder.Precheck?
            if childReceipt == nil, let input = AgentFileChangeRecorder.authorizedPrecheckInput(
                toolName: name, input: input, owner: boundOwner ?? currentBuiltinOwner
            ) {
                try await fileChangePrecheckAdmission?(name)
                fileChangePrecheck = AgentFileChangeRecorder.precheck(toolName: name, input: input)
            } else {
                fileChangePrecheck = nil
            }
            let output: String
            if let boundOwner {
                output = try await executeThroughBoundBuiltinOwner(
                    base, owner: boundOwner, name: name, input: input
                )
            } else {
                output = try await base.execute(name: name, input: input)
            }
            onRecorded(ActionRecord(
                toolName: name,
                argsSummary: args,
                resultSummary: Self.summarizeResult(output, knownSecretValues: knownSecretValues),
                succeeded: true,
                fileChange: childReceipt != nil
                    ? AgentFileChangeRecorder.authoritativeChildChange(
                        toolName: name, input: input, owner: boundOwner ?? currentBuiltinOwner,
                        receipt: childReceipt, knownSecretValues: knownSecretValues)
                    : AgentFileChangeRecorder.change(
                    toolName: name,
                    input: input,
                    precheck: fileChangePrecheck,
                    knownSecretValues: knownSecretValues,
                    timestamp: Date()
                ),
                sourceSessionID: sourceSessionID
            ))
            return output
        } catch {
            onRecorded(ActionRecord(
                toolName: name,
                argsSummary: args,
                resultSummary: Self.redactError(error.localizedDescription, knownSecretValues: knownSecretValues),
                succeeded: false,
                sourceSessionID: sourceSessionID
            ))
            throw error
        }
    }

    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
            throw CrossSessionReadAuthorizationError.capabilityRequired
        }
        let sourceSessionID = await Self.verifiedSourceSessionID(toolName: SessionReadTool.toolName)
        let args = Self.summarize(input, knownSecretValues: knownSecretValues)
        do {
            let output = try await aware.executeSessionRead(
                input: input,
                authorization: authorization,
                context: context,
                now: now
            )
            onRecorded(ActionRecord(
                toolName: SessionReadTool.toolName,
                argsSummary: args,
                resultSummary: Self.summarizeResult(output, knownSecretValues: knownSecretValues),
                succeeded: true,
                sourceSessionID: sourceSessionID
            ))
            return output
        } catch {
            onRecorded(ActionRecord(
                toolName: SessionReadTool.toolName,
                argsSummary: args,
                resultSummary: Self.redactError(error.localizedDescription, knownSecretValues: knownSecretValues),
                succeeded: false,
                sourceSessionID: sourceSessionID
            ))
            throw error
        }
    }

    /// 参数摘要：JSON 序列化 + 内容级脱敏 + 截断（≤120 字符）
    static func summarize(_ input: [String: Any], knownSecretValues: [String] = []) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        let redacted = ContentSecretRedactor.redact(text, knownSecrets: knownSecretValues)
        return redacted.count > 120 ? String(redacted.prefix(120)) + "…" : redacted
    }

    /// 结果摘要：去换行 + 内容级脱敏 + 截断（≤80 字符）
    static func summarizeResult(_ output: String, knownSecretValues: [String] = []) -> String {
        let flat = output.replacingOccurrences(of: "\n", with: " ")
        let redacted = ContentSecretRedactor.redact(flat, knownSecrets: knownSecretValues)
        return redacted.count > 80 ? String(redacted.prefix(80)) + "…" : redacted
    }

    /// 工具错误文本：内容级脱敏（截断语义与既有行为一致——不额外截断）
    static func redactError(_ text: String, knownSecretValues: [String] = []) -> String {
        ContentSecretRedactor.redact(text, knownSecrets: knownSecretValues)
    }
}

// MARK: - 工具调用历史视图

/// 工具调用历史展示（最近在前）：当前可经聊天命令「工具历史」查看；
/// 视图本身可挂接到侧栏/面板（历史/撤销 UI 的展示层）。
struct ActionHistoryView: View {
    let history: ActionHistoryStore

    @Environment(\.themeTokens) private var theme

    var body: some View {
        List(history.records.reversed()) { record in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: record.succeeded ? "wrench.and.screwdriver" : "exclamationmark.triangle")
                        .foregroundStyle(record.succeeded ? Color.secondary : (theme?.statusDanger ?? .red))
                    Text("`\(record.toolName)`")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(record.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(record.argsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(record.resultSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
        }
    }
}
