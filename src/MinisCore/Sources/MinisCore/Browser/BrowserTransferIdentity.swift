import Foundation
import CryptoKit
import Darwin

public typealias BrowserTransferFileAccess = @MainActor @Sendable (String, URL) async throws -> Void

public enum BrowserTransferFileAccessContext {
    @TaskLocal public static var current: BrowserTransferFileAccess?
}

public struct BrowserTransferFileIdentity: Equatable, Sendable {
    public let path: String
    public let fingerprint: String
    public let contentDigest: String

    @MainActor
    static func capture(path: String, upload: Bool, access: BrowserTransferFileAccess?) async throws -> Self {
        guard path.hasPrefix("/"), !path.contains("\0"), let access else {
            throw BrowserTransferError.filePermissionRequired
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        try validateFloor(url, upload: upload)
        try await access(upload ? "file_read" : "file_write", url)
        try Task.checkCancellation()
        // Only permission/live-policy evaluation stays on MainActor. All file
        // opening, hashing and repeated disk reads run on this worker.
        let worker = Task.detached(priority: .userInitiated) {
            try captureOnDisk(url: url, upload: upload)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func validateFloor(_ url: URL, upload: Bool) throws {
        let parts = url.pathComponents.map { $0.lowercased() }
        guard !parts.contains(".git"),
              ![".gitconfig", ".git-credentials", ".gitmodules"].contains(url.lastPathComponent.lowercased()),
              !SensitiveFilePolicy.contains(url.path), !SensitiveFilePolicy.isCredentialPath(url.path),
              BypassAppDataFloor.violation(path: url.path, access: upload ? .read : .modify) == nil,
              upload || BypassSystemFloor.violation(path: url.path, operation: .modify) == nil else {
            throw BrowserTransferError.filePermissionRequired
        }
    }

    /// 路径里除系统自带的 /tmp、/var、/etc（指向 /private/...）之外没有符号链接，
    /// 且最后一段本身不是符号链接。macOS 会把 /private/var/... 与 /var/... 视为同一位置，
    /// 直接比较 resolvingSymlinksInPath 的结果会把 /private 下的正常路径误判为"已变化"。
    static func isPhysicalPath(_ url: URL) -> Bool {
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let parent = url.deletingLastPathComponent().path
        guard let resolved = Darwin.realpath(parent, nil) else { return false }
        defer { free(resolved) }
        guard String(cString: resolved) == systemAliasNormalized(parent) else { return false }
        var info = stat()
        if Darwin.lstat(path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { return false }
        return true
    }

    static func systemAliasNormalized(_ path: String) -> String {
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func token(_ info: stat) -> String {
        "\(info.st_dev)|\(info.st_ino)|\(info.st_nlink)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)"
    }

    static func captureOnDisk(url: URL, upload: Bool) throws -> Self {
        try Task.checkCancellation()
        try validateFloor(url, upload: upload)
        guard isPhysicalPath(url) else { throw BrowserTransferError.changedFile }
        if !upload {
            var parent = stat(), existing = stat()
            guard Darwin.lstat(url.path, &existing) != 0, errno == ENOENT,
                  Darwin.lstat(url.deletingLastPathComponent().path, &parent) == 0,
                  (parent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw BrowserTransferError.changedFile }
            // Parent mtime changes when WebKit creates its owned staging file;
            // its device/inode identity, rather than directory contents, binds output.
            return Self(path: url.path, fingerprint: "\(parent.st_dev)|\(parent.st_ino)", contentDigest: "")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BrowserTransferError.changedFile }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), before.st_nlink == 1 else {
            throw BrowserTransferError.changedFile
        }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            guard count >= 0 else { throw BrowserTransferError.changedFile }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat(), currentPath = stat()
        guard Darwin.fstat(descriptor, &after) == 0, Darwin.lstat(url.path, &currentPath) == 0,
              before.st_nlink == 1, after.st_nlink == 1, currentPath.st_nlink == 1,
              token(before) == token(after), token(after) == token(currentPath),
              isPhysicalPath(url) else { throw BrowserTransferError.changedFile }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Self(path: url.path, fingerprint: token(after) + "|" + digest, contentDigest: digest)
    }
}

public enum BrowserTransferError: Error {
    case filePermissionRequired, changedFile, unavailable, prohibitedTarget, cancelled, failed
}

public struct BrowserTransferFailure: Error, Sendable {
    public let cancelled: Bool
    public let partialOutputPath: String?
    public let code: String
}
