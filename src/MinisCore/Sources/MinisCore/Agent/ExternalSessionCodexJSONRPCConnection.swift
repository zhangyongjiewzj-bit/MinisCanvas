import Foundation
import Darwin

/// Values on the official Codex app-server JSON-RPC connection. This is not the
/// older MinisCore `customWireV1` envelope.
public indirect enum CodexJSONValue: Codable, Equatable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CodexJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: CodexJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: CodexJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

public enum CodexJSONRPCID: Codable, Hashable, Sendable {
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) { self = .integer(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct ExternalSessionCodexJSONRPCMessage: Sendable, Equatable {
    public let method: String
    public let requestID: CodexJSONRPCID?
    public let params: [String: CodexJSONValue]

    public init(method: String, requestID: CodexJSONRPCID?, params: [String: CodexJSONValue]) {
        self.method = method
        self.requestID = requestID
        self.params = params
    }
}

public enum ExternalSessionCodexJSONRPCError: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnected
    case invalidEndpoint
    case malformedMessage
    case unexpectedResponse
    case remote(code: Int, message: String)
    case disconnected
    case timedOut
    case cancelled
    /// Bytes may already have reached the owned server; reconcile before retry.
    case effectUnknown
    case serverRequestNotPending
    case unsupportedServerVersion(String)
}

public enum ExternalSessionCodexStdioCloseOutcome: Sendable, Equatable {
    case joined
    /// Complete retirement has not been proved; this is neither EOF nor release.
    case holdingOrIncomplete
}

/// Terminal facts are complete only after the exact Process, reader and work
/// joined. A bounded close may instead report a typed, incomplete HOLD.
public struct ExternalSessionCodexStdioTerminationReceipt: Sendable {
    public let ownerID: UUID
    public let processIdentifier: Int32?
    public let terminationStatus: Int32?
    public let processWaited: Bool
    public let readerReachedEOF: Bool
    public let parserTasksJoined: Int
    public let requestTasksJoined: Int
    public let callbackTasksJoined: Int
    public let stdoutClosed: Bool
    public let allPipeHandlesClosed: Bool
    /// Computed from existing evidence fields: no new stored receipt layout.
    /// This deliberately does not pretend all incomplete receipts timed out.
    public var closeOutcome: ExternalSessionCodexStdioCloseOutcome {
        isComplete ? .joined : .holdingOrIncomplete
    }
    public var isComplete: Bool {
        processWaited && readerReachedEOF && parserTasksJoined == 1 && stdoutClosed && allPipeHandlesClosed
    }
}

/// Keeps this exact connection alive while a caller retires it. Waiting never
/// starts a process or closes another generation; close must already begin.
public struct ExternalSessionCodexStdioTermination: Sendable {
    public let ownerID: UUID
    private let join: @Sendable () async throws -> ExternalSessionCodexStdioTerminationReceipt
    fileprivate init(ownerID: UUID, join: @escaping @Sendable () async throws -> ExternalSessionCodexStdioTerminationReceipt) {
        self.ownerID = ownerID; self.join = join
    }
    public func wait() async throws -> ExternalSessionCodexStdioTerminationReceipt { try await join() }
}

private enum CodexOwnedWorkKind: Sendable {
    case parser, timeout(CodexJSONRPCID), writer(CodexJSONRPCID), callback
    var isRequest: Bool { switch self { case .timeout, .writer: true; default: false } }
}

/// Only tracks tasks that already do this connection's protocol work. The
/// finished bit selects candidates for pruning; removal always awaits value.
private final class CodexOwnedWork: @unchecked Sendable {
    struct Entry: Sendable { let id: UUID; let kind: CodexOwnedWorkKind; let task: Task<Void, Never> }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var finished: Set<UUID> = []
    private var retired = false
    private var joined = (parser: 0, request: 0, callback: 0)
    @discardableResult
    func launch(_ kind: CodexOwnedWorkKind, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return nil }
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.markFinished(id) }
            await body()
        }
        entries[id] = Entry(id: id, kind: kind, task: task)
        return task
    }
    private func markFinished(_ id: UUID) { lock.lock(); finished.insert(id); lock.unlock() }
    func completed() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { finished.contains($0.id) }
    }
    func removeAfterActualJoin(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: id) else { return }
        finished.remove(id)
        switch entry.kind { case .parser: joined.parser += 1; case .callback: joined.callback += 1; default: joined.request += 1 }
    }
    func cancelTimeout(_ id: CodexJSONRPCID) {
        lock.lock(); let tasks = entries.values.filter { if case let .timeout(candidate) = $0.kind { return candidate == id }; return false }.map(\.task); lock.unlock()
        tasks.forEach { $0.cancel() }
    }
    func cancelRequests() {
        lock.lock(); let tasks = entries.values.filter { $0.kind.isRequest }.map(\.task); lock.unlock()
        tasks.forEach { $0.cancel() }
    }
    func retire() -> [Entry] {
        lock.lock(); retired = true; let result = Array(entries.values); lock.unlock()
        result.filter { $0.kind.isRequest }.forEach { $0.task.cancel() }
        return result
    }
    func joinedCounts() -> (parser: Int, request: Int, callback: Int) {
        lock.lock(); defer { lock.unlock() }; return joined
    }
}

/// DispatchGroup is entered for the original blocking read operation and
/// leaves from that operation's defer, never from a marker or parser state.
private final class CodexOwnedReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var eof = false
    init() { group.enter() }
    func finish(reachedEOF: Bool) { lock.lock(); eof = reachedEOF; lock.unlock(); group.leave() }
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
        return reachedEOF()
    }
    private func reachedEOF() -> Bool { lock.lock(); defer { lock.unlock() }; return eof }
}

/// The handler is installed before run(), so an exit before close() cannot
/// be lost. This only records Foundation's terminal notification; it never
/// substitutes a marker, EOF, timeout or cancellation for the actual wait.
private final class CodexOwnedProcessExitNotice: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recordTermination() {
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        terminated = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Bounds observation, not ownership. The original join task continues to
/// retain its Process, pipes and work after a timeout. Timer tasks are cancelled
/// and actually joined; neither timeout nor caller cancellation publishes EOF.
private final class CodexOwnedCloseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let ownerID: UUID
    private let pid: Int32?
    private var terminal: ExternalSessionCodexStdioTerminationReceipt?
    private var waiters: [UUID: CheckedContinuation<ExternalSessionCodexStdioTerminationReceipt?, Never>] = [:]
    private var expired: Set<UUID> = []
    private var waited = false
    private var status: Int32?
    private var eof = false
    private var counts = (parser: 0, request: 0, callback: 0)
    init(ownerID: UUID, pid: Int32?) { self.ownerID = ownerID; self.pid = pid }
    func didWait(status: Int32) { lock.lock(); waited = true; self.status = status; lock.unlock() }
    func didReadEOF(_ eof: Bool) { lock.lock(); self.eof = eof; lock.unlock() }
    func didJoin(_ counts: (parser: Int, request: Int, callback: Int)) {
        lock.lock(); self.counts = counts; lock.unlock()
    }
    func publish(_ receipt: ExternalSessionCodexStdioTerminationReceipt) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = receipt
        let pending = Array(waiters.values)
        waiters.removeAll(); expired.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(returning: receipt) }
    }
    private func expire(_ id: UUID) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        let waiter = waiters.removeValue(forKey: id)
        if waiter == nil { expired.insert(id) }
        lock.unlock()
        waiter?.resume(returning: nil)
    }
    func observe(nanoseconds: UInt64) async -> ExternalSessionCodexStdioTerminationReceipt? {
        let id = UUID()
        let timer = Task.detached { [self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            expire(id)
        }
        let result: ExternalSessionCodexStdioTerminationReceipt? = await withCheckedContinuation { continuation in
            lock.lock()
            if let terminal {
                lock.unlock(); continuation.resume(returning: terminal)
            } else if expired.remove(id) != nil {
                lock.unlock(); continuation.resume(returning: nil)
            } else {
                waiters[id] = continuation; lock.unlock()
            }
        }
        timer.cancel()
        await timer.value
        clearExpired(id)
        return result
    }
    private func clearExpired(_ id: UUID) { lock.lock(); expired.remove(id); lock.unlock() }
    func holdingReceipt() -> ExternalSessionCodexStdioTerminationReceipt {
        lock.lock(); defer { lock.unlock() }
        if let terminal { return terminal }
        return ExternalSessionCodexStdioTerminationReceipt(
            ownerID: ownerID, processIdentifier: pid, terminationStatus: status,
            processWaited: waited, readerReachedEOF: eof, parserTasksJoined: counts.parser,
            requestTasksJoined: counts.request, callbackTasksJoined: counts.callback,
            stdoutClosed: false, allPipeHandlesClosed: false)
    }
}

/// One connection is one official app-server JSON-RPC stream. No implicit
/// default CODEX_HOME, socket or running desktop process is selected here.
public protocol ExternalSessionCodexJSONRPCConnection: AnyObject, Sendable {
    func request(method: String, params: [String: CodexJSONValue]) async throws -> [String: CodexJSONValue]
    func notifications() async -> AsyncStream<ExternalSessionCodexJSONRPCMessage>
    func respond(to requestID: CodexJSONRPCID, result: CodexJSONValue) async throws
}

private struct CodexJSONRPCEnvelope: Codable {
    let id: CodexJSONRPCID?
    let method: String?
    let params: CodexJSONValue?
    let result: CodexJSONValue?
    let error: CodexJSONRPCRemoteError?

    init(id: CodexJSONRPCID? = nil, method: String? = nil, params: CodexJSONValue? = nil,
         result: CodexJSONValue? = nil, error: CodexJSONRPCRemoteError? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

private struct CodexJSONRPCRemoteError: Codable {
    let code: Int
    let message: String
}

private final class CodexJSONRPCCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Owns a single explicitly configured app-server stdio process. `connect()`
/// runs initialize and waits for its response before sending initialized; the
/// public request path stays closed until both have completed.
public actor ExternalSessionCodexStdioConnection: ExternalSessionCodexJSONRPCConnection {
    public static let supportedServerVersion = "0.151.0"
    private static let maximumFrameBytes = 8 * 1024 * 1024
    private enum State { case idle, initializing, ready, closed }

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL
    private let timeoutNanoseconds: UInt64
    private let closeTimeoutNanoseconds: UInt64
    private let experimentalDynamicTools: Bool
    private var state: State = .idle
    private let lifetimeOwnerID = UUID()
    private let ownedWork = CodexOwnedWork()
    private let ownedProcessExit = CodexOwnedProcessExitNotice()
    private var ownedReader: CodexOwnedReader?
    private var closeJoinTask: Task<ExternalSessionCodexStdioTerminationReceipt, Never>?
    private var closeObservation: CodexOwnedCloseObservation?
    private var process: Process?
    private var userAgent: String?
    private var input: Pipe?
    private var output: Pipe?
    private var nextID = 1
    private var pending: [CodexJSONRPCID: CheckedContinuation<[String: CodexJSONValue], Error>] = [:]
    private var writtenRequestIDs: Set<CodexJSONRPCID> = []
    private var writerBusy = false
    private var writerWaiters: [CheckedContinuation<Void, Never>] = []
    private var serverRequests: Set<CodexJSONRPCID> = []
    private var subscribers: [UUID: AsyncStream<ExternalSessionCodexJSONRPCMessage>.Continuation] = [:]
    private var queuedMessages: [ExternalSessionCodexJSONRPCMessage] = []

    public init(executableURL: URL, arguments: [String] = ["app-server", "--stdio"],
                environment: [String: String], workingDirectory: URL,
                timeoutNanoseconds: UInt64 = 10_000_000_000,
                experimentalDynamicTools: Bool = false,
                closeTimeoutNanoseconds: UInt64 = 3_000_000_000) throws {
        guard executableURL.isFileURL, workingDirectory.isFileURL,
              executableURL.path.hasPrefix("/"), workingDirectory.path.hasPrefix("/"),
              timeoutNanoseconds > 0, closeTimeoutNanoseconds > 0,
              closeTimeoutNanoseconds <= 10_000_000_000 else { throw ExternalSessionCodexJSONRPCError.invalidEndpoint }
        self.executableURL = executableURL
        self.arguments = arguments
        var childEnvironment = try ChildProcessEnvironment.values()
        // This transport accepts its existing explicit home and Python flags,
        // never a general replacement environment or provider credentials.
        if let home = environment["CODEX_HOME"], home.hasPrefix("/"), !home.utf8.contains(0) {
            childEnvironment["CODEX_HOME"] = home
        }
        for name in ["PYTHONUNBUFFERED", "PYTHONDONTWRITEBYTECODE"] {
            if let value = environment[name], value == "0" || value == "1" {
                childEnvironment[name] = value
            }
        }
        self.environment = childEnvironment
        self.workingDirectory = workingDirectory
        self.timeoutNanoseconds = timeoutNanoseconds
        self.closeTimeoutNanoseconds = closeTimeoutNanoseconds
        self.experimentalDynamicTools = experimentalDynamicTools
    }

    public func connect() async throws {
        guard state == .idle else { throw ExternalSessionCodexJSONRPCError.alreadyConnected }
        state = .initializing
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let input = Pipe()
        let output = Pipe()
        let fd = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            finishDisconnected()
            throw ExternalSessionCodexJSONRPCError.invalidEndpoint
        }
        process.standardInput = input
        process.standardOutput = output
        // An unread stderr pipe can fill and suspend app-server indefinitely.
        // This transport keeps no external-session diagnostics or content.
        process.standardError = FileHandle.nullDevice
        // Use Foundation's asynchronous exit delivery rather than asking an
        // arbitrary close worker to drive the first termination RunLoop wait.
        let exitNotice = ownedProcessExit
        process.terminationHandler = { _ in exitNotice.recordTermination() }
        do { try process.run() }
        catch { finishDisconnected(); throw error }
        self.process = process
        self.input = input
        self.output = output
        // The parent's unused pipe ends must not keep EOF alive after the child exits.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let handle = output.fileHandleForReading
        let reader = CodexOwnedReader()
        ownedReader = reader
        let work = ownedWork
        let chunks = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(32)) { continuation in
            // FileHandle.availableData is blocking. Keep it off Swift's
            // cooperative executor so multiple owned connections cannot
            // starve actor cancellation and timeout tasks.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var reachedEOF = false
                defer { reader.finish(reachedEOF: reachedEOF) }
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { reachedEOF = true; continuation.finish(); return }
                    switch continuation.yield(chunk) {
                    case .enqueued: break
                    case .dropped, .terminated:
                        continuation.finish()
                        work.launch(.callback) { [weak self] in await self?.finishDisconnected() }
                        return
                    @unknown default:
                        continuation.finish()
                        work.launch(.callback) { [weak self] in await self?.finishDisconnected() }
                        return
                    }
                }
            }
        }
        ownedWork.launch(.parser) { [weak self] in
            var buffer = Data()
            for await chunk in chunks {
                guard buffer.count + chunk.count <= Self.maximumFrameBytes else {
                    await self?.finishDisconnected(); return
                }
                buffer.append(chunk)
                // A partial frame may be large. Scanning the entire growing
                // buffer on every chunk is quadratic when no newline arrives.
                if chunk.contains(10) {
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        await self?.handle(line: line)
                    }
                }
            }
            await self?.finishDisconnected()
        }
        do {
            var initializeParams: [String: CodexJSONValue] = [
                "clientInfo": .object([
                    "name": .string("miniscanvas"),
                    "title": .string("MinisCanvas"),
                    "version": .string("1.0.0")
                ])
            ]
            // Dynamic tools are experimental in the pinned 0.151 protocol.
            // Existing read/control connections never opt in implicitly.
            if experimentalDynamicTools {
                initializeParams["capabilities"] = .object(["experimentalApi": .bool(true)])
            }
            let initializeResult = try await sendRPC(method: "initialize", params: initializeParams)
            guard let agent = initializeResult["userAgent"]?.stringValue, !agent.isEmpty else {
                throw ExternalSessionCodexJSONRPCError.malformedMessage
            }
            // The method schemas shipped with this adapter were generated by
            // CLI 0.151.0. A different version needs an explicit compatibility
            // review; the initialize userAgent is the only version signal on
            // this stable connection.
            guard agent.split(separator: " ", maxSplits: 1).first == "miniscanvas/\(Self.supportedServerVersion)" else {
                throw ExternalSessionCodexJSONRPCError.unsupportedServerVersion(agent)
            }
            userAgent = agent
            try await write(CodexJSONRPCEnvelope(method: "initialized", params: .object([:])))
            guard state == .initializing else { throw ExternalSessionCodexJSONRPCError.disconnected }
            state = .ready
        } catch {
            finishDisconnected()
            throw error
        }
    }

    public func request(method: String, params: [String: CodexJSONValue]) async throws -> [String: CodexJSONValue] {
        try Task.checkCancellation()
        guard state == .ready else { throw ExternalSessionCodexJSONRPCError.notConnected }
        return try await sendRPC(method: method, params: params)
    }

    /// Retires this connection's owned child process and event stream. Never
    /// acts on a pre-existing Codex Desktop process or thread.
    @discardableResult
    public func close() async -> ExternalSessionCodexStdioTerminationReceipt {
        if let closeObservation {
            return await closeObservation.observe(nanoseconds: closeTimeoutNanoseconds)
                ?? closeObservation.holdingReceipt()
        }
        finishDisconnected()
        let tasks = ownedWork.retire()
        let work = ownedWork
        let process = self.process
        let exitNotice = ownedProcessExit
        let reader = ownedReader
        let output = self.output
        let input = self.input
        let ownerID = lifetimeOwnerID
        let observation = CodexOwnedCloseObservation(ownerID: ownerID, pid: process?.processIdentifier)
        closeObservation = observation
        // This task performs the actual join, retaining the original objects;
        // it is deliberately not a child of the protocol-work set it joins.
        let join = Task.detached(priority: .utility) {
            var waited = false
            var status: Int32?
            if let process {
                // No timeout can mark this complete. Keep this exact Process
                // alive until its registered terminal notification arrives,
                // then still perform the original real Foundation wait.
                await exitNotice.wait()
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }
                waited = true
                status = process.terminationStatus
                observation.didWait(status: process.terminationStatus)
            }
            let eof = await reader?.wait() ?? false
            observation.didReadEOF(eof)
            for entry in tasks {
                await entry.task.value
                work.removeAfterActualJoin(entry.id)
                observation.didJoin(work.joinedCounts())
            }
            var stdoutClosed = false
            if let output {
                do { try output.fileHandleForReading.close(); stdoutClosed = true }
                catch { stdoutClosed = false }
            }
            var allPipeHandlesClosed = stdoutClosed
            // No writer/reader can still touch these exact Foundation handles.
            for handle in [input?.fileHandleForReading, input?.fileHandleForWriting,
                           output?.fileHandleForWriting].compactMap({ $0 }) {
                do { try handle.close() } catch { allPipeHandlesClosed = false }
            }
            let joined = work.joinedCounts()
            let receipt = ExternalSessionCodexStdioTerminationReceipt(
                ownerID: ownerID, processIdentifier: process?.processIdentifier,
                terminationStatus: status, processWaited: waited, readerReachedEOF: eof,
                parserTasksJoined: joined.parser, requestTasksJoined: joined.request,
                callbackTasksJoined: joined.callback, stdoutClosed: stdoutClosed,
                allPipeHandlesClosed: allPipeHandlesClosed
            )
            observation.publish(receipt)
            return receipt
        }
        closeJoinTask = join
        return await observation.observe(nanoseconds: closeTimeoutNanoseconds)
            ?? observation.holdingReceipt()
    }

    public func terminationCompletion() -> ExternalSessionCodexStdioTermination {
        ExternalSessionCodexStdioTermination(ownerID: lifetimeOwnerID) { [self] in
            guard await self.isClosed() else { throw ExternalSessionCodexJSONRPCError.alreadyConnected }
            return await self.waitForActualClose()
        }
    }

    /// Explicit custody wait: unlike bounded close(), this never turns a
    /// pending join into a receipt. A caller in HOLD can await the true end.
    private func waitForActualClose() async -> ExternalSessionCodexStdioTerminationReceipt {
        if closeJoinTask == nil { _ = await close() }
        return await closeJoinTask!.value
    }

    private func isClosed() -> Bool { state == .closed }

    private func joinCompletedWork() async {
        for entry in ownedWork.completed() {
            await entry.task.value
            ownedWork.removeAfterActualJoin(entry.id)
        }
    }

    public func isReady() -> Bool { state == .ready }

    public func handshakeUserAgent() -> String? { state == .ready ? userAgent : nil }

    public func notifications() -> AsyncStream<ExternalSessionCodexJSONRPCMessage> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            subscribers[id] = continuation
            for message in queuedMessages { continuation.yield(message) }
            queuedMessages.removeAll()
            continuation.onTermination = { [weak self] _ in
                self?.ownedWork.launch(.callback) { [weak self] in await self?.removeSubscriber(id) }
            }
            if state == .closed { continuation.finish() }
        }
    }

    public func respond(to requestID: CodexJSONRPCID, result: CodexJSONValue) async throws {
        try Task.checkCancellation()
        guard state == .ready, serverRequests.contains(requestID) else {
            throw ExternalSessionCodexJSONRPCError.serverRequestNotPending
        }
        try await write(CodexJSONRPCEnvelope(id: requestID, result: result))
        serverRequests.remove(requestID)
    }

    private func sendRPC(method: String, params: [String: CodexJSONValue]) async throws -> [String: CodexJSONValue] {
        try Task.checkCancellation()
        await joinCompletedWork()
        guard state != .closed else { throw ExternalSessionCodexJSONRPCError.disconnected }
        let id = CodexJSONRPCID.integer(nextID)
        let cancellation = CodexJSONRPCCancellationFlag()
        nextID += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                ownedWork.launch(.timeout(id)) { [weak self, timeoutNanoseconds] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    await self?.expire(id)
                }
                let envelope = CodexJSONRPCEnvelope(id: id, method: method, params: .object(params))
                ownedWork.launch(.writer(id)) { [weak self] in
                    guard let self else { return }
                    do { try await self.write(envelope, pendingID: id, cancellation: cancellation) }
                    catch { await self.failPending(id, error: error) }
                }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            self?.ownedWork.launch(.callback) { [weak self] in await self?.cancel(id) }
        }
    }

    private func acquireWriter() async {
        if !writerBusy { writerBusy = true; return }
        await withCheckedContinuation { writerWaiters.append($0) }
    }

    private func releaseWriter() {
        if writerWaiters.isEmpty { writerBusy = false }
        else { writerWaiters.removeFirst().resume() }
    }

    /// Nonblocking writes keep the actor available to expire/cancel requests.
    /// A partial frame is never retried on another connection: closing this
    /// owned process leaves the external effect explicitly unknown.
    private func write(_ envelope: CodexJSONRPCEnvelope, pendingID: CodexJSONRPCID? = nil,
                       cancellation: CodexJSONRPCCancellationFlag? = nil) async throws {
        try Task.checkCancellation()
        var bytes = try JSONEncoder().encode(envelope)
        bytes.append(10)
        guard bytes.count <= Self.maximumFrameBytes else {
            throw ExternalSessionCodexJSONRPCError.malformedMessage
        }
        await acquireWriter()
        defer { releaseWriter() }
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(clamping: timeoutNanoseconds))
        var offset = 0
        while offset < bytes.count {
            guard state != .closed, let input else { throw ExternalSessionCodexJSONRPCError.disconnected }
            if let pendingID, pending[pendingID] == nil {
                throw writtenRequestIDs.contains(pendingID)
                    ? ExternalSessionCodexJSONRPCError.effectUnknown
                    : ExternalSessionCodexJSONRPCError.cancelled
            }
            if Task.isCancelled || cancellation?.isCancelled == true {
                if offset > 0 { finishDisconnected(); throw ExternalSessionCodexJSONRPCError.effectUnknown }
                throw ExternalSessionCodexJSONRPCError.cancelled
            }
            if clock.now >= deadline {
                if offset > 0 { finishDisconnected() }
                throw offset > 0 ? ExternalSessionCodexJSONRPCError.effectUnknown
                    : ExternalSessionCodexJSONRPCError.timedOut
            }
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(input.fileHandleForWriting.fileDescriptor,
                             buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                if let pendingID { writtenRequestIDs.insert(pendingID) }
                continue
            }
            if written < 0 && (errno == EAGAIN || errno == EINTR) {
                try await Task.sleep(nanoseconds: 1_000_000)
                continue
            }
            finishDisconnected()
            throw ExternalSessionCodexJSONRPCError.disconnected
        }
    }

    private func handle(line: Data) {
        guard state != .closed else { return }
        guard let envelope = try? JSONDecoder().decode(CodexJSONRPCEnvelope.self, from: line) else {
            finishDisconnected(); return
        }
        if let method = envelope.method {
            guard let params = envelope.params?.objectValue else { finishDisconnected(); return }
            if let id = envelope.id { serverRequests.insert(id) }
            let message = ExternalSessionCodexJSONRPCMessage(method: method, requestID: envelope.id, params: params)
            if subscribers.isEmpty {
                // This queue is only a short handoff for a listener attaching
                // during initialization. Overflow closes the connection rather
                // than silently dropping an approval request or status event.
                guard queuedMessages.count < 128 else { finishDisconnected(); return }
                queuedMessages.append(message)
            }
            for continuation in subscribers.values {
                switch continuation.yield(message) {
                case .enqueued: break
                case .dropped:
                    // Never silently discard a streamed delta or approval.
                    finishDisconnected()
                    return
                case .terminated: break
                @unknown default:
                    finishDisconnected()
                    return
                }
            }
            return
        }
        guard let id = envelope.id, let continuation = pending.removeValue(forKey: id) else { return }
        writtenRequestIDs.remove(id)
        ownedWork.cancelTimeout(id)
        if let error = envelope.error {
            continuation.resume(throwing: ExternalSessionCodexJSONRPCError.remote(code: error.code, message: error.message))
        } else if let result = envelope.result?.objectValue {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: ExternalSessionCodexJSONRPCError.unexpectedResponse)
        }
    }

    private func expire(_ id: CodexJSONRPCID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        ownedWork.cancelTimeout(id)
        let mayHaveReachedServer = writtenRequestIDs.remove(id) != nil
        continuation.resume(throwing: mayHaveReachedServer
            ? ExternalSessionCodexJSONRPCError.effectUnknown
            : ExternalSessionCodexJSONRPCError.timedOut)
        if mayHaveReachedServer { finishDisconnected() }
    }

    private func cancel(_ id: CodexJSONRPCID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        ownedWork.cancelTimeout(id)
        let mayHaveReachedServer = writtenRequestIDs.remove(id) != nil
        continuation.resume(throwing: mayHaveReachedServer
            ? ExternalSessionCodexJSONRPCError.effectUnknown
            : ExternalSessionCodexJSONRPCError.cancelled)
        if mayHaveReachedServer { finishDisconnected() }
    }

    private func failPending(_ id: CodexJSONRPCID, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        ownedWork.cancelTimeout(id)
        let mayHaveReachedServer = writtenRequestIDs.remove(id) != nil
        continuation.resume(throwing: mayHaveReachedServer
            ? ExternalSessionCodexJSONRPCError.effectUnknown : error)
        if mayHaveReachedServer { finishDisconnected() }
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    private func finishDisconnected() {
        guard state != .closed else { return }
        state = .closed
        userAgent = nil
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        ownedWork.cancelRequests()
        // Release cancelled writers parked behind a suspended nonblocking write.
        let waiters = writerWaiters
        writerWaiters.removeAll()
        writerBusy = false
        for waiter in waiters { waiter.resume() }
        for (id, continuation) in pending {
            continuation.resume(throwing: writtenRequestIDs.contains(id)
                ? ExternalSessionCodexJSONRPCError.effectUnknown
                : ExternalSessionCodexJSONRPCError.disconnected)
        }
        pending.removeAll()
        writtenRequestIDs.removeAll()
        serverRequests.removeAll()
        queuedMessages.removeAll()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}
