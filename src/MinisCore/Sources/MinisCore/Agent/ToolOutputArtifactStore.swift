import Foundation
import Darwin

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
    // A successful producer write is the only registration entry point. These
    // receipts live only in this process; restarting never restores a grant.
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
        guard rawPath == url.standardizedFileURL.path,
              url.deletingLastPathComponent().path == directory.path,
              url.pathExtension == "txt",
              let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              id.uuidString == url.deletingPathExtension().lastPathComponent,
              url.resolvingSymlinksInPath().path == rawPath,
              let receipt = Self.receipts.receipt(path: rawPath) else {
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
        let excerptLength = min(1_500, max(1, thresholdCharacters / 2))
        let preview = String(redactedOutput.prefix(excerptLength))
            + "\n…中间内容见输出文件…\n"
            + String(redactedOutput.suffix(excerptLength))
        return ToolOutputArtifact(artifactID: artifactID, fileURL: fileURL, preview: preview, characterCount: count, byteCount: redactedOutput.utf8.count)
    }
}
