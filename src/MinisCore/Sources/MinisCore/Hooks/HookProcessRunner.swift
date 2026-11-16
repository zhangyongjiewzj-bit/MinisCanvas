import Darwin
import Foundation

// MARK: - Goal18 Hooks: command execution

public struct HookCommandRequest: Sendable {
    public let command: String
    /// JSON event, written to the command's stdin.
    public let stdin: Data
    /// The complete child environment. Nothing is inherited implicitly.
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let timeout: TimeInterval

    public init(command: String, stdin: Data, environment: [String: String],
                workingDirectory: URL?, timeout: TimeInterval) {
        self.command = command
        self.stdin = stdin
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

public struct HookCommandResult: Sendable, Equatable {
    /// nil when the process never ran or did not exit normally in time.
    public let exitCode: Int32?
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    public let launchError: String?
    /// The calling task was cancelled; the process group was terminated.
    public let cancelled: Bool

    public init(exitCode: Int32?, stdout: Data, stderr: Data, timedOut: Bool, launchError: String?,
                cancelled: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launchError = launchError
        self.cancelled = cancelled
    }
}

/// Set from the task-cancellation handler, read by the blocking poll loop.
final class HookCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

public protocol HookCommandRunning: Sendable {
    func run(_ request: HookCommandRequest) async -> HookCommandResult
}

/// Runs `/bin/zsh -c <command>` in a private process group with an explicit
/// environment, a hard timeout and bounded output. Single-threaded `poll(2)`
/// loop: stdin write, stdout/stderr read, exit watch and deadline in one place,
/// so there is no reader/watchdog race and no unbounded wait on a pipe that a
/// leaked descendant keeps open.
public struct HookProcessRunner: HookCommandRunning {
    public static let outputLimit = 256 * 1024
    private static let terminateGrace: TimeInterval = 0.3
    private static let drainGraceAfterExit: TimeInterval = 0.25
    private static let hardStopAfterTerminate: TimeInterval = 2.0

    public init() {}

    /// Cancelling the calling task terminates the private process group (SIGTERM,
    /// then SIGKILL after a short grace) instead of waiting for the timeout.
    public func run(_ request: HookCommandRequest) async -> HookCommandResult {
        let cancellation = HookCancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.runBlocking(request, cancellation: cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func failure(_ message: String) -> HookCommandResult {
        HookCommandResult(exitCode: nil, stdout: Data(), stderr: Data(), timedOut: false, launchError: message)
    }

    private static func closeIfOpen(_ descriptor: Int32) {
        if descriptor >= 0 { close(descriptor) }
    }

    private static func markCloseOnExec(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    private static func markNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Only the still-owned private group may be signalled; a missing group has
    /// no safe positive-PID fallback (the leader PID may have been reused).
    private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        guard pid > 0, kill(-pid, 0) == 0 else { return }
        _ = kill(-pid, signal)
    }

    private static func exitCode(fromStatus status: Int32) -> Int32 {
        let signalBits = status & 0x7f
        if signalBits == 0 { return (status >> 8) & 0xff }
        if signalBits != 0x7f { return 128 + signalBits }
        return status
    }

    private static func drain(_ descriptor: inout Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while descriptor >= 0 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let room = outputLimit - data.count
                if room > 0 { data.append(contentsOf: buffer[0..<min(Int(count), room)]) }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return }
            close(descriptor)
            descriptor = -1
        }
    }

    static func runBlocking(
        _ request: HookCommandRequest, cancellation: HookCancellationFlag = HookCancellationFlag()
    ) -> HookCommandResult {
        guard !request.command.contains("\0") else { return failure("command contains NUL") }

        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        func closeAllPipes() {
            for descriptor in stdinPipe + stdoutPipe + stderrPipe { closeIfOpen(descriptor) }
        }
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            let code = errno
            closeAllPipes()
            return failure("pipe failed (errno \(code))")
        }
        for descriptor in stdinPipe + stdoutPipe + stderrPipe { markCloseOnExec(descriptor) }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeAllPipes()
            return failure("file actions init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let actionResult = [
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
        ].first { $0 != 0 }
        guard actionResult == nil else {
            closeAllPipes()
            return failure("file actions failed")
        }

        let workingDirectory = (request.workingDirectory ?? FileManager.default.temporaryDirectory).path
        let chdirResult = workingDirectory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard chdirResult == 0 else {
            closeAllPipes()
            return failure("chdir setup failed")
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeAllPipes()
            return failure("spawn attributes failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var childSignalMask = sigset_t()
        var childSignalDefaults = sigset_t()
        guard sigemptyset(&childSignalMask) == 0, sigemptyset(&childSignalDefaults) == 0 else {
            closeAllPipes()
            return failure("signal set failed")
        }
        for signalNumber in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] {
            _ = sigaddset(&childSignalDefaults, signalNumber)
        }
        // CLOEXEC_DEFAULT: the child inherits ONLY fds 0/1/2, never an app socket or file.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let attributeResults = [
            posix_spawnattr_setsigmask(&attributes, &childSignalMask),
            posix_spawnattr_setsigdefault(&attributes, &childSignalDefaults),
            posix_spawnattr_setflags(&attributes, flags),
            posix_spawnattr_setpgroup(&attributes, 0),
        ]
        guard attributeResults.allSatisfy({ $0 == 0 }) else {
            closeAllPipes()
            return failure("spawn attributes failed")
        }

        var environmentEntries: [UnsafeMutablePointer<CChar>?] = request.environment.keys.sorted().map {
            strdup($0 + "=" + (request.environment[$0] ?? ""))
        }
        defer { for entry in environmentEntries { free(entry) } }
        guard environmentEntries.allSatisfy({ $0 != nil }) else {
            closeAllPipes()
            return failure("environment allocation failed")
        }
        environmentEntries.append(nil)

        var pid: pid_t = 0
        let spawnResult: Int32 = "/bin/zsh".withCString { executable in
            "-c".withCString { flag in
                request.command.withCString { commandCString in
                    var argv: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: executable),
                        UnsafeMutablePointer(mutating: flag),
                        UnsafeMutablePointer(mutating: commandCString),
                        nil,
                    ]
                    return argv.withUnsafeMutableBufferPointer { argvBuffer in
                        environmentEntries.withUnsafeMutableBufferPointer { environmentBuffer in
                            posix_spawn(&pid, executable, &actions, &attributes,
                                        argvBuffer.baseAddress, environmentBuffer.baseAddress)
                        }
                    }
                }
            }
        }
        guard spawnResult == 0 else {
            closeAllPipes()
            return failure("spawn failed (errno \(spawnResult))")
        }

        // Parent keeps only its own ends.
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        var stdinDescriptor = stdinPipe[1]
        var stdoutDescriptor = stdoutPipe[0]
        var stderrDescriptor = stderrPipe[0]
        markNonBlocking(stdinDescriptor)
        markNonBlocking(stdoutDescriptor)
        markNonBlocking(stderrDescriptor)
        _ = fcntl(stdinDescriptor, F_SETNOSIGPIPE, 1)

        let payload = [UInt8](request.stdin)
        var payloadOffset = 0
        if payload.isEmpty {
            close(stdinDescriptor)
            stdinDescriptor = -1
        }
        var outputData = Data()
        var errorData = Data()
        var exitStatus: Int32?
        var exitedAt: Date?
        var timedOut = false
        var cancelled = false
        var terminateSentAt: Date?
        var killSent = false
        let deadline = Date().addingTimeInterval(max(0.05, request.timeout))

        while true {
            if exitStatus == nil {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid {
                    exitStatus = status
                    exitedAt = Date()
                } else if reaped < 0 && errno != EINTR {
                    exitStatus = 0
                    exitedAt = Date()
                }
            }
            let now = Date()
            if exitStatus == nil {
                if terminateSentAt == nil && cancellation.isCancelled {
                    cancelled = true
                    signalGroup(pid, SIGTERM)
                    terminateSentAt = now
                } else if terminateSentAt == nil && now >= deadline {
                    timedOut = true
                    signalGroup(pid, SIGTERM)
                    terminateSentAt = now
                } else if let sentAt = terminateSentAt {
                    let elapsed = now.timeIntervalSince(sentAt)
                    if !killSent && elapsed >= terminateGrace {
                        signalGroup(pid, SIGKILL)
                        killSent = true
                    }
                    if elapsed >= hardStopAfterTerminate { break }
                }
            } else {
                if stdoutDescriptor < 0 && stderrDescriptor < 0 { break }
                if let exited = exitedAt, now.timeIntervalSince(exited) >= drainGraceAfterExit { break }
            }

            var pollSet: [pollfd] = []
            var pollKinds: [Int] = []
            if stdinDescriptor >= 0 {
                pollSet.append(pollfd(fd: stdinDescriptor, events: Int16(POLLOUT), revents: 0))
                pollKinds.append(0)
            }
            if stdoutDescriptor >= 0 {
                pollSet.append(pollfd(fd: stdoutDescriptor, events: Int16(POLLIN), revents: 0))
                pollKinds.append(1)
            }
            if stderrDescriptor >= 0 {
                pollSet.append(pollfd(fd: stderrDescriptor, events: Int16(POLLIN), revents: 0))
                pollKinds.append(2)
            }
            if pollSet.isEmpty {
                usleep(10_000)
                continue
            }
            let ready = poll(&pollSet, nfds_t(pollSet.count), 20)
            guard ready > 0 else { continue }
            for (index, entry) in pollSet.enumerated() where entry.revents != 0 {
                switch pollKinds[index] {
                case 0:
                    let remaining = payload.count - payloadOffset
                    let written = payload.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return write(stdinDescriptor, base.advanced(by: payloadOffset), remaining)
                    }
                    if written > 0 {
                        payloadOffset += written
                        if payloadOffset >= payload.count {
                            close(stdinDescriptor)
                            stdinDescriptor = -1
                        }
                    } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                        continue
                    } else {
                        // EPIPE or any other error: the command does not read stdin.
                        close(stdinDescriptor)
                        stdinDescriptor = -1
                    }
                case 1:
                    drain(&stdoutDescriptor, into: &outputData)
                default:
                    drain(&stderrDescriptor, into: &errorData)
                }
            }
        }

        // The leader may have exited while a descendant still holds the group (a
        // backgrounded child, or the loop gave up waiting): kill what is left of the
        // private group once more. A group id stays reserved while it has members,
        // so this cannot hit an unrelated process.
        signalGroup(pid, SIGKILL)
        if exitStatus == nil {
            // Reap the leader after the kill so it does not stay a zombie.
            for _ in 0..<20 {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) != 0 { break }
                usleep(5_000)
            }
        }
        closeIfOpen(stdinDescriptor)
        closeIfOpen(stdoutDescriptor)
        closeIfOpen(stderrDescriptor)
        return HookCommandResult(
            exitCode: exitStatus.map { exitCode(fromStatus: $0) },
            stdout: outputData,
            stderr: errorData,
            timedOut: timedOut,
            launchError: nil,
            cancelled: cancelled
        )
    }
}
