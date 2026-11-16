import Foundation
import Darwin
import os
@testable import MinisCore
import Testing

final class ArtifactAOwnedPhysicalRoot: Sendable {
    let root: URL
    let device: Int32
    let inode: UInt64
    private let removed = OSAllocatedUnfairLock(initialState: false)
    init(label: String) throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let canonicalParent = try #require(PolicyRuntimePathBoundary.canonicalPath(formal.rootDirectory.path))
        let parent = URL(fileURLWithPath: canonicalParent, isDirectory: true)
        var pin = stat()
        try #require(lstat(parent.path, &pin) == 0)
        try #require(pin.st_uid == geteuid() && (pin.st_mode & S_IFMT) == S_IFDIR && (pin.st_mode & 0o777) == 0o700)
        try #require(UInt64(pin.st_dev) == formal.rootDevice && UInt64(pin.st_ino) == formal.rootInode)
        root = parent.appendingPathComponent(label + UUID().uuidString, isDirectory: true)
        try #require(mkdir(root.path, 0o700) == 0)
        var info = stat()
        try #require(lstat(root.path, &info) == 0 && info.st_uid == geteuid() && info.st_dev == pin.st_dev && (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o777) == 0o700)
        device = info.st_dev
        inode = info.st_ino
        print("ARTIFACT_OWNED_ROOT path=\(root.path) dev=\(device) ino=\(inode) uid=\(info.st_uid) mode=700")
    }
    func cleanup() -> Bool {
        removed.withLock { alreadyRemoved in
            var info = stat()
            if alreadyRemoved {
                errno = 0
                return lstat(root.path, &info) == -1 && errno == ENOENT
            }
            guard lstat(root.path, &info) == 0, info.st_uid == geteuid(), info.st_dev == device,
                  info.st_ino == inode, (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700 else { return false }
            do { try FileManager().removeItem(at: root) } catch { return false }
            errno = 0
            guard lstat(root.path, &info) == -1 && errno == ENOENT else { return false }
            alreadyRemoved = true
            print("ARTIFACT_OWNED_CLEANUP exactIdentity=true absent=true")
            return true
        }
    }
}
