import Darwin
import Foundation

// MARK: - Public value types

/// Lifecycle of one background `shell_execute` command.
public enum BackgroundShellState: String, Sendable, Equatable, Codable {
    case running
    case interrupted
    case outputFailure
    /// The shell exited by itself (inspect `exitCode`).
    case exited
    /// The configured background limit elapsed; the private group was killed.
    case timedOut
    /// The user (task centre) or the model (`shell_stop`) stopped it.
    case stopped
    /// The owning conversation was deleted or archived.
    case terminatedBySessionEnd
    /// The application is quitting.
    case terminatedByApplicationExit

    public var isTerminal: Bool { self != .running }

    /// Stable snake_case spelling used in tool results.
    public var wireName: String {
        switch self {
        case .running: return "running"
        case .interrupted: return "interrupted"
        case .outputFailure: return "output_failure"
        case .exited: return "exited"
        case .timedOut: return "timed_out"
        case .stopped: return "stopped"
        case .terminatedBySessionEnd: return "terminated_session_end"
        case .terminatedByApplicationExit: return "terminated_app_exit"
        }
    }
}

/// Why termination was requested. This is also what is written to the record.
public enum BackgroundShellStopReason: String, Sendable, Equatable {
    case user
    case model
    case sessionEnded
    case applicationExit

    var terminalState: BackgroundShellState {
        switch self {
        case .user, .model: return .stopped
        case .sessionEnded: return .terminatedBySessionEnd
        case .applicationExit: return .terminatedByApplicationExit
        }
    }
}

/// Immutable view of one background command. Holds no output body.
public struct BackgroundShellSnapshot: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let sessionID: String
    /// Redacted, single-line, truncated; never the raw command text.
    public let commandPreview: String
    public let state: BackgroundShellState
    public let exitCode: Int32?
    public let processID: Int32
    public let startedAt: Date
    public let endedAt: Date?
    public let timeoutSeconds: TimeInterval
    public let stdoutBytes: Int
    public let stderrBytes: Int
    /// Human-readable termination record, e.g. "stopped by the user".
    public let endNote: String?
    /// True once the owning conversation ended and the retained output was
    /// dropped (the task centre then shows no output for this record).
    public let outputDiscarded: Bool

    public init(
        id: String, sessionID: String, commandPreview: String, state: BackgroundShellState,
        exitCode: Int32?, processID: Int32, startedAt: Date, endedAt: Date?,
        timeoutSeconds: TimeInterval, stdoutBytes: Int, stderrBytes: Int, endNote: String?,
        outputDiscarded: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.commandPreview = commandPreview
        self.state = state
        self.exitCode = exitCode
        self.processID = processID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeoutSeconds = timeoutSeconds
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.endNote = endNote
        self.outputDiscarded = outputDiscarded
    }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// One entry of the in-memory audit trail kept by the registry.
public struct BackgroundShellEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case started, stopRequested, finished
    }
    public let kind: Kind
    public let snapshot: BackgroundShellSnapshot
    /// Present for `.stopRequested` and for stopped `.finished` events.
    public let reason: BackgroundShellStopReason?
    public let at: Date

    public init(kind: Kind, snapshot: BackgroundShellSnapshot, reason: BackgroundShellStopReason?, at: Date) {
        self.kind = kind
        self.snapshot = snapshot
        self.reason = reason
        self.at = at
    }
}

/// Result of one `shell_output` read.
public struct BackgroundShellOutput: Sendable, Equatable {
    public let snapshot: BackgroundShellSnapshot
    /// Redacted text produced since the previous model read (or everything
    /// retained when `fromStart` was requested).
    public let stdout: String
    public let stderr: String
    /// Bytes that fell off the retention window before they could be read.
    public let stdoutDroppedBytes: Int
    public let stderrDroppedBytes: Int
    /// True when this call hit the per-call cap and unread bytes remain.
    public let moreAvailable: Bool
    public var nextOffset: Int = 0
    public var outputPath: String? = nil
    public var readError: String? = nil
}

public enum BackgroundShellError: Error, Equatable, Sendable {
    case tooManyRunning(limit: Int)
}

// MARK: - Registry

/// Process-wide book of background shell commands.
///
/// Ownership rules (all deliberate):
/// - The monitor task is the only caller of `waitpid` and the only sender of
///   signals for its record. `stop`/`terminateAll` merely set a flag, so a
///   process-group id is never signalled after the leader was reaped by
///   another path, and never by `pkill` or a looked-up process name.
/// - Signals go to the private group created by `POSIX_SPAWN_SETPGROUP`, using
///   the existing `terminateShell` (TERM, short grace, KILL).
/// - Commands are spawned by `BuiltinToolExecutor.spawnShell`, so the
///   environment snapshot and signal masks are the foreground ones.
public final class BackgroundShellRegistry: @unchecked Sendable {
    public static let shared = BackgroundShellRegistry()
    public static let didChangeNotification = Notification.Name("MinisCanvas.BackgroundShellRegistry.didChange")
    private let persistence: BackgroundShellPersistence
    public static let defaultTimeoutSeconds: TimeInterval = 1800
    public static let defaultMaximumTimeoutSeconds: TimeInterval = 3600
    /// Absolute ceiling for any configured maximum (24 hours).
    public static let hardMaximumTimeoutSeconds: TimeInterval = 86_400
    public static let defaultMaximumRunning = 8
    public static let retainedFinishedLimit = 50
    public static let outputRetentionPerStream = 1 << 20
    public static let outputBytesPerReadPerStream = 128 * 1024
    static let terminationGrace: TimeInterval = 0.5
    static let drainGrace: TimeInterval = 1
    static let previewLimit = 120
    static let eventLimit = 400

    private struct OutputBuffer {
        var data = Data()
        var droppedBytes = 0
        var readCursor = 0 // absolute offset already returned to the model
        var total: Int { droppedBytes + data.count }

        /// Empties the buffer but keeps the byte totals consistent.
        mutating func discard() {
            droppedBytes += data.count
            data = Data()
            readCursor = droppedBytes
        }

        mutating func append(_ chunk: Data, limit: Int) {
            data.append(chunk)
            if data.count > limit {
                let excess = data.count - limit
                data = Data(data.dropFirst(excess))
                droppedBytes += excess
            }
        }
    }

    private final class Record {
        let id: String
        let sessionID: String
        let commandPreview: String
        let timeoutSeconds: TimeInterval
        let startedAt: Date
        var processID: Int32 = 0
        var processStart: UInt64?
        var pendingStdout = Data()
        var pendingStderr = Data()
        var outputError: String?
        var knownSecrets: [String] = []
        var state: BackgroundShellState = .running
        var exitCode: Int32?
        var endedAt: Date?
        var endNote: String?
        var stopReason: BackgroundShellStopReason?
        var stdout = OutputBuffer()
        var stderr = OutputBuffer()
        /// Set when the owning conversation ended: buffers are emptied and
        /// later output is not retained.
        var outputDiscarded = false

        init(id: String, sessionID: String, commandPreview: String,
             timeoutSeconds: TimeInterval, startedAt: Date) {
            self.id = id
            self.sessionID = sessionID
            self.commandPreview = commandPreview
            self.timeoutSeconds = timeoutSeconds
            self.startedAt = startedAt
        }

        func snapshot() -> BackgroundShellSnapshot {
            BackgroundShellSnapshot(
                id: id, sessionID: sessionID, commandPreview: commandPreview,
                state: state, exitCode: exitCode, processID: processID,
                startedAt: startedAt, endedAt: endedAt, timeoutSeconds: timeoutSeconds,
                stdoutBytes: stdout.total, stderrBytes: stderr.total, endNote: endNote,
                outputDiscarded: outputDiscarded)
        }
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var eventLog: [BackgroundShellEvent] = []
    private var configuredMaximumRunning: Int
    private var configuredDefaultTimeout: TimeInterval
    private var configuredMaximumTimeout: TimeInterval
    private var sink: (@Sendable (BackgroundShellEvent) -> Void)?

    public init(
        storageRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MinisCanvas/BackgroundShell", isDirectory: true),
        maximumRunning: Int = BackgroundShellRegistry.defaultMaximumRunning,
        defaultTimeoutSeconds: TimeInterval = BackgroundShellRegistry.defaultTimeoutSeconds,
        maximumTimeoutSeconds: TimeInterval = BackgroundShellRegistry.defaultMaximumTimeoutSeconds
    ) {
        persistence = BackgroundShellPersistence(root: storageRoot)
        configuredMaximumRunning = max(1, maximumRunning)
        let maximum = Self.clampMaximum(maximumTimeoutSeconds)
        configuredMaximumTimeout = maximum
        configuredDefaultTimeout = min(max(1, defaultTimeoutSeconds), maximum)
    }

    // MARK: Configuration

    /// Upper bound for the model-supplied `timeout` of a background command.
    /// Configurable at runtime; clamped to 1 second ... 24 hours.
    public var maximumTimeoutSeconds: TimeInterval {
        get { lock.withLock { configuredMaximumTimeout } }
        set {
            lock.withLock {
                configuredMaximumTimeout = Self.clampMaximum(newValue)
                configuredDefaultTimeout = min(configuredDefaultTimeout, configuredMaximumTimeout)
            }
        }
    }

    /// Timeout used when the model passes none.
    public var defaultTimeoutSeconds: TimeInterval {
        lock.withLock { configuredDefaultTimeout }
    }

    public var maximumRunning: Int {
        get { lock.withLock { configuredMaximumRunning } }
        set { lock.withLock { configuredMaximumRunning = max(1, newValue) } }
    }

    /// Receives every event after it is appended to the in-memory trail. The
    /// closure runs on an arbitrary thread and must not call back into the
    /// registry synchronously.
    public func setEventSink(_ sink: (@Sendable (BackgroundShellEvent) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    private static func clampMaximum(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultMaximumTimeoutSeconds }
        return min(hardMaximumTimeoutSeconds, max(1, value))
    }

    /// `raw` is the model's `timeout` argument. Missing/invalid -> default.
    public func resolveTimeout(_ raw: Any?) -> TimeInterval {
        let limits = lock.withLock { (configuredDefaultTimeout, configuredMaximumTimeout) }
        guard let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else {
            return limits.0
        }
        return min(limits.1, max(0.001, number.doubleValue))
    }

    // MARK: Queries

    public var runningCount: Int {
        lock.withLock { records.values.filter { $0.state == .running }.count }
    }
    public var hasRunning: Bool { runningCount > 0 }

    /// Newest first. `sessionID == nil` returns every session (UI), otherwise
    /// only that session's commands.
    public func snapshots(sessionID: String? = nil) -> [BackgroundShellSnapshot] {
        lock.withLock {
            order.reversed().compactMap { records[$0] }
                .filter { sessionID == nil || $0.sessionID == sessionID }
                .map { $0.snapshot() }
        }
    }

    public func snapshot(id: String, sessionID: String? = nil) -> BackgroundShellSnapshot? {
        lock.withLock {
            guard let record = records[id], sessionID == nil || record.sessionID == sessionID else { return nil }
            return record.snapshot()
        }
    }

    public func events() -> [BackgroundShellEvent] { lock.withLock { eventLog } }

    /// Non-consuming tail for display. Redacted; at most `maxBytes` per stream.
    public func tail(id: String, maxBytes: Int = 4096) -> (stdout: String, stderr: String)? {
        lock.withLock {
            guard let record = records[id] else { return nil }
            if record.outputDiscarded { return ("", "") }
            do {
                let file = try FileHandle(forReadingFrom: persistence.outputURL(id))
                defer { try? file.close() }
                let end = try file.seekToEnd()
                try file.seek(toOffset: end > UInt64(max(0, maxBytes)) ? end - UInt64(max(0, maxBytes)) : 0)
                let bytes = try file.read(upToCount: max(0, maxBytes)) ?? Data()
                return (Self.redactedTail(bytes, maxBytes), "")
            } catch { return ("后台输出读取失败：\(error.localizedDescription)", "") }
        }
    }

    // MARK: Model reads

    /// Returns output produced since the previous read for the same session
    /// (or the retained buffer when `fromStart`). A normal read advances the
    /// read cursor only by the bytes actually returned; a `fromStart` re-read
    /// never moves the cursor, so later incremental reads do not repeat it.
    public func readOutput(id: String, sessionID: String, fromStart: Bool = false) -> BackgroundShellOutput? {
        lock.withLock {
            guard let record = records[id], record.sessionID == sessionID else { return nil }
            let cap = Self.outputBytesPerReadPerStream
            let finished = record.state.isTerminal
            let out = Self.consume(&record.stdout, fromStart: fromStart, cap: cap, finished: finished)
            let err = Self.consume(&record.stderr, fromStart: fromStart, cap: cap, finished: finished)
            return BackgroundShellOutput(
                snapshot: record.snapshot(), stdout: out.text, stderr: err.text,
                stdoutDroppedBytes: record.stdout.droppedBytes, stderrDroppedBytes: record.stderr.droppedBytes,
                moreAvailable: out.more || err.more)
        }
    }

    private static func consume(_ buffer: inout OutputBuffer, fromStart: Bool, cap: Int, finished: Bool)
        -> (text: String, more: Bool) {
        let startOffset = max(fromStart ? 0 : buffer.readCursor, buffer.droppedBytes)
        let available = buffer.total - startOffset
        guard available > 0 else { return ("", false) }
        let begin = buffer.data.startIndex + (startOffset - buffer.droppedBytes)
        var count = min(available, cap)
        // While the process still runs (or the cap cuts the data), never
        // return half of a UTF-8 scalar; the remainder is read next time.
        if !finished || count < available {
            count -= incompleteUTF8Suffix(buffer.data[begin..<(begin + count)])
        }
        guard count > 0 else { return ("", false) }
        let slice = buffer.data[begin..<(begin + count)]
        if !fromStart { buffer.readCursor = startOffset + count }
        return (ContentSecretRedactor.redact(String(decoding: slice, as: UTF8.self)), available > count)
    }

    /// Number of trailing bytes forming an incomplete UTF-8 scalar (0...3).
    static func incompleteUTF8Suffix(_ bytes: Data) -> Int {
        let tail = Array(bytes.suffix(3))
        guard !tail.isEmpty else { return 0 }
        for back in 1...tail.count {
            let byte = tail[tail.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // continuation byte
            let needed: Int
            if byte & 0b1110_0000 == 0b1100_0000 { needed = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { needed = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { needed = 4 }
            else { return 0 } // ASCII or invalid lead
            return back < needed ? back : 0
        }
        return 0
    }

    private static func redactedTail(_ data: Data, _ maxBytes: Int) -> String {
        let slice = data.suffix(max(0, maxBytes))
        // Drop leading continuation bytes so the tail starts on a scalar.
        let trimmed = slice.drop(while: { $0 & 0b1100_0000 == 0b1000_0000 })
        return ContentSecretRedactor.redact(String(decoding: trimmed, as: UTF8.self))
    }

    // MARK: Start (two phase: reserve, then attach the spawned process)

    /// Reserves a record before any process exists, so a full registry never
    /// spawns. The caller must follow with `attach` or `abandon`.
    func reserve(command: String, sessionID: String, timeoutSeconds: TimeInterval, knownSecrets: [String] = []) throws -> String {
        try lock.withLock {
            let running = records.values.filter { $0.state == .running }.count
            guard running < configuredMaximumRunning else {
                throw BackgroundShellError.tooManyRunning(limit: configuredMaximumRunning)
            }
            let id = "bg-" + String(UUID().uuidString.prefix(8)).lowercased()
            records[id] = Record(
                id: id, sessionID: sessionID, commandPreview: Self.preview(command, knownSecrets: knownSecrets),
                timeoutSeconds: timeoutSeconds, startedAt: Date())
            records[id]?.knownSecrets = knownSecrets
            do { try persistence.append("", id: id) }
            catch { records.removeValue(forKey: id); throw error }
            order.append(id)
            return id
        }
    }

    func abandon(id: String) {
        lock.withLock {
            do {
                try persistence.remove(id: id)
                records.removeValue(forKey: id)
                order.removeAll { $0 == id }
            } catch {
                records[id]?.state = .outputFailure
                records[id]?.endedAt = Date()
                records[id]?.endNote = "后台启动失败，登记清理失败：\(error.localizedDescription)"
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    static func preview(_ command: String, knownSecrets: [String] = []) -> String {
        let single = command.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        let redacted = ContentSecretRedactor.redact(single, knownSecrets: knownSecrets)
        return redacted.count > previewLimit ? String(redacted.prefix(previewLimit)) + "…" : redacted
    }

    /// Takes ownership of the spawned shell and starts the single monitor task.
    @discardableResult
    func attach(id: String, shell: SpawnedShell) throws -> BackgroundShellSnapshot? {
        let started: (event: BackgroundShellEvent, sink: (@Sendable (BackgroundShellEvent) -> Void)?)? = try lock.withLock {
            guard let record = records[id] else { return nil }
            record.processID = shell.pid
            record.processStart = BackgroundShellPersistence.processStart(shell.pid)
            try persistence.write(.init(snapshot: record.snapshot(), processStart: record.processStart))
            try persistence.append("", id: id)
            let event = BackgroundShellEvent(kind: .started, snapshot: record.snapshot(), reason: nil, at: Date())
            appendEventLocked(event)
            return (event, sink)
        }
        guard let started else {
            // The record vanished; never leave an unowned process behind.
            terminateShell(shell.pid, force: true)
            _ = pollShellExit(shell.pid)
            return nil
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        started.sink?(started.event)
        Task.detached(priority: .utility) { [self] in
            await monitor(id: id, shell: shell)
        }
        return started.event.snapshot
    }

    // MARK: Stop

    /// Requests termination of one command. Returns false when the id is
    /// unknown (or belongs to another session when `sessionID` is given) or the
    /// command is already finished. The monitor performs the signalling.
    @discardableResult
    public func stop(id: String, reason: BackgroundShellStopReason, sessionID: String? = nil) -> Bool {
        let pending: (event: BackgroundShellEvent, sink: (@Sendable (BackgroundShellEvent) -> Void)?)? = lock.withLock {
            guard let record = records[id], sessionID == nil || record.sessionID == sessionID,
                  record.state == .running else { return nil }
            if record.stopReason == nil {
                record.stopReason = reason
                let event = BackgroundShellEvent(kind: .stopRequested, snapshot: record.snapshot(), reason: reason, at: Date())
                appendEventLocked(event)
                return (event, sink)
            }
            // A termination was already requested; keep the first reason.
            return (BackgroundShellEvent(kind: .stopRequested, snapshot: record.snapshot(), reason: record.stopReason, at: Date()), nil)
        }
        guard let pending else { return false }
        pending.sink?(pending.event)
        return true
    }

    /// Stops every running command of one session and waits (bounded) until
    /// the monitors have finished signalling and reaping.
    @discardableResult
    public func terminateAll(sessionID: String, reason: BackgroundShellStopReason,
                             waitSeconds: TimeInterval = 3) async -> Int {
        let ids = lock.withLock { records.values.filter { $0.sessionID == sessionID && $0.state == .running }.map(\.id) }
        for id in ids { stop(id: id, reason: reason) }
        await waitUntilFinished(ids: ids, waitSeconds: waitSeconds)
        // The monitor did not finish in time: do not leave the group behind.
        return ids.count
    }

    /// Application exit: stop everything and wait (bounded).
    @discardableResult
    public func terminateAll(reason: BackgroundShellStopReason = .applicationExit,
                             waitSeconds: TimeInterval = 3) async -> Int {
        let ids = lock.withLock { records.values.filter { $0.state == .running }.map(\.id) }
        for id in ids { stop(id: id, reason: reason) }
        await waitUntilFinished(ids: ids, waitSeconds: waitSeconds)
        return ids.count
    }

    /// Drops the retained output of every command of an ended conversation and
    /// stops retaining new output for it (bounds memory: up to 2 MiB per
    /// record otherwise stays resident for the life of the app). Records stay
    /// listed so the task centre can still show what ran and how it ended.
    public func discardOutput(sessionID: String) {
        lock.withLock {
            for record in records.values where record.sessionID == sessionID {
                record.outputDiscarded = true
                record.stdout.discard()
                record.stderr.discard()
                record.pendingStdout.removeAll()
                record.pendingStderr.removeAll()
                do {
                    try persistence.discardLog(id: record.id)
                    try persistence.write(.init(snapshot: record.snapshot(), processStart: record.processStart))
                }
                catch { record.endNote = "会话输出清理失败：\(error.localizedDescription)" }
            }
        }
    }

    public func waitUntilFinished(ids: [String], waitSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            let pending = lock.withLock { ids.contains { records[$0]?.state == .running } }
            if !pending { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Monitor

    private enum Ending {
        case exited(Int32?)
        case observationFailed(String)
        case timedOut
        case stopRequested(BackgroundShellStopReason)
    }

    private func monitor(id: String, shell: SpawnedShell) async {
        let pid = shell.pid
        let lifetime = ShellPipeReaderLifetime()
        let stdoutReader = Self.makeReader(shell.stdout, lifetime: lifetime, failure: { [weak self] message in
            self?.recordOutputFailure(id: id, message: message)
        }) { [weak self] chunk in
            self?.appendOutput(id: id, isStdout: true, chunk: chunk)
        }
        let stderrReader = Self.makeReader(shell.stderr, lifetime: lifetime, failure: { [weak self] message in
            self?.recordOutputFailure(id: id, message: message)
        }) { [weak self] chunk in
            self?.appendOutput(id: id, isStdout: false, chunk: chunk)
        }

        let timeout = lock.withLock { records[id]?.timeoutSeconds ?? 0 }
        let deadline = Date().addingTimeInterval(timeout)
        var ending: Ending = .timedOut
        while true {
            do {
                var info = siginfo_t()
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
                    if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } else if info.si_pid == pid {
                    // WNOWAIT keeps the exited leader unreaped while its private
                    // group is terminated, preventing a recycled process-group ID.
                    terminateShell(pid, force: true)
                    ending = .exited(await reapShell(pid, timeout: Self.terminationGrace))
                    break
                }
            } catch {
                ending = .observationFailed(error.localizedDescription)
                break
            }
            if lock.withLock({ records[id]?.outputError != nil }) { ending = .stopRequested(.user); break }
            if let reason = lock.withLock({ records[id]?.stopReason }) { ending = .stopRequested(reason); break }
            if Date() >= deadline { ending = .timedOut; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var exitStatus: Int32?
        switch ending {
        case .exited(let status):
            exitStatus = status
        case .observationFailed:
            break
        case .timedOut, .stopRequested:
            // The leader stays unreaped through the grace period, so the
            // group id cannot be recycled before the signals are sent.
            terminateShell(pid, force: false)
            exitStatus = await reapShell(pid, timeout: Self.terminationGrace)
            if exitStatus == nil {
                terminateShell(pid, force: true)
                exitStatus = await reapShell(pid, timeout: Self.terminationGrace)
            }
        }
        await lifetime.beginFinalDrain(gracePeriod: Self.drainGrace)
        _ = await stdoutReader.value
        _ = await stderrReader.value

        let state: BackgroundShellState
        let note: String
        let code: Int32? = exitStatus.map { shellExitCode($0) }
        switch ending {
        case .observationFailed(let error):
            state = .interrupted
            note = "后台进程观测失败：\(error)"
        case .exited:
            state = .exited
            note = "exited with code \(code ?? -1)"
        case .timedOut:
            state = .timedOut
            note = "killed after the \(Int(timeout))s background limit"
        case .stopRequested(let reason):
            state = reason.terminalState
            switch reason {
            case .user: note = "stopped by the user"
            case .model: note = "stopped by shell_stop"
            case .sessionEnded: note = "terminated because the conversation ended"
            case .applicationExit: note = "terminated because the application exited"
            }
        }
        lock.withLock {
            if let record = records[id] {
                flushOutput(record, isStdout: true, final: true)
                flushOutput(record, isStdout: false, final: true)
            }
        }
        finish(id: id, state: state, exitCode: code, note: note)
    }

    private func finish(id: String, state: BackgroundShellState, exitCode: Int32?, note: String) {
        let pending: (event: BackgroundShellEvent, sink: (@Sendable (BackgroundShellEvent) -> Void)?)? = lock.withLock {
            guard let record = records[id], record.state == .running else { return nil }
            record.state = record.outputError == nil ? state : .outputFailure
            record.exitCode = exitCode
            record.endedAt = Date()
            record.endNote = record.outputError ?? note
            do { try persistence.write(.init(snapshot: record.snapshot(), processStart: record.processStart)) }
            catch { record.endNote = "后台任务登记写入失败：\(error.localizedDescription)" }
            let event = BackgroundShellEvent(kind: .finished, snapshot: record.snapshot(), reason: record.stopReason, at: Date())
            appendEventLocked(event)
            evictFinishedLocked()
            return (event, sink)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if let pending { pending.sink?(pending.event) }
    }

    private func recordOutputFailure(id: String, message: String) {
        lock.withLock { records[id]?.outputError = "后台输出读取失败：" + message }
    }

    func appendOutput(id: String, isStdout: Bool, chunk: Data) {
        lock.withLock {
            guard let record = records[id], !record.outputDiscarded else { return }
            if isStdout { record.pendingStdout.append(chunk) }
            else { record.pendingStderr.append(chunk) }
            flushOutput(record, isStdout: isStdout, final: false)
        }
    }


    // Buffer through a newline so credentials split between pipe chunks are never persisted raw.
    private func flushOutput(_ record: Record, isStdout: Bool, final: Bool) {
        var pending = isStdout ? record.pendingStdout : record.pendingStderr
        // Data retains its collection index after removeFirst; an index is
        // not a byte count once a previous line has been consumed.
        let count = final ? pending.count : (pending.lastIndex(of: 10).map {
            pending.distance(from: pending.startIndex, to: $0) + 1
        } ?? 0)
        guard pending.count <= Self.outputRetentionPerStream else {
            record.outputError = "后台命令单行输出超过 1 MiB，已停止；未保存该行。"
            return
        }
        guard count > 0 else { return }
        let text = ContentSecretRedactor.redact(String(decoding: pending.prefix(count), as: UTF8.self), knownSecrets: record.knownSecrets)
        do { try persistence.append(text, id: record.id) }
        catch { record.outputError = "后台输出保存失败（每任务上限 16 MiB）：\(error.localizedDescription)"; return }
        let bytes = Data(text.utf8)
        if isStdout { record.stdout.append(bytes, limit: Self.outputRetentionPerStream) }
        else { record.stderr.append(bytes, limit: Self.outputRetentionPerStream) }
        pending.removeFirst(count)
        if isStdout { record.pendingStdout = pending } else { record.pendingStderr = pending }
    }

    /// Cursor is a byte offset in the combined, already-redacted output log.
    public func readOutput(id: String, sessionID: String, offset: Int) -> BackgroundShellOutput? {
        lock.withLock {
            guard let record = records[id], record.sessionID == sessionID, !record.outputDiscarded else { return nil }
            var output = BackgroundShellOutput(snapshot: record.snapshot(), stdout: "", stderr: "",
                stdoutDroppedBytes: 0, stderrDroppedBytes: 0, moreAvailable: false)
            do {
                let value = try persistence.read(id: id, offset: offset, cap: Self.outputBytesPerReadPerStream)
                output = BackgroundShellOutput(snapshot: record.snapshot(), stdout: value.0, stderr: "",
                    stdoutDroppedBytes: 0, stderrDroppedBytes: 0, moreAvailable: value.2,
                    nextOffset: value.1, outputPath: persistence.outputURL(id).path)
            } catch { output.readError = "后台输出读取失败：\(error.localizedDescription)" }
            return output
        }
    }

    /// Startup reconciliation never signals a PID unless its kernel start time still matches.
    @discardableResult
    public func recoverInterruptedJobs() throws -> Int {
        let saved = try persistence.records().sorted { $0.snapshot.startedAt < $1.snapshot.startedAt }
        var cleaned = 0
        try lock.withLock {
            for item in saved {
                let old = item.snapshot
                guard records[old.id] == nil else { continue }
                let record = Record(id: old.id, sessionID: old.sessionID,
                    commandPreview: old.commandPreview, timeoutSeconds: old.timeoutSeconds, startedAt: old.startedAt)
                record.processID = old.processID
                record.processStart = item.processStart
                record.state = old.state
                record.exitCode = old.exitCode
                record.endedAt = old.endedAt
                record.endNote = old.endNote
                record.outputDiscarded = old.outputDiscarded
                if old.state == .running {
                    if let start = item.processStart, start == BackgroundShellPersistence.processStart(old.processID),
                       getpgid(old.processID) == old.processID {
                        if kill(-old.processID, SIGKILL) != 0 && errno != ESRCH { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        cleaned += 1
                    }
                    record.state = .interrupted
                    record.endedAt = Date()
                    record.endNote = "上次应用中断；仅清理核对身份一致的自有进程。"
                    try persistence.write(.init(snapshot: record.snapshot(), processStart: item.processStart))
                }
                records[old.id] = record
                order.append(old.id)
            }
            evictFinishedLocked()
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return cleaned
    }

    private func appendEventLocked(_ event: BackgroundShellEvent) {
        eventLog.append(event)
        if eventLog.count > Self.eventLimit { eventLog.removeFirst(eventLog.count - Self.eventLimit) }
    }

    private func evictFinishedLocked() {
        let finished = order.filter { records[$0]?.state.isTerminal == true }
        guard finished.count > Self.retainedFinishedLimit else { return }
        for id in finished.prefix(finished.count - Self.retainedFinishedLimit) {
            do { try persistence.remove(id: id) } catch { records[id]?.endNote = "历史输出清理失败：\(error.localizedDescription)"; continue }
            records.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
    }

    /// Incremental pipe reader: poll(2) with a short timeout so cancellation
    /// and the final-drain deadline stay observable; ends at EOF.
    private static func makeReader(
        _ handle: FileHandle, lifetime: ShellPipeReaderLifetime,
        failure: @escaping @Sendable (String) -> Void,
        deliver: @escaping @Sendable (Data) -> Void
    ) -> Task<Void, Never> {
        let duplicated = dup(handle.fileDescriptor)
        guard duplicated >= 0 else {
            failure(String(cString: strerror(errno)))
            return Task {}
        }
        return Task.detached(priority: .utility) {
            let reader = FileHandle(fileDescriptor: duplicated, closeOnDealloc: true)
            let fd = reader.fileDescriptor
            // The FileHandle owns the duplicated descriptor; keep it alive
            // for the whole polling loop.
            defer { withExtendedLifetime(reader) {} }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if Task.isCancelled { return }
                if await lifetime.drainExpired() { return }
                let polled: (ready: Int32, error: Int32) = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                        let ready = poll(&pfd, 1, 50)
                        continuation.resume(returning: (ready, errno))
                    }
                }
                if polled.ready < 0 {
                    if polled.error == EINTR { continue }
                    failure(String(cString: strerror(polled.error)))
                    return
                }
                if polled.ready == 0 { continue }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    failure(String(cString: strerror(errno)))
                    return
                }
                deliver(Data(buffer.prefix(count)))
            }
        }
    }
}
