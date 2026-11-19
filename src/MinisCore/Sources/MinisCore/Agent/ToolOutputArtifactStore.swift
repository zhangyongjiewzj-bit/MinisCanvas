import Foundation
import Darwin
import CryptoKit

public struct ToolOutputArtifact: Sendable, Equatable {
    public let artifactID: UUID
    public let fileURL: URL
    public let preview: String
    public let characterCount: Int
    public let byteCount: Int

    /// Can be appended to a timeout diagnostic without changing its failure.
    public var referenceText: String {
        "已提供的输出已保存：\(fileURL.path) [artifact_id:\(artifactID.uuidString)]（\(characterCount) 字符，\(byteCount) UTF-8 字节）\n\(preview)"
    }
}

/// Stores only output already passed through the consumer's secret redactor.
/// The consumer injects its SessionStore root and admitted session identity.
public struct ToolOutputArtifactStore: Sendable {
    // A successful producer write is the only registration entry point. Receipts
    // live in this process; after a restart a grant returns only when the
    // session manifest (size + SHA-256) still matches the file byte for byte.
    private struct Receipt: Sendable {
        let path: String
        let inode: UInt64
        let device: UInt64
        let bytes: UInt64
    }

    private final class Receipts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Receipt] = [:]
        func insert(_ receipt: Receipt) {
            lock.lock(); defer { lock.unlock() }
            values[receipt.path] = receipt
        }
        func receipt(path: String) -> Receipt? {
            lock.lock(); defer { lock.unlock() }
            return values[path]
        }
        func remove(path: String) {
            lock.lock(); defer { lock.unlock() }
            values[path] = nil
        }
        func remove(directory: String) {
            lock.lock(); defer { lock.unlock() }
            values = values.filter { !$0.key.hasPrefix(directory + "/") }
        }
    }
    private static let receipts = Receipts()

    public let sessionStorageRoot: URL
    public let sessionID: UUID

    public init(sessionStorageRoot: URL, sessionID: UUID) {
        self.sessionStorageRoot = sessionStorageRoot
        self.sessionID = sessionID
    }

    public static func directory(sessionStorageRoot: URL, sessionID: UUID) -> URL {
        sessionStorageRoot.appendingPathComponent("tool-output", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// The injected root belongs to SessionStore, never the project grant.
    /// Reject redirected artifact subdirectories even if they point to another
    /// session within the same storage root.
    public func validatedDirectory() throws -> URL {
        let root = sessionStorageRoot.standardizedFileURL.resolvingSymlinksInPath()
        let expected = Self.directory(sessionStorageRoot: root, sessionID: sessionID)
        guard expected.resolvingSymlinksInPath().standardizedFileURL.path == expected.path else {
            throw ToolExecutorError.pathViolation(expected.path)
        }
        return expected
    }

    /// Both the outer policy and the base reader use this same trusted scope.
    /// Absent scope is not an exception: the ordinary policy chain still owns it.
    public static func resolveOwnedArtifact(path: String) throws -> URL? {
        guard let scope = ToolOutputArtifactSessionScope.current else { return nil }
        guard scope.sessionStorageRoot.isFileURL else {
            throw ToolExecutorError.pathViolation(path)
        }
        return try Self(sessionStorageRoot: scope.sessionStorageRoot, sessionID: scope.sessionID)
            .resolveArtifactPath(path)
    }

    /// Reads through a descriptor bound to the producer receipt. Every parent
    /// component is opened without following links, then fstat binds the final
    /// regular file to the same inode/device/size before and after the read.
    public static func readOwnedArtifact(path: String) throws -> Data? {
        guard let url = try resolveOwnedArtifact(path: path) else { return nil }
        guard let receipt = receipts.receipt(path: url.path) else {
            throw ToolExecutorError.pathViolation(path)
        }
        let components = url.pathComponents.filter { $0 != "/" }
        var parentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else { throw readError(path: path) }
        defer { Darwin.close(parentFD) }
        for component in components.dropLast() {
            let next = Darwin.openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw readError(path: path) }
            Darwin.close(parentFD)
            parentFD = next
        }
        guard let basename = components.last else { throw ToolExecutorError.pathViolation(path) }
        let fileFD = Darwin.openat(parentFD, basename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fileFD >= 0 else { throw readError(path: path) }
        defer { Darwin.close(fileFD) }
        try validateDescriptor(fileFD, receipt: receipt, path: path)
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: false)
        let data: Data
        do { data = try handle.readToEnd() ?? Data() }
        catch { throw mappedReadFailure(error, path: path) ?? error }
        try validateDescriptor(fileFD, receipt: receipt, path: path)
        guard UInt64(data.count) == receipt.bytes else { throw ToolExecutorError.pathViolation(path) }
        return data
    }

    private static func validateDescriptor(_ fd: Int32, receipt: Receipt, path: String) throws {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw readError(path: path) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              UInt64(info.st_ino) == receipt.inode,
              UInt64(bitPattern: Int64(info.st_dev)) == receipt.device,
              info.st_size >= 0, UInt64(info.st_size) == receipt.bytes else {
            throw ToolExecutorError.pathViolation(path)
        }
    }

    private static func readError(path: String) -> Error {
        let code = errno
        if code == EACCES || code == EPERM { return ToolExecutorError.permissionDenied(path) }
        if code == ENOENT { return ToolExecutorError.fileNotFound(path) }
        if code == ELOOP || code == ENOTDIR { return ToolExecutorError.pathViolation(path) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSFilePathErrorKey: path])
    }

    /// A read-only exception candidate for existing file_read(path:). The caller
    /// must still enforce its original invocation identity and read bounds.
    /// nil grants nothing: ordinary paths retain their existing policy decision.
    /// No user-supplied path can register itself as an output artifact.
    public func resolveArtifactPath(_ rawPath: String) throws -> URL? {
        let root = sessionStorageRoot.standardizedFileURL.resolvingSymlinksInPath()
        let outputRoot = root.appendingPathComponent("tool-output", isDirectory: true).path + "/"
        guard rawPath.hasPrefix(outputRoot) else { return nil }
        let directory = try validatedDirectory()
        let url = URL(fileURLWithPath: rawPath)
        // 文本输出叫 <UUID>.txt；MCP 图片叫 mcp-image-<UUID>.<png|jpg|gif|webp>。
        let baseName = url.deletingPathExtension().lastPathComponent
        let idText: String
        if url.pathExtension == "txt" {
            idText = baseName
        } else if Self.imageExtensions.contains(url.pathExtension), baseName.hasPrefix(Self.imagePrefix) {
            idText = String(baseName.dropFirst(Self.imagePrefix.count))
        } else {
            throw ToolExecutorError.pathViolation(rawPath)
        }
        guard rawPath == url.standardizedFileURL.path,
              url.deletingLastPathComponent().path == directory.path,
              let id = UUID(uuidString: idText),
              id.uuidString == idText,
              url.resolvingSymlinksInPath().path == rawPath,
              let receipt = Self.receipts.receipt(path: rawPath)
                ?? Self.restoreReceiptFromManifest(url: url, directory: directory) else {
            throw ToolExecutorError.pathViolation(rawPath)
        }
        let current: Receipt
        do { current = try Self.fileReceipt(at: url) }
        catch { throw Self.mappedReadFailure(error, path: rawPath) ?? error }
        guard current.inode == receipt.inode, current.device == receipt.device,
              current.bytes == receipt.bytes else {
            throw ToolExecutorError.pathViolation(rawPath)
        }
        return url
    }

    private static func mappedReadFailure(
        _ error: Error, path: String, depth: Int = 0
    ) -> ToolExecutorError? {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == CocoaError.Code.fileReadNoPermission.rawValue
                || ns.code == CocoaError.Code.fileWriteNoPermission.rawValue {
                return .permissionDenied(path)
            }
            if ns.code == CocoaError.Code.fileReadNoSuchFile.rawValue
                || ns.code == CocoaError.Code.fileNoSuchFile.rawValue {
                return .fileNotFound(path)
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            if ns.code == Int(EACCES) || ns.code == Int(EPERM) { return .permissionDenied(path) }
            if ns.code == Int(ENOENT) { return .fileNotFound(path) }
        }
        if depth < 4, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return mappedReadFailure(underlying, path: path, depth: depth + 1)
        }
        return nil
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "gif", "webp"]
    private static let imagePrefix = "mcp-image-"
    private static let manifestName = "manifest.json"
    private static let manifestLock = NSLock()

    private struct ManifestEntry: Codable {
        let bytes: UInt64
        let sha256: String
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 登记读取凭据的同时，把“文件名 -> 字节数 + 内容 SHA-256”写进会话输出目录的清单。
    /// 重启后凭据只在清单存在且文件字节数与哈希都仍然匹配时才恢复；清单写失败只影响重启后的续读。
    private static func recordManifest(directory: URL, fileName: String, data: Data) {
        manifestLock.lock(); defer { manifestLock.unlock() }
        let manifestURL = directory.appendingPathComponent(manifestName)
        var entries: [String: ManifestEntry] = [:]
        if let existing = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([String: ManifestEntry].self, from: existing) {
            entries = decoded
        }
        entries[fileName] = ManifestEntry(bytes: UInt64(data.count), sha256: sha256Hex(data))
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        FileManager.default.createFile(
            atPath: manifestURL.path, contents: encoded, attributes: [.posixPermissions: 0o600])
    }

    /// 每个会话输出目录的总量上限（图片与超长输出合计）。
    static let sessionByteLimit: UInt64 = 512 * 1024 * 1024

    /// 写入后检查会话输出目录总量：超过上限就按修改时间从最旧的删起，直到不超过上限；
    /// 刚写入的文件和清单不删。被删文件同时从清单和读取回执里去掉，之后按路径读取会提示文件不存在。
    static func enforceSessionQuota(directory: URL, keeping keptFileName: String, limit: UInt64 = sessionByteLimit) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: UInt64, date: Date)] = []
        var total: UInt64 = 0
        for url in urls where url.lastPathComponent != manifestName {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = UInt64(values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }
        var removed: [String] = []
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            if file.url.lastPathComponent == keptFileName { continue }
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            removed.append(file.url.lastPathComponent)
            receipts.remove(path: file.url.path)
        }
        guard !removed.isEmpty else { return }
        manifestLock.lock(); defer { manifestLock.unlock() }
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard let existing = try? Data(contentsOf: manifestURL),
              var entries = try? JSONDecoder().decode([String: ManifestEntry].self, from: existing) else { return }
        for name in removed { entries[name] = nil }
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        FileManager.default.createFile(
            atPath: manifestURL.path, contents: encoded, attributes: [.posixPermissions: 0o600])
    }

    private static func restoreReceiptFromManifest(url: URL, directory: URL) -> Receipt? {
        manifestLock.lock()
        let manifestData = try? Data(contentsOf: directory.appendingPathComponent(manifestName))
        manifestLock.unlock()
        guard let manifestData,
              let entries = try? JSONDecoder().decode([String: ManifestEntry].self, from: manifestData),
              let entry = entries[url.lastPathComponent],
              let current = try? fileReceipt(at: url),
              current.bytes == entry.bytes,
              let data = try? Data(contentsOf: url),
              UInt64(data.count) == entry.bytes,
              sha256Hex(data) == entry.sha256 else { return nil }
        receipts.insert(current)
        return current
    }

    private static func fileReceipt(at url: URL) throws -> Receipt {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let bytes = attributes[.size] as? NSNumber else {
            throw ToolExecutorError.pathViolation(url.path)
        }
        return Receipt(path: url.path, inode: inode.uint64Value,
                       device: device.uint64Value, bytes: bytes.uint64Value)
    }

    /// Called only by the owner after actual deletion, never on archive.
    public func removeSessionArtifacts() throws {
        let directory = try validatedDirectory()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        Self.receipts.remove(directory: directory.path)
    }

    /// 把工具返回的图片存进会话输出目录，供工具卡片显示缩略图。
    /// 同时登记读取回执和清单，模型之后可按路径 file_read 这张图（只限本会话输出目录）。
    /// 会话被永久删除时随输出目录一起清掉。
    public func persistImage(_ data: Data, fileExtension: String) throws -> URL {
        let allowed: Set<String> = ["png", "jpg", "gif", "webp"]
        guard allowed.contains(fileExtension), !data.isEmpty else {
            throw ToolExecutorError.invalidParameter("image extension")
        }
        let directory = try validatedDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fileURL = directory.appendingPathComponent("\(Self.imagePrefix)\(UUID().uuidString).\(fileExtension)")
        guard FileManager.default.createFile(
            atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        Self.receipts.insert(try Self.fileReceipt(at: fileURL))
        Self.recordManifest(directory: directory, fileName: fileURL.lastPathComponent, data: data)
        Self.enforceSessionQuota(directory: directory, keeping: fileURL.lastPathComponent)
        return fileURL
    }

    /// At exactly the threshold, keep the existing inline output contract.
    /// Write errors propagate; a reference is never returned for a failed write.
    public func persistIfLarge(
        redactedOutput: String,
        thresholdCharacters: Int = 30_000
    ) throws -> ToolOutputArtifact? {
        precondition(thresholdCharacters > 0)
        let count = redactedOutput.count
        guard count > thresholdCharacters else { return nil }
        let directory = try validatedDirectory()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let artifactID = UUID()
        let fileURL = directory.appendingPathComponent(artifactID.uuidString + ".txt")
        guard FileManager.default.createFile(
            atPath: fileURL.path, contents: Data(redactedOutput.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        Self.receipts.insert(try Self.fileReceipt(at: fileURL))
        Self.recordManifest(directory: directory, fileName: fileURL.lastPathComponent,
                            data: Data(redactedOutput.utf8))
        Self.enforceSessionQuota(directory: directory, keeping: fileURL.lastPathComponent)
        let excerptLength = min(1_500, max(1, thresholdCharacters / 2))
        let preview = String(redactedOutput.prefix(excerptLength))
            + "\n…中间内容见输出文件…\n"
            + String(redactedOutput.suffix(excerptLength))
        return ToolOutputArtifact(artifactID: artifactID, fileURL: fileURL, preview: preview, characterCount: count, byteCount: redactedOutput.utf8.count)
    }
}
