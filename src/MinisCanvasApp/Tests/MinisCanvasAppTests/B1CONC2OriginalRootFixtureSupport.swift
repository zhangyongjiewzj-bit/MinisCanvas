import Foundation
import Darwin
import Testing
import MinisCore

// Strict original Core-consumer fixture in the App test bundle; not an original Core bundle claim.
enum B1CONC2OriginalRootFixtureSupport {
    private struct Lease {
        let root: URL
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        func finish() throws {
            var s = stat()
            try #require(lstat(root.path, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR && s.st_mode & 0o777 == 0o700 && s.st_dev == device && s.st_ino == inode && s.st_uid == owner && owner == geteuid(), "original consumer root changed; preserve exact root")
            try FileManager().removeItem(at: root)
            errno = 0
            try #require(lstat(root.path, &s) == -1 && errno == ENOENT)
            print("CONC2_ORIGINAL_ROOT_CLEANUP exactIdentity=true absent=true")
        }
    }
    private enum Failure: Error { case both(business: any Error, cleanup: any Error) }
    private static func create() throws -> Lease {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let parent = formal.rootDirectory
        var p = stat()
        try #require(lstat(parent.path, &p) == 0 && p.st_mode & S_IFMT == S_IFDIR && p.st_mode & 0o777 == 0o700 && p.st_uid == geteuid() && UInt64(p.st_dev) == formal.rootDevice)
        let root = parent.appendingPathComponent("B1CONC2-original-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var s = stat()
        try #require(lstat(root.path, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR && s.st_mode & 0o777 == 0o700 && s.st_uid == geteuid() && s.st_dev == p.st_dev && s.st_ino != p.st_ino)
        print("CONC2_ORIGINAL_ROOT uid=\(s.st_uid) dev=\(s.st_dev) inode=\(s.st_ino) mode=700")
        return Lease(root: root, device: s.st_dev, inode: s.st_ino, owner: s.st_uid)
    }
    static func withRoot(_ body: (URL) async throws -> Void) async throws {
        let lease = try create()
        let business: Result<Void, any Error>
        do { try await body(lease.root); business = .success(()) }
        catch { business = .failure(error) }
        do { try lease.finish() }
        catch {
            if case .failure(let original) = business { throw Failure.both(business: original, cleanup: error) }
            throw error
        }
        try business.get()
    }
}
