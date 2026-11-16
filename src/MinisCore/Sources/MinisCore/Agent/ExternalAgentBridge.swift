import Foundation
import Darwin

// MARK: - External Agent Runner Protocol

/// 外部 CLI agent 桥协议（E23 多智能体协同）。
///
/// 实现方把 `SubAgentTask` 翻译成一条外部 CLI 调用（Process 执行），返回纯文本输出。
/// 约定：`isAvailable == false` 时 `run` 应抛 `ExternalAgentError.binaryNotFound`。
public protocol ExternalAgentRunner: Sendable {
    /// agent 名（如 `"codex"`），与 `SubAgentAgentType.external(name:)` 对应。
    var name: String { get }
    /// 底层 CLI 是否已安装（`which` 语义，纯 PATH 扫描，不启动子进程）。
    var isAvailable: Bool { get }
    /// Capabilities guaranteed by the external runner integration.
    var capabilities: Set<ProviderCapability> { get }
    /// 执行任务，返回 CLI 标准输出文本；失败抛 `ExternalAgentError`。
    func run(task: SubAgentTask) async throws -> String
    /// 在编排器给定的工作目录里执行（runner 自己注入的目录优先）。
    func run(task: SubAgentTask, workingDirectory: URL?) async throws -> String
    /// Best-effort cancellation of the active invocation.
    func cancel(task: SubAgentTask) async
}

// MARK: - Errors

public extension ExternalAgentRunner {
    var capabilities: Set<ProviderCapability> { [] }
    func cancel(task: SubAgentTask) async {}
    func run(task: SubAgentTask, workingDirectory: URL?) async throws -> String {
        try await run(task: task)
    }
}

public enum ExternalAgentError: Error, Sendable, Equatable {
    /// 未找到可执行文件（未安装 / 路径不存在）。
    case binaryNotFound(String)
    /// 进程退出码非 0。
    case nonZeroExit(Int32, String)
    /// 超过超时时间被强制终止。
    case timeout(String)
    /// 进程启动失败。
    case spawnFailed(String)
}

extension ExternalAgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let binary):
            return "未在以下位置找到 \(binary)："
                + ExternalAgentBinaryLocator.searchedLocations(for: binary).joined(separator: "、")
        case .nonZeroExit(let code, let stderr):
            return "外部 CLI 退出码 \(code): \(stderr)"
        case .timeout(let binary):
            return "外部 CLI '\(binary)' 执行超时"
        case .spawnFailed(let detail):
            return "外部 CLI 启动失败: \(detail)"
        }
    }
}

// MARK: - Reconnect-bound external collaboration identity

/// Identity shared by every delivery of one external collaboration attempt.
/// A new attempt must use a new `attemptID`, even when it reuses a correlation.
public struct ExternalAgentInvocationIdentity: Codable, Equatable, Hashable, Sendable {
    public let correlationID: String
    public let attemptID: String

    public init(correlationID: String, attemptID: String) {
        self.correlationID = correlationID
        self.attemptID = attemptID
    }

    public var isValid: Bool {
        !correlationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@frozen public enum ExternalAgentTerminalOutcomeV1: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// Redacted terminal state emitted by the external collaboration bridge.
/// Raw provider output is intentionally not a field of this value.
public struct ExternalAgentTerminalEventV1: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumSummaryCharacters = 512

    public let schemaVersion: Int
    public let identity: ExternalAgentInvocationIdentity
    public let eventID: String
    public let sourceID: ExternalSessionSourceID
    public let threadID: ExternalSessionThreadID
    public let turnID: ExternalSessionTurnID?
    public let sequence: UInt64
    public let sourceCursor: ExternalSessionCursorV1
    public let occurredAt: Date
    public let connectionGeneration: UInt64
    public let outcome: ExternalAgentTerminalOutcomeV1
    public let redactedSummary: String

    public init(
        schemaVersion: Int = ExternalAgentTerminalEventV1.schemaVersion,
        identity: ExternalAgentInvocationIdentity,
        eventID: String,
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        turnID: ExternalSessionTurnID? = nil,
        sequence: UInt64,
        sourceCursor: ExternalSessionCursorV1,
        occurredAt: Date,
        connectionGeneration: UInt64,
        outcome: ExternalAgentTerminalOutcomeV1,
        summary: String
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.eventID = eventID
        self.sourceID = sourceID
        self.threadID = threadID
        self.turnID = turnID
        self.sequence = sequence
        self.sourceCursor = sourceCursor
        self.occurredAt = occurredAt
        self.connectionGeneration = connectionGeneration
        self.outcome = outcome
        self.redactedSummary = Self.redact(summary)
    }

    /// Compatibility-friendly read name for consumers that call the bounded
    /// terminal text a summary. The stored value remains explicitly redacted.
    public var summary: String { redactedSummary }
    public var correlationID: String { identity.correlationID }
    public var attemptID: String { identity.attemptID }

    private static func redact(_ value: String) -> String {
        let words = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var redactedNextWord = false
        let sanitized = words.map { word -> String in
            if redactedNextWord {
                redactedNextWord = false
                return "[REDACTED]"
            }
            if word.lowercased() == "bearer" || word.lowercased().hasPrefix("bearer:") {
                redactedNextWord = true
                return "[REDACTED]"
            }
            if word.hasPrefix("/") || word.contains("\\") {
                return "[REDACTED_PATH]"
            }
            return word
        }.joined(separator: " ")
        return String(sanitized.prefix(Self.maximumSummaryCharacters))
    }
}

@frozen public enum ExternalAgentTerminalAcceptance: String, Codable, Equatable, Sendable {
    case accepted
    case rejectedDuplicate
    case rejectedStaleAttempt
    case rejectedStopped
    case rejectedInvalid
}

/// Small, thread-safe production fence for reconnect, duplicate delivery and
/// stop races. It is transport-agnostic and never exposes provider payloads.
public final class ExternalAgentReconnectFence: @unchecked Sendable {
    private struct EventKey: Hashable {
        let identity: ExternalAgentInvocationIdentity
        let eventID: String
    }

    private let lock = NSLock()
    private var activeIdentity: ExternalAgentInvocationIdentity?
    private var stopped = false
    private var seen: Set<EventKey> = []

    public init() {}

    @discardableResult
    public func reconnect(identity: ExternalAgentInvocationIdentity) -> Bool {
        guard identity.isValid else { return false }
        lock.lock()
        activeIdentity = identity
        stopped = false
        lock.unlock()
        return true
    }

    @discardableResult
    public func stop(identity: ExternalAgentInvocationIdentity) -> Bool {
        lock.lock()
        guard activeIdentity == identity else {
            lock.unlock()
            return false
        }
        stopped = true
        lock.unlock()
        return true
    }

    public func accept(_ event: ExternalAgentTerminalEventV1) -> ExternalAgentTerminalAcceptance {
        guard event.identity.isValid, !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejectedInvalid
        }
        lock.lock()
        defer { lock.unlock() }
        guard activeIdentity == event.identity else { return .rejectedStaleAttempt }
        guard !stopped else { return .rejectedStopped }
        let key = EventKey(identity: event.identity, eventID: event.eventID)
        guard seen.insert(key).inserted else { return .rejectedDuplicate }
        return .accepted
    }
}

// MARK: - Availability Check (PATH scan, no subprocess)

/// 检查 `binary` 是否可执行：含 `/` 时直接查文件系统；否则按 PATH 逐目录扫描。
internal func executableExists(_ binary: String) -> Bool {
    if binary.contains("/") {
        return FileManager.default.isExecutableFile(atPath: binary)
    }
    let path = ChildProcessEnvironment.executableSearchPath
    let fm = FileManager.default
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + binary
        if fm.isExecutableFile(atPath: candidate) { return true }
    }
    return false
}

// MARK: - External agent binary lookup

/// 外部智能体可执行文件查找。先按 `ExternalSessionCommandTemplate` 同一份候选
/// 列表（含 `$HOME/.local/bin`）找，再退回子进程 PATH；找到即返回绝对路径。
/// shell 的 `ChildProcessEnvironment.executableSearchPath` 不改。
enum ExternalAgentBinaryLocator {
    static let hermesCandidates = [
        "$HOME/.local/bin/hermes",
        "/opt/homebrew/bin/hermes",
        "/usr/local/bin/hermes"
    ]

    static func candidates(for binary: String) -> [String] {
        switch binary {
        case "claude": ExternalSessionCommandTemplate.claudeCode.binaryCandidates
        case "codex": ExternalSessionCommandTemplate.codex.binaryCandidates
        case "hermes": hermesCandidates
        default: []
        }
    }

    /// 按查找顺序列出会检查的绝对路径（`$HOME` 已展开）。
    static func searchedLocations(for binary: String, home: String = NSHomeDirectory()) -> [String] {
        if binary.contains("/") { return [binary] }
        let listed = candidates(for: binary).map { candidate in
            candidate.hasPrefix("$HOME") ? home + String(candidate.dropFirst("$HOME".count)) : candidate
        }
        let fromPath = ChildProcessEnvironment.executableSearchPath
            .split(separator: ":").map { String($0) + "/" + binary }
        var seen = Set<String>()
        return (listed + fromPath).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func resolve(
        _ binary: String,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        searchedLocations(for: binary, home: home).first(where: isExecutable)
    }
}

/// 外部进程的工作目录：授权工作区或项目根；没有、或者是 `/`、用户主目录时，
/// 改用新建的临时目录。
enum ExternalAgentWorkingDirectory {
    static func resolve(parent: String?, home: String = NSHomeDirectory()) -> URL {
        if let parent, !parent.isEmpty {
            let standardized = URL(fileURLWithPath: parent).standardizedFileURL.path
            let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
            if standardized != "/", standardized != homePath {
                return URL(fileURLWithPath: standardized, isDirectory: true)
            }
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-external-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        return temporary
    }
}

// MARK: - Shared CLI Process Runner

/// Waits for process exit without scheduling the termination callback through
/// a Swift actor. `Process.terminationHandler` can therefore publish status
/// even when the cooperative executor is saturated by unrelated work.
private final class ProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var pendingStatus: Int32?
    private var didFinish = false

    func register() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let status = pendingStatus {
                pendingStatus = nil
                lock.unlock()
                cont.resume(returning: status)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: status)
        } else {
            pendingStatus = status
            lock.unlock()
        }
    }

    /// `Process.terminationHandler` is best-effort on the early-exit path.
    /// A dedicated waiter makes completion observable even when Foundation
    /// returns from `run()` without delivering that callback. `finish` is
    /// idempotent so the callback and this fallback cannot double-resume.
    func startFallback(process: ProcessBox, name: String) {
        let thread = Thread { [self, process] in
            process.process.waitUntilExit()
            finish(process.process.terminationStatus)
        }
        thread.name = name
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// `Process` / `Pipe` 不是 Sendable，装箱后供并发任务捕获（与 `AgentContentPart`
/// 同款 `@unchecked` 约定）。
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    let hasPrivateProcessGroup: Bool

    init(_ process: Process) {
        self.process = process
        // Foundation may already launch this invocation as a group leader.
        // A post-exec setpgid can fail even for that existing private group;
        // retain its ownership so an exited leader's pipe-owning descendants
        // are still reachable by the invocation's cancellation/watchdog.
        let pid = process.processIdentifier
        self.hasPrivateProcessGroup = pid > 0
            && (getpgid(pid) == pid || setpgid(pid, pid) == 0)
    }

    func terminate(force: Bool) {
        let signal = force ? SIGKILL : SIGTERM
        let pid = process.processIdentifier
        let descendants = pid > 0 ? descendantPIDs(of: pid) : []
        if hasPrivateProcessGroup, pid > 0, kill(-pid, 0) == 0 {
            _ = kill(-pid, signal)
        } else if pid > 0, process.isRunning {
            _ = kill(pid, signal)
        } else if process.isRunning {
            process.terminate()
        }
        // A helper can fork before the parent is moved into its private
        // process group. Signal the observed descendant snapshot as well so
        // pipes cannot remain open outside that group.
        for child in descendants {
            _ = kill(child, signal)
        }
    }

    private func descendantPIDs(of root: pid_t) -> [pid_t] {
        var direct = [pid_t](repeating: 0, count: 64)
        let byteCount = Int32(direct.count * MemoryLayout<pid_t>.stride)
        let result = proc_listchildpids(root, &direct, byteCount)
        guard result > 0 else { return [] }
        let count = min(Int(result) / MemoryLayout<pid_t>.stride, direct.count)
        let children = direct.prefix(count).filter { $0 > 0 }
        return children + children.flatMap { descendantPIDs(of: $0) }
    }
}

private final class PipeBox: @unchecked Sendable {
    let pipe: Pipe
    private let lock = NSLock()
    private var readEndClosed = false

    init(_ pipe: Pipe) { self.pipe = pipe }

    func closeReadEnd() {
        lock.lock()
        guard !readEndClosed else {
            lock.unlock()
            return
        }
        readEndClosed = true
        let handle = pipe.fileHandleForReading
        lock.unlock()
        handle.closeFile()
    }
}

/// Drains a blocking FileHandle on a dedicated thread instead of occupying a
/// cooperative Swift task. Closing the read end makes the thread publish the
/// bytes accumulated before timeout/cancellation.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var result: Data?
    private var continuation: CheckedContinuation<Data, Never>?
    private var started = false
    private var finished = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func start(name: String) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let thread = Thread { [self] in
            finish(readPipeData(handle))
        }
        thread.name = name
        thread.qualityOfService = .utility
        thread.start()
    }

    func value() async -> Data {
        await withCheckedContinuation { cont in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(returning: result)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func finish(_ data: Data) {
        lock.lock()
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: data)
        } else {
            result = data
            lock.unlock()
        }
    }

    private func readPipeData(_ handle: FileHandle) -> Data {
        var data = Data()
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024),
                      !chunk.isEmpty else {
                    return data
                }
                data.append(chunk)
            } catch {
                return data
            }
        }
    }
}

/// Independent wall-clock watchdog. A dedicated condition-waiting thread is
/// not delayed by cooperative-executor saturation and is cancelled promptly
/// when the process exits normally.
private final class ProcessTimeoutController: @unchecked Sendable {
    private enum State {
        case armed
        case completed
        case timedOut
    }

    private let condition = NSCondition()
    private var state: State = .armed

    func start(
        timeoutSeconds: TimeInterval,
        process: ProcessBox,
        stdout: PipeBox,
        stderr: PipeBox,
        stdoutReader: PipeReader,
        stderrReader: PipeReader
    ) {
        let thread = Thread { [self] in
            let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
            condition.lock()
            while state == .armed {
                if !condition.wait(until: deadline) {
                    // The caller can be delayed after both dedicated readers
                    // reach EOF. Treat that physical completion as success;
                    // an exited parent with a descendant-held pipe still has
                    // an unfinished reader and therefore times out.
                    state = !process.process.isRunning
                        && stdoutReader.isFinished
                        && stderrReader.isFinished
                        ? .completed
                        : .timedOut
                    break
                }
            }
            let timedOut = state == .timedOut
            condition.unlock()
            guard timedOut else { return }

            process.terminate(force: false)
            let graceDeadline = Date().addingTimeInterval(0.25)
            while process.process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.terminate(force: true)
            stdout.closeReadEnd()
            stderr.closeReadEnd()
        }
        thread.name = "com.miniscanvas.external-agent.timeout"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func complete() {
        condition.lock()
        if state == .armed {
            state = .completed
            condition.broadcast()
        }
        condition.unlock()
    }

    var didTimeOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .timedOut
    }
}

/// Owns the process handles for one external invocation at a time. Cancellation
/// is keyed by SubAgentTask.executionID, never by the human-facing task ID.
private actor CLIProcessRegistry {
    static let shared = CLIProcessRegistry()
    private struct Registration {
        let process: ProcessBox
        let stdout: PipeBox
        let stderr: PipeBox
    }

    private var processes: [String: Registration] = [:]
    private var cancellationRequested: Set<String> = []
    // Keep enough completed IDs to discard duplicate, delayed cancellation
    // without imposing a lifetime or capacity limit on genuine pre-cancel.
    private static let recentCompletionLimit = 256
    private var recentCompletions: [String] = []
    private var recentCompletionSet: Set<String> = []

    private func forgetCompletion(_ executionID: String) {
        guard recentCompletionSet.remove(executionID) != nil else { return }
        recentCompletions.removeAll { $0 == executionID }
    }

    func register(
        _ executionID: String,
        process: ProcessBox,
        stdout: PipeBox,
        stderr: PipeBox
    ) -> Bool {
        forgetCompletion(executionID)
        if cancellationRequested.contains(executionID) {
            process.terminate(force: true)
            stdout.closeReadEnd()
            stderr.closeReadEnd()
            return false
        }
        processes[executionID] = Registration(
            process: process,
            stdout: stdout,
            stderr: stderr
        )
        return true
    }

    @discardableResult
    func remove(_ executionID: String) -> Bool {
        processes.removeValue(forKey: executionID)
        let wasCancelled = cancellationRequested.remove(executionID) != nil
        forgetCompletion(executionID)
        recentCompletions.append(executionID)
        recentCompletionSet.insert(executionID)
        if recentCompletions.count > Self.recentCompletionLimit {
            recentCompletionSet.remove(recentCompletions.removeFirst())
        }
        return wasCancelled
    }

    func removeAfterSpawnFailure(_ executionID: String) {
        remove(executionID)
    }

    func cancel(_ executionID: String) {
        guard !recentCompletionSet.contains(executionID) else { return }
        cancellationRequested.insert(executionID)
        guard let registration = processes[executionID] else { return }
        registration.process.terminate(force: true)
        registration.stdout.closeReadEnd()
        registration.stderr.closeReadEnd()
    }
}

/// 通用「跑一条外部 CLI」实现：`/usr/bin/env <binary> <args>`（或绝对路径直跑），
/// 带 cwd 注入、超时终止、stdout/stderr 分离读取（并行 drain 防管道写满死锁）。
internal enum CLIProcessRunner {
    static func run(
        binary: String,
        arguments: [String],
        workingDirectory: URL?,
        timeoutSeconds: TimeInterval,
        executionID: String? = nil,
        standardInput: Data? = nil
    ) async throws -> String {
        let cancellationID = executionID ?? "cli-\(UUID().uuidString)"
        return try await withTaskCancellationHandler(operation: {
            try await runUncancelled(
                binary: binary,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds,
                executionID: cancellationID,
                standardInput: standardInput
            )
        }, onCancel: {
            Task { await cancel(executionID: cancellationID) }
        })
    }

    private static func runUncancelled(
        binary: String,
        arguments: [String],
        workingDirectory: URL?,
        timeoutSeconds: TimeInterval,
        executionID: String,
        standardInput: Data?
    ) async throws -> String {
        guard executableExists(binary) else { throw ExternalAgentError.binaryNotFound(binary) }

        let process = Process()
        process.environment = try ChildProcessEnvironment.values()
        if let cwd = workingDirectory {
            process.currentDirectoryURL = cwd
        }
        if binary.contains("/") {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        } else {
            // 依赖 PATH 解析，避免写死绝对路径。
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [binary] + arguments
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // nil keeps the historical behaviour (inherited stdin). Non-nil data
        // is delivered through a private pipe, never argv or a shell string.
        let stdin: Pipe? = standardInput == nil ? nil : Pipe()
        if let stdin { process.standardInput = stdin }

        let stdoutBox = PipeBox(stdout)
        let stderrBox = PipeBox(stderr)
        let waiter = ProcessWaiter()
        let timeoutController = ProcessTimeoutController()

        process.terminationHandler = { p in
            waiter.finish(p.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            await CLIProcessRegistry.shared.removeAfterSpawnFailure(executionID)
            throw ExternalAgentError.spawnFailed(error.localizedDescription)
        }
        if let stdin, let standardInput {
            writeStandardInput(standardInput, to: stdin)
        }
        // Establish the private process group only after launch so the
        // process identifier is valid. Descendant helpers then share the
        // group and are terminated with the parent on timeout/cancel.
        let processBox = ProcessBox(process)
        guard await CLIProcessRegistry.shared.register(
            executionID,
            process: processBox,
            stdout: stdoutBox,
            stderr: stderrBox
        ) else {
            await CLIProcessRegistry.shared.remove(executionID)
            throw ExternalAgentError.spawnFailed("外部 CLI 在启动前已取消")
        }
        waiter.startFallback(
            process: processBox,
            name: "com.miniscanvas.external-agent.waiter"
        )

        // Blocking pipe drains use dedicated threads so they cannot starve
        // Swift's cooperative executor or the timeout watchdog.
        let stdoutReader = PipeReader(stdoutBox.pipe.fileHandleForReading)
        let stderrReader = PipeReader(stderrBox.pipe.fileHandleForReading)
        stdoutReader.start(name: "com.miniscanvas.external-agent.stdout")
        stderrReader.start(name: "com.miniscanvas.external-agent.stderr")
        timeoutController.start(
            timeoutSeconds: timeoutSeconds,
            process: processBox,
            stdout: stdoutBox,
            stderr: stderrBox,
            stdoutReader: stdoutReader,
            stderrReader: stderrReader
        )
        let status = await waiter.register()

        let outData = await stdoutReader.value()
        let errData = await stderrReader.value()
        // Keep the wall-clock deadline armed through pipe EOF. A child that
        // outlives an exited parent must not hold this invocation open.
        timeoutController.complete()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errorText = String(data: errData, encoding: .utf8) ?? ""
        let wasCancelled = await CLIProcessRegistry.shared.remove(executionID)

        if timeoutController.didTimeOut { throw ExternalAgentError.timeout(binary) }
        // A leader may exit successfully while a descendant still owns its
        // pipe. Cancellation of that live invocation cannot publish the
        // leader's earlier success after reclaiming the descendant.
        if wasCancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard status == 0 else { throw ExternalAgentError.nonZeroExit(status, errorText) }
        return output
    }

    static func cancel(executionID: String?) async {
        guard let executionID else { return }
        await CLIProcessRegistry.shared.cancel(executionID)
    }

    /// Writes on a dedicated thread (a child that never reads must not block
    /// the caller) and closes the write end so the child sees EOF. SIGPIPE is
    /// disabled on the descriptor so an early-exiting child yields EPIPE only.
    private static func writeStandardInput(_ data: Data, to pipe: Pipe) {
        // The parent's copy of the read end is no longer needed after spawn.
        try? pipe.fileHandleForReading.close()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let box = PipeBox(pipe)
        let thread = Thread {
            let pipe = box.pipe
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0 && errno == EINTR { continue }
                    break
                }
            }
            try? pipe.fileHandleForWriting.close()
        }
        thread.name = "com.miniscanvas.external-agent.stdin"
        thread.qualityOfService = .utility
        thread.start()
    }
}

// MARK: - Harness adapter

/// Transport-injected Harness runner. Production wiring supplies the Harness transport;
/// tests can inject a deterministic closure without starting an external CLI.
public struct HarnessAgentRunner: ExternalAgentRunner {
    public let modelID: String
    private let execute: @Sendable (SubAgentTask) async throws -> String
    private let cancelExecution: (@Sendable (SubAgentTask) async -> Void)?

    public init(
        modelID: String,
        execute: @escaping @Sendable (SubAgentTask) async throws -> String,
        cancel: (@Sendable (SubAgentTask) async -> Void)? = nil
    ) {
        self.modelID = modelID
        self.execute = execute
        self.cancelExecution = cancel
    }

    public var name: String { "harness:\(modelID)" }
    public var isAvailable: Bool { true }

    public func run(task: SubAgentTask) async throws -> String {
        try await execute(task)
    }

    public func cancel(task: SubAgentTask) async {
        await cancelExecution?(task)
    }
}

// MARK: - Concrete Runners

/// Codex CLI 桥：`codex exec "<instructions>"`。超时默认 300s，cwd 可注入。
public struct CodexAgentRunner: ExternalAgentRunner {
    public let name: String
    /// CLI 可执行名（含 `/` 视为路径，否则按 PATH 解析）。默认 `"codex"`。
    public var binaryPath: String
    /// 子进程工作目录（可注入）。
    public var workingDirectory: URL?
    /// 超时秒数，默认 300。
    public var timeoutSeconds: TimeInterval
    /// 参数构造器，默认 `["exec", instructions]`；可覆盖以适配 codex 子命令变化。
    public var argumentBuilder: @Sendable (SubAgentTask) -> [String]

    public init(
        name: String = "codex",
        binaryPath: String = "codex",
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 300,
        argumentBuilder: @escaping @Sendable (SubAgentTask) -> [String] = { ["exec", $0.instructions] }
    ) {
        self.name = name
        self.binaryPath = binaryPath
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.argumentBuilder = argumentBuilder
    }

    public var isAvailable: Bool { ExternalAgentBinaryLocator.resolve(binaryPath) != nil }

    public func run(task: SubAgentTask) async throws -> String {
        try await run(task: task, workingDirectory: nil)
    }

    public func run(task: SubAgentTask, workingDirectory directory: URL?) async throws -> String {
        guard let binary = ExternalAgentBinaryLocator.resolve(binaryPath) else {
            throw ExternalAgentError.binaryNotFound(binaryPath)
        }
        return try await CLIProcessRunner.run(
            binary: binary,
            arguments: argumentBuilder(task),
            workingDirectory: workingDirectory ?? directory,
            timeoutSeconds: timeoutSeconds,
            executionID: task.executionID
        )
    }

    public func cancel(task: SubAgentTask) async {
        await CLIProcessRunner.cancel(executionID: task.executionID)
    }
}

/// Hermes CLI 桥。默认参数 `["run", instructions]`（hermes 子命令形态可经
/// `argumentBuilder` 覆盖）；`hermes` 命令不存在时 `isAvailable == false`。
public struct HermesAgentRunner: ExternalAgentRunner {
    public let name: String
    public var binaryPath: String
    public var workingDirectory: URL?
    public var timeoutSeconds: TimeInterval
    public var argumentBuilder: @Sendable (SubAgentTask) -> [String]

    public init(
        name: String = "hermes",
        binaryPath: String = "hermes",
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 300,
        argumentBuilder: @escaping @Sendable (SubAgentTask) -> [String] = { ["-z", $0.instructions] }
    ) {
        self.name = name
        self.binaryPath = binaryPath
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.argumentBuilder = argumentBuilder
    }

    public var isAvailable: Bool { ExternalAgentBinaryLocator.resolve(binaryPath) != nil }

    public func run(task: SubAgentTask) async throws -> String {
        try await run(task: task, workingDirectory: nil)
    }

    public func run(task: SubAgentTask, workingDirectory directory: URL?) async throws -> String {
        guard let binary = ExternalAgentBinaryLocator.resolve(binaryPath) else {
            throw ExternalAgentError.binaryNotFound(binaryPath)
        }
        return try await CLIProcessRunner.run(
            binary: binary,
            arguments: argumentBuilder(task),
            workingDirectory: workingDirectory ?? directory,
            timeoutSeconds: timeoutSeconds,
            executionID: task.executionID
        )
    }

    public func cancel(task: SubAgentTask) async {
        await CLIProcessRunner.cancel(executionID: task.executionID)
    }
}

/// Claude Code CLI 桥：`claude -p "<instructions>"`（print 模式）。
public struct ClaudeAgentRunner: ExternalAgentRunner {
    public let name: String
    public var binaryPath: String
    public var workingDirectory: URL?
    public var timeoutSeconds: TimeInterval
    public var argumentBuilder: @Sendable (SubAgentTask) -> [String]

    public init(
        name: String = "claude",
        binaryPath: String = "claude",
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 300,
        argumentBuilder: @escaping @Sendable (SubAgentTask) -> [String] = { ["-p", $0.instructions] }
    ) {
        self.name = name
        self.binaryPath = binaryPath
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.argumentBuilder = argumentBuilder
    }

    public var isAvailable: Bool { ExternalAgentBinaryLocator.resolve(binaryPath) != nil }

    public func run(task: SubAgentTask) async throws -> String {
        try await run(task: task, workingDirectory: nil)
    }

    public func run(task: SubAgentTask, workingDirectory directory: URL?) async throws -> String {
        guard let binary = ExternalAgentBinaryLocator.resolve(binaryPath) else {
            throw ExternalAgentError.binaryNotFound(binaryPath)
        }
        return try await CLIProcessRunner.run(
            binary: binary,
            arguments: argumentBuilder(task),
            workingDirectory: workingDirectory ?? directory,
            timeoutSeconds: timeoutSeconds,
            executionID: task.executionID
        )
    }

    public func cancel(task: SubAgentTask) async {
        await CLIProcessRunner.cancel(executionID: task.executionID)
    }
}
