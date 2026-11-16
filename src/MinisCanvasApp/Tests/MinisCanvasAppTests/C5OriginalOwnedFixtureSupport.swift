import Foundation
import CryptoKit
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

// Test-only dependency/ownership fixture. No NSApp, AX, network or real Keychain.
@MainActor
final class C5OriginalOwnedFixture {
    let root: URL
    let defaults: UserDefaults
    let domain: UsageDefaultsDomain
    let logManager: LogManager
    private let device: dev_t
    private let inode: ino_t
    private let suite: String
    private var extraSuites: [String] = []
    init() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let r = formal.rootDirectory.appendingPathComponent("C5-original-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var s = stat()
        try #require(lstat(r.path, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR && s.st_uid == geteuid() && s.st_mode & 0o777 == 0o700)
        root = r; device = s.st_dev; inode = s.st_ino
        suite = "com.miniscanvas.c5.original." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        domain = .suite(suite)
        logManager = LogManager(directory: r.appendingPathComponent("logs"), ringCapacity: 20)
    }
    func freshDefaults(_ originalName: String) -> UserDefaults {
        let suffix = SHA256.hash(data: Data(originalName.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = suite + "." + suffix
        extraSuites.append(name)
        let value = UserDefaults(suiteName: name)!
        value.removePersistentDomain(forName: name)
        return value
    }
    func cleanup() {
        var s = stat()
        let same = lstat(root.path, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR && s.st_uid == geteuid() && s.st_dev == device && s.st_ino == inode && s.st_mode & 0o777 == 0o700
        #expect(same, "C5 exact owned root lease changed; preserve instead of removing")
        guard same else { return }
        for name in extraSuites + [suite] { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("C5 exact owned fixture cleanup failed; preserve evidence") }
        #expect(!FileManager.default.fileExists(atPath: root.path), "C5 owned fixture post-cleanup absence")
    }
}
