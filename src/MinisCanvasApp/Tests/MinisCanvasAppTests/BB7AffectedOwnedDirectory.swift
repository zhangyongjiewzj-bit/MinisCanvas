import Foundation
import Darwin
import MinisCore
import Testing

enum BB7AffectedOwnedDirectory {
    private struct Failure: Error { let description: String }
    static func withDirectory(_ body: (URL) throws -> Void) throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let parent = formal.rootDirectory
        var p = stat()
        try #require(lstat(parent.path, &p) == 0)
        try #require((p.st_mode & S_IFMT) == S_IFDIR && p.st_uid == geteuid() && (p.st_mode & 0o777) == 0o700)
        try #require(UInt64(p.st_dev) == formal.rootDevice && UInt64(p.st_ino) == formal.rootInode)
        let directory = parent.appendingPathComponent("bb7-backlink-" + UUID().uuidString, isDirectory: true)
        try #require(mkdir(directory.path, 0o700) == 0)
        var identity = stat()
        guard lstat(directory.path, &identity) == 0,
              (identity.st_mode & S_IFMT) == S_IFDIR, identity.st_uid == geteuid(),
              (identity.st_mode & 0o777) == 0o700, identity.st_dev == p.st_dev else {
            throw Failure(description: "owned root qualification failed; preserve root")
        }
        print("BB7_OWNED_ROOT path=\(directory.path) dev=\(identity.st_dev) ino=\(identity.st_ino) uid=\(identity.st_uid) mode=700")
        let business = Result { try body(directory) }
        let cleanup: Result<Void, any Error> = Result {
            var current = stat()
            try #require(lstat(directory.path, &current) == 0)
            try #require(current.st_dev == identity.st_dev && current.st_ino == identity.st_ino && current.st_uid == identity.st_uid && (current.st_mode & S_IFMT) == S_IFDIR && (current.st_mode & 0o777) == 0o700)
            try FileManager().removeItem(at: directory)
            errno = 0
            try #require(lstat(directory.path, &current) == -1 && errno == ENOENT)
            print("BB7_OWNED_CLEANUP identity=true absent=true")
        }
        switch (business, cleanup) {
        case (.success, .success): return
        case (.failure(let error), .success): throw error
        case (.success, .failure(let error)): throw error
        case (.failure(let businessError), .failure(let cleanupError)):
            throw Failure(description: "business=\(businessError); cleanup=\(cleanupError)")
        }
    }
}
