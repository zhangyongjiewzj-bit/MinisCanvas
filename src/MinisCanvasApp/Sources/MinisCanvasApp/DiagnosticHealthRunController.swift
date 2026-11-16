import Darwin
import Foundation
import Observation
import Security
import MinisCore

enum DiagnosticDefaultKeychainStatus: Equatable, Sendable {
    case notChecked
    case isolated
    case checking
    case unknown
    case measured(unlocked: Bool, readable: Bool)

    static func map(status: Int32, flags: UInt32) -> Self {
        guard status == errSecSuccess else { return .unknown }
        return .measured(unlocked: flags & UInt32(kSecUnlockStateStatus) != 0,
                         readable: flags & UInt32(kSecReadPermStatus) != 0)
    }

    var message: String {
        switch self {
        case .notChecked: return "默认钥匙串库：未检测。"
        case .isolated: return "隔离或测试环境：未检测默认钥匙串库。"
        case .checking: return "正在查询默认钥匙串库状态。"
        case .unknown: return "默认钥匙串库状态未知；请由本人检查系统权限。"
        case .measured(let unlocked, let readable):
            return "默认钥匙串库：" + (unlocked ? "已解锁" : "未解锁")
                + "、" + (readable ? "可读" : "不可读") + "。"
        }
    }
}

enum DiagnosticStorageProbeOutcome: Equatable, Sendable {
    case writable
    case unwritable
    case refused
    case cancelled
}

enum DiagnosticHealthRunState: Equatable {
    case unavailable
    case idle
    case running
    case completed(Date)
    case cancelled
    case failed
}

/// Content-free projections of existing product state. Refreshing these rows
/// never runs a transport, reads credentials or repairs data.
struct DiagnosticLocalStatus: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let nextStep: String
    let settingsPageID: String
    let checkedAt: Date?

    init(id: String, title: String, message: String, nextStep: String,
         settingsPageID: String, checkedAt: Date? = nil) {
        self.id = id; self.title = title; self.message = message
        self.nextStep = nextStep; self.settingsPageID = settingsPageID
        self.checkedAt = checkedAt
    }
}

/// An explicit, isolated storage observation. Its report has one measured
/// storage item; environment, backend, network, and Provider remain unknown.
/// The existing exporter only reads the last completed, fresh report.
@MainActor
@Observable
final class DiagnosticHealthRunController {
    typealias Checker = @Sendable (RuntimeIsolationProfile) async -> DiagnosticStorageProbeOutcome
    typealias KeychainStatusReader = @Sendable () -> (status: Int32, flags: UInt32)

    private struct ProfileIdentity: Equatable {
        let mode: RuntimeIsolationProfile.Mode
        let launchIdentity: String
        let device: UInt64
        let inode: UInt64
    }

    private var profile: RuntimeIsolationProfile
    @ObservationIgnored private let localStatusProvider: @MainActor () -> [DiagnosticLocalStatus]
    @ObservationIgnored private let cachedFailureReportProvider: @MainActor () -> HealthReport?
    private let cachedFailureProfile: RuntimeIsolationProfile
    private(set) var localStatuses: [DiagnosticLocalStatus] = []
    private(set) var localSnapshotAt: Date?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var metadataGeneration: UInt64 = 0
    @ObservationIgnored private let keychainStatusReader: KeychainStatusReader
    @ObservationIgnored private var keychainTask: Task<(status: Int32, flags: UInt32), Never>?
    @ObservationIgnored private var keychainGeneration: UInt64 = 0
    private(set) var defaultKeychainStatus: DiagnosticDefaultKeychainStatus = .notChecked
    private(set) var defaultKeychainCheckedAt: Date?
    @ObservationIgnored private var restartProcess: Process?
    private(set) var safeRestartRequested = false
    private(set) var safeRestartMessage: String?
    @ObservationIgnored private let checker: Checker
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeTask: Task<DiagnosticStorageProbeOutcome, Never>?
    private var cachedIdentity: ProfileIdentity?

    private(set) var state: DiagnosticHealthRunState
    private(set) var lastCompletedReport: HealthReport?

    init(
        profile: RuntimeIsolationProfile,
        checker: @escaping Checker,
        localStatusProvider: @escaping @MainActor () -> [DiagnosticLocalStatus] = { [] },
        cachedFailureReportProvider: @escaping @MainActor () -> HealthReport? = { nil },
        keychainStatusReader: KeychainStatusReader? = nil,
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.profile = profile
        self.checker = checker
        self.localStatusProvider = localStatusProvider
        self.cachedFailureReportProvider = cachedFailureReportProvider
        self.cachedFailureProfile = profile
        self.keychainStatusReader = keychainStatusReader ?? Self.readDefaultKeychainStatus
        self.clock = clock
        self.state = Self.identity(for: profile) == nil ? .unavailable : .idle
    }

    var defaultKeychainStatusText: String {
        let observed = defaultKeychainCheckedAt.map { " 检查时间：" + $0.formatted() } ?? ""
        return defaultKeychainStatus.message + observed
            + " 默认库状态，不代表具体 API Key ACL；具体凭据未检测。"
    }

    /// The View calls this only from its explicit user button.
    func checkDefaultKeychainStatus() async {
        guard !Task.isCancelled, defaultKeychainStatus != .checking else { return }
        guard profile.mode == .production, !RuntimeIsolationProfile.isRunningInTestProcess() else {
            defaultKeychainStatus = .isolated
            defaultKeychainCheckedAt = nil
            return
        }
        do {
            guard try FormalTestIsolationPaths.resolveCurrentProcess() == nil else {
                defaultKeychainStatus = .isolated
                defaultKeychainCheckedAt = nil
                return
            }
        } catch {
            defaultKeychainStatus = .isolated
            defaultKeychainCheckedAt = nil
            return
        }
        keychainGeneration &+= 1
        let request = keychainGeneration
        let observedProfile = profile
        let reader = keychainStatusReader
        defaultKeychainStatus = .checking
        defaultKeychainCheckedAt = nil
        let operation = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return (status: Int32(errSecUserCanceled), flags: UInt32(0)) }
            return reader()
        }
        keychainTask = operation
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        guard keychainGeneration == request, profile == observedProfile,
              profile.mode == .production else { return }
        keychainTask = nil
        guard !operation.isCancelled, !Task.isCancelled else {
            defaultKeychainStatus = .notChecked
            defaultKeychainCheckedAt = nil
            return
        }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite else {
            defaultKeychainStatus = .unknown
            return
        }
        defaultKeychainStatus = DiagnosticDefaultKeychainStatus.map(status: result.status, flags: result.flags)
        defaultKeychainCheckedAt = now
    }

    /// This deprecated macOS API reports only default-library metadata.
    /// It supplies no item reference, secret value, path, or unlock request.
    nonisolated private static func readDefaultKeychainStatus() -> (status: Int32, flags: UInt32) {
        // Runtime binding avoids a deprecated declaration reference on Swift 6.3.
        // This loses compile-time symbol signature checking: keep the C ABI exactly
        // aligned with Security/SecKeychain.h's SecKeychainGetStatus declaration.
        typealias GetStatus = @convention(c) (SecKeychain?, UnsafeMutablePointer<SecKeychainStatus>) -> OSStatus
        // Darwin dlfcn.h defines RTLD_DEFAULT as ((void *) -2); Swift does not import this macro.
        let defaultLookupHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = Darwin.dlsym(defaultLookupHandle, "SecKeychainGetStatus") else {
            return (errSecUnimplemented, 0)
        }
        let getStatus: GetStatus = unsafeBitCast(symbol, to: GetStatus.self)
        var flags: SecKeychainStatus = 0
        let status = getStatus(nil, &flags)
        return (status, flags)
    }

    func restartInSafeMode(settings: SettingsCenter, requestQuit: @escaping @MainActor () -> Void) {
        guard !safeRestartRequested else { return }
        safeRestartRequested = true
        settings.enableSafeMode()
        guard let payload = settings.settingsStore.settings.providerSettings[SafetyControlState.settingsKey]?[SafetyControlState.payloadKey],
              let bytes = payload.data(using: .utf8),
              let saved = try? JSONDecoder().decode(SafetyControlState.self, from: bytes),
              saved.safeModeEnabled, settings.settingsStore.lastPersistenceError == nil else {
            safeRestartMessage = "安全模式未能持久保存，未退出或重启应用。"
            return
        }
        safeRestartMessage = "正在准备安全模式重启；等待退出接力就绪。"
        do {
            restartProcess = try SafeModeRelaunch.start(profile: profile, onReady: { [weak self] process in
                guard let self, self.restartProcess === process else { return }
                self.safeRestartMessage = "接力已就绪，正在正常退出；仅在原实例退出后冷启动。"
                requestQuit()
            }, onFailure: { [weak self] process in
                guard let self, self.restartProcess === process else { return }
                self.restartProcess = nil
                self.safeRestartMessage = "本次安全模式重启未完成，未自动重试；安全模式保持开启。请正常退出后从原应用包重新打开。"
            })
        } catch {
            safeRestartMessage = "未能准备重启接力，应用未退出；安全模式保持开启。"
        }
    }

    @discardableResult
    func refreshReadOnlyStatus() -> Task<Void, Never> {
        localStatuses = localStatusProvider()
        localSnapshotAt = clock()
        metadataTask?.cancel()
        metadataGeneration &+= 1
        let request = metadataGeneration
        let observedProfile = profile
        let refresh = Task { [weak self] in
            let operation = Task.detached(priority: .utility) {
                DiagnosticSessionStorageMetadata.message(for: observedProfile)
            }
            let message = await withTaskCancellationHandler {
                await operation.value
            } onCancel: { operation.cancel() }
            guard let self, !Task.isCancelled, self.metadataGeneration == request,
                  self.profile == observedProfile else { return }
            if let index = self.localStatuses.firstIndex(where: { $0.id == "storage" }) {
                let old = self.localStatuses[index]
                self.localStatuses[index] = DiagnosticLocalStatus(id: old.id, title: old.title,
                    message: message, nextStep: old.nextStep, settingsPageID: old.settingsPageID,
                    checkedAt: self.clock())
            }
            self.metadataTask = nil
        }
        metadataTask = refresh
        return refresh
    }

    /// Only fixed product labels/counts and timestamps enter this projection.
    /// It is separate from the existing five-module JSON export schema.
    var localStatusText: String {
        (["状态与自检（本地快照；未发起网络请求或读取凭据内容）"] + localStatuses.map {
            let observed = $0.checkedAt.map { "；已有检查时间：" + $0.formatted() } ?? ""
            return ContentSecretRedactor.redact($0.title + "：" + $0.message + observed + "\n怎么办：" + $0.nextStep)
        } + [defaultKeychainStatusText]).joined(separator: "\n")
    }

    var canRun: Bool { Self.identity(for: profile) != nil }
    var isRunning: Bool { state == .running }
    var hasFreshSnapshot: Bool { reportForExport() != nil }
    var lastCompletedAt: Date? { lastCompletedReport?.timestamp }
    var storageStatus: HealthStatus? { freshStorageReport()?.items.first?.status }

    /// Only the button calls this method. A second click cannot start a second
    /// probe; closing/cancelling invalidates the generation before late work
    /// can publish an apparently fresh result.
    func run() async {
        guard let startedIdentity = Self.identity(for: profile) else {
            state = .unavailable
            return
        }
        guard !isRunning else { return }
        generation &+= 1
        let runGeneration = generation
        let runProfile = profile
        let checker = checker
        state = .running
        let operation = Task { await checker(runProfile) }
        activeTask = operation

        let outcome = await operation.value
        guard generation == runGeneration else { return }
        activeTask = nil
        guard Self.identity(for: profile) == startedIdentity else {
            clearCache()
            state = .unavailable
            return
        }
        guard !operation.isCancelled else {
            state = .cancelled
            return
        }
        switch outcome {
        case .writable, .unwritable:
            let completedAt = clock()
            guard completedAt.timeIntervalSince1970.isFinite else {
                state = .failed
                return
            }
            let item = HealthItem(
                name: "隔离诊断临时目录",
                category: .storage,
                status: outcome == .writable ? .ok : .error,
                message: outcome == .writable ? "写入校验完成" : "写入校验失败"
            )
            lastCompletedReport = HealthReport(items: [item], timestamp: completedAt)
            cachedIdentity = startedIdentity
            state = .completed(completedAt)
        case .refused:
            state = .failed
        case .cancelled:
            state = .cancelled
        }
    }

    func cancel() {
        keychainGeneration &+= 1
        keychainTask?.cancel()
        keychainTask = nil
        defaultKeychainStatus = .notChecked
        defaultKeychainCheckedAt = nil
        metadataGeneration &+= 1
        metadataTask?.cancel()
        metadataTask = nil
        guard isRunning else { return }
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        state = .cancelled
    }

    /// A changed profile cannot inherit a report from another root or mode.
    func bindProfile(_ newProfile: RuntimeIsolationProfile) {
        let previousIdentity = Self.identity(for: profile)
        let nextIdentity = Self.identity(for: newProfile)
        if profile != newProfile || previousIdentity != nextIdentity {
            cancel()
            clearCache()
            state = nextIdentity == nil ? .unavailable : .idle
        }
        profile = newProfile
    }

    /// Export revalidates existing metadata-bound failures and the completed
    /// storage probe. It never starts a transport or reads a credential value.
    func reportForExport() -> HealthReport? {
        let now = clock()
        let cachedFailures = profile == cachedFailureProfile
            && (profile.mode == .production || profile.isDisposableRootIntact)
            ? cachedFailureReportProvider() : nil
        let failures = cachedFailures.flatMap { report -> HealthReport? in
            let age = now.timeIntervalSince(report.timestamp)
            return now.timeIntervalSince1970.isFinite && report.timestamp.timeIntervalSince1970.isFinite
                && (0...600).contains(age) ? report : nil
        }
        let storage = freshStorageReport()
        let reports = [failures, storage].compactMap { $0 }
        guard let oldest = reports.map(\.timestamp).min() else { return nil }
        return HealthReport(items: reports.flatMap(\.items), timestamp: oldest)
    }

    private func freshStorageReport() -> HealthReport? {
        guard let report = lastCompletedReport,
              let cachedIdentity,
              cachedIdentity == Self.identity(for: profile) else { return nil }
        let now = clock()
        let elapsed = now.timeIntervalSince(report.timestamp)
        guard now.timeIntervalSince1970.isFinite,
              report.timestamp.timeIntervalSince1970.isFinite,
              elapsed >= 0,
              elapsed <= 600 else { return nil }
        return report
    }

    private func clearCache() {
        lastCompletedReport = nil
        cachedIdentity = nil
    }

    private static func identity(for profile: RuntimeIsolationProfile) -> ProfileIdentity? {
        guard profile.mode == .isolatedTest || profile.mode == .packagedField,
              let rootIdentity = profile.disposableRootIdentity,
              profile.isDisposableRootIntact,
              profile.temporaryDirectory.path == profile.rootDirectory
                .appendingPathComponent("temporary", isDirectory: true).path else { return nil }
        return ProfileIdentity(
            mode: profile.mode,
            launchIdentity: profile.launchIdentity,
            device: rootIdentity.device,
            inode: rootIdentity.inode
        )
    }
}

/// Uses directory descriptors anchored to the validated disposable root.
/// Neither a replaced root nor a symlinked `temporary` entry can redirect the
/// probe. It creates and removes only its own unpredictable leaf name.
enum DiagnosticIsolatedStorageProbe {
    static func check(_ profile: RuntimeIsolationProfile) async -> DiagnosticStorageProbeOutcome {
        let operation = Task.detached(priority: .utility) { checkSynchronously(profile) }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func checkSynchronously(_ profile: RuntimeIsolationProfile) -> DiagnosticStorageProbeOutcome {
        guard (profile.mode == .isolatedTest || profile.mode == .packagedField),
              let expected = profile.disposableRootIdentity,
              profile.isDisposableRootIntact,
              profile.temporaryDirectory.path == profile.rootDirectory
                .appendingPathComponent("temporary", isDirectory: true).path,
              !Task.isCancelled else { return .refused }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootFD = Darwin.open(profile.rootDirectory.path, directoryFlags)
        guard rootFD >= 0 else { return .refused }
        defer { Darwin.close(rootFD) }
        var rootStat = stat()
        guard Darwin.fstat(rootFD, &rootStat) == 0,
              UInt64(rootStat.st_dev) == expected.device,
              UInt64(rootStat.st_ino) == expected.inode,
              rootStat.st_uid == geteuid(),
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              (rootStat.st_mode & mode_t(0o022)) == 0 else { return .refused }

        func rootStillMatches() -> Bool {
            let checkFD = Darwin.open(profile.rootDirectory.path, directoryFlags)
            guard checkFD >= 0 else { return false }
            defer { Darwin.close(checkFD) }
            var current = stat()
            return Darwin.fstat(checkFD, &current) == 0
                && UInt64(current.st_dev) == expected.device
                && UInt64(current.st_ino) == expected.inode
                && current.st_uid == geteuid()
                && (current.st_mode & S_IFMT) == S_IFDIR
                && (current.st_mode & mode_t(0o022)) == 0
        }

        let temporaryFD = Darwin.openat(rootFD, "temporary", directoryFlags)
        // A missing or symlinked profile directory is an unsafe namespace,
        // not evidence that a valid storage directory was tested.
        guard temporaryFD >= 0 else { return .refused }
        defer { Darwin.close(temporaryFD) }
        var temporaryStat = stat()
        guard Darwin.fstat(temporaryFD, &temporaryStat) == 0,
              temporaryStat.st_dev == rootStat.st_dev,
              temporaryStat.st_uid == geteuid(),
              (temporaryStat.st_mode & S_IFMT) == S_IFDIR,
              (temporaryStat.st_mode & mode_t(0o022)) == 0,
              rootStillMatches(),
              !Task.isCancelled else { return .refused }

        let name = ".miniscanvas-health-\(UUID().uuidString).tmp"
        let fileFlags = O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC
        let fileFD = Darwin.openat(temporaryFD, name, fileFlags, mode_t(0o600))
        guard fileFD >= 0 else { return rootStillMatches() ? .unwritable : .refused }
        defer { Darwin.close(fileFD) }
        var createdStat = stat()
        guard Darwin.fstat(fileFD, &createdStat) == 0,
              createdStat.st_dev == rootStat.st_dev,
              createdStat.st_uid == geteuid(),
              (createdStat.st_mode & S_IFMT) == S_IFREG,
              (createdStat.st_mode & mode_t(0o077)) == 0,
              createdStat.st_nlink == 1 else { return .refused }

        func removeOwnProbe() -> Bool {
            var current = stat()
            guard Darwin.fstatat(temporaryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == createdStat.st_dev,
                  current.st_ino == createdStat.st_ino,
                  (current.st_mode & S_IFMT) == S_IFREG else { return false }
            return Darwin.unlinkat(temporaryFD, name, 0) == 0
        }

        let bytes = Array("MinisCanvasHealth".utf8)
        let wroteAll = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fileFD, base.advanced(by: offset), raw.count - offset)
                if wrote < 0 && errno == EINTR { continue }
                guard wrote > 0 else { return false }
                offset += wrote
            }
            return true
        }
        var readBack = [UInt8](repeating: 0, count: bytes.count)
        let readAll = wroteAll && Darwin.lseek(fileFD, 0, SEEK_SET) == 0
            && readBack.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.read(fileFD, base.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        let result: DiagnosticStorageProbeOutcome = Task.isCancelled
            ? .cancelled
            : (readAll && readBack == bytes ? .writable : .unwritable)
        guard removeOwnProbe(), rootStillMatches() else { return .refused }
        return result
    }
}


// Metadata only. No file payload is opened, and directory traversal remains
// relative to the configured session root without following symbolic links.
enum DiagnosticSessionStorageMetadata {
    static func message(for profile: RuntimeIsolationProfile) -> String {
        let incomplete = "会话库存储未完整统计；磁盘剩余未知。未测试写入权限。"
        if profile.mode != .production && !profile.isDisposableRootIntact { return incomplete }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = Darwin.open(profile.sessionDirectory.path, flags)
        guard root >= 0 else { return incomplete }
        defer { Darwin.close(root) }
        var original = stat()
        guard Darwin.fstat(root, &original) == 0 else { return incomplete }
        var visited = 0
        var bytes: Int64 = 0
        func visit(_ descriptor: Int32, depth: Int) -> Bool {
            guard !Task.isCancelled, depth <= 64 else { return false }
            let copy = Darwin.dup(descriptor)
            guard copy >= 0 else { return false }
            guard let directory = fdopendir(copy) else {
                Darwin.close(copy)
                return false
            }
            defer { closedir(directory) }
            errno = 0
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1
                guard visited <= 10_000, !Task.isCancelled else { return false }
                var info = stat()
                guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_dev == original.st_dev else { return false }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFREG):
                    guard info.st_size >= 0, bytes <= Int64.max - info.st_size else { return false }
                    bytes += info.st_size
                case mode_t(S_IFDIR):
                    let child = Darwin.openat(descriptor, name, flags)
                    guard child >= 0 else { return false }
                    var opened = stat()
                    let complete = Darwin.fstat(child, &opened) == 0
                        && opened.st_dev == info.st_dev && opened.st_ino == info.st_ino
                        && visit(child, depth: depth + 1)
                    Darwin.close(child)
                    guard complete else { return false }
                default:
                    return false
                }
                errno = 0
            }
            return errno == 0
        }
        let complete = visit(root, depth: 0)
        var current = stat()
        guard !Task.isCancelled,
              Darwin.lstat(profile.sessionDirectory.path, &current) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              profile.mode == .production || profile.isDisposableRootIntact else { return incomplete }
        var volume = statfs()
        let freeBytes: Int64?
        if Darwin.fstatfs(root, &volume) == 0, volume.f_bsize > 0,
           volume.f_bavail <= UInt64(Int64.max) / UInt64(volume.f_bsize) {
            freeBytes = Int64(volume.f_bavail * UInt64(volume.f_bsize))
        } else {
            freeBytes = nil
        }
        let size = complete ? "会话库逻辑大小 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            : "会话库存储未完整统计"
        let free = freeBytes.map { "同卷可用空间 " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? "磁盘剩余未知"
        return size + "；" + free + "。范围为当前配置的会话根目录（含附件与运行记录）；仅统计元数据，未测试写入权限。"
    }
}
