import Foundation

// MARK: - MemoryFileKind

/// The kind of a file-based memory document.
public enum MemoryFileKind: String, Codable, Sendable {
    /// Persistent standing instructions injected into the system prompt on
    /// every session (when memory is enabled).
    case global
    /// The assistant's soul / persona description document.
    case soul
    /// A per-day log auto-created during conversation (`<yyyy-MM-dd>.md`).
    case daily
}

// MARK: - MemoryFileInfo

/// A file-based memory document visible in the management UI.
public struct MemoryFileInfo: Identifiable, Sendable {
    /// The file name on disk (e.g. `GLOBAL.md`, `2026-08-04.md`).
    public let name: String
    public let kind: MemoryFileKind
    /// Last modification time of the file.
    public let modifiedAt: Date
    /// A short preview (first line truncated) for the list UI.
    public let preview: String
    /// Size of the file in bytes.
    public let byteCount: Int
    /// The full relative path (e.g. `GLOBAL.md`, `daily/2026-08-04.md`).
    public let relativePath: String
    public let isReadable: Bool

    public var id: String { relativePath }

    public init(
        name: String,
        kind: MemoryFileKind,
        modifiedAt: Date,
        preview: String,
        byteCount: Int,
        relativePath: String,
        isReadable: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.preview = preview
        self.byteCount = byteCount
        self.relativePath = relativePath
        self.isReadable = isReadable
    }
}

// MARK: - MemoryFileStore

/// File-based memory: persistent standing instructions (`GLOBAL.md`), a soul
/// document (`SOUL.md`) and per-day auto-created logs (`daily/<date>.md`).
///
/// These are plain Markdown files (viewable / editable by the user) living
/// under `<directory>/memory/`, alongside the fact-based `facts.json` managed
/// by `MemoryStore`. The two models coexist: `MemoryStore` stores discrete
/// facts; `MemoryFileStore` stores free-form documents.
///
/// All reads/writes are serialized under an internal lock; writes are atomic.
/// The store is safe to share across tasks.
public final class MemoryFileStore: @unchecked Sendable {

    /// Root directory the store persists under (the "project directory").
    public let directory: URL
    public var persistenceDomain: PersistenceTransactionFence.Domain { .memories(directory) }

    /// The memory subdirectory holding all file-based documents.
    public var memoryDirectory: URL {
        directory.appendingPathComponent("memory", isDirectory: true)
    }

    /// `GLOBAL.md` — persistent standing instructions.
    public var globalURL: URL {
        memoryDirectory.appendingPathComponent("GLOBAL.md", isDirectory: false)
    }

    /// `SOUL.md` — the soul / persona document.
    public var soulURL: URL {
        memoryDirectory.appendingPathComponent("SOUL.md", isDirectory: false)
    }

    /// `daily/` — per-day auto-created logs.
    public var dailyDirectory: URL {
        memoryDirectory.appendingPathComponent("daily", isDirectory: true)
    }

    private let lock = NSLock()
    private let fm = FileManager.default

    public init(directory: URL) {
        let admission = PersistenceTransactionFence.read([PersistenceTransactionFence.Domain.memories(directory)])
        defer { admission.release() }
        self.directory = directory
    }

    // MARK: - GLOBAL.md

    /// Read the current `GLOBAL.md` content ("" when absent).
    public func readGlobal() -> String {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            readFile(at: globalURL)

        }
    }

    /// Prompt preparation distinguishes an absent document from a failed read.
    /// Reuse the management reader's physical-root check, including symlinks.
    func readGlobalForInjection() throws -> String? {
        try PersistenceTransactionFence.withRead([persistenceDomain]) {
            try lock.withLock {
                guard let url = url(forName: "GLOBAL.md") else { throw CocoaError(.fileReadNoPermission) }
                let data: Data
                do { data = try PersistenceTransactionFence.data(at: url, domain: persistenceDomain) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
                guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                return text
            }
        }
    }

    /// Overwrite `GLOBAL.md` with `content`. Creates parent dirs as needed.
    public func writeGlobal(_ content: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try writeFile(at: globalURL, content: content)

        }
    }

    // MARK: - SOUL.md

    /// Read the current `SOUL.md` content ("" when absent).
    public func readSoul() -> String {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            readFile(at: soulURL)

        }
    }

    /// Overwrite `SOUL.md` with `content`. Creates parent dirs as needed.
    public func writeSoul(_ content: String) throws {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            try writeFile(at: soulURL, content: content)

        }
    }

    // MARK: - Daily logs

    /// The URL for the daily log of `date` (`daily/<yyyy-MM-dd>.md`).
    public func dailyURL(for date: Date) -> URL {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            dailyDirectory.appendingPathComponent(Self.dailyFileName(for: date), isDirectory: false)

        }
    }

    /// File name for a daily log (`yyyy-MM-dd.md`).
    public static func dailyFileName(for date: Date) -> String {
        Self.dailyFormatter.string(from: date) + ".md"
    }

    /// Read today's (or a given date's) daily log content ("" when absent).
    public func readDaily(for date: Date) -> String {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            readFile(at: dailyURL(for: date))

        }
    }

    /// Ensure the daily log for `date` exists on disk (creates it with a
    /// heading when missing). Returns the URL of the log.
    /// - Note: this is the "auto-create during conversation" entry point.
    @discardableResult
    public func ensureDailyLog(for date: Date = Date()) throws -> URL {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            let url = dailyURL(for: date)
            try lock.withLock {
                try fm.createDirectory(at: dailyDirectory, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) {
                    let heading = "# 每日记忆 \(Self.dailyFormatter.string(from: date))\n\n"
                    try writeFileUnlocked(at: url, content: heading)
                }
            }
            return url

        }
    }

    /// Append a line to the daily log for `date`, auto-creating the log first.
    /// Returns the URL of the log.
    @discardableResult
    public func appendToDailyLog(_ text: String, date: Date = Date()) throws -> URL {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try ensureDailyLog(for: date)
            guard !trimmed.isEmpty else { return url }
            try lock.withLock {
                var existing: String
                if fm.fileExists(atPath: url.path) {
                    guard let readable = readFileUnlocked(at: url) else {
                        throw MemoryFileStoreReadError.unreadable(url)
                    }
                    existing = readable
                } else {
                    existing = ""
                }
                if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
                existing += "- " + trimmed + "\n"
                try writeFileUnlocked(at: url, content: existing)
            }
            return url

        }
    }

    /// List all file-based memory documents (GLOBAL.md, SOUL.md, daily logs),
    /// sorted by modification time (newest first).
    public func listFiles() -> [MemoryFileInfo] {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            lock.withLock {
                var result: [MemoryFileInfo] = []

                // GLOBAL.md
                if let global = fileInfo(globalURL, kind: .global, relPath: "GLOBAL.md") {
                    result.append(global)
                }
                // SOUL.md
                if let soul = fileInfo(soulURL, kind: .soul, relPath: "SOUL.md") {
                    result.append(soul)
                }
                // daily/
                if let urls = try? PersistenceTransactionFence.children(at: dailyDirectory, domain: persistenceDomain) {
                    for url in urls where url.pathExtension == "md" {
                        if let info = fileInfo(url, kind: .daily, relPath: "daily/" + url.lastPathComponent) {
                            result.append(info)
                        }
                    }
                }

                return result.sorted { $0.modifiedAt > $1.modifiedAt }
            }

        }
    }

    /// Read a file-based document by its `name` (e.g. `GLOBAL.md`,
    /// `2026-08-04.md`, or a relative path like `daily/2026-08-04.md`).
    /// Returns nil when the file does not exist.
    public func readDocument(named name: String) -> String? {
        return PersistenceTransactionFence.withRead([persistenceDomain]) {
            guard let url = url(forName: name) else { return nil }
            return readFileOptional(at: url)

        }
    }

    /// Overwrite a file-based document by `name`. Returns false when the
    /// name doesn't resolve to a known document file.
    @discardableResult
    public func writeDocument(named name: String, content: String) throws -> Bool {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            guard let url = url(forName: name) else { return false }
            try writeFile(at: url, content: content)
            return true

        }
    }

    /// Delete a file-based document by `name`. Returns false when the name
    /// doesn't resolve to a known document file (or it doesn't exist).
    @discardableResult
    public func deleteDocument(named name: String) throws -> Bool {
        return try PersistenceTransactionFence.withWrite([persistenceDomain]) {
            guard let url = url(forName: name) else { return false }
            return try lock.withLock {
                guard fm.fileExists(atPath: url.path) else { return false }
                try fm.removeItem(at: url)
                return true
            }

        }
    }

    // MARK: - Name resolution

    /// Resolve a document name to a URL. Accepts `GLOBAL.md`, `SOUL.md`,
    /// `daily/2026-08-04.md`, or a bare date file name (`2026-08-04.md`).
    private func url(forName name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("/")
        else { return nil }

        let candidate: URL
        switch trimmed {
        case "GLOBAL.md": candidate = globalURL
        case "SOUL.md": candidate = soulURL
        default:
            if trimmed.hasPrefix("daily/") {
                let fileName = String(trimmed.dropFirst("daily/".count))
                guard isSingleDocumentFileName(fileName) else { return nil }
                candidate = dailyDirectory.appendingPathComponent(fileName, isDirectory: false)
            } else {
                // Bare names are daily documents, but must remain one path
                // component so they cannot escape through traversal.
                guard isSingleDocumentFileName(trimmed) else { return nil }
                candidate = dailyDirectory.appendingPathComponent(trimmed, isDirectory: false)
            }
        }

        return memoryContainedURL(candidate)
    }

    private func isSingleDocumentFileName(_ name: String) -> Bool {
        guard name.count > 4,
              name.hasSuffix(".md"),
              !name.isEmpty,
              name != ".md",
              name != "..md",
              !name.contains("/"),
              !name.contains("\\")
        else { return false }
        return true
    }

    private func memoryContainedURL(_ candidate: URL) -> URL? {
        if PersistenceTransactionFence.requiresReopen(persistenceDomain) {
            let root = memoryDirectory.standardizedFileURL.path + "/"
            return candidate.standardizedFileURL.path.hasPrefix(root) ? candidate : nil
        }

        let root = memoryDirectory.resolvingSymlinksInPath().standardizedFileURL
        // Foundation does not consistently resolve a symlinked parent when
        // the final child does not exist yet. Resolve the nearest existing
        // ancestor first, then resolve the candidate itself.
        var unresolvedComponents: [String] = []
        var ancestor = candidate.deletingLastPathComponent()
        while !fm.fileExists(atPath: ancestor.path) {
            guard ancestor.path != ancestor.deletingLastPathComponent().path,
                  let component = ancestor.lastPathComponent.isEmpty ? nil : ancestor.lastPathComponent
            else { return nil }
            unresolvedComponents.insert(component, at: 0)
            ancestor = ancestor.deletingLastPathComponent()
        }
        var resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        unresolvedComponents.append(candidate.lastPathComponent)
        for component in unresolvedComponents {
            resolvedAncestor.appendPathComponent(component, isDirectory: false)
        }
        let resolved = resolvedAncestor.resolvingSymlinksInPath().standardizedFileURL
        // Physical resolution can spell an existing Darwin ancestor as `/var`
        // while the missing root retains `/private/var`. Reuse the persistence
        // domain's alias spelling after resolution on both sides of this guard.
        let rootComponents = URL(
            fileURLWithPath: PersistenceTransactionFence.stablePath(root)
        ).pathComponents
        let resolvedComponents = URL(
            fileURLWithPath: PersistenceTransactionFence.stablePath(resolved)
        ).pathComponents
        guard resolvedComponents.count > rootComponents.count,
              resolvedComponents.starts(with: rootComponents)
        else { return nil }
        return candidate
    }

    // MARK: - Internals

    private func readFile(at url: URL) -> String {
        readFileOptional(at: url) ?? ""
    }

    private func readFileOptional(at url: URL) -> String? {
        lock.withLock {
            readFileUnlocked(at: url)
        }
    }

    private func readFileUnlocked(at url: URL) -> String? {
        guard let data = try? PersistenceTransactionFence.data(at: url, domain: persistenceDomain) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func writeFile(at url: URL, content: String) throws {
        try lock.withLock {
            try writeFileUnlocked(at: url, content: content)
        }
    }

    private func writeFileUnlocked(at url: URL, content: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = content.data(using: .utf8) else {
            throw MemoryFileStoreError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private func fileInfo(_ url: URL, kind: MemoryFileKind, relPath: String) -> MemoryFileInfo? {
        if PersistenceTransactionFence.requiresReopen(persistenceDomain) {
            guard let image = PersistenceTransactionFence.beforeImage(at: url, domain: persistenceDomain) else { return nil }
            let content = String(data: image.data, encoding: .utf8)
            return MemoryFileInfo(name: url.lastPathComponent, kind: kind, modifiedAt: image.modifiedAt,
                                  preview: Self.preview(of: content ?? ""),
                                  byteCount: image.data.count, relativePath: relPath, isReadable: content != nil)
        }

        // Listing must obey the same target boundary as open/save/delete.
        // A directory named `.md` is not an empty memory document. Resolve
        // metadata only after admission so an existing in-root alias remains valid.
        guard memoryContainedURL(url) != nil,
              let attrs = try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              attrs[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        let modifiedAt = (attrs[.modificationDate] as? Date) ?? Date()
        let byteCount = (attrs[.size] as? Int) ?? 0
        let content = readFileUnlocked(at: url)
        let preview = MemoryFileStore.preview(of: content ?? "")
        return MemoryFileInfo(
            name: url.lastPathComponent,
            kind: kind,
            modifiedAt: modifiedAt,
            preview: preview,
            byteCount: byteCount,
            relativePath: relPath, isReadable: content != nil
        )
    }

    /// First non-empty line, truncated to ~80 chars; "" when empty.
    static func preview(of content: String) -> String {
        let firstLine = content
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 {
            return String(trimmed.prefix(80)) + "…"
        }
        return trimmed
    }

    /// `yyyy-MM-dd` formatter for daily log file names. Created per call to
    /// keep it away from shared mutable state (thread-safe).
    private static var dailyFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

// MARK: - Errors

private enum MemoryFileStoreReadError: Error {
    case unreadable(URL)
}

public enum MemoryFileStoreError: Error, Equatable, Sendable {
    case encodingFailed
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
