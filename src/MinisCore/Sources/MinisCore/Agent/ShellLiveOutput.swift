import Foundation

/// 前台命令的实时输出：只给界面的进度通道。
/// - 不进入工具结果，也不会起新一轮；命令结束后模型拿到的仍是原来的完整结果；
/// - 限速（约每 0.25 秒一批）、限量（合计 16000 字符）、先脱敏再交给界面；
/// - 只按完整行输出（\r 也算换行，进度条会按行显示）；没有换行的半行等命令结束后的结果再看。
public enum ShellLiveOutput {
    /// 收到一批已脱敏的新输出文本。可能在任意线程回调。
    public typealias Sink = @Sendable (_ text: String) -> Void
    @TaskLocal public static var sink: Sink?
    public static let maxTotalCharacters = 16_000
    static let minimumFlushInterval: TimeInterval = 0.25
    static let maximumPartialLineBytes = 8 * 1024
}

final class ShellLiveOutputRelay: @unchecked Sendable {
    private let sink: ShellLiveOutput.Sink
    private let knownSecrets: [String]
    private let lock = NSLock()
    private var partial: [Bool: Data] = [false: Data(), true: Data()]
    private var ready = ""
    private var emitted = 0
    private var lastFlush = Date.distantPast
    private var scheduled = false
    private var stopped = false

    init(sink: @escaping ShellLiveOutput.Sink, knownSecrets: [String]) {
        self.sink = sink
        self.knownSecrets = knownSecrets
    }

    /// 命令结束（或被取消）后不再输出；命令的完整结果由工具结果给出。
    func finish() {
        lock.withLock { stopped = true; ready = "" }
    }

    func feed(_ data: Data, isStderr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        var buffer = partial[isStderr] ?? Data()
        buffer.append(data)
        if let lastBreak = buffer.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let complete = buffer[buffer.startIndex...lastBreak]
            buffer = Data(buffer[(lastBreak + 1)...])
            appendLocked(Data(complete))
        } else if buffer.count > ShellLiveOutput.maximumPartialLineBytes {
            appendLocked(buffer + Data([0x0A]))
            buffer = Data()
        }
        partial[isStderr] = buffer
        scheduleFlushLocked()
    }

    private func appendLocked(_ bytes: Data) {
        guard emitted < ShellLiveOutput.maxTotalCharacters else { return }
        var text = String(decoding: bytes, as: UTF8.self)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        ready += text
    }

    private func scheduleFlushLocked() {
        guard !scheduled, !ready.isEmpty else { return }
        scheduled = true
        let wait = max(0, ShellLiveOutput.minimumFlushInterval - Date().timeIntervalSince(lastFlush))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        let batch: String? = lock.withLock {
            scheduled = false
            guard !stopped, !ready.isEmpty, emitted < ShellLiveOutput.maxTotalCharacters else { return nil }
            lastFlush = Date()
            let text = ready
            ready = ""
            return text
        }
        guard let batch else { return }
        var safe = ContentSecretRedactor.redact(batch, knownSecrets: knownSecrets)
        let remaining = ShellLiveOutput.maxTotalCharacters - lock.withLock { emitted }
        if safe.count > remaining {
            safe = String(safe.prefix(max(0, remaining))) + "\n…（实时输出已达上限，其余内容在命令结束后的结果里）\n"
            lock.withLock { emitted = ShellLiveOutput.maxTotalCharacters; ready = "" }
        } else {
            lock.withLock { emitted += safe.count }
        }
        sink(safe)
        lock.withLock { scheduleFlushLocked() }
    }
}
