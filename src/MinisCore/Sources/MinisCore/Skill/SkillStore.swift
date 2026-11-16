import Foundation

public struct SkillParsedDocument: Equatable, Sendable {
    public var name: String
    public var description: String
    public var version: String
    public var body: String

    public init(name: String = "Untitled Skill", description: String = "", version: String = "1.0.0", body: String = "") {
        self.name = name
        self.description = description
        self.version = version
        self.body = body
    }
}

public enum SkillStoreInitialLoadError: Error, Equatable, Sendable { case pending }
public enum FrozenProjectionMutationError: Error, Equatable, Sendable { case readOnly }

public enum SkillContentExpectation: Sendable {
    case absent
    case hash(String)
}

public final class SkillStore: @unchecked Sendable {
    public static let maxSkillContentBytes = 1_048_576
    public static let defaultSkillName = "Untitled Skill"
    public let skillsRoot: URL
    private let transactionDomain: PersistenceTransactionFence.Domain
    public var persistenceDomain: PersistenceTransactionFence.Domain { transactionDomain }
    private var installedSkills: [Skill] = []
    public private(set) var skills: [Skill] {
        get {
            if let before = beforeProjection() { return before.skills }
            return readyRead(or: { [] }) { synchronized { installedSkills } }
        }
        set { installedSkills = newValue }
    }
    public var lifecycleReceiptsFileURL: URL { skillsRoot.appendingPathComponent("lifecycle-receipts.json") }
    private let mutex = NSRecursiveLock()
    private static let rootWrites = RootWriteCoordination()
    private final class RootWriteCoordination: @unchecked Sendable {
        private let tableLock = NSLock()
        private final class Entry {
            let lock = NSRecursiveLock()
            var heldRoot: SkillFilesystemBoundary.RootIdentity?
        }
        private var entries: [PersistenceTransactionFence.Domain: Entry] = [:]
        func perform<T>(domain: PersistenceTransactionFence.Domain, root: URL, deadline: TimeInterval, _ action: () throws -> T) throws -> T {
            tableLock.lock()
            let entry: Entry
            if let existing = entries[domain] { entry = existing }
            else { let created = Entry(); entries[domain] = created; entry = created }
            tableLock.unlock()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, entry.lock.lock(before: Date(timeIntervalSinceNow: remaining)) else {
                throw SkillError.importFailed(reason: "Skill root write admission timeout")
            }
            defer { entry.lock.unlock() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SkillError.importFailed(reason: "Skill root write admission timeout") }
            guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(root) else {
                throw SkillError.importFailed(reason: "Untrusted skill root")
            }
            if let heldRoot = entry.heldRoot {
                guard heldRoot == rootIdentity else {
                    throw SkillError.importFailed(reason: "Skill root coordination changed")
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw SkillError.importFailed(reason: "Skill root write admission timeout")
                }
                return try action()
            }
            let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw SkillError.importFailed(reason: "Skill root coordination unavailable") }
            defer { close(rootFD) }
            var rootInfo = stat()
            guard fstat(rootFD, &rootInfo) == 0,
                  UInt64(rootInfo.st_dev) == rootIdentity.device, UInt64(rootInfo.st_ino) == rootIdentity.inode else {
                throw SkillError.importFailed(reason: "Skill root coordination changed")
            }
            let name = ".skill-root-write.lock"
            let fd = openat(rootFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SkillError.importFailed(reason: "Skill root coordination unavailable") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_mode & 0o7777 == 0o600, info.st_uid == geteuid(), info.st_nlink == 1 else {
                throw SkillError.importFailed(reason: "Unsafe skill root coordination file")
            }
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SkillError.importFailed(reason: "Skill root write admission timeout") }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
                let failure = errno
                guard failure == EWOULDBLOCK || failure == EINTR else {
                    throw SkillError.importFailed(reason: "Skill root coordination unavailable")
                }
                Thread.sleep(forTimeInterval: min(remaining, 0.01))
            }
            defer { _ = flock(fd, LOCK_UN) }
            var named = stat()
            guard fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == info.st_dev, named.st_ino == info.st_ino,
                  named.st_mode == info.st_mode, named.st_uid == info.st_uid, named.st_nlink == 1,
                  SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity) else {
                throw SkillError.importFailed(reason: "Skill root coordination replaced")
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SkillError.importFailed(reason: "Skill root write admission timeout")
            }
            entry.heldRoot = rootIdentity
            defer { entry.heldRoot = nil }
            return try action()
        }
    }
    private struct InitialLoadState {
        var ready = false
        var attempt: InitialLoadAttempt?
        var observedAttempt = false
    }
    private let initialStateLock = NSLock()
    private var initialState = InitialLoadState()
    private final class InitialLoadWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        func install(_ value: CheckedContinuation<Void, Never>) {
            lock.lock()
            let resume = finished
            if !resume { continuation = value }
            lock.unlock()
            if resume { value.resume() }
        }
        func finish() {
            lock.lock()
            finished = true
            let value = continuation; continuation = nil
            lock.unlock()
            value?.resume()
        }
    }
    private final class InitialLoadAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var waiters: [InitialLoadWaiter] = []
        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }
        func wait(waiterRegistered: (@Sendable () -> Void)?) async {
            let waiter = InitialLoadWaiter()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiter.install(continuation)
                    lock.lock()
                    let complete = finished
                    if !complete { waiters.append(waiter) }
                    lock.unlock()
                    if complete { waiter.finish() }
                    else { waiterRegistered?() }
                }
            } onCancel: { waiter.finish() }
        }
        func finish() {
            lock.lock()
            finished = true
            let values = waiters; waiters.removeAll()
            lock.unlock()
            for waiter in values { waiter.finish() }
        }
    }
    private var ledgerIsReadable = true
    private var frozen = false
    private var generation: UInt64 = 0
    private let instanceID = UUID()
    private var ledger = Ledger()
    private var cachedRaw: [String: String] = [:]
    private var frozenFiles: [String: [String: String]] = [:]
    private var sharedMask: [String: Bool] = [:]
    private let observer: SkillStoreFilesystemAccessObserver?
    internal enum BL6EnablementFaultPoint: Sendable { case afterIntentPersisted, afterSharedStatePersisted }
    internal var bl6EnablementFaultInjector: (@Sendable (BL6EnablementFaultPoint) throws -> Void)?

    private struct Previous: Codable {
        var content: String
        var receipt: SkillLifecycleReceipt?
        var manifest: SkillSourceManifest?
    }
    private struct Completion: Codable {
        var record: BL6SettingsReplayRecord
        var skillID: String
        var scope: MemoryScope
        var sourceReceiptID: String
        var sourceContentHash: String
        var beforeMask: Bool?
        var afterMask: Bool?
        var legacyMask: Bool?
        var beforeDisabled: Bool
        var afterDisabled: Bool
    }
    private struct Pending: Codable { var completion: Completion }
    private struct Ledger: Codable {
        var receipts: [String: SkillLifecycleReceipt] = [:]
        var disabledSkillIDs: Set<String> = []
        var previousVersions: [String: Previous] = [:]
        var bl6EnablementRecords: [String: Completion] = [:]
        var bl6EnablementPending: Pending?
        enum CodingKeys: String, CodingKey { case receipts, disabledSkillIDs, previousVersions, bl6EnablementRecords, bl6EnablementPending }
        init() {}
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            receipts = try box.decode([String: SkillLifecycleReceipt].self, forKey: .receipts)
            disabledSkillIDs = try box.decodeIfPresent(Set<String>.self, forKey: .disabledSkillIDs) ?? []
            previousVersions = try box.decodeIfPresent([String: Previous].self, forKey: .previousVersions) ?? [:]
            bl6EnablementRecords = try box.decodeIfPresent([String: Completion].self, forKey: .bl6EnablementRecords) ?? [:]
            bl6EnablementPending = try box.decodeIfPresent(Pending.self, forKey: .bl6EnablementPending)
        }
    }
    private struct Write: Codable { let path: String; let data: Data? }
    private var sharedURL: URL { skillsRoot.deletingLastPathComponent().appendingPathComponent("skills-enabled.json") }
    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }; return try operation()
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public convenience init(skillsRoot: URL? = nil) { self.init(skillsRoot: skillsRoot, filesystemAccessObserver: nil) }
    internal convenience init(skillsRoot: URL?, filesystemAccessObserver: SkillStoreFilesystemAccessObserver?) {
        self.init(root: skillsRoot ?? Self.defaultSkillsRoot(), observer: filesystemAccessObserver, bootstrap: false)
    }
    private init(root: URL, observer: SkillStoreFilesystemAccessObserver?, bootstrap: Bool, domain: PersistenceTransactionFence.Domain? = nil) {
        skillsRoot = root; transactionDomain = domain ?? .skills(root); self.observer = observer
        if !bootstrap { reload() }
    }
    public static func defaultSkillsRoot() -> URL {
        if let isolated = FormalTestIsolationPaths.currentOrFail() { return isolated.skillsRoot }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MinisCore", isDirectory: true).appendingPathComponent("skills", isDirectory: true)
    }
    public static func startForAppBootstrap(skillsRoot: URL) -> SkillStore {
        bootstrapStore(skillsRoot: skillsRoot, observer: nil)
    }
    internal static func startForAppBootstrap(skillsRoot: URL, filesystemAccessObserver: SkillStoreFilesystemAccessObserver?) -> SkillStore {
        bootstrapStore(skillsRoot: skillsRoot, observer: filesystemAccessObserver)
    }
    private static func bootstrapStore(skillsRoot: URL, observer: SkillStoreFilesystemAccessObserver?) -> SkillStore {
        let store = SkillStore(root: skillsRoot, observer: observer, bootstrap: true)
        _ = store.beginInitialAttempt(observe: false)
        return store
    }
    private func initialLoading<T>(_ action: (inout InitialLoadState) -> T) -> T {
        initialStateLock.lock(); defer { initialStateLock.unlock() }
        return action(&initialState)
    }
    public var isInitialLoadComplete: Bool { initialLoading { $0.ready } }
    private func publishInitialReadiness() { initialLoading { $0.ready = true } }
    private func beforeProjection() -> Snapshot? {
        guard !frozen else { return nil }
        return PersistenceTransactionFence.beforeView(transactionDomain)?.skills
    }
    private func readyRead<T>(or pending: () throws -> T, checkingDomain: Bool = true, _ action: () throws -> T) rethrows -> T {
        if checkingDomain && !frozen {
            do { try PersistenceTransactionFence.requireLiveRead(transactionDomain) }
            catch { return try pending() }
        }
        guard isInitialLoadComplete else { return try pending() }
        return try action()
    }
    private func beginInitialAttempt(observe: Bool = true) -> InitialLoadAttempt? {
        let decision: (attempt: InitialLoadAttempt?, start: Bool) = initialLoading { state in
            if let current = state.attempt, !current.isFinished || !state.observedAttempt {
                if observe { state.observedAttempt = true }
                return (current, false)
            }
            guard !state.ready, !frozen else { return (nil, false) }
            let attempt = InitialLoadAttempt()
            state.attempt = attempt; state.observedAttempt = observe
            return (attempt, true)
        }
        if decision.start, let attempt = decision.attempt {
            DispatchQueue.global(qos: .utility).async {
                self.reload()
                attempt.finish()
            }
        }
        return decision.attempt
    }
    public func waitForInitialLoad() async {
        await waitForInitialLoad(waiterRegistered: nil)
    }
    // 仅供测试证明注册时序，生产路径固定为 nil。
    internal func waitForInitialLoad(waiterRegistered: (@Sendable () -> Void)?) async {
        guard !Task.isCancelled, let attempt = beginInitialAttempt() else { return }
        await attempt.wait(waiterRegistered: waiterRegistered)
    }
    public func skillDirectoryURL(for skillId: String) -> URL {
        skillsRoot.appendingPathComponent(Self.isSafeSkillID(skillId) ? skillId : ".invalid-skill-id", isDirectory: true)
    }
    public func skillManifestURL(for skillID: String) -> URL { skillDirectoryURL(for: skillID).appendingPathComponent("manifest.json") }
    private func assertInitialReadReady() throws {
        if !frozen { try PersistenceTransactionFence.requireLiveRead(transactionDomain) }
        guard isInitialLoadComplete else {
            if frozen { throw FrozenProjectionMutationError.readOnly }
            throw SkillStoreInitialLoadError.pending
        }
    }
    private func assertMutable() throws {
        if frozen { throw FrozenProjectionMutationError.readOnly }
        if !isInitialLoadComplete { throw SkillStoreInitialLoadError.pending }
        if !ledgerIsReadable || ledger.bl6EnablementPending != nil { throw BL6SkillEnablementError.recoveryRequired }
    }
    private func rootReady() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: skillsRoot.path) { try manager.createDirectory(at: skillsRoot, withIntermediateDirectories: true) }
        guard SkillFilesystemBoundary.isApprovedRoot(skillsRoot) else { throw SkillError.importFailed(reason: "Untrusted skill root") }
    }
    private func withDiskLock<T>(deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2, _ action: () throws -> T) throws -> T {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw SkillError.importFailed(reason: "Skill transaction timeout") }
        try rootReady()
        // Process admission → root flock → Fence → instance mutex → skill flock.
        return try Self.rootWrites.perform(domain: persistenceDomain, root: skillsRoot, deadline: deadline) {
            try PersistenceTransactionFence.withWrite([persistenceDomain]) {
                try rootReady()
                return try action()
            }
        }
    }
    private func withReadFence<T>(_ action: () throws -> T) rethrows -> T {
        try PersistenceTransactionFence.withRead([persistenceDomain], action)
    }
    private func validateReplacementTarget(_ directory: URL) throws {
        guard let descriptor = SkillDescriptorReader.openDirectory(directory, within: skillsRoot) else { throw SkillError.importFailed(reason: "Unsafe replacement directory") }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & 0o022 == 0 else { throw SkillError.importFailed(reason: "Writable replacement directory") }
        if fstatat(descriptor, "SKILL.md", &information, AT_SYMLINK_NOFOLLOW) == 0 {
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_nlink == 1 else { throw SkillError.importFailed(reason: "Unsafe existing skill source") }
        } else if errno != ENOENT { throw SkillError.importFailed(reason: "Existing skill source unavailable") }
    }
    private func withSkillImportLock<T>(_ id: String, allowPending: Bool = false, createIfMissing: Bool = true, _ action: () throws -> T) throws -> T {
        let directory = skillDirectoryURL(for: id)
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard createIfMissing else { throw SkillError.importFailed(reason: "No verifiable previous version") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        guard SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot) else { throw SkillError.importFailed(reason: "Unsafe skill import directory") }
        try validateReplacementTarget(directory)
        let lockURL = directory.appendingPathComponent(".skill-import.lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600) } ?? -1 }
        guard descriptor >= 0 else { throw SkillError.importFailed(reason: "Skill import coordination unavailable") }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_mode & 0o777 == 0o600,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SkillError.importFailed(reason: "Skill import conflict or unsafe coordination file") }
        defer { flock(descriptor, LOCK_UN) }
        guard let before = SkillDescriptorReader.identity(descriptor),
              SkillFilesystemBoundary.isTrustedRegularFile(lockURL, within: directory) else { throw SkillError.importFailed(reason: "Skill coordination identity changed") }
        let confirmation = lockURL.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1 }
        guard confirmation >= 0 else { throw SkillError.importFailed(reason: "Skill coordination disappeared") }
        defer { close(confirmation) }
        guard SkillDescriptorReader.identity(confirmation) == before else { throw SkillError.importFailed(reason: "Skill coordination replaced") }
        guard allowPending || !pendingMarkerExists(id) else { throw SkillError.importFailed(reason: "Skill import requires recovery") }
        return try action()
    }
    private struct ImportMarker: Codable {
        var schema = "miniscore.skill-import-transaction"
        var version = 2
        var transactionID: String
        var generation: UInt64
        var skillID: String
        var skillFileName = "SKILL.md"
        var manifestFileName = "manifest.json"
        var skillTempName: String
        var manifestTempName: String
        var targetBindingDigest: String
        var previousPairDigest: String
        var expectedPairDigest: String
        var expectedContentHash: String
        var expectedManifest: SkillSourceManifest
        var previousContentHash: String?
        var previousManifest: SkillSourceManifest?
        var markerDigest: String
    }
    private static let importMarkerName = ".skill-import-pending.json"
    private static func transactionDigest(_ fields: [String]) -> String {
        var framed = "miniscore.skill-import-transaction-digest:v1"
        for field in fields { framed += String(field.utf8.count) + ":" + field }
        return SkillManifest.hash(framed)
    }
    private static func manifestFields(_ manifest: SkillSourceManifest?) -> [String] {
        guard let manifest else { return ["<missing>"] }
        return [manifest.schema, String(manifest.version), manifest.skillID, manifest.source.dbValue, manifest.skillVersion, manifest.contentHash]
    }
    private static func pairDigest(id: String, hash: String?, manifest: SkillSourceManifest?) -> String {
        transactionDigest(["pair", id, hash ?? "<missing>"] + manifestFields(manifest))
    }
    private func targetDigest(_ id: String) -> String {
        Self.transactionDigest(["target", skillsRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            skillDirectoryURL(for: id).resolvingSymlinksInPath().standardizedFileURL.path, id])
    }
    private static func markerDigest(_ marker: ImportMarker) -> String {
        transactionDigest(["marker", marker.schema, String(marker.version), marker.transactionID, String(marker.generation),
            marker.skillID, marker.skillFileName, marker.manifestFileName, marker.skillTempName, marker.manifestTempName,
            marker.targetBindingDigest, marker.previousPairDigest, marker.expectedPairDigest, marker.expectedContentHash] +
            manifestFields(marker.expectedManifest) + [marker.previousContentHash ?? "<missing>"] + manifestFields(marker.previousManifest))
    }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func entryExists(_ url: URL) -> Bool {
        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &information) } ?? -1 }
        return status == 0 || errno != ENOENT
    }
    private func pendingMarkerExists(_ id: String) -> Bool {
        Self.entryExists(skillDirectoryURL(for: id).appendingPathComponent(Self.importMarkerName))
    }
    private func secureData(_ name: String, in directory: URL, maximum: Int, permissions: mode_t? = nil) -> Data? {
        guard SkillDescriptorReader.validRelativeComponents(name)?.count == 1,
              let directoryFD = SkillDescriptorReader.openDirectory(directory, within: skillsRoot) else { return nil }
        defer { close(directoryFD) }
        let descriptor = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              permissions.map({ information.st_mode & 0o777 == $0 }) ?? true,
              let before = SkillDescriptorReader.identity(descriptor), before.byteCount >= 0, before.byteCount <= Int64(maximum),
              let data = SkillDescriptorReader.read(rootDescriptor: directoryFD, relativePath: name, maximumBytes: maximum),
              SkillDescriptorReader.identity(descriptor) == before else { return nil }
        let confirmation = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard confirmation >= 0 else { return nil }
        defer { close(confirmation) }
        guard SkillDescriptorReader.identity(confirmation) == before else { return nil }
        return data
    }
    private func writeExclusive(_ data: Data, name: String, in directory: URL) throws {
        guard SkillDescriptorReader.validRelativeComponents(name)?.count == 1,
              let directoryFD = SkillDescriptorReader.openDirectory(directory, within: skillsRoot) else { throw SkillError.importFailed(reason: "Unsafe import destination") }
        defer { close(directoryFD) }
        let descriptor = name.withCString { openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw SkillError.importFailed(reason: "Import staging conflict") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { storage in
            var written = 0
            while written < storage.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, storage.baseAddress!.advanced(by: written), storage.count - written)
                #else
                let count = Glibc.write(descriptor, storage.baseAddress!.advanced(by: written), storage.count - written)
                #endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SkillError.importFailed(reason: "Import staging write failed") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw SkillError.importFailed(reason: "Import staging could not be synchronized") }
    }
    private func renameImportFile(_ name: String, to destination: String, in directory: URL) throws {
        guard let descriptor = SkillDescriptorReader.openDirectory(directory, within: skillsRoot) else { throw SkillError.importFailed(reason: "Import directory changed") }
        defer { close(descriptor) }
        let result = name.withCString { old in destination.withCString { new in renameat(descriptor, old, descriptor, new) } }
        guard result == 0 else { throw SkillError.importFailed(reason: "Import pair could not be committed") }
        guard fsync(descriptor) == 0 else { throw SkillError.importFailed(reason: "Import directory could not be synchronized") }
    }
    private func removeImportFile(_ name: String, in directory: URL) throws {
        guard let descriptor = SkillDescriptorReader.openDirectory(directory, within: skillsRoot) else { throw SkillError.importFailed(reason: "Import directory changed") }
        defer { close(descriptor) }
        let result = name.withCString { unlinkat(descriptor, $0, 0) }
        guard result == 0 || errno == ENOENT else { throw SkillError.importFailed(reason: "Import evidence cleanup failed") }
        guard fsync(descriptor) == 0 else { throw SkillError.importFailed(reason: "Import cleanup could not be synchronized") }
    }
    private func validMarker(_ marker: ImportMarker, for id: String) -> Bool {
        func stagingName(_ name: String, prefix: String) -> Bool {
            name.hasPrefix(prefix) && name.hasSuffix(".tmp") && name.count > prefix.count + 4 && name.count <= 256 &&
            !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { $0.value < 32 }
        }
        guard marker.schema == "miniscore.skill-import-transaction", marker.version == 2,
              !marker.transactionID.isEmpty, marker.transactionID.utf8.count <= 128,
              !marker.transactionID.unicodeScalars.contains(where: { $0.value < 32 }), marker.generation > 0,
              marker.skillID == id, Self.isSafeSkillID(id), marker.skillFileName == "SKILL.md", marker.manifestFileName == "manifest.json",
              stagingName(marker.skillTempName, prefix: ".SKILL.md."), stagingName(marker.manifestTempName, prefix: ".manifest.json."),
              marker.skillTempName != marker.manifestTempName,
              [marker.targetBindingDigest, marker.previousPairDigest, marker.expectedPairDigest, marker.expectedContentHash, marker.markerDigest].allSatisfy(Self.isDigest),
              marker.expectedManifest.schema == SkillSourceManifest.currentSchema,
              marker.expectedManifest.version == SkillSourceManifest.currentVersion,
              marker.expectedManifest.skillID == id, marker.expectedManifest.contentHash == marker.expectedContentHash,
              marker.previousContentHash.map(Self.isDigest) ?? true,
              marker.previousManifest.map({ $0.skillID == id && Self.isDigest($0.contentHash) }) ?? true else { return false }
        return marker.targetBindingDigest == targetDigest(id) &&
            marker.previousPairDigest == Self.pairDigest(id: id, hash: marker.previousContentHash, manifest: marker.previousManifest) &&
            marker.expectedPairDigest == Self.pairDigest(id: id, hash: marker.expectedContentHash, manifest: marker.expectedManifest) &&
            marker.markerDigest == Self.markerDigest(marker)
    }
    private func recoverImport(_ id: String) throws {
        let directory = skillDirectoryURL(for: id)
        guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(skillsRoot),
              let directoryIdentity = SkillFilesystemBoundary.trustedDirectoryIdentity(directory, within: skillsRoot),
              let markerData = secureData(Self.importMarkerName, in: directory, maximum: 64 * 1024, permissions: 0o600),
              let marker = try? JSONDecoder().decode(ImportMarker.self, from: markerData), validMarker(marker, for: id) else {
            throw SkillError.importFailed(reason: "Unrecognized pending import evidence")
        }
        func identitiesMatch() -> Bool {
            SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: rootIdentity) &&
                SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot, matching: directoryIdentity)
        }
        let bodyExists = Self.entryExists(directory.appendingPathComponent("SKILL.md"))
        let manifestExists = Self.entryExists(directory.appendingPathComponent("manifest.json"))
        let bodyData = bodyExists ? secureData("SKILL.md", in: directory, maximum: Self.maxSkillContentBytes) : nil
        let body = bodyData.flatMap { String(data: $0, encoding: .utf8) }
        let actualHash = body.map(SkillManifest.hash)
        let manifestData = manifestExists ? secureData("manifest.json", in: directory, maximum: SkillFilesystemBoundary.maxManifestBytes) : nil
        let actualManifest = manifestData.flatMap { try? JSONDecoder().decode(SkillSourceManifest.self, from: $0) }
        guard (!bodyExists || body != nil), (!manifestExists || actualManifest != nil),
              actualHash == marker.previousContentHash || actualHash == marker.expectedContentHash,
              actualManifest == marker.previousManifest || actualManifest == marker.expectedManifest else {
            throw SkillError.importFailed(reason: "Pending import contains an unknown generation")
        }
        let stagedBodyExists = Self.entryExists(directory.appendingPathComponent(marker.skillTempName))
        let stagedManifestExists = Self.entryExists(directory.appendingPathComponent(marker.manifestTempName))
        let stagedBodyData = stagedBodyExists ? secureData(marker.skillTempName, in: directory, maximum: Self.maxSkillContentBytes) : nil
        let stagedBody = stagedBodyData.flatMap { String(data: $0, encoding: .utf8) }
        let stagedManifestData = stagedManifestExists ? secureData(marker.manifestTempName, in: directory, maximum: SkillFilesystemBoundary.maxManifestBytes) : nil
        let stagedManifest = stagedManifestData.flatMap { try? JSONDecoder().decode(SkillSourceManifest.self, from: $0) }
        guard !stagedBodyExists || stagedBody.map({ SkillManifest.hash($0) == marker.expectedContentHash }) == true,
              !stagedManifestExists || stagedManifest == marker.expectedManifest else { throw SkillError.importFailed(reason: "Pending import staging changed") }
        guard actualHash == marker.expectedContentHash || stagedBody != nil,
              actualManifest == marker.expectedManifest || stagedManifest != nil,
              let targetBody = actualHash == marker.expectedContentHash ? body : stagedBody,
              Self.parse(skillMD: targetBody).version == marker.expectedManifest.skillVersion,
              identitiesMatch() else { throw SkillError.importFailed(reason: "Pending import target is incomplete") }
        if actualHash != marker.expectedContentHash {
            try renameImportFile(marker.skillTempName, to: "SKILL.md", in: directory)
        }
        guard identitiesMatch() else { throw SkillError.importFailed(reason: "Pending import directory changed") }
        if actualManifest != marker.expectedManifest {
            try renameImportFile(marker.manifestTempName, to: "manifest.json", in: directory)
        }
        guard identitiesMatch(), rawDisk(id).map(SkillManifest.hash) == marker.expectedContentHash,
              manifestDisk(id) == marker.expectedManifest,
              secureData(Self.importMarkerName, in: directory, maximum: 64 * 1024, permissions: 0o600) == markerData else {
            throw SkillError.importFailed(reason: "Pending import verification changed")
        }
        // Only recognized staging files are removed, and the marker is last.
        if stagedBodyExists, Self.entryExists(directory.appendingPathComponent(marker.skillTempName)) { try removeImportFile(marker.skillTempName, in: directory) }
        if stagedManifestExists, Self.entryExists(directory.appendingPathComponent(marker.manifestTempName)) { try removeImportFile(marker.manifestTempName, in: directory) }
        try removeImportFile(Self.importMarkerName, in: directory)
    }
    private func recoverPendingImports(heldSkillID: String? = nil) throws {
        observer?(.directoryList)
        let entries = try FileManager.default.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: nil)
        for directory in entries {
            let id = directory.lastPathComponent
            guard !id.hasPrefix("."), Self.isSafeSkillID(id), SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot), pendingMarkerExists(id) else { continue }
            // One unavailable or hostile skill cannot erase unrelated catalog items.
            do {
                if id == heldSkillID { try recoverImport(id) }
                else { try withSkillImportLock(id, allowPending: true) { try recoverImport(id) } }
            } catch { continue }
        }
    }
    private func verifyContentExpectation(_ expectation: SkillContentExpectation?, for id: String) throws {
        guard let expectation else { return }
        let file = skillDirectoryURL(for: id).appendingPathComponent("SKILL.md")
        let matches: Bool
        switch expectation {
        case .absent:
            matches = !Self.entryExists(file)
        case let .hash(expected):
            matches = SkillFilesystemBoundary.isTrustedRegularFile(file, within: skillsRoot, maximumBytes: Self.maxSkillContentBytes) &&
                rawDisk(id).map(SkillManifest.hash) == expected
        }
        guard matches else { throw SkillError.importFailed(reason: "reviewed skill target changed") }
    }
    private func persistImportPair(id: String, content: String, manifest: SkillSourceManifest, nextLedger: Ledger,
                                   contentExpectation: SkillContentExpectation? = nil) throws {
        try verifyContentExpectation(contentExpectation, for: id)
        let directory = skillDirectoryURL(for: id)
        guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(skillsRoot),
              let directoryIdentity = SkillFilesystemBoundary.trustedDirectoryIdentity(directory, within: skillsRoot) else { throw SkillError.importFailed(reason: "Import target changed") }
        let previousContentExists = Self.entryExists(directory.appendingPathComponent("SKILL.md"))
        let previousManifestExists = Self.entryExists(directory.appendingPathComponent("manifest.json"))
        let previousContent = previousContentExists ? rawDisk(id) : nil
        let previousManifest = previousManifestExists ? manifestDisk(id) : nil
        guard !previousContentExists || previousContent != nil, !previousManifestExists || previousManifest != nil else { throw SkillError.importFailed(reason: "Unknown previous import pair") }
        let identifier = UUID().uuidString
        let bodyName = ".SKILL.md." + identifier + ".tmp"
        let manifestName = ".manifest.json." + identifier + ".tmp"
        let previousHash = previousContent.map(SkillManifest.hash)
        var marker = ImportMarker(transactionID: identifier, generation: generation == UInt64.max ? UInt64.max : max(1, generation + 1),
            skillID: id, skillTempName: bodyName, manifestTempName: manifestName,
            targetBindingDigest: targetDigest(id), previousPairDigest: Self.pairDigest(id: id, hash: previousHash, manifest: previousManifest),
            expectedPairDigest: Self.pairDigest(id: id, hash: manifest.contentHash, manifest: manifest), expectedContentHash: manifest.contentHash,
            expectedManifest: manifest, previousContentHash: previousHash, previousManifest: previousManifest, markerDigest: "")
        marker.markerDigest = Self.markerDigest(marker)
        let encoded = try Self.encode(marker)
        guard encoded.count <= 64 * 1024, validMarker(marker, for: id) else { throw SkillError.importFailed(reason: "Import marker exceeds its persistent boundary") }
        var ownedStaging: [(name: String, bytes: Data, identity: SkillFilesystemBoundary.EntryIdentity)] = []
        func stage(_ bytes: Data, named name: String) throws {
            try writeExclusive(bytes, name: name, in: directory)
            guard let identity = SkillFilesystemBoundary.trustedRegularFileIdentity(directory.appendingPathComponent(name), within: skillsRoot, maximumBytes: max(Self.maxSkillContentBytes, 64 * 1024)) else {
                throw SkillError.importFailed(reason: "Import staging identity changed")
            }
            ownedStaging.append((name, bytes, identity))
        }
        func removeOwnedStaging() throws {
            guard SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: rootIdentity),
                  SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot, matching: directoryIdentity) else { return }
            for owned in ownedStaging.reversed() {
                let file = directory.appendingPathComponent(owned.name)
                guard SkillFilesystemBoundary.isTrustedRegularFile(file, within: skillsRoot,
                    maximumBytes: max(Self.maxSkillContentBytes, 64 * 1024), matching: owned.identity),
                    secureData(owned.name, in: directory, maximum: max(Self.maxSkillContentBytes, 64 * 1024)) == owned.bytes else { continue }
                try removeImportFile(owned.name, in: directory)
            }
        }
        func verifyReviewedTarget() throws {
            do { try verifyContentExpectation(contentExpectation, for: id) }
            catch { try? removeOwnedStaging(); throw error }
        }
        try stage(Data(content.utf8), named: bodyName)
        try stage(try Self.encode(manifest), named: manifestName)
        guard SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: rootIdentity),
              SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot, matching: directoryIdentity) else { throw SkillError.importFailed(reason: "Import target changed before staging") }
        try verifyReviewedTarget()
        guard rawDisk(id).map(SkillManifest.hash) == previousHash, manifestDisk(id) == previousManifest else { throw SkillError.importFailed(reason: "Previous import pair changed during staging") }
        try stage(encoded, named: Self.importMarkerName)
        // The approved lifecycle state is persisted before exposing the pair. A
        // crash leaving the old pair cannot inject that pair with the new hash.
        try verifyReviewedTarget()
        do { try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(nextLedger))]) }
        catch { try? removeOwnedStaging(); throw error }
        try recoverImport(id)
    }

    private func destination(_ path: String) throws -> URL {
        if path == "@shared" { return sharedURL }
        guard let parts = SkillDescriptorReader.validRelativeComponents(path), parts.count <= 2,
              !parts[0].hasPrefix("."), parts.count == 1 ? parts[0] == "lifecycle-receipts.json" :
                (Self.isSafeSkillID(parts[0]) && ["SKILL.md", "manifest.json"].contains(parts[1])) else {
            throw SkillError.importFailed(reason: "Invalid transaction destination")
        }
        return parts.reduce(skillsRoot) { $0.appendingPathComponent($1) }
    }
    private func apply(_ writes: [Write]) throws {
        for write in writes {
            let url = try destination(write.path)
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            guard url == sharedURL ? SkillFilesystemBoundary.isApprovedRoot(directory) :
                    (directory == skillsRoot || SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot)) else {
                throw SkillError.importFailed(reason: "Transaction directory changed")
            }
            if FileManager.default.fileExists(atPath: url.path), !SkillFilesystemBoundary.isTrustedRegularFile(url, within: directory) {
                throw SkillError.importFailed(reason: "Transaction file changed")
            }
            if let data = write.data { try data.write(to: url, options: [.atomic]) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func commit(_ writes: [Write]) throws {
        var previous: [Write] = []
        for write in writes {
            let url = try destination(write.path)
            if FileManager.default.fileExists(atPath: url.path) {
                guard SkillFilesystemBoundary.isTrustedRegularFile(url, within: url.deletingLastPathComponent()) else { throw SkillError.importFailed(reason: "Unsafe persistence file") }
                previous.append(Write(path: write.path, data: try Data(contentsOf: url)))
            } else { previous.append(Write(path: write.path, data: nil)) }
        }
        do { try apply(writes) }
        catch {
            // This rollback covers an observed write failure. Crash-time pair
            // recovery remains the existing v2 marker contract, never this list.
            for write in previous.reversed() { try? apply([write]) }
            generation &+= 1
            throw error
        }
    }
    private func readRootFile(_ name: String, maximum: Int) -> Data? {
        observer?(.fileRead)
        guard let descriptor = SkillDescriptorReader.openDirectory(skillsRoot) else { return nil }
        defer { close(descriptor) }
        return SkillDescriptorReader.read(rootDescriptor: descriptor, relativePath: name, maximumBytes: maximum)
    }
    private func readLedger() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: lifecycleReceiptsFileURL.path) else { return Ledger() }
        guard let data = readRootFile("lifecycle-receipts.json", maximum: 64 * Self.maxSkillContentBytes) else { throw BL6SkillEnablementError.recoveryRequired }
        return try decodeLedger(data)
    }
    private func decodeLedger(_ data: Data) throws -> Ledger {
        if let value = try? JSONDecoder().decode(Ledger.self, from: data) { return value }
        if let old = try? JSONDecoder().decode([String: SkillLifecycleReceipt].self, from: data) {
            var value = Ledger(); value.receipts = old; return value
        }
        throw BL6SkillEnablementError.recoveryRequired
    }
    private func readMask() throws -> [String: Bool] {
        observer?(.fileRead)
        guard FileManager.default.fileExists(atPath: sharedURL.path) else { return [:] }
        guard SkillFilesystemBoundary.isTrustedRegularFile(sharedURL, within: sharedURL.deletingLastPathComponent(), maximumBytes: 4 * Self.maxSkillContentBytes),
              let value = try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: sharedURL)) else { throw BL6SkillEnablementError.recoveryRequired }
        return value
    }
    private func rawDisk(_ id: String, path: String = "SKILL.md", maximum: Int = SkillStore.maxSkillContentBytes) -> String? {
        guard Self.isSafeSkillID(id), SkillDescriptorReader.validRelativeComponents(path) != nil else { return nil }
        let file = skillDirectoryURL(for: id).appendingPathComponent(path)
        guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(skillsRoot),
              let fileIdentity = SkillFilesystemBoundary.trustedRegularFileIdentity(file, within: skillsRoot, maximumBytes: maximum) else { return nil }
        observer?(.fileRead)
        guard let descriptor = SkillDescriptorReader.openDirectory(skillsRoot) else { return nil }
        defer { close(descriptor) }
        guard let data = SkillDescriptorReader.read(rootDescriptor: descriptor, relativePath: id + "/" + path, maximumBytes: maximum),
              SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: rootIdentity),
              SkillFilesystemBoundary.isTrustedRegularFile(file, within: skillsRoot, maximumBytes: maximum, matching: fileIdentity) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func manifestDisk(_ id: String) -> SkillSourceManifest? {
        guard let text = rawDisk(id, path: "manifest.json", maximum: SkillFilesystemBoundary.maxManifestBytes) else { return nil }
        return try? JSONDecoder().decode(SkillSourceManifest.self, from: Data(text.utf8))
    }
    private func inspect(_ id: String, raw: String, parsed: ParsedSkillMD) -> SkillIntegrity {
        let hash = SkillManifest.hash(raw)
        guard FileManager.default.fileExists(atPath: skillManifestURL(for: id).path) else {
            return SkillIntegrity(state: .missingManifest, observedContentHash: hash)
        }
        guard let manifest = manifestDisk(id) else { return SkillIntegrity(state: .malformedManifest, observedContentHash: hash) }
        guard manifest.schema == SkillSourceManifest.currentSchema, manifest.version == SkillSourceManifest.currentVersion,
              manifest.skillID == id, manifest.skillVersion == parsed.version else {
            return SkillIntegrity(state: .manifestMismatch, manifest: manifest, observedContentHash: hash)
        }
        guard manifest.contentHash == hash else { return SkillIntegrity(state: .hashMismatch, manifest: manifest, observedContentHash: hash) }
        return SkillIntegrity(state: .verified, manifest: manifest, observedContentHash: hash)
    }
    private func mainSourceIsAbsent(_ id: String) -> Bool {
        guard let directory = SkillDescriptorReader.openDirectory(skillDirectoryURL(for: id), within: skillsRoot) else { return false }
        defer { close(directory) }
        var attributes = stat()
        return fstatat(directory, "SKILL.md", &attributes, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }
    private final class ScanContentionBudget {
        var remaining: TimeInterval = 2
        var exhausted = false
    }

    private func refreshProjection(persistQuarantine: Bool = true, heldSkillID: String? = nil) throws {
        // The scan can take longer than two seconds. Only lock backoff spends this shared budget.
        let contentionBudget = ScanContentionBudget()
        let prior = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        var nextLedger: Ledger
        do { nextLedger = try readLedger(); ledgerIsReadable = true }
        catch { nextLedger = Ledger(); ledgerIsReadable = false }
        if let pending = nextLedger.bl6EnablementPending { nextLedger.disabledSkillIDs.insert(pending.completion.skillID) }
        let mask = (try? readMask()) ?? [:]
        observer?(.directoryList)
        let children = try FileManager.default.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: nil)
        var next: [Skill] = [], rawContents: [String: String] = [:]
        var changedLedger = false
        for directory in children {
            let id = directory.lastPathComponent
            guard !id.hasPrefix("."), Self.isSafeSkillID(id), SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot) else { continue }
            if prior[id] == nil, nextLedger.receipts[id] == nil, !pendingMarkerExists(id),
               !Self.entryExists(directory.appendingPathComponent("SKILL.md")),
               !Self.entryExists(directory.appendingPathComponent("manifest.json")) { continue }
            func consume() {
                guard !pendingMarkerExists(id) else { return }
                guard let raw = rawDisk(id), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if var known = prior[id], known.integrity.state == .verified, mainSourceIsAbsent(id),
                       let manifest = manifestDisk(id), manifest == known.integrity.manifest,
                       let receipt = nextLedger.receipts[id], receipt == ledger.receipts[id], receipt.state == .active,
                       receipt.contentHash == manifest.contentHash, receipt.sourceIdentity == "skill:\(id)@\(manifest.contentHash)" {
                        known.body = ""
                        next.append(known)
                    }
                    return
                }
                var parsed = Self.parse(skillMD: raw)
                let integrity = inspect(id, raw: raw, parsed: parsed)
                let source = integrity.manifest?.source ?? .file
                if parsed.name == Self.defaultSkillName, case let .url(address) = source { parsed.name = Self.nameFromURL(address) }
                let hash = SkillManifest.hash(raw)
                let receipt = nextLedger.receipts[id]
                let receiptMatches = receipt.flatMap { receipt in integrity.manifest.map { Self.receiptIsBound(receipt, id: id, manifest: $0, requiresApproval: receipt.state == .active) && receipt.contentHash == hash } } ?? false
                if integrity.state != .verified || !receiptMatches {
                    if let receipt, receipt.state != .quarantined {
                        nextLedger.receipts[id] = SkillLifecycle.quarantine(receipt, reason: "Installed content or manifest changed")
                        changedLedger = true
                    }
                    if !nextLedger.disabledSkillIDs.contains(id) { nextLedger.disabledSkillIDs.insert(id); changedLedger = true }
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
                let installed = prior[id]?.installedAt ?? attributes?[.creationDate] as? Date ?? Date()
                let updated = prior[id].flatMap { cachedRaw[id] == raw ? $0.updatedAt : nil } ?? attributes?[.modificationDate] as? Date ?? installed
                let enabled = !nextLedger.disabledSkillIDs.contains(id) && (mask["app:" + id] ?? mask[id] ?? true) && integrity.state == .verified && receiptMatches && receipt?.state == .active
                next.append(Skill(id: id, name: parsed.name, description: parsed.description, version: parsed.version,
                                  importSource: source, isEnabled: enabled, installedAt: installed, updatedAt: updated,
                                  body: parsed.body, useCount: prior[id]?.useCount ?? 0, integrity: integrity))
                rawContents[id] = raw
            }
            if id == heldSkillID { consume() }
            else {
                guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(skillsRoot),
                      let directoryIdentity = SkillFilesystemBoundary.trustedDirectoryIdentity(directory, within: skillsRoot) else {
                    throw SkillError.importFailed(reason: "Skill scan identity changed")
                }
                let complete: Bool? = coordinatedRead(id, rootIdentity: rootIdentity, directoryIdentity: directoryIdentity,
                    limit: .infinity, contentionBudget: contentionBudget) { consume(); return true }
                // 任一技能未完整读取，本次刷新全有或全无：不发布新集合或ready，等待显式重试。
                guard complete == true else { throw SkillError.importFailed(reason: "Skill scan could not obtain a complete version") }
            }
        }
        if changedLedger && persistQuarantine && ledgerIsReadable && nextLedger.bl6EnablementPending == nil { try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(nextLedger))]) }
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if skills != next || cachedRaw != rawContents || ledger.receipts != nextLedger.receipts || ledger.disabledSkillIDs != nextLedger.disabledSkillIDs { generation &+= 1 }
        ledger = nextLedger; cachedRaw = rawContents; sharedMask = mask
        skills = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public func reload() {
        if synchronized({ frozen }) { return }
        do {
            try withDiskLock {
                try synchronized {
                    try recoverPendingImports()
                    do { try recoverEnablementPending() } catch { ledgerIsReadable = false }
                    try refreshProjection()
                    publishInitialReadiness()
                }
            }
        } catch { synchronized { ledgerIsReadable = false; generation &+= 1 } }
    }
    private func mutate<T>(coordinating skillID: String? = nil, _ action: () throws -> T) throws -> T {
        // Acquire the common domain before the instance mutex on every live path.
        // A frozen view is rejected without ever entering live persistence.
        try assertInitialReadReady()
        try synchronized { try assertMutable() }
        return try withDiskLock {
            try synchronized {
                try assertMutable()
                func perform() throws -> T {
                    try recoverPendingImports(heldSkillID: skillID)
                    if let skillID, pendingMarkerExists(skillID) { throw SkillError.importFailed(reason: "Skill import requires recovery") }
                    try recoverEnablementPending(); try refreshProjection(heldSkillID: skillID)
                    try assertMutable()
                    return try action()
                }
                if let skillID { return try withSkillImportLock(skillID, allowPending: true, createIfMissing: false, perform) }
                return try perform()
            }
        }
    }
    public func allSkills() -> [Skill] {
        if let before = beforeProjection() { return before.skills }
        return readyRead(or: { [] }) {
            withReadFence { synchronized { skills } }
        }
    }
    public func rawContent(_ skillId: String) -> String? {
        if let before = beforeProjection() { return Self.isSafeSkillID(skillId) ? before.rawContents[skillId] : nil }
        return readyRead(or: { nil }) {
            withReadFence { synchronized {
                guard Self.isSafeSkillID(skillId) else { return nil }
                return frozen ? cachedRaw[skillId] : rawDisk(skillId)
            } }
        }
    }
    public func skillContent(_ skillId: String) -> String? {
        guard let raw = rawContent(skillId) else { return nil }
        let body = Self.parse(skillMD: raw).body
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }
    public func lifecycleReceipt(for skillID: String) -> SkillLifecycleReceipt? {
        if let before = beforeProjection() { return before.lifecycleReceipts[skillID] }
        return readyRead(or: { nil }) {
            withReadFence { synchronized { ledgerIsReadable ? ledger.receipts[skillID] : nil } }
        }
    }
    public func integrity(for skillID: String) -> SkillIntegrity? { allSkills().first { $0.id == skillID }?.integrity }
    public func search(_ query: String) -> [Skill] {
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return allSkills().filter { skill in let haystack = (skill.name + " " + skill.description).lowercased(); return words.allSatisfy(haystack.contains) }
    }
    private func validActivation(_ id: String, raw: String, within scope: MemoryScope?) -> Bool {
        guard let skill = skills.first(where: { $0.id == id }), skill.isEnabled, skill.integrity.state == .verified,
              let manifest = skill.integrity.manifest, manifest.contentHash == SkillManifest.hash(raw),
              let receipt = ledger.receipts[id], Self.receiptIsBound(receipt, id: id, manifest: manifest),
              !ledger.disabledSkillIDs.contains(id),
              sharedMask["app:" + id] ?? sharedMask[id] ?? true else { return false }
        return SkillLifecycle.isActivationValid(receipt, currentContentHash: manifest.contentHash, scope: scope)
    }
    public func isInjectable(_ skill: Skill, within scope: MemoryScope? = nil) -> Bool {
        injectableSkills([skill], within: scope).contains(skill.id)
    }

    internal func injectableSkills(
        _ candidates: [Skill],
        within scope: MemoryScope?,
        accepting: (Skill, String?) -> Bool = { _, _ in true }
    ) -> Set<String> {
        guard candidates.contains(where: \.isEnabled) else { return [] }
        return readyRead(or: { [] }) {
            if synchronized({ frozen }) {
                return withReadFence { synchronized {
                    guard ledgerIsReadable, ledger.bl6EnablementPending == nil else { return [] }
                    return Set(candidates.compactMap { skill in
                        guard skill.isEnabled, accepting(skill, cachedRaw[skill.id]), let raw = cachedRaw[skill.id],
                              validActivation(skill.id, raw: raw, within: scope) else { return nil }
                        return skill.id
                    })
                } }
            }
            do {
                return try withDiskLock {
                    try synchronized {
                        guard ledgerIsReadable, ledger.bl6EnablementPending == nil,
                              candidates.contains(where: { $0.isEnabled && Self.isSafeSkillID($0.id) }) else { return [] }
                        try refreshProjection()
                        var accepted = Set<String>()
                        for skill in candidates {
                            guard skill.isEnabled, Self.isSafeSkillID(skill.id),
                                  accepting(skill, cachedRaw[skill.id]) else { continue }
                            do {
                                if try validatesLiveCandidate(skill, within: scope) { accepted.insert(skill.id) }
                            } catch {
                                // A failed quarantine write may have changed disk state.
                                // Reestablish a complete projection before considering another candidate.
                                try refreshProjection()
                            }
                        }
                        return accepted
                    }
                }
            } catch { return [] }
        }
    }

    private func validatesLiveCandidate(_ skill: Skill, within scope: MemoryScope?) throws -> Bool {
        if let current = skills.first(where: { $0.id == skill.id }),
           let capturedManifest = skill.integrity.manifest, let liveManifest = current.integrity.manifest,
           capturedManifest.contentHash == liveManifest.contentHash, capturedManifest != liveManifest,
           let receipt = ledger.receipts[skill.id], receipt.contentHash == liveManifest.contentHash {
            var next = ledger
            next.receipts[skill.id] = SkillLifecycle.quarantine(receipt, reason: "Live source manifest differs from captured skill")
            next.disabledSkillIDs.insert(skill.id)
            try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(next))])
            try refreshProjection(); generation &+= 1
            return false
        }
        guard ledgerIsReadable, ledger.bl6EnablementPending == nil,
              let current = skills.first(where: { $0.id == skill.id }), current.isEnabled,
              current.importSource == skill.importSource, current.version == skill.version,
              current.integrity == skill.integrity, let raw = cachedRaw[skill.id] else { return false }
        return validActivation(skill.id, raw: raw, within: scope)
    }
    private static func trust(_ source: SkillImportSource) -> SkillTrust {
        switch source { case .bundled, .file: return .local; case .url, .session: return .untrusted }
    }
    private static func receiptIsBound(_ receipt: SkillLifecycleReceipt, id: String, manifest: SkillSourceManifest, requiresApproval: Bool = true) -> Bool {
        receipt.skillID == id && receipt.contentHash == manifest.contentHash &&
            receipt.sourceIdentity == "skill:\(id)@\(manifest.contentHash)" && receipt.trust == trust(manifest.source) &&
            (!requiresApproval || receipt.approvedBy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
    @discardableResult
    public func importSkill(content: String, source: SkillImportSource = .file) throws -> Skill {
        let approval = SkillApproval(approverID: "explicit-user-import")
        return try importSkillThroughLifecycle(content: content, source: source, reason: "explicit user import compatibility", approval: approval).skill
    }
    @discardableResult
    public func importSkillThroughLifecycle(content: String, source: SkillImportSource = .file, reason: String,
                                            scope: MemoryScope? = nil, approval: SkillApproval? = nil,
                                            contentExpectation: SkillContentExpectation? = nil) throws -> SkillLifecycleImportResult {
        do {
            return try mutate {
                guard content.utf8.count <= Self.maxSkillContentBytes else { throw SkillError.contentTooLarge }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillError.invalidContent }
                var parsed = Self.parse(skillMD: content)
                if parsed.name == Self.defaultSkillName, case let .url(address) = source { parsed.name = Self.nameFromURL(address) }
                let id = Self.slugify(parsed.name)
                guard Self.isSafeSkillID(id), !id.isEmpty else { throw SkillError.invalidContent }
                let receipt = try withSkillImportLock(id) {
                try verifyContentExpectation(contentExpectation, for: id)
                if let _ = contentExpectation { try refreshProjection(heldSkillID: id) }
                let old = skills.first { $0.id == id }
                let previousRaw = cachedRaw[id]
                let manifest = SkillSourceManifest(skillID: id, source: source, skillVersion: parsed.version, content: content)
                var next = ledger
                var receipt: SkillLifecycleReceipt
                if previousRaw == content, let current = ledger.receipts[id],
                   current.action == .activate, current.state == .active, current.trust != .untrusted,
                   current.approvedBy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                   current.scope == scope, current.sourceIdentity == "skill:\(id)@\(manifest.contentHash)",
                   SkillLifecycle.isActivationValid(current, currentContentHash: manifest.contentHash, scope: scope) {
                    receipt = current
                } else {
                    let proposal = SkillLifecycle.propose(SkillManifest(skillID: id, name: parsed.name, content: content, trust: Self.trust(source)), scope: scope, reason: reason)
                    if Self.trust(source) == .untrusted {
                        receipt = SkillLifecycle.quarantine(proposal, reason: reason)
                    } else if let approval {
                        guard let approved = SkillLifecycle.approve(proposal, approval: approval, reason: reason),
                              let active = SkillLifecycle.activate(approved, currentContentHash: manifest.contentHash, reason: reason) else { throw SkillError.importFailed(reason: "Approval rejected") }
                        receipt = active
                    } else { receipt = Self.trust(source) == .untrusted ? SkillLifecycle.quarantine(proposal, reason: reason) : proposal }
                    if let previousRaw, let previousManifest = old?.integrity.manifest,
                       previousManifest.contentHash == SkillManifest.hash(previousRaw), let previousReceipt = ledger.receipts[id],
                       previousReceipt.contentHash == previousManifest.contentHash {
                        next.previousVersions[id] = Previous(content: previousRaw, receipt: previousReceipt, manifest: previousManifest)
                    }
                }
                next.receipts[id] = receipt
                if receipt.state != .active || old?.isEnabled == false { next.disabledSkillIDs.insert(id) }
                else if old == nil { next.disabledSkillIDs.remove(id) }
                try persistImportPair(id: id, content: content, manifest: manifest, nextLedger: next, contentExpectation: contentExpectation)
                return receipt
                }
                try refreshProjection()
                guard var result = skills.first(where: { $0.id == id }) else { throw SkillError.importFailed(reason: "Committed skill unavailable") }
                result.updatedAt = Date()
                if let position = skills.firstIndex(where: { $0.id == id }) { skills[position] = result }
                generation &+= 1
                return SkillLifecycleImportResult(skill: result, receipt: receipt)
            }
        } catch is BL6SkillEnablementError {
            throw SkillError.importFailed(reason: "Skill lifecycle persistence unavailable")
        } catch is CocoaError {
            throw SkillError.importFailed(reason: "Skill lifecycle persistence failed")
        } catch is POSIXError {
            throw SkillError.importFailed(reason: "Skill lifecycle persistence failed")
        }
    }
    public func importSkill(from url: URL, source: SkillImportSource = .file) throws -> [Skill] {
        try assertInitialReadReady()
        try synchronized { try assertMutable() }
        guard url.isFileURL else { throw SkillError.importFailed(reason: "Import path is not a local file") }
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw SkillError.importFailed(reason: "Import path is unavailable or unsafe") }
        if attributes[.type] as? FileAttributeType == .typeRegular {
            if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(Self.maxSkillContentBytes) { throw SkillError.contentTooLarge }
            guard let descriptor = SkillDescriptorReader.openDirectory(url.deletingLastPathComponent()) else { throw SkillError.noSkillMD(at: url.path) }
            defer { close(descriptor) }
            guard let data = SkillDescriptorReader.read(rootDescriptor: descriptor, relativePath: url.lastPathComponent, maximumBytes: Self.maxSkillContentBytes) else { throw SkillError.invalidContent }
            guard let raw = String(data: data, encoding: .utf8) else { throw SkillError.importFailed(reason: "skill source is not a stable UTF-8 file") }
            return [try importSkill(content: raw, source: source)]
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SkillError.noSkillMD(at: url.path) }
        let direct = url.appendingPathComponent("SKILL.md")
        if manager.fileExists(atPath: direct.path) { return try importSkill(from: direct, source: source) }
        observer?(.directoryList)
        let entries = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        var imported: [Skill] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            let attrs = try manager.attributesOfItem(atPath: entry.path)
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw SkillError.importFailed(reason: "Unsafe collection member") }
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  manager.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path) else { continue }
            guard let descriptor = SkillDescriptorReader.openDirectory(entry, within: url) else { throw SkillError.importFailed(reason: "Collection member is unreadable") }
            let bytes = SkillDescriptorReader.read(rootDescriptor: descriptor, relativePath: "SKILL.md", maximumBytes: Self.maxSkillContentBytes)
            close(descriptor)
            guard let bytes, let content = String(data: bytes, encoding: .utf8) else { throw SkillError.invalidContent }
            imported.append(try importSkill(content: content, source: source))
        }
        return imported
    }
    @discardableResult
    public func setEnabled(_ skillId: String, enabled: Bool, within scope: MemoryScope? = nil) -> Bool {
        do {
            return try mutate {
                guard let skill = skills.first(where: { $0.id == skillId }), let raw = cachedRaw[skillId] else { return false }
                if enabled {
                    guard let receipt = ledger.receipts[skillId], skill.integrity.state == .verified,
                          SkillLifecycle.isActivationValid(receipt, currentContentHash: SkillManifest.hash(raw), scope: scope) else { return false }
                }
                var next = ledger
                if enabled { next.disabledSkillIDs.remove(skillId) } else { next.disabledSkillIDs.insert(skillId) }
                try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(next))])
                try refreshProjection(); generation &+= 1; return true
            }
        } catch { return false }
    }
    public func approveAndActivateSkill(_ skillID: String, approval: SkillApproval, reason: String) throws -> SkillLifecycleReceipt {
        try mutate {
            guard let skill = skills.first(where: { $0.id == skillID }), let raw = cachedRaw[skillID], skill.integrity.state == .verified else { throw SkillError.skillNotFound(skillID) }
            let proposal = SkillLifecycle.propose(SkillManifest(skillID: skillID, name: skill.name, content: raw, trust: Self.trust(skill.importSource)), scope: approval.scope, reason: reason)
            guard let approved = SkillLifecycle.approve(proposal, approval: approval, reason: reason),
                  let active = SkillLifecycle.activate(approved, currentContentHash: SkillManifest.hash(raw), reason: reason) else { throw SkillError.importFailed(reason: "Approval rejected") }
            var next = ledger; next.receipts[skillID] = active; next.disabledSkillIDs.remove(skillID)
            try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(next))]); try refreshProjection(); generation &+= 1
            return active
        }
    }
    private func verifiablePrevious(_ id: String) -> Previous? {
        guard let previous = ledger.previousVersions[id], let manifest = previous.manifest,
              manifest.schema == SkillSourceManifest.currentSchema, manifest.version == SkillSourceManifest.currentVersion,
              manifest.skillID == id, manifest.contentHash == SkillManifest.hash(previous.content),
              manifest.skillVersion == Self.parse(skillMD: previous.content).version,
              let receipt = previous.receipt, Self.receiptIsBound(receipt, id: id, manifest: manifest) else { return nil }
        return previous
    }
    public func canRollbackSkill(_ skillID: String) -> Bool {
        return readyRead(or: { false }) {
            withReadFence { synchronized { ledgerIsReadable && ledger.receipts[skillID] != nil && ledger.receipts[skillID]?.state != .quarantined && verifiablePrevious(skillID) != nil } }
        }
    }
    public func rollbackSkill(_ skillID: String, reason: String) throws -> SkillLifecycleReceipt {
        guard Self.isSafeSkillID(skillID) else { throw SkillError.importFailed(reason: "No verifiable previous version") }
        return try mutate(coordinating: skillID) {
            guard let prior = verifiablePrevious(skillID), let manifest = prior.manifest, let current = ledger.receipts[skillID], current.state != .quarantined,
                  let receipt = SkillLifecycle.rollback(current, previousContentHash: manifest.contentHash, previousReceipt: prior.receipt, reason: reason) else { throw SkillError.importFailed(reason: "No verifiable previous version") }
            var next = ledger; next.receipts[skillID] = receipt; next.disabledSkillIDs.insert(skillID); next.previousVersions.removeValue(forKey: skillID)
            try commit([Write(path: skillID + "/SKILL.md", data: Data(prior.content.utf8)), Write(path: skillID + "/manifest.json", data: Self.encode(manifest)), Write(path: "lifecycle-receipts.json", data: Self.encode(next))])
            try refreshProjection(heldSkillID: skillID); generation &+= 1; return receipt
        }
    }
    public struct Snapshot: Sendable, Equatable {
        public let skillsRoot: URL
        public let skills: [Skill]
        public let lifecycleReceipts: [String: SkillLifecycleReceipt]
        public let disabledSkillIDs: Set<String>
        public let rawContents: [String: String]
        public let fileContents: [String: [String: String]]
        public init(skillsRoot: URL, skills: [Skill], lifecycleReceipts: [String: SkillLifecycleReceipt], disabledSkillIDs: Set<String>, rawContents: [String: String], fileContents: [String: [String: String]] = [:]) {
            self.skillsRoot = skillsRoot; self.skills = skills; self.lifecycleReceipts = lifecycleReceipts
            self.disabledSkillIDs = disabledSkillIDs; self.rawContents = rawContents; self.fileContents = fileContents
        }
    }
    public struct TurnCapture: Sendable {
        private let owner: SkillStore
        fileprivate let instance: UUID
        fileprivate let generation: UInt64
        fileprivate let readyAtCapture: Bool
        fileprivate init(owner: SkillStore, instance: UUID, generation: UInt64, readyAtCapture: Bool) {
            self.owner = owner; self.instance = instance; self.generation = generation; self.readyAtCapture = readyAtCapture
        }
        public func prepareStore() -> SkillStore? {
            guard readyAtCapture, !Task.isCancelled, let captured = owner.prepareContents(for: self), !Task.isCancelled else { return nil }
            let frozen = SkillStore.makeSnapshotStore(from: captured, domain: owner.transactionDomain)
            return Task.isCancelled ? nil : frozen
        }
    }
    public func captureTurnAuthority() -> TurnCapture {
        readyRead(or: { TurnCapture(owner: self, instance: instanceID, generation: 0, readyAtCapture: false) }, checkingDomain: false) {
            synchronized { TurnCapture(owner: self, instance: instanceID, generation: generation, readyAtCapture: true) }
        }
    }
    public func matchesTurnAuthority(_ capture: TurnCapture) -> Bool {
        guard capture.readyAtCapture else { return false }
        do { try PersistenceTransactionFence.requireLiveRead(transactionDomain) } catch { return false }
        return readyRead(or: { false }) {
            synchronized { capture.instance == instanceID && capture.generation == generation && ledgerIsReadable && ledger.bl6EnablementPending == nil }
        }
    }
    private func prepareContents(for capture: TurnCapture) -> Snapshot? {
        let seed: (value: Snapshot, frozen: Bool)? = withReadFence { synchronized {
            guard matchesTurnAuthority(capture), !Task.isCancelled else { return nil }
            return (Snapshot(skillsRoot: skillsRoot, skills: skills, lifecycleReceipts: ledger.receipts,
                disabledSkillIDs: ledger.disabledSkillIDs, rawContents: cachedRaw, fileContents: frozenFiles), frozen)
        } }
        guard let seed else { return nil }
        if seed.frozen { return Task.isCancelled ? nil : seed.value }
        do {
            let mask = try readMask()
            guard let rootIdentity = SkillFilesystemBoundary.approvedRootIdentity(skillsRoot) else {
                throw SkillError.importFailed(reason: "Preparation root unavailable")
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var files: [String: [String: String]] = [:]
            for skill in seed.value.skills {
                try Task.checkCancellation()
                let directory = skillDirectoryURL(for: skill.id)
                guard let directoryIdentity = SkillFilesystemBoundary.trustedDirectoryIdentity(directory, within: skillsRoot) else {
                    throw SkillError.importFailed(reason: "Preparation directory unavailable")
                }
                var failure: Error?
                let complete: Bool? = coordinatedRead(skill.id, rootIdentity: rootIdentity, directoryIdentity: directoryIdentity, limit: deadline) {
                    do {
                        let manifestData = self.secureData("manifest.json", in: directory, maximum: SkillFilesystemBoundary.maxManifestBytes)
                        let manifest = manifestData.flatMap { try? JSONDecoder().decode(SkillSourceManifest.self, from: $0) }
                        if skill.integrity.state == .verified {
                            guard manifest == skill.integrity.manifest else { throw SkillError.importFailed(reason: "Preparation manifest changed") }
                        }
                        var entries: [String: String] = [:]
                        if let manifestText = manifestData.flatMap({ String(data: $0, encoding: .utf8) }) { entries["manifest.json"] = manifestText }
                        if seed.value.rawContents[skill.id] == nil, self.mainSourceIsAbsent(skill.id) {
                            guard manifest == skill.integrity.manifest else { throw SkillError.importFailed(reason: "Known source proof changed") }
                            for path in self.listDiskFiles(skill.id) where path != "SKILL.md" {
                                try Task.checkCancellation()
                                guard let text = self.rawDisk(skill.id, path: path) else { throw SkillError.importFailed(reason: "Preparation auxiliary content changed") }
                                entries[path] = text
                            }
                        } else {
                            for path in self.listDiskFiles(skill.id) {
                                try Task.checkCancellation()
                                guard let text = self.rawDisk(skill.id, path: path) else { throw SkillError.importFailed(reason: "Preparation payload changed") }
                                entries[path] = text
                            }
                            guard entries["SKILL.md"] == seed.value.rawContents[skill.id] else { throw SkillError.importFailed(reason: "Preparation content changed") }
                        }
                        guard self.secureData("manifest.json", in: directory, maximum: SkillFilesystemBoundary.maxManifestBytes) == manifestData else {
                            throw SkillError.importFailed(reason: "Preparation manifest changed during reading")
                        }
                        files[skill.id] = entries
                        return true
                    } catch { failure = error; return nil }
                }
                try Task.checkCancellation()
                if let failure { throw failure }
                guard complete == true else { throw SkillError.importFailed(reason: "Preparation coordination unavailable") }
            }
            try Task.checkCancellation()
            guard try readMask() == mask, SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: rootIdentity) else {
                throw SkillError.importFailed(reason: "Preparation shared state changed")
            }
            let currentLedger: Ledger
            if let data = secureData("lifecycle-receipts.json", in: skillsRoot, maximum: 64 * Self.maxSkillContentBytes) {
                currentLedger = try decodeLedger(data)
            } else if !Self.entryExists(lifecycleReceiptsFileURL) { currentLedger = Ledger() }
            else { throw SkillError.importFailed(reason: "Preparation lifecycle unavailable") }
            guard currentLedger.receipts == seed.value.lifecycleReceipts,
                  currentLedger.disabledSkillIDs == seed.value.disabledSkillIDs, currentLedger.bl6EnablementPending == nil else {
                throw SkillError.importFailed(reason: "Preparation lifecycle changed")
            }
            var projected = seed.value.skills
            for index in projected.indices {
                let id = projected[index].id
                let receipt = seed.value.lifecycleReceipts[id]
                projected[index].isEnabled = !seed.value.disabledSkillIDs.contains(id) &&
                    (mask["app:" + id] ?? mask[id] ?? true) && projected[index].integrity.state == .verified &&
                    receipt?.state == .active && receipt.flatMap { receipt in projected[index].integrity.manifest.map { Self.receiptIsBound(receipt, id: id, manifest: $0) } } == true
            }
            let value = Snapshot(skillsRoot: skillsRoot, skills: projected, lifecycleReceipts: seed.value.lifecycleReceipts,
                disabledSkillIDs: seed.value.disabledSkillIDs, rawContents: seed.value.rawContents, fileContents: files)
            return withReadFence { synchronized {
                guard !Task.isCancelled, ledgerIsReadable, ledger.bl6EnablementPending == nil,
                      ledger.receipts == seed.value.lifecycleReceipts, ledger.disabledSkillIDs == seed.value.disabledSkillIDs,
                      cachedRaw == seed.value.rawContents else { return nil }
                if generation != capture.generation {
                    // A coherent value can finish after ABA; the capture's currentness stays false.
                    return skills == projected ? value : nil
                }
                if skills != projected {
                    let expands = zip(skills, projected).contains { !$0.0.isEnabled && $0.1.isEnabled }
                    skills = projected; sharedMask = mask; generation &+= 1
                    return expands ? nil : value
                }
                sharedMask = mask
                return value
            } }
        } catch is CancellationError { return nil }
        catch {
            if !Task.isCancelled { synchronized { if generation == capture.generation { generation &+= 1 } } }
            return nil
        }
    }
    public func snapshot() -> Snapshot {
        if let before = beforeProjection() { return before }
        return readyRead(or: { Snapshot(skillsRoot: skillsRoot, skills: [], lifecycleReceipts: [:], disabledSkillIDs: [], rawContents: [:]) }) {
            withReadFence { synchronized {
                func value() -> Snapshot {
                    Snapshot(skillsRoot: skillsRoot, skills: skills, lifecycleReceipts: ledger.receipts, disabledSkillIDs: ledger.disabledSkillIDs, rawContents: cachedRaw, fileContents: frozenFiles)
                }
                if frozen { return value() }
                do {
                    return try { () throws -> Snapshot in
                        let diskAuthority = try readLedger()
                        try refreshProjection(persistQuarantine: false)
                        let before = generation
                        var files: [String: [String: String]] = [:]
                        for skill in skills {
                            if Task.isCancelled { throw CancellationError() }
                            var entries: [String: String] = [:]
                            if cachedRaw[skill.id] == nil, mainSourceIsAbsent(skill.id) {
                                guard let text = rawDisk(skill.id, path: "manifest.json", maximum: SkillFilesystemBoundary.maxManifestBytes),
                                      let manifest = try? JSONDecoder().decode(SkillSourceManifest.self, from: Data(text.utf8)),
                                      manifest == skill.integrity.manifest else { throw SkillError.importFailed(reason: "Known source proof changed") }
                                var entries = ["manifest.json": text]
                                for path in listDiskFiles(skill.id) where path != "SKILL.md" {
                                    try Task.checkCancellation()
                                    guard let text = rawDisk(skill.id, path: path) else { throw SkillError.importFailed(reason: "Snapshot auxiliary content changed") }
                                    entries[path] = text
                                }
                                files[skill.id] = entries
                                continue
                            }
                            for path in listDiskFiles(skill.id) {
                                guard let text = rawDisk(skill.id, path: path) else { throw SkillError.importFailed(reason: "Snapshot changed during preparation") }
                                entries[path] = text
                            }
                            guard entries["SKILL.md"] == cachedRaw[skill.id] else { throw SkillError.importFailed(reason: "Snapshot content changed") }
                            if let manifest = rawDisk(skill.id, path: "manifest.json", maximum: SkillFilesystemBoundary.maxManifestBytes) { entries["manifest.json"] = manifest }
                            files[skill.id] = entries
                        }
                        let diskAfter = try readLedger()
                        guard diskAuthority.receipts == diskAfter.receipts, diskAuthority.disabledSkillIDs == diskAfter.disabledSkillIDs,
                              diskAuthority.bl6EnablementPending?.completion.record == diskAfter.bl6EnablementPending?.completion.record else {
                            throw SkillError.importFailed(reason: "Snapshot lifecycle changed")
                        }
                        for skill in skills {
                            try Task.checkCancellation()
                            if let expected = files[skill.id]?["SKILL.md"] {
                                guard rawDisk(skill.id) == expected else { throw SkillError.importFailed(reason: "Snapshot source changed") }
                            } else if !mainSourceIsAbsent(skill.id) { throw SkillError.importFailed(reason: "Snapshot source appeared") }
                            guard rawDisk(skill.id, path: "manifest.json", maximum: SkillFilesystemBoundary.maxManifestBytes) == files[skill.id]?["manifest.json"] else {
                                throw SkillError.importFailed(reason: "Snapshot manifest changed")
                            }
                        }
                        guard before == generation else { throw SkillError.importFailed(reason: "Snapshot authority changed") }
                        return Snapshot(skillsRoot: skillsRoot, skills: skills, lifecycleReceipts: ledger.receipts, disabledSkillIDs: ledger.disabledSkillIDs, rawContents: cachedRaw, fileContents: files)
                    }()
                } catch {
                    if !Task.isCancelled { generation &+= 1 }
                    return Snapshot(skillsRoot: skillsRoot, skills: [], lifecycleReceipts: [:], disabledSkillIDs: [], rawContents: [:])
                }
            } }
        }
    }
    public static func makeSnapshotStore(from snapshot: Snapshot) -> SkillStore {
        makeSnapshotStore(from: snapshot, domain: nil)
    }
    private static func makeSnapshotStore(from snapshot: Snapshot, domain: PersistenceTransactionFence.Domain?) -> SkillStore {
        let store = SkillStore(root: snapshot.skillsRoot, observer: nil, bootstrap: true, domain: domain)
        store.frozen = true; store.publishInitialReadiness(); store.skills = snapshot.skills
        store.ledger.receipts = snapshot.lifecycleReceipts; store.ledger.disabledSkillIDs = snapshot.disabledSkillIDs
        store.cachedRaw = snapshot.rawContents; store.frozenFiles = snapshot.fileContents
        return store
    }
    public func makeSnapshotStore() -> SkillStore {
        if let before = beforeProjection() { return Self.makeSnapshotStore(from: before, domain: transactionDomain) }
        return readyRead(or: {
            let store = SkillStore(root: skillsRoot, observer: nil, bootstrap: true, domain: transactionDomain)
            store.frozen = true
            return store
        }) { Self.makeSnapshotStore(from: snapshot(), domain: transactionDomain) }
    }
    public func snapshotForTurn() -> SkillStore { makeSnapshotStore() }
    private func listDiskFiles(_ id: String) -> [String] {
        guard Self.isSafeSkillID(id), SkillFilesystemBoundary.isTrustedDirectory(skillDirectoryURL(for: id), within: skillsRoot) else { return Self.isSafeSkillID(id) ? ["SKILL.md"] : [] }
        observer?(.recursiveEnumeration)
        let directory = skillDirectoryURL(for: id)
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return ["SKILL.md"] }
        var paths: [String] = []
        while let path = walker.nextObject() as? String {
            guard let components = SkillDescriptorReader.validRelativeComponents(path),
                  !components.contains(where: { $0.hasPrefix(".") }) else { walker.skipDescendants(); continue }
            let entry = components.reduce(directory) { $0.appendingPathComponent($1) }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path) else { continue }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { walker.skipDescendants(); continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  SkillFilesystemBoundary.isTrustedRegularFile(entry, within: directory, maximumBytes: Self.maxSkillContentBytes) else { continue }
            guard path != "SKILL.md", entry.lastPathComponent != "manifest.json" else { continue }
            paths.append(path)
        }
        return ["SKILL.md"] + paths.sorted()
    }
    public func listSkillFiles(_ skillId: String) -> [String] {
        if let before = beforeProjection() {
            guard Self.isSafeSkillID(skillId) else { return [] }
            return ["SKILL.md"] + (before.fileContents[skillId] ?? [:]).keys.filter {
                $0 != "SKILL.md" && $0.split(separator: "/").allSatisfy { !$0.hasPrefix(".") } && !$0.hasSuffix("manifest.json")
            }.sorted()
        }
        return readyRead(or: { [] }) {
            withReadFence { synchronized {
                guard Self.isSafeSkillID(skillId) else { return [] }
                if frozen { return ["SKILL.md"] + (frozenFiles[skillId] ?? [:]).keys.filter { $0 != "SKILL.md" && $0.split(separator: "/").allSatisfy { !$0.hasPrefix(".") } && !$0.hasSuffix("manifest.json") }.sorted() }
                return listDiskFiles(skillId)
            } }
        }
    }
    public func readSkillFile(_ skillId: String, relativePath: String) -> String? {
        if let before = beforeProjection() {
            guard Self.isSafeSkillID(skillId), SkillDescriptorReader.validRelativeComponents(relativePath) != nil else { return nil }
            return relativePath == "SKILL.md" ? before.rawContents[skillId] : before.fileContents[skillId]?[relativePath]
        }
        return readyRead(or: { nil }) {
            withReadFence { synchronized {
                guard Self.isSafeSkillID(skillId), SkillDescriptorReader.validRelativeComponents(relativePath) != nil else { return nil }
                if frozen { return relativePath == "SKILL.md" ? cachedRaw[skillId] : frozenFiles[skillId]?[relativePath] }
                return rawDisk(skillId, path: relativePath)
            } }
        }
    }
    public func catalogFileSnapshot(for skillID: String, expectedRootIdentity: SkillFilesystemBoundary.RootIdentity,
                                    expectedSkillDirectoryIdentity: SkillFilesystemBoundary.EntryIdentity, waitUntil deadline: TimeInterval) -> SkillCatalogFileSnapshot? {
        catalogFileSnapshot(for: skillID, expectedRootIdentity: expectedRootIdentity,
            expectedSkillDirectoryIdentity: expectedSkillDirectoryIdentity, waitUntil: deadline, lockAttemptObserver: nil)
    }
    // Internal observation of real flock attempts only; production passes nil.
    internal func catalogFileSnapshot(for skillID: String, expectedRootIdentity: SkillFilesystemBoundary.RootIdentity,
                                      expectedSkillDirectoryIdentity: SkillFilesystemBoundary.EntryIdentity, waitUntil deadline: TimeInterval,
                                      lockAttemptObserver: (@Sendable (Bool) -> Void)?) -> SkillCatalogFileSnapshot? {
        if let before = beforeProjection() {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  Self.isSafeSkillID(skillID) else { return nil }
            return cachedCatalogSnapshot(before.rawContents[skillID], manifest: before.fileContents[skillID]?["manifest.json"])
        }
        return readyRead(or: { nil }) {
            let limit = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
            return withReadFence {
                guard ProcessInfo.processInfo.systemUptime < limit,
                      mutex.lock(before: Date(timeIntervalSinceNow: max(0, limit - ProcessInfo.processInfo.systemUptime))) else { return nil }
                defer { mutex.unlock() }
                guard Self.isSafeSkillID(skillID) else { return nil }
                if frozen {
                    return cachedCatalogSnapshot(cachedRaw[skillID], manifest: frozenFiles[skillID]?["manifest.json"])
                }
                return readCatalogUnderCoordination(skillID, rootIdentity: expectedRootIdentity,
                    directoryIdentity: expectedSkillDirectoryIdentity, limit: limit, observe: lockAttemptObserver)
            }
        }
    }
    private func cachedCatalogSnapshot(_ content: String?, manifest: String?) -> SkillCatalogFileSnapshot? {
        guard let content else { return nil }
        let manifestData = manifest.map { Data($0.utf8) }
        return SkillCatalogFileSnapshot(content: content, manifestData: manifestData,
            contentByteCount: content.utf8.count, manifestByteCount: manifestData?.count ?? 0)
    }

    /// Reads a complete catalog batch, omitting individually rejected entries.
    /// The shared two-second budget covers only lock waits. Total wall time may exceed it.
    public func catalogFileSnapshots(
        for skillIDs: [String],
        expectedRootIdentity: SkillFilesystemBoundary.RootIdentity
    ) -> [String: SkillCatalogFileSnapshot]? {
        let budget = ScanContentionBudget()
        let before = beforeProjection()
        guard before != nil || isInitialLoadComplete else { return nil }
        var snapshots: [String: SkillCatalogFileSnapshot] = [:]
        func currentRoot() -> Bool {
            !Task.isCancelled && SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: expectedRootIdentity)
        }
        for id in skillIDs {
            guard currentRoot() else { return nil }
            guard Self.isSafeSkillID(id),
                  let directoryIdentity = SkillFilesystemBoundary.trustedDirectoryIdentity(skillDirectoryURL(for: id), within: skillsRoot)
            else { continue }
            if let before {
                snapshots[id] = cachedCatalogSnapshot(before.rawContents[id], manifest: before.fileContents[id]?["manifest.json"])
                continue
            }
            let entry: (snapshot: SkillCatalogFileSnapshot?, complete: Bool) = readyRead(or: { (nil, false) }) {
                withReadFence {
                    guard !Task.isCancelled else { return (nil, false) }
                    if !mutex.try() {
                        guard budget.remaining > 0 else { return (nil, false) }
                        let started = ProcessInfo.processInfo.systemUptime
                        let acquired = mutex.lock(before: Date(timeIntervalSinceNow: budget.remaining))
                        budget.remaining -= ProcessInfo.processInfo.systemUptime - started
                        guard acquired else { return (nil, false) }
                    }
                    defer { mutex.unlock() }
                    guard budget.remaining > 0, !Task.isCancelled else { return (nil, false) }
                    if frozen {
                        return (cachedCatalogSnapshot(cachedRaw[id], manifest: frozenFiles[id]?["manifest.json"]), true)
                    }
                    let snapshot = readCatalogUnderCoordination(id, rootIdentity: expectedRootIdentity,
                        directoryIdentity: directoryIdentity, limit: .infinity, observe: nil, contentionBudget: budget)
                    return (snapshot, !budget.exhausted)
                }
            }
            guard entry.complete else { return nil }
            snapshots[id] = entry.snapshot
        }
        return currentRoot() ? snapshots : nil
    }

    private func readCatalogUnderCoordination(_ id: String, rootIdentity: SkillFilesystemBoundary.RootIdentity,
                                              directoryIdentity: SkillFilesystemBoundary.EntryIdentity,
                                              limit: TimeInterval, observe: (@Sendable (Bool) -> Void)?,
                                              contentionBudget: ScanContentionBudget? = nil) -> SkillCatalogFileSnapshot? {
        coordinatedRead(id, rootIdentity: rootIdentity, directoryIdentity: directoryIdentity, limit: limit, observe: observe, contentionBudget: contentionBudget) {
            if contentionBudget != nil { self.observer?(.fileRead) }
            return SkillCatalogFileSnapshot.read(skillDirectory: self.skillDirectoryURL(for: id), within: self.skillsRoot,
                expectedRootIdentity: rootIdentity, expectedSkillDirectoryIdentity: directoryIdentity)
        }
    }
    private func coordinatedRead<T>(_ id: String, rootIdentity: SkillFilesystemBoundary.RootIdentity,
                                     directoryIdentity: SkillFilesystemBoundary.EntryIdentity,
                                     limit: TimeInterval, observe: (@Sendable (Bool) -> Void)? = nil,
                                     contentionBudget: ScanContentionBudget? = nil,
                                     _ action: () -> T?) -> T? {
        let directory = skillDirectoryURL(for: id)
        guard let directoryFD = SkillDescriptorReader.openDirectory(directory, within: skillsRoot) else { return nil }
        defer { close(directoryFD) }
        func currentDirectory() -> Bool {
            SkillFilesystemBoundary.isApprovedRoot(skillsRoot, matching: rootIdentity) &&
                SkillFilesystemBoundary.isTrustedDirectory(directory, within: skillsRoot, matching: directoryIdentity)
        }
        func readPair() -> T? {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < limit, currentDirectory() else { return nil }
            return action()
        }
        let descriptor = openat(directoryFD, ".skill-import.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { return nil }
            let value = readPair()
            var absent = stat()
            guard fstatat(directoryFD, ".skill-import.lock", &absent, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT, contentionBudget == nil || !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < limit, currentDirectory() else { return nil }
            return value
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_mode & 0o777 == 0o600, opened.st_uid == geteuid(), opened.st_nlink == 1,
              currentDirectory() else { return nil }
        func sameLock() -> Bool {
            var current = stat()
            return fstatat(directoryFD, ".skill-import.lock", &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && current.st_mode & 0o777 == 0o600 &&
                current.st_uid == opened.st_uid && current.st_nlink == 1 &&
                current.st_dev == opened.st_dev && current.st_ino == opened.st_ino && currentDirectory()
        }
        var resolution = timespec()
        guard clock_getres(CLOCK_MONOTONIC, &resolution) == 0 else { return nil }
        let quantum = Double(resolution.tv_sec) + Double(resolution.tv_nsec) / 1_000_000_000
        let budget = contentionBudget?.remaining ?? (limit - ProcessInfo.processInfo.systemUptime)
        guard quantum > 0, budget > 0 else { return nil }
        var probes = Int(ceil(log2(max(1, budget / quantum)))) + 1
        let pause = DispatchSemaphore(value: 0)
        var acquired = false
        while probes > 0 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < limit, sameLock() else { return nil }
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
                acquired = true; observe?(true); break
            }
            guard errno == EWOULDBLOCK else { return nil }
            observe?(false)
            if contentionBudget != nil { observer?(.scanLockContention(id)) }
            probes -= 1
            let remaining = contentionBudget?.remaining ?? (limit - ProcessInfo.processInfo.systemUptime)
            guard probes > 0, remaining > quantum else {
                contentionBudget?.exhausted = true
                return nil
            }
            let waitStarted = contentionBudget.map { _ in ProcessInfo.processInfo.systemUptime }
            _ = pause.wait(timeout: .now() + remaining / 2)
            if let contentionBudget, let waitStarted {
                contentionBudget.remaining -= ProcessInfo.processInfo.systemUptime - waitStarted
                guard contentionBudget.remaining > quantum else {
                    contentionBudget.exhausted = true
                    return nil
                }
            }
        }
        guard acquired else { return nil }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard sameLock() else { return nil }
        let result = readPair()
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < limit, sameLock() else { return nil }
        return result
    }
    private func deletionFingerprint(_ ids: [String]) -> String {
        let values = ids.sorted().map { id in id + ":" + (cachedRaw[id].map(SkillManifest.hash) ?? "missing") + ":" + (ledger.receipts[id]?.receiptID ?? "none") }
        return SkillManifest.hash(values.joined(separator: "\n"))
    }
    private var deletionScope: String { skillsRoot.standardizedFileURL.path }
    public func previewDeletion(skillID: String, now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        try mutate {
            guard skills.contains(where: { $0.id == skillID }) else { throw SkillError.skillNotFound(skillID) }
            return try SkillDeletionService(store: self).preview(skillID: skillID, now: now, ttl: ttl)
        }
    }
    public func previewRemoveAll(now: Date = Date(), ttl: TimeInterval = 300) throws -> OperationIntent {
        try mutate {
            .preview(targetID: "all", targetType: "skill-set", targetName: "All skills", affectedCount: skills.count,
                     impactSummary: "Remove all installed skills and approvals", scopeID: "skills:all",
                     revision: Int(truncatingIfNeeded: generation), fingerprint: deletionFingerprint(skills.map(\.id)), now: now, ttl: ttl)
        }
    }
    public func deleteSkill(_ skillId: String) throws -> DeletionReceipt {
        try synchronized {
            if frozen { try assertMutable() }
        }
        throw DeletionGateError.firstConfirmationRequired
    }
    public func removeSkill(_ skillId: String) {}
    public func removeAll() {}
    @discardableResult
    public func removeSkill(_ skillId: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt { try deleteSkill(skillId, intent: intent, now: now) }
    @discardableResult
    public func deleteSkill(_ skillId: String, intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        try mutate {
            guard intent.targetID == skillId, intent.targetType == "skill" else { throw DeletionGateError.targetChanged }
            try DeletionGate.checkLifecycle(intent)
            let service = SkillDeletionService(store: self)
            let receipt = try service.delete(intent, now: now)
            do {
                var next = ledger
                next.receipts.removeValue(forKey: skillId)
                next.disabledSkillIDs.remove(skillId)
                next.previousVersions.removeValue(forKey: skillId)
                try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(next))])
            } catch {
                try? service.restore(receipt)
                throw error
            }
            try refreshProjection(); generation &+= 1
            return receipt
        }
    }
    @discardableResult
    public func removeAll(intent: OperationIntent, now: Date = Date()) throws -> DeletionReceipt {
        try delete(ids: allSkills().map(\.id), target: "all", intent: intent, now: now)
    }
    private func delete(ids: [String], target: String, intent: OperationIntent, now: Date) throws -> DeletionReceipt {
        try mutate {
            guard intent.operationType == .delete, intent.targetID == target,
                  intent.targetType == (target == "all" ? "skill-set" : "skill") else { throw DeletionGateError.targetChanged }
            guard intent.scopeID == (target == "all" ? "skills:all" : deletionScope) else { throw DeletionGateError.invalidScope }
            guard let expiry = intent.expiresAt, expiry > now else { throw DeletionGateError.expired }
            guard let first = intent.firstConfirmation, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeletionGateError.firstConfirmationRequired }
            guard let second = intent.secondConfirmation, !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeletionGateError.secondConfirmationRequired }
            guard intent.revision == Int(truncatingIfNeeded: generation), intent.fingerprint == deletionFingerprint(ids),
                  intent.affectedCount == ids.count, ids.allSatisfy({ cachedRaw[$0] != nil }),
                  target != "all" || Set(ids) == Set(skills.map(\.id)) else { throw DeletionGateError.targetChanged }
            let manager = FileManager.default
            let trash = skillsRoot.appendingPathComponent(".trash", isDirectory: true)
            if !manager.fileExists(atPath: trash.path) { try manager.createDirectory(at: trash, withIntermediateDirectories: false) }
            guard SkillFilesystemBoundary.isTrustedDirectory(trash, within: skillsRoot) else { throw DeletionGateError.targetChanged }
            let staging = trash.appendingPathComponent(intent.operationID.uuidString, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            var moved: [String] = []
            do {
                for id in ids {
                    guard SkillFilesystemBoundary.isTrustedDirectory(skillDirectoryURL(for: id), within: skillsRoot) else { throw DeletionGateError.targetChanged }
                    try manager.moveItem(at: skillDirectoryURL(for: id), to: staging.appendingPathComponent(id)); moved.append(id)
                }
                var next = ledger
                for id in ids { next.receipts.removeValue(forKey: id); next.disabledSkillIDs.remove(id); next.previousVersions.removeValue(forKey: id) }
                try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(next))])
            } catch {
                for id in moved.reversed() { try? manager.moveItem(at: staging.appendingPathComponent(id), to: skillDirectoryURL(for: id)) }
                if moved.contains(where: { manager.fileExists(atPath: staging.appendingPathComponent($0).path) }) { ledgerIsReadable = false }
                throw error
            }
            try refreshProjection(); generation &+= 1
            return DeletionReceipt(operationID: intent.operationID, targetID: target, scopeID: intent.scopeID, affectedCount: ids.count, outcome: "deleted", createdAt: now)
        }
    }
    private func enablementView(_ scope: MemoryScope) throws -> BL6SkillEnablementSnapshot {
        guard scope.isValid else { throw BL6SkillEnablementError.invalidScope }
        let visible = skills.filter { skill in
            guard let receipt = ledger.receipts[skill.id], let raw = cachedRaw[skill.id], skill.integrity.state == .verified else { return false }
            guard let manifest = skill.integrity.manifest, Self.receiptIsBound(receipt, id: skill.id, manifest: manifest) else { return false }
            return SkillLifecycle.isActivationValid(receipt, currentContentHash: SkillManifest.hash(raw), scope: receipt.scope == nil ? nil : scope)
        }
        var values: [String: Bool] = [:]
        for skill in visible { values["skills.app:" + skill.id + ".enabled"] = skill.isEnabled }
        let pairs = visible.sorted { $0.id < $1.id }.map { skill in
            skill.id + "|" + (ledger.receipts[skill.id]?.receiptID ?? "") + "|" + (cachedRaw[skill.id].map(SkillManifest.hash) ?? "") + "|" + String(skill.isEnabled)
        }
        let maskData = try Self.encode(sharedMask)
        let revision = SkillManifest.hash(scope.sessionID + "\n" + scope.projectID + "\n" + pairs.joined(separator: "\n") + "\n" + maskData.base64EncodedString())
        return BL6SkillEnablementSnapshot(revision: revision, values: values)
    }
    public func bl6SkillEnablementSnapshot(visibleTo scope: MemoryScope) throws -> BL6SkillEnablementSnapshot {
        if let before = beforeProjection() { return try Self.makeSnapshotStore(from: before, domain: transactionDomain).enablementView(scope) }
        if !frozen { try PersistenceTransactionFence.requireLiveRead(transactionDomain) }
        return try readyRead(or: { throw SkillStoreInitialLoadError.pending }) {
            try withReadFence { try synchronized {
                guard ledgerIsReadable, ledger.bl6EnablementPending == nil else { throw BL6SkillEnablementError.recoveryRequired }
                if frozen { return try enablementView(scope) }
                return try { () throws -> BL6SkillEnablementSnapshot in
                    _ = try readLedger(); _ = try readMask()
                    try refreshProjection(persistQuarantine: false)
                    guard ledgerIsReadable, ledger.bl6EnablementPending == nil else { throw BL6SkillEnablementError.recoveryRequired }
                    return try enablementView(scope)
                }()
            } }
        }
    }
    public func bl6SkillEnablementReplayRecord(for requestID: String, profileID: String) throws -> BL6SettingsReplayRecord? {
        if !frozen { try PersistenceTransactionFence.requireLiveRead(transactionDomain) }
        return try readyRead(or: { throw SkillStoreInitialLoadError.pending }) {
            try withReadFence { try synchronized {
                guard ledgerIsReadable, ledger.bl6EnablementPending == nil else { throw BL6SkillEnablementError.recoveryRequired }
                func find() throws -> BL6SettingsReplayRecord? {
                    guard let record = ledger.bl6EnablementRecords[requestID]?.record else { return nil }
                    guard record.profileID == profileID else { throw BL6SkillEnablementError.conflict }
                    return record
                }
                if frozen { return try find() }
                return try { () throws -> BL6SettingsReplayRecord? in ledger = try readLedger(); _ = try readMask(); guard ledger.bl6EnablementPending == nil else { throw BL6SkillEnablementError.recoveryRequired }; return try find() }()
            } }
        }
    }
    public func bl6SkillEnablementReplayRecord(receiptID: String, profileID: String) throws -> BL6SettingsReplayRecord? {
        if !frozen { try PersistenceTransactionFence.requireLiveRead(transactionDomain) }
        return try readyRead(or: { throw SkillStoreInitialLoadError.pending }) {
            try withReadFence { try synchronized {
                guard ledgerIsReadable, ledger.bl6EnablementPending == nil else { throw BL6SkillEnablementError.recoveryRequired }
                func find() throws -> BL6SettingsReplayRecord? {
                    guard let record = ledger.bl6EnablementRecords.values.first(where: { $0.record.receipt.receiptID == receiptID })?.record else { return nil }
                    guard record.profileID == profileID else { throw BL6SkillEnablementError.conflict }; return record
                }
                if frozen { return try find() }
                return try { () throws -> BL6SettingsReplayRecord? in ledger = try readLedger(); _ = try readMask(); guard ledger.bl6EnablementPending == nil else { throw BL6SkillEnablementError.recoveryRequired }; return try find() }()
            } }
        }
    }
    public func replayBL6SkillEnablementRecord(_ expected: BL6SettingsReplayRecord, profileID: String) throws -> BL6SettingsReceipt {
        guard let stored = try bl6SkillEnablementReplayRecord(for: expected.requestID, profileID: profileID), stored == expected else { throw BL6SkillEnablementError.conflict }
        return stored.receipt
    }
    private func recoverEnablementPending() throws {
        var current = try readLedger()
        guard let pending = current.bl6EnablementPending?.completion else { return }
        guard Self.isSafeSkillID(pending.skillID), pending.scope.isValid,
              let raw = rawDisk(pending.skillID), SkillManifest.hash(raw) == pending.sourceContentHash,
              current.receipts[pending.skillID]?.receiptID == pending.sourceReceiptID,
              current.receipts[pending.skillID]?.contentHash == pending.sourceContentHash,
              pending.record.requestID == pending.record.receipt.requestID else { throw BL6SkillEnablementError.recoveryRequired }
        let mask = try readMask(), key = "app:" + pending.skillID
        guard mask[pending.skillID] == pending.legacyMask else { throw BL6SkillEnablementError.recoveryRequired }
        let complete: Bool
        if mask[key] == pending.afterMask { complete = true }
        else if mask[key] == pending.beforeMask { complete = false }
        else { throw BL6SkillEnablementError.recoveryRequired }
        let disabled = complete ? pending.afterDisabled : pending.beforeDisabled
        if disabled { current.disabledSkillIDs.insert(pending.skillID) } else { current.disabledSkillIDs.remove(pending.skillID) }
        if complete { current.bl6EnablementRecords[pending.record.requestID] = pending }
        current.bl6EnablementPending = nil
        try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(current))])
    }
    public func commitBL6SkillEnablement(skillID: String, enabled: Bool, visibleTo scope: MemoryScope,
                                         profileID: String, expectedRevision: String, undo: BL6SettingsReplayRecord? = nil,
                                         makeReplayRecord: @Sendable (String, String) throws -> BL6SettingsReplayRecord) throws -> BL6SettingsReplayRecord {
        try mutate {
            guard scope.isValid, !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BL6SkillEnablementError.invalidScope }
            let before = try enablementView(scope), catalogKey = "skills.app:" + skillID + ".enabled"
            guard before.revision == expectedRevision else { throw BL6SkillEnablementError.staleRevision }
            guard before.values[catalogKey] != nil, let raw = cachedRaw[skillID], let receipt = ledger.receipts[skillID] else { throw BL6SkillEnablementError.invalidSkill }
            guard ledger.bl6EnablementRecords.count < 1_024 else { throw BL6SkillEnablementError.conflict }
            if let undo {
                guard let original = ledger.bl6EnablementRecords[undo.requestID], original.record == undo,
                      original.skillID == skillID, original.scope == scope, original.record.profileID == profileID,
                      original.sourceReceiptID == receipt.receiptID, original.sourceContentHash == SkillManifest.hash(raw),
                      sharedMask["app:" + skillID] == original.afterMask,
                      ledger.disabledSkillIDs.contains(skillID) == original.afterDisabled,
                      enabled == (!original.beforeDisabled && (original.beforeMask ?? original.legacyMask ?? true)) else { throw BL6SkillEnablementError.conflict }
            }
            let oldLedger = ledger, oldMask = sharedMask
            var newMask = oldMask; newMask["app:" + skillID] = enabled
            var newLedger = ledger
            if enabled { newLedger.disabledSkillIDs.remove(skillID) } else { newLedger.disabledSkillIDs.insert(skillID) }
            if let undo, let original = ledger.bl6EnablementRecords[undo.requestID] {
                newMask["app:" + skillID] = original.beforeMask
                if original.beforeDisabled { newLedger.disabledSkillIDs.insert(skillID) }
                else { newLedger.disabledSkillIDs.remove(skillID) }
            }
            // Compute the exact committed view in memory without publishing it.
            ledger = newLedger; sharedMask = newMask
            let priorSkills = skills
            if let index = skills.firstIndex(where: { $0.id == skillID }) { skills[index].isEnabled = enabled }
            let after: BL6SkillEnablementSnapshot
            do { after = try enablementView(scope) } catch { ledger = oldLedger; sharedMask = oldMask; skills = priorSkills; throw error }
            ledger = oldLedger; sharedMask = oldMask; skills = priorSkills
            let record = try makeReplayRecord(before.revision, after.revision)
            guard try readMask() == oldMask, rawDisk(skillID) == raw,
                  try readLedger().receipts[skillID] == receipt else { throw BL6SkillEnablementError.staleRevision }
            try record.frozenInput.validateForApprovedEffect()
            guard record.profileID == profileID, record.sessionID == scope.sessionID,
                  !record.scope.isEmpty, !record.approvalBindingDigest.isEmpty, !record.payloadDigest.isEmpty,
                  record.approvalExpiresAt > Date(), record.requestID == record.receipt.requestID,
                  !record.requestID.isEmpty, record.receipt.previousRevision == before.revision,
                  record.receipt.effectiveRevision == after.revision,
                  record.frozenInput.expectedRevision == expectedRevision,
                  record.frozenInput.operation == record.operation, record.receipt.operation == record.operation,
                  record.receipt.changedKeys.contains(catalogKey), !record.receipt.secretValuesExposed else { throw BL6SkillEnablementError.conflict }
            if let undo {
                guard record.operation == .rollback, record.frozenInput.changes.isEmpty,
                      record.scope == undo.scope, record.frozenInput.undoReceiptID == undo.receipt.receiptID else { throw BL6SkillEnablementError.conflict }
            } else {
                guard record.frozenInput.changes[catalogKey] == .toggle(enabled) else { throw BL6SkillEnablementError.conflict }
            }
            if let stored = ledger.bl6EnablementRecords[record.requestID] {
                guard stored.record == record else { throw BL6SkillEnablementError.conflict }; return stored.record
            }
            let completion = Completion(record: record, skillID: skillID, scope: scope, sourceReceiptID: receipt.receiptID,
                sourceContentHash: SkillManifest.hash(raw), beforeMask: oldMask["app:" + skillID], afterMask: newMask["app:" + skillID],
                legacyMask: oldMask[skillID], beforeDisabled: oldLedger.disabledSkillIDs.contains(skillID), afterDisabled: newLedger.disabledSkillIDs.contains(skillID))
            var pending = oldLedger; pending.bl6EnablementPending = Pending(completion: completion)
            var seamFailure: Error?
            func fault(_ point: BL6EnablementFaultPoint) throws {
                do { try bl6EnablementFaultInjector?(point) }
                catch { seamFailure = error; throw error }
            }
            do {
                try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(pending))])
                ledger = pending
                try fault(.afterIntentPersisted)
                try commit([Write(path: "@shared", data: Self.encode(newMask))])
                try fault(.afterSharedStatePersisted)
                newLedger.bl6EnablementRecords[record.requestID] = completion
                newLedger.bl6EnablementPending = nil
                try commit([Write(path: "lifecycle-receipts.json", data: Self.encode(newLedger))])
                try refreshProjection(); generation &+= 1; return record
            } catch {
                ledgerIsReadable = false; ledger.disabledSkillIDs.insert(skillID)
                if let index = skills.firstIndex(where: { $0.id == skillID }) { skills[index].isEnabled = false }
                generation &+= 1
                if let seamFailure { throw seamFailure }
                throw BL6SkillEnablementError.persistenceFailed
            }
        }
    }

    public typealias ParsedSkillMD = SkillParsedDocument
    public static let maximumContentBytes = maxSkillContentBytes

    public static func isSafeSkillID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." &&
        !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" }
    }

    public static func slugify(_ name: String) -> String {
        let lowered = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []
        var word = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.joined(separator: "-")
    }

    public static func nameFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        var pieces = url.pathComponents.filter { $0 != "/" }
        if pieces.last?.caseInsensitiveCompare("SKILL.md") == .orderedSame { pieces.removeLast() }
        if let marker = pieces.firstIndex(where: { $0 == "blob" || $0 == "tree" }), marker + 1 < pieces.count {
            pieces.removeSubrange(marker...marker + 1)
        }
        return pieces.isEmpty ? urlString : pieces.joined(separator: "/")
    }

    /// Recognizes a small metadata grammar without interpreting general YAML.
    public static func parse(skillMD content: String) -> ParsedSkillMD {
        let lines = content.components(separatedBy: "\n")
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let explicitFence = lines.first.map { clean($0) == "---" } ?? false
        let first = explicitFence ? 1 : 0
        guard let end = lines.indices.dropFirst(first).first(where: { clean(lines[$0]) == "---" }) else {
            return ParsedSkillMD(body: content)
        }
        var values: [String: String] = [:]
        var currentKey: String?
        var chunks: [String] = []
        var multilineStyle: Character?
        var recognized = false
        var validHeader = true

        func unquote(_ input: String) -> String {
            guard input.count >= 2, let head = input.first, let tail = input.last,
                  (head == "\"" && tail == "\"") || (head == "'" && tail == "'") else { return input }
            return String(input.dropFirst().dropLast())
        }
        func flush() {
            guard let key = currentKey else { return }
            switch multilineStyle {
            case "|": values[key] = chunks.joined(separator: "\n")
            case ">": values[key] = chunks.joined(separator: " ")
            default: values[key] = chunks.joined(separator: " ")
            }
            currentKey = nil
            chunks = []
            multilineStyle = nil
        }

        for index in first..<end {
            let line = lines[index]
            let trimmed = clean(line)
            if trimmed.isEmpty {
                if multilineStyle == "|" { chunks.append("") }
                continue
            }
            if (line.first == " " || line.first == "\t"), currentKey != nil {
                chunks.append(trimmed)
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { validHeader = false; break }
            let key = clean(String(line[..<colon])).lowercased()
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else {
                validHeader = false
                break
            }
            let value = clean(String(line[line.index(after: colon)...]))
            guard ["name", "description", "version"].contains(key) else { continue }
            recognized = true
            currentKey = key
            if value.first == "|" || value.first == ">" {
                multilineStyle = value.first
            } else {
                chunks.append(unquote(value))
            }
        }
        flush()
        guard validHeader, recognized else { return ParsedSkillMD(body: content) }
        let body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSkillMD(name: values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Skill",
                             description: values["description"] ?? "",
                             version: values["version"].flatMap { $0.isEmpty ? nil : $0 } ?? "1.0.0", body: body)
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A descriptor identifies the opened object, independently of subsequent path changes.
internal enum SkillDescriptorReader {
    struct Identity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    static func identity(_ descriptor: Int32) -> Identity? {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { return nil }
        #if canImport(Darwin)
        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanos = Int64(information.st_mtimespec.tv_nsec)
        #else
        let seconds = Int64(information.st_mtim.tv_sec)
        let nanos = Int64(information.st_mtim.tv_nsec)
        #endif
        return Identity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino),
                        byteCount: Int64(information.st_size), modifiedSeconds: seconds,
                        modifiedNanoseconds: nanos)
    }

    static func validRelativeComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    static func openDirectory(_ url: URL, within root: URL? = nil) -> Int32? {
        guard url.isFileURL else { return nil }
        let boundary = root ?? url
        guard boundary.isFileURL, let approved = SkillFilesystemBoundary.approvedRootIdentity(boundary) else { return nil }
        let rootParts = boundary.standardizedFileURL.pathComponents
        let destinationParts = url.standardizedFileURL.pathComponents
        guard destinationParts.count >= rootParts.count,
              Array(destinationParts.prefix(rootParts.count)) == rootParts else { return nil }
        let relative = Array(destinationParts.dropFirst(rootParts.count))
        let expectedDirectory: SkillFilesystemBoundary.EntryIdentity?
        if relative.isEmpty { expectedDirectory = nil }
        else {
            guard let identity = SkillFilesystemBoundary.trustedDirectoryIdentity(url, within: boundary) else { return nil }
            expectedDirectory = identity
        }
        // realpath is applied only to the publicly approved root. In particular,
        // no root-relative member path is resolved through a symbolic link.
        let physical = boundary.withUnsafeFileSystemRepresentation { path in path.flatMap { realpath($0, nil) } }
        guard let physical else { return nil }
        defer { free(physical) }
        var descriptor = open(physical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let openedRoot = identity(descriptor), openedRoot.device == approved.device, openedRoot.inode == approved.inode,
              SkillFilesystemBoundary.isApprovedRoot(boundary, matching: approved) else { close(descriptor); return nil }
        for component in relative {
            guard component != ".", component != "..", !component.isEmpty else { close(descriptor); return nil }
            let next = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        guard SkillFilesystemBoundary.isApprovedRoot(boundary, matching: approved), let opened = identity(descriptor) else { close(descriptor); return nil }
        if let expectedDirectory {
            guard opened.device == expectedDirectory.device, opened.inode == expectedDirectory.inode,
                  SkillFilesystemBoundary.isTrustedDirectory(url, within: boundary, matching: expectedDirectory) else { close(descriptor); return nil }
        } else if opened.device != approved.device || opened.inode != approved.inode { close(descriptor); return nil }
        return descriptor
    }

    static func read(rootDescriptor: Int32, relativePath: String, maximumBytes: Int,
                     expectedRoot: Identity? = nil) -> Data? {
        guard maximumBytes >= 0, let components = validRelativeComponents(relativePath),
              let rootBefore = identity(rootDescriptor),
              expectedRoot.map({ $0.device == rootBefore.device && $0.inode == rootBefore.inode }) ?? true else { return nil }
        var directory = dup(rootDescriptor)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for part in components.dropLast() {
            let next = part.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }
        guard let leaf = components.last else { return nil }
        let descriptor = leaf.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var fileInformation = stat()
        guard fstat(descriptor, &fileInformation) == 0,
              fileInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInformation.st_nlink == 1,
              let before = identity(descriptor), before.byteCount >= 0,
              before.byteCount <= Int64(maximumBytes) else { return nil }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                #if canImport(Darwin)
                Darwin.read(descriptor, storage.baseAddress, storage.count)
                #else
                Glibc.read(descriptor, storage.baseAddress, storage.count)
                #endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard bytes.count <= maximumBytes - count else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard identity(descriptor) == before, identity(rootDescriptor) == rootBefore,
              bytes.count == before.byteCount else { return nil }
        // Reopen the path while the original descriptor remains held. Replacement
        // by another inode is a rejected read, even if its bytes happen to agree.
        let confirmation = leaf.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard confirmation >= 0 else { return nil }
        defer { close(confirmation) }
        var confirmationInformation = stat()
        guard fstat(confirmation, &confirmationInformation) == 0,
              confirmationInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              confirmationInformation.st_nlink == 1,
              identity(confirmation) == before else { return nil }
        return bytes
    }
}

internal enum SkillStoreFilesystemAccess: Sendable, Equatable {
    case fileRead, directoryList, recursiveEnumeration, resourceValues, symlinkResolution
    case scanLockContention(String)
}
internal typealias SkillStoreFilesystemAccessObserver = @Sendable (SkillStoreFilesystemAccess) -> Void
public struct BL6SkillEnablementSnapshot: Equatable, Sendable {
    public let revision: String
    public let values: [String: Bool]
    public init(revision: String, values: [String: Bool]) { self.revision = revision; self.values = values }
}
public enum BL6SkillEnablementError: Error, Equatable, Sendable {
    case invalidScope, invalidSkill, staleRevision, conflict, recoveryRequired, persistenceFailed
}
