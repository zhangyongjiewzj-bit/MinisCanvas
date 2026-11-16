import Foundation

/// Process-local admission is acquired before any store lock. A completed import
/// remains latched for this process, including stores constructed after commit.
public enum PersistenceTransactionError: Error, Equatable, Sendable {
    case busy
    case cancelled
    case drainTimedOut
    case illegalUpgrade
    case reopenRequired
    case recoveryRequired
    case bootstrapAfterStoreOpened
    case unavailableBeforeView
}

public enum PersistenceTransactionFence {
    public struct Domain: Hashable, Codable, Sendable, Comparable {
        public let scope: SyncScope
        public let root: URL
        public init(scope: SyncScope, root: URL) {
            self.scope = scope
            // File URL directory hints and the system /var and /tmp aliases
            // must not change admission identity when the first file is created.
            self.root = URL(fileURLWithPath: PersistenceTransactionFence.stablePath(root.resolvingSymlinksInPath()), isDirectory: false)
        }
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.key < rhs.key
        }
        fileprivate var key: String { scope.rawValue + ":" + root.path }
        public static func sessions(_ directory: URL) -> Self {
            Self(scope: .sessions, root: directory.appendingPathComponent("sessions"))
        }
        public static func memories(_ directory: URL) -> Self {
            Self(scope: .memories, root: directory.appendingPathComponent("memory"))
        }
        public static func skills(_ root: URL) -> Self { Self(scope: .skills, root: root) }
        public static func settings(_ directory: URL) -> Self {
            Self(scope: .settings, root: directory.appendingPathComponent("settings.json"))
        }
    }

    /// Value images never expose a writable staging path. Metadata accompanies
    /// bytes so compound readers cannot combine two different disk generations.
    public struct FileImage: Codable, Equatable, Sendable {
        public let data: Data
        public let mode: UInt16
        public let modifiedAt: Date
        public init(data: Data, mode: UInt16, modifiedAt: Date) {
            self.data = data; self.mode = mode; self.modifiedAt = modifiedAt
        }
    }
    public struct BeforeView: Sendable {
        public let files: [String: FileImage]
        public let settings: AppSettings?
        public let skills: SkillStore.Snapshot?
        public init(files: [String: FileImage], settings: AppSettings?, skills: SkillStore.Snapshot?) {
            self.files = files; self.settings = settings; self.skills = skills
        }
    }
    private enum Phase { case normal, draining, exclusive, committed, recovery, bootstrap }
    private final class Entry {
        var phase: Phase = .normal
        var active = 0
        var epoch: UInt64 = 0
        var everOpened = false
        var before: BeforeView?
        var exclusiveOwner: String?
    }
    private final class Registry: @unchecked Sendable {
        let condition = NSCondition()
        var entries: [Domain: Entry] = [:]
        var profiles: [Domain: Set<Domain>] = [:]
        func expanded(_ domains: [Domain]) -> [Domain] {
            Array(Set(domains.flatMap { profiles[$0].map(Array.init) ?? [$0] })).sorted()
        }
        func entry(_ domain: Domain) -> Entry {
            if let entry = entries[domain] { return entry }
            let entry = Entry(); entries[domain] = entry; return entry
        }
    }
    private static let registry = Registry()
    private static let threadKey = "MinisCore.PersistenceTransactionFence.admission.v1"
    fileprivate final class ThreadState: NSObject {
        let identity = UUID().uuidString
        var depths: [Domain: Int] = [:]
        var counted: Set<Domain> = []
    }
    private static func threadState() -> ThreadState {
        if let state = Thread.current.threadDictionary[threadKey] as? ThreadState { return state }
        let state = ThreadState(); Thread.current.threadDictionary[threadKey] = state; return state
    }

    /// A trusted composition binds the complete owned-root set once. Normal
    /// operations then admit that union before their first store lock, including
    /// callbacks that touch another store. Conflicting ownership fails closed.
    static func registerProfile(_ domains: [Domain]) -> Bool {
        let group = Set(domains)
        registry.condition.lock(); defer { registry.condition.unlock() }
        guard !group.isEmpty else { return false }
        if group.allSatisfy({ registry.profiles[$0] == group }) { return true }
        guard group.allSatisfy({ registry.profiles[$0] == nil && registry.entry($0).active == 0 && registry.entry($0).phase == .normal }) else { return false }
        for domain in group { registry.profiles[domain] = group }
        return true
    }

    public final class Admission {
        fileprivate let domains: [Domain]
        private let owner: ThreadState
        private var released = false
        fileprivate init(domains: [Domain], owner: ThreadState) {
            self.domains = domains; self.owner = owner
        }
        public func release() {
            guard !released else { return }
            precondition(threadState() === owner, "Persistence admission cannot cross await/thread boundaries")
            released = true
            registry.condition.lock()
            for domain in domains {
                let depth = owner.depths[domain, default: 0]
                precondition(depth > 0)
                if depth == 1 {
                    owner.depths.removeValue(forKey: domain)
                    if owner.counted.remove(domain) != nil { registry.entry(domain).active -= 1 }
                } else { owner.depths[domain] = depth - 1 }
            }
            registry.condition.broadcast(); registry.condition.unlock()
        }
        deinit { release() }
        public func requireWritable() throws {
            registry.condition.lock(); defer { registry.condition.unlock() }
            for domain in domains {
                switch registry.entry(domain).phase {
                case .normal, .draining:
                    guard owner.counted.contains(domain) else { throw PersistenceTransactionError.busy }
                case .committed: throw PersistenceTransactionError.reopenRequired
                case .recovery: throw PersistenceTransactionError.recoveryRequired
                default: throw PersistenceTransactionError.busy
                }
            }
        }
    }

    /// New reads wait outside store locks during drain/publication, then consume
    /// the captured BEFORE view. Existing nested operations reuse their token.
    public static func read(_ domains: [Domain]) -> Admission {
        let owner = threadState()
        registry.condition.lock()
        let ordered = registry.expanded(domains)
        while ordered.contains(where: { domain in
            if owner.depths[domain, default: 0] > 0 { return false }
            let entry = registry.entry(domain)
            if entry.exclusiveOwner == owner.identity { return false }
            return entry.phase == .draining || entry.phase == .exclusive || entry.phase == .bootstrap
        }) { registry.condition.wait() }
        for domain in ordered {
            let entry = registry.entry(domain)
            entry.everOpened = true
            if owner.depths[domain, default: 0] == 0 && entry.phase == .normal {
                entry.active += 1; owner.counted.insert(domain)
            }
            owner.depths[domain, default: 0] += 1
        }
        registry.condition.unlock()
        return Admission(domains: ordered, owner: owner)
    }
    public static func write(_ domains: [Domain]) throws -> Admission {
        let admission = read(domains)
        do { try admission.requireWritable(); return admission }
        catch { admission.release(); throw error }
    }
    public static func withRead<T>(_ domains: [Domain], _ body: () throws -> T) rethrows -> T {
        let admission = read(domains); defer { admission.release() }; return try body()
    }
    public static func withWrite<T>(_ domains: [Domain], _ body: () throws -> T) throws -> T {
        let admission = try write(domains); defer { admission.release() }; return try body()
    }
    public static func epoch(_ domains: [Domain]) -> [UInt64] {
        registry.condition.lock(); defer { registry.condition.unlock() }
        return Array(Set(domains)).sorted().map { registry.entry($0).epoch }
    }
    public static func beforeView(_ domain: Domain) -> BeforeView? {
        registry.condition.lock(); defer { registry.condition.unlock() }
        let entry = registry.entry(domain)
        return entry.phase == .committed || entry.phase == .recovery || entry.phase == .exclusive ? entry.before : nil
    }
    public static func requiresReopen(_ domain: Domain) -> Bool {
        registry.condition.lock(); defer { registry.condition.unlock() }
        let entry = registry.entry(domain)
        let phase = entry.phase
        return phase == .committed || phase == .recovery || (phase == .exclusive && entry.before != nil)
    }
    public static func requireLiveRead(_ domain: Domain) throws {
        registry.condition.lock(); defer { registry.condition.unlock() }
        switch registry.entry(domain).phase {
        case .committed: throw PersistenceTransactionError.reopenRequired
        case .recovery: throw PersistenceTransactionError.recoveryRequired
        case .exclusive where registry.entry(domain).before != nil: throw PersistenceTransactionError.busy
        default: break
        }
    }
    static func stablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }
    public static func beforeImage(at url: URL, domain: Domain) -> FileImage? {
        let admission = read([domain]); defer { admission.release() }
        return beforeView(domain)?.files[stablePath(url)]
    }
    public static func data(at url: URL, domain: Domain) throws -> Data {
        let admission = read([domain]); defer { admission.release() }
        if requiresReopen(domain) {
            guard let view = beforeView(domain) else { throw PersistenceTransactionError.unavailableBeforeView }
            guard let image = view.files[stablePath(url)] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return image.data
        }
        return try Data(contentsOf: url)
    }
    public static func exists(at url: URL, domain: Domain) -> Bool {
        let admission = read([domain]); defer { admission.release() }
        if requiresReopen(domain) {
            guard let view = beforeView(domain) else { return false }
            let path = stablePath(url)
            return view.files[path] != nil || view.files.keys.contains { $0.hasPrefix(path + "/") }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
    public static func children(at directory: URL, domain: Domain) throws -> [URL] {
        let admission = read([domain]); defer { admission.release() }
        if requiresReopen(domain) {
            guard let view = beforeView(domain) else { throw PersistenceTransactionError.unavailableBeforeView }
            let prefix = stablePath(directory) + "/"
            return Set(view.files.keys.compactMap { path -> String? in
                guard path.hasPrefix(prefix) else { return nil }
                return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            }).sorted().map { directory.appendingPathComponent($0) }
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    public static func byteCount(at url: URL, domain: Domain) throws -> Int {
        let admission = read([domain]); defer { admission.release() }
        if requiresReopen(domain) {
            guard let view = beforeView(domain) else { throw PersistenceTransactionError.unavailableBeforeView }
            return view.files[stablePath(url)]?.data.count ?? 0
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    public final class ExclusiveAdmission {
        fileprivate let domains: [Domain]
        private let owner: String
        private var finished = false
        fileprivate init(domains: [Domain], owner: String) { self.domains = domains; self.owner = owner }
        /// Captured before the first mutation, this also protects a synchronous
        /// cancellation/fault callback running on the exclusive owner's thread.
        func captureBefore(_ view: BeforeView) {
            precondition(!finished && threadState().identity == owner)
            registry.condition.lock()
            for domain in domains { registry.entry(domain).before = view }
            registry.condition.unlock()
        }
        /// Call only after durable rollback verification or the COMMITTED fsync.
        public func finish(committed: Bool, recoveryRequired: Bool, before: BeforeView?) {
            precondition(!finished && threadState().identity == owner)
            registry.condition.lock()
            for domain in domains {
                let entry = registry.entry(domain)
                precondition(entry.exclusiveOwner == owner)
                entry.before = before
                entry.phase = recoveryRequired ? .recovery : (committed ? .committed : .normal)
                if committed { entry.epoch += 1 }
                entry.exclusiveOwner = nil
            }
            finished = true
            registry.condition.broadcast(); registry.condition.unlock()
        }
        deinit {
            if !finished {
                registry.condition.lock()
                for domain in domains {
                    let entry = registry.entry(domain)
                    entry.phase = .recovery; entry.exclusiveOwner = nil
                }
                registry.condition.broadcast(); registry.condition.unlock()
            }
        }
    }
    public static func exclusive(
        _ domains: [Domain], deadline: Date, cancelled: () -> Bool = { false }
    ) throws -> ExclusiveAdmission {
        let owner = threadState()
        guard owner.depths.isEmpty else { throw PersistenceTransactionError.illegalUpgrade }
        registry.condition.lock()
        let ordered = registry.expanded(domains)
        guard !ordered.isEmpty else { registry.condition.unlock(); throw PersistenceTransactionError.busy }
        guard ordered.allSatisfy({ registry.entry($0).phase == .normal }) else {
            registry.condition.unlock(); throw PersistenceTransactionError.busy
        }
        for domain in ordered { registry.entry(domain).phase = .draining }
        while ordered.contains(where: { registry.entry($0).active > 0 }) {
            registry.condition.unlock()
            let cancellation = cancelled()
            let expired = Date() >= deadline
            registry.condition.lock()
            if cancellation || expired {
                for domain in ordered { registry.entry(domain).phase = .normal }
                registry.condition.broadcast(); registry.condition.unlock()
                throw cancellation ? PersistenceTransactionError.cancelled : .drainTimedOut
            }
            _ = registry.condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        for domain in ordered {
            let entry = registry.entry(domain); entry.phase = .exclusive; entry.exclusiveOwner = owner.identity
        }
        registry.condition.unlock()
        if cancelled() || Date() >= deadline {
            let admission = ExclusiveAdmission(domains: ordered, owner: owner.identity)
            admission.finish(committed: false, recoveryRequired: false, before: nil)
            throw PersistenceTransactionError.cancelled
        }
        return ExclusiveAdmission(domains: ordered, owner: owner.identity)
    }

    /// The registry is never reset. Only a fresh process, before its first
    /// canonical store admission, can execute recovery and open a new epoch.
    public static func bootstrapBeforeStores<T>(_ domains: [Domain], recovery: () throws -> T) throws -> T {
        let ordered = Array(Set(domains)).sorted()
        registry.condition.lock()
        guard ordered.allSatisfy({ let e = registry.entry($0); return !e.everOpened && e.phase == .normal }) else {
            registry.condition.unlock(); throw PersistenceTransactionError.bootstrapAfterStoreOpened
        }
        for domain in ordered { registry.entry(domain).phase = .bootstrap }
        registry.condition.unlock()
        do {
            let result = try recovery()
            registry.condition.lock()
            for domain in ordered {
                let entry = registry.entry(domain); entry.phase = .normal; entry.everOpened = true; entry.epoch += 1
            }
            registry.condition.broadcast(); registry.condition.unlock()
            return result
        } catch {
            registry.condition.lock()
            for domain in ordered { registry.entry(domain).phase = .recovery; registry.entry(domain).everOpened = true }
            registry.condition.broadcast(); registry.condition.unlock()
            throw error
        }
    }
}
