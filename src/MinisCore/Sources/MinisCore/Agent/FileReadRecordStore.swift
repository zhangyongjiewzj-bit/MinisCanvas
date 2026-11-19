import Foundation
import Darwin
import CryptoKit

/// 会话内的“读取记录”：file_read 读过哪些文件、读时的版本（大小、修改时间、内容摘要）。
/// 对齐 Claude Code 的“先读再改”：
/// - 读过之后文件被外部改动 -> 拒绝写入/编辑，提示重新读取；
/// - 从未读过的文件：编辑放行；整体覆盖已有非空文件则要求先读；
/// - 用户随消息附上的文件、@ 引用的文件由 App 登记为“已读”。
/// 只在内存里保存，不落盘；键是会话 ID + 规范化后的物理路径。
public final class FileReadRecordStore: @unchecked Sendable {
    public static let shared = FileReadRecordStore()

    public enum Status: Equatable, Sendable {
        case neverRead
        case current
        case modifiedSinceRead
    }

    private struct Record {
        var size: Int64
        var mtimeNanos: Int64
        var sha256: String?
    }

    /// 为核对内容摘要而整文件读取的大小上限；更大的文件只比较大小和修改时间。
    static let digestLimitBytes = 8 * 1024 * 1024
    private static let maxRecordsPerSession = 5000

    private let lock = NSLock()
    private var records: [String: [String: Record]] = [:]

    public init() {}

    /// 记录路径用的统一键：符号链接解析后的物理路径，并按大小写规则折叠。
    public static func key(forPath path: String) -> String {
        let physical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return PolicyRuntimePathBoundary.foldedForPathComparison(physical)
    }

    private static func snapshot(path: String, data: Data?) -> Record? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        let size = Int64(info.st_size)
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        var digest: String?
        if size <= Int64(digestLimitBytes) {
            let bytes = data ?? (try? Data(contentsOf: URL(fileURLWithPath: path)))
            if let bytes, Int64(bytes.count) == size { digest = sha256(bytes) }
        }
        return Record(size: size, mtimeNanos: mtime, sha256: digest)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 登记“这个会话已读过该文件的当前版本”。文件不存在或不是普通文件时不登记。
    public func recordRead(sessionID: String, path: String, data: Data? = nil) {
        guard !sessionID.isEmpty, let record = Self.snapshot(path: path, data: data) else { return }
        let key = Self.key(forPath: path)
        lock.withLock {
            var perSession = records[sessionID] ?? [:]
            if perSession.count >= Self.maxRecordsPerSession, perSession[key] == nil { perSession.removeAll() }
            perSession[key] = record
            records[sessionID] = perSession
        }
    }

    /// 先只记大小和修改时间（立即返回，不读文件内容），内容摘要放到后台补算。
    /// 给主线程上的登记（附件、@ 引用）用，避免大文件在界面线程上算哈希。
    /// 补算时若文件已变（大小或时间不同），不写摘要，保持保守判断。
    public func recordReadDeferringDigest(sessionID: String, path: String) {
        guard !sessionID.isEmpty else { return }
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }
        let size = Int64(info.st_size)
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        let key = Self.key(forPath: path)
        lock.withLock {
            var perSession = records[sessionID] ?? [:]
            if perSession.count >= Self.maxRecordsPerSession, perSession[key] == nil { perSession.removeAll() }
            perSession[key] = Record(size: size, mtimeNanos: mtime, sha256: nil)
            records[sessionID] = perSession
        }
        guard size <= Int64(Self.digestLimitBytes) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  Int64(bytes.count) == size else { return }
            let digest = Self.sha256(bytes)
            lock.withLock {
                if var current = records[sessionID]?[key], current.size == size,
                   current.mtimeNanos == mtime, current.sha256 == nil {
                    current.sha256 = digest
                    records[sessionID]?[key] = current
                }
            }
        }
    }

    /// 比较读取记录与磁盘上的当前版本。只有时间变化、内容摘要相同时仍算“当前”。
    public func status(sessionID: String, path: String) -> Status {
        guard !sessionID.isEmpty else { return .current }
        let key = Self.key(forPath: path)
        guard let recorded = lock.withLock({ records[sessionID]?[key] }) else { return .neverRead }
        guard let now = Self.snapshot(path: path, data: nil) else { return .modifiedSinceRead }
        if now.size == recorded.size, now.mtimeNanos == recorded.mtimeNanos { return .current }
        if now.size == recorded.size, let before = recorded.sha256, before == now.sha256 {
            lock.withLock { records[sessionID]?[key] = now }
            return .current
        }
        return .modifiedSinceRead
    }

    public func forget(sessionID: String, path: String) {
        let key = Self.key(forPath: path)
        lock.withLock { _ = records[sessionID]?.removeValue(forKey: key) }
    }

    public func clear(sessionID: String) {
        lock.withLock { _ = records.removeValue(forKey: sessionID) }
    }
}
