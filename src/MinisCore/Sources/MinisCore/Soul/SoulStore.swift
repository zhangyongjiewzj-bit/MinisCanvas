import Foundation

// MARK: - Soul

/// A personality / persona definition: an identity the assistant adopts for
/// a session. The active soul's `systemPrompt` is injected at prompt-build
/// time by the host app.
public struct Soul: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var systemPrompt: String
    /// At most one soul is active at a time.
    public var isActive: Bool

    public init(id: String, name: String, systemPrompt: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.isActive = isActive
    }
}

// MARK: - SoulStore

/// JSON-file-backed store for Soul personas, persisted as
/// `<directory>/souls.json`.
///
/// Layout: a single JSON array of `Soul` records (souls.json), seeded with
/// the default soul on first access. Every mutation is serialized under an
/// internal lock and written atomically, so the store is safe to share
/// across tasks. Responsibility reference: OpenMinis `SoulStore` (persistent
/// personality) with a multi-soul, JSON model instead of a single SOUL.md.
public final class SoulStore: @unchecked Sendable {

    /// Root directory the store persists under (the "project directory").
    public let directory: URL

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Default root directory for the MinisCanvas app (Application Support).
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MinisCanvas", isDirectory: true)
    }

    /// The default soul seeded on first run.
    public static let defaultSoul = Soul(
        id: "miniscanvas-assistant",
        name: "MinisCanvas 助手",
        systemPrompt: "你是 MinisCanvas 助手，一个简洁、高效的中文 AI 助手。你帮助用户完成绘画、视频、写作与编码等创作任务，回答时优先使用中文，保持清晰直接。",
        isActive: true
    )

    /// File holding all souls: `<directory>/souls.json`.
    public var soulsFileURL: URL {
        directory.appendingPathComponent("souls.json")
    }

    // MARK: - Queries

    /// All souls in stable order (seeding the default soul when the file is
    /// missing or empty). Unreadable/corrupt files fall back to the default.
    public func listSouls() -> [Soul] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// The currently active soul, or `nil` when no soul is marked active.
    public func activeSoul() -> Soul? {
        listSouls().first { $0.isActive }
    }

    // MARK: - Mutations

    /// Activate the soul with `id`, deactivating all others, and persist.
    /// Throws `SoulStoreError.soulNotFound` when no soul has that id.
    @discardableResult
    public func setActive(_ id: String) throws -> Soul {
        try lock.withLock {
            var souls = loadUnlocked()
            guard let index = souls.firstIndex(where: { $0.id == id }) else {
                throw SoulStoreError.soulNotFound(id)
            }
            for i in souls.indices {
                souls[i].isActive = (i == index)
            }
            try persistUnlocked(souls)
            return souls[index]
        }
    }

    /// Insert a new soul, or replace an existing one with the same id.
    /// Persists immediately. A soul whose `isActive` is `true` deactivates
    /// all others on write.
    @discardableResult
    public func upsert(_ soul: Soul) throws -> Soul {
        try lock.withLock {
            var souls = loadUnlocked()
            if let index = souls.firstIndex(where: { $0.id == soul.id }) {
                souls[index] = soul
            } else {
                souls.append(soul)
            }
            if soul.isActive {
                for i in souls.indices where souls[i].id != soul.id {
                    souls[i].isActive = false
                }
            }
            try persistUnlocked(souls)
            return soul
        }
    }

    /// Remove a soul by id. No-op when it does not exist. The default soul
    /// cannot be deleted.
    public func delete(id: String) throws {
        try lock.withLock {
            var souls = loadUnlocked()
            souls.removeAll { $0.id == id && $0.id != Self.defaultSoul.id }
            try persistUnlocked(souls)
        }
    }

    // MARK: - Internals

    /// Load souls, seeding the default when the file is missing. A corrupt
    /// or empty file also falls back to the default seed.
    private func loadUnlocked() -> [Soul] {
        let url = soulsFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let souls = try? decoder.decode([Soul].self, from: data),
              !souls.isEmpty
        else {
            // Seed once: if nothing is on disk, write the default soul.
            let seed = [Self.defaultSoul]
            try? persistUnlocked(seed)
            return seed
        }
        return souls
    }

    private func persistUnlocked(_ souls: [Soul]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(souls)
        try data.write(to: soulsFileURL, options: .atomic)
    }
}

// MARK: - Errors

public enum SoulStoreError: Error, Equatable, Sendable {
    case soulNotFound(String)
}

// MARK: - Lock helper

extension NSLock {
    /// Run `body` while holding the lock.
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
