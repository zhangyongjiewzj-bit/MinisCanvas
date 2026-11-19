import Foundation
import Darwin

/// Only the model shell and visible terminal use this snapshot. MCP, hooks and
/// external bridges keep ChildProcessEnvironment's existing allowlist.
public enum ModelShellEnvironment {
    public static let failureNotification = Notification.Name("MinisCanvasModelShellEnvironmentFailed")
    public static let failureMessage = "登录 Shell 环境读取失败或超过5秒，命令暂用原有隔离环境；用户安装的工具与 SSH/Git 凭据可能不可用。请检查 Shell 启动配置后重新启动应用。"
    private static let state = ModelShellEnvironmentState()

    public static func startSnapshot() { state.start() }
    public static func configure(stripCredentials: Bool, noninteractive: Bool) {
        state.configure(stripCredentials: stripCredentials, noninteractive: noninteractive)
    }
    public static func takePendingFailureNotice() -> Bool { state.takePendingFailure() }

    public static func values() throws -> [String: String] {
        let snapshot = state.snapshot()
        let base = try snapshot ?? ChildProcessEnvironment.values()
        let directories = try ChildProcessEnvironment.profileRoot().map {
            try ChildProcessEnvironment.isolatedDirectories(root: $0)
        }
        let options = state.options()
        return values(snapshot: base, stripCredentials: options.strip,
                      noninteractive: options.noninteractive, directories: directories)
    }

    static func values(snapshot: [String: String], stripCredentials: Bool, noninteractive: Bool,
                       directories: (home: String, temporary: String)? = nil) -> [String: String] {
        var result = snapshot
        // The snapshot is taken after login startup; do not run .zshenv again
        // for each command (especially after opting to strip credentials).
        result["ZDOTDIR"] = "/var/empty"
        if let directories {
            result["HOME"] = directories.home
            result["TMPDIR"] = directories.temporary
        }
        if stripCredentials {
            result = result.filter { !SubprocessEnvironmentNotice.credentialLike($0.key) }
        }
        if noninteractive {
            result.merge(["GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "true",
                          "GIT_PAGER": "cat", "PAGER": "cat"]) { _, new in new }
        }
        return result
    }

    /// 导入 Key 页专用的登录 shell 快照读取：只返回 `names` 里列出的变量，不经 `values()`，
    /// 所以不受"去掉凭据变量"设置影响、不改写 HOME/ZDOTDIR；也不会抛错。
    /// 快照可能还在后台捕获（最长约 5 秒），等待发生在后台队列，调用方 `await` 即可，不会阻塞主线程。
    /// 快照失败或超时返回空字典。结果只在内存里给导入页显示掩码用，不写日志、不落盘。
    public static func loginShellValues(named names: Set<String>) async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: filteredValues(snapshot: state.snapshot(), names: names))
            }
        }
    }

    static func filteredValues(snapshot: [String: String]?, names: Set<String>) -> [String: String] {
        guard let snapshot else { return [:] }
        return snapshot.filter { names.contains($0.key) }
    }

    /// Used only to redact command output in memory; never persist these values.
    public static func knownCredentialValues() -> [String] {
        state.cachedSnapshot().map { knownCredentialValues(snapshot: $0) } ?? []
    }

    static func knownCredentialValues(snapshot: [String: String]) -> [String] {
        // Name-guessed shell credentials shorter than the established floor are mostly
        // switches ("1"/"true"); literal replacement would corrupt paths and numbers.
        // Explicitly provided credentials (broker/envStore) are unaffected.
        snapshot.compactMap { name, value in
            SubprocessEnvironmentNotice.credentialLike(name) && value.count >= EnvVarRedactor.minMatchLen ? value : nil
        }
    }

    public static func withCStringVector(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) -> Int32 {
        let environment: [String: String]
        do { environment = try values() }
        catch { return EINVAL }
        var entries = environment.keys.sorted().map { strdup($0 + "=" + (environment[$0] ?? "")) }
        defer { for entry in entries { free(entry) } }
        guard entries.allSatisfy({ $0 != nil }) else { return ENOMEM }
        entries.append(nil)
        return entries.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return ENOMEM }
            return body(base)
        }
    }

    static func decodeSnapshot(_ data: Data) -> [String: String]? {
        let marker = Data("\0MINISCANVAS_LOGIN_ENV\0".utf8)
        guard let range = data.range(of: marker) else { return nil }
        var values: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            guard let equal = entry.firstIndex(of: 61), equal != entry.startIndex else { continue }
            let name = String(decoding: entry[..<equal], as: UTF8.self)
            let value = String(decoding: entry[entry.index(after: equal)...], as: UTF8.self)
            values[name] = value
        }
        guard values["PATH"] != nil else { return nil }
        return values
    }

    /// The five-second deadline covers shell startup, output drain and exit.
    /// A private session lets timeout reap the startup shell and its children.
    fileprivate static func capture() throws -> [String: String] {
        var parent = ProcessInfo.processInfo.environment
        // Never source the actual user's shell startup files in formal/field runs.
        if let root = try ChildProcessEnvironment.profileRoot() {
            let directories = try ChildProcessEnvironment.isolatedDirectories(root: root)
            parent["HOME"] = directories.home
            parent["TMPDIR"] = directories.temporary
            parent["ZDOTDIR"] = directories.home
        }
        let shell = parent["SHELL"] ?? "/bin/zsh"
        let output = Pipe()
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = output.fileHandleForWriting.fileDescriptor
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else { throw CaptureError.io }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CaptureError.io }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let setup = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addclose(&actions, readFD),
            posix_spawn_file_actions_addclose(&actions, writeFD)
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { throw CaptureError.io }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw CaptureError.io }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else { throw CaptureError.io }
        var arguments: [UnsafeMutablePointer<CChar>?] = [shell, "-ilc", "printf '\\0MINISCANVAS_LOGIN_ENV\\0'; exec /usr/bin/env -0"].map { argument in
            argument.withCString { strdup($0) }
        }
        var environment: [UnsafeMutablePointer<CChar>?] = parent.map { entry in
            (entry.key + "=" + entry.value).withCString { strdup($0) }
        }
        defer {
            for entry in arguments { free(entry) }
            for entry in environment { free(entry) }
        }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw CaptureError.io }
        arguments.append(nil)
        environment.append(nil)
        var pid: pid_t = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let status = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                shell.withCString { executable in
                    posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress, envp.baseAddress)
                }
            }
        }
        guard status == 0 else { throw CaptureError.launch }
        var reaped = false
        defer {
            if !reaped {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        try output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var eof = false
        var exitStatus: Int32 = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw CaptureError.io }
            if !reaped {
                let waited = waitpid(pid, &exitStatus, WNOHANG)
                if waited == pid { reaped = true }
                else if waited == -1 && errno != EINTR { throw CaptureError.io }
            }
            if reaped && eof {
                guard exitStatus == 0, let snapshot = decodeSnapshot(data) else { throw CaptureError.invalid }
                return snapshot
            }
            var descriptor = pollfd(fd: eof ? -1 : readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
        // The direct child may have exited while descendants retain stdout.
        // Kill the owned group on that timeout too, without signalling a reaped PID.
        if reaped { kill(-pid, SIGKILL) }
        throw CaptureError.timeout
    }

    private enum CaptureError: Error { case io, launch, invalid, timeout }
}

private final class ModelShellEnvironmentState: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var finished = false
    private var value: [String: String]?
    private var pendingFailure = false
    private var stripCredentials = false
    private var noninteractive = true

    func start() {
        condition.lock()
        guard !started else { condition.unlock(); return }
        started = true
        condition.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot: [String: String]?
            do { snapshot = try ModelShellEnvironment.capture() }
            catch { snapshot = nil }
            self.condition.lock()
            self.value = snapshot
            self.pendingFailure = snapshot == nil
            self.finished = true
            self.condition.broadcast()
            self.condition.unlock()
            if snapshot == nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: ModelShellEnvironment.failureNotification, object: nil)
                }
            }
        }
    }

    func snapshot() -> [String: String]? {
        start()
        condition.lock()
        defer { condition.unlock() }
        while !finished { condition.wait() }
        return value
    }
    func cachedSnapshot() -> [String: String]? {
        condition.lock()
        defer { condition.unlock() }
        return value
    }
    func configure(stripCredentials: Bool, noninteractive: Bool) {
        condition.lock()
        defer { condition.unlock() }
        self.stripCredentials = stripCredentials
        self.noninteractive = noninteractive
    }
    func options() -> (strip: Bool, noninteractive: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (stripCredentials, noninteractive)
    }
    func takePendingFailure() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let result = pendingFailure
        pendingFailure = false
        return result
    }
}
