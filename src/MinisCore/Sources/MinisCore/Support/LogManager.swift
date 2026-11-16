import Foundation

/// Log severity levels, ordered lowest → highest. `rawValue` doubles as the
/// severity rank for threshold filtering.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }
}

/// A single structured log entry, kept in memory for `recentLogs()` and
/// written to the on-disk log file.
public struct LogEntry: Sendable, Equatable {
    public let eventID: String
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String,
        eventID: String? = nil,
        knownSecrets: [String] = []
    ) {
        let scrubbed = AppLogRedactionPolicy.scrub(
            eventID: eventID,
            category: category,
            message: message,
            knownSecrets: knownSecrets
        )
        self.eventID = scrubbed.eventID
        self.timestamp = timestamp
        self.level = level
        self.category = scrubbed.category
        self.message = scrubbed.message
    }

    /// Single-line human-readable form, e.g. `[2026-08-03 10:00:00] [INFO] [Network] message`.
    public var formatted: String {
        let df = Self.formatter
        return "[\(df.string(from: timestamp))] [\(level.label)] [\(category)] [\(eventID)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Level-filtered structured logger with in-memory ring buffer (`recentLogs()`
/// for UI) and optional append-only file persistence (`logs/app.log`, rotated
/// by size). Thread-safe; a drop-in complement to `AppLogger` (which stays for
/// os.Logger integration).
public final class LogManager: @unchecked Sendable {
    public static let shared = LogManager()

    private let lock = NSLock()
    private let fileURL: URL
    private let maxFileSize: UInt64
    private let ringCapacity: Int
    private var knownSecrets: Set<String>

    private var ring: [LogEntry] = []
    private var _minimumLevel: LogLevel = .debug
    private var _isFileLoggingEnabled = true

    /// - Parameters:
    ///   - directory: Directory for `logs/app.log`. Defaults to
    ///     `~/Library/Application Support/MinisCanvas/logs`.
    ///   - maxFileSize: Rotate (app.log → app.1.log) once the file reaches this size.
    ///   - ringCapacity: Max entries kept in memory for `recentLogs()`.
    public init(
        directory: URL? = nil,
        maxFileSize: UInt64 = 1_000_000,
        ringCapacity: Int = 500,
        knownSecrets: [String] = []
    ) {
        let dir = directory ?? {
            if let formal = FormalTestIsolationPaths.currentOrFail() {
                return formal.logDirectory
            }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("MinisCanvas/logs", isDirectory: true)
        }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("app.log", isDirectory: false)
        self.maxFileSize = maxFileSize
        self.ringCapacity = max(1, ringCapacity)
        self.knownSecrets = Set(knownSecrets.filter { !$0.isEmpty })
    }

    // MARK: - Configuration

    /// Protect already-resolved values before their owner can emit a log.
    /// Retain previous values for delayed messages after rotation or deletion;
    /// this registry never resolves credentials or persists their plaintext.
    public func registerKnownSecrets(_ values: [String]) {
        lock.lock()
        defer { lock.unlock() }
        knownSecrets.formUnion(values.filter { !$0.isEmpty })
    }

    /// Messages below this level are dropped entirely (buffer + file).
    public var minimumLevel: LogLevel {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _minimumLevel
        }
        set {
            lock.lock()
            _minimumLevel = newValue
            lock.unlock()
        }
    }

    /// Master switch for on-disk persistence (buffer is unaffected).
    public var isFileLoggingEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isFileLoggingEnabled
        }
        set {
            lock.lock()
            _isFileLoggingEnabled = newValue
            lock.unlock()
        }
    }

    /// Whether `level` passes the current threshold.
    public func shouldLog(_ level: LogLevel) -> Bool {
        level >= minimumLevel
    }

    // MARK: - Logging

    public func log(
        level: LogLevel,
        category: String,
        message: String,
        eventID: String? = nil
    ) {
        // Registration, redaction and both sinks share one ordering boundary.
        // A registered value cannot race an in-flight file append.
        lock.lock()
        defer { lock.unlock() }
        guard level >= _minimumLevel else { return }
        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            eventID: eventID,
            knownSecrets: Array(knownSecrets)
        )

        ring.append(entry)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        if _isFileLoggingEnabled {
            appendToFile(entry)
        }
    }

    public func debug(_ message: String, category: String = "General", eventID: String? = nil) { log(level: .debug, category: category, message: message, eventID: eventID) }
    public func info(_ message: String, category: String = "General", eventID: String? = nil) { log(level: .info, category: category, message: message, eventID: eventID) }
    public func warn(_ message: String, category: String = "General", eventID: String? = nil) { log(level: .warn, category: category, message: message, eventID: eventID) }
    public func error(_ message: String, category: String = "General", eventID: String? = nil) { log(level: .error, category: category, message: message, eventID: eventID) }

    // MARK: - Reading

    /// Most recent entries first (newest at index 0). Empty until something is logged.
    public func recentLogs(limit: Int? = nil) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let result = Array(ring.reversed())
        if let limit, limit > 0 {
            return Array(result.prefix(limit))
        }
        return result
    }

    /// Formatted single string of the last `limit` entries, for UI display.
    public func recentLogsText(limit: Int = 100) -> String {
        recentLogs(limit: limit).map(\.formatted).joined(separator: "\n")
    }

    /// Current on-disk log file URL (nil if the file doesn't exist yet).
    public func logFileURL() -> URL? {
        FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Clear the in-memory ring buffer (settings UI "clear logs" action).
    /// The on-disk log file is left untouched.
    public func clearLogs() {
        lock.lock()
        ring.removeAll()
        lock.unlock()
    }

    // MARK: - File persistence

    private func appendToFile(_ entry: LogEntry) {
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data((entry.formatted + "\n").utf8))
    }

    /// Renames `app.log` → `app.1.log` (replacing any previous backup) once the
    /// file reaches `maxFileSize`.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size >= maxFileSize
        else { return }
        let backup = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)
    }
}
