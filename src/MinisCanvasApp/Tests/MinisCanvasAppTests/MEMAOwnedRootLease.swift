import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

struct MEMAOwnedRootLease {
    enum Failure: Error {
        case unsafeParent, unsafeRoot, changedIdentity, notRemoved
        case businessAndCleanup(String, String)
    }
    let root: URL
    let device: dev_t
    let inode: ino_t
    let owner: uid_t

    static func create(parent: URL, prefix: String) throws -> Self {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              (parentInfo.st_mode & 0o777) == 0o700,
              parentInfo.st_uid == geteuid(), parentInfo.st_uid == formal.rootOwner
        else { throw Failure.unsafeParent }
        let root = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700,
              info.st_uid == geteuid(), info.st_uid == formal.rootOwner,
              info.st_dev == parentInfo.st_dev, info.st_ino != parentInfo.st_ino,
              UInt64(info.st_ino) != formal.rootInode
        else { throw Failure.unsafeRoot }
        let lease = Self(root: root, device: info.st_dev, inode: info.st_ino, owner: info.st_uid)
        print("MEMA_LEASE_CREATE root=\(root.path) dev=\(info.st_dev) inode=\(info.st_ino) uid=\(info.st_uid) mode=700 parent=\(parent.path) runnerTMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "nil")")
        return lease
    }

    static func actualFMProfile(label: String) throws -> (Self, RuntimeIsolationProfile) {
        // Foundation's actual FM parent is independent of injected TMPDIR.
        let lease = try create(parent: FileManager.default.temporaryDirectory,
                               prefix: "mema-" + label + "-")
        do {
            let profile = try RuntimeIsolationProfile.makePackagedField(
                label: label,
                processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                                     RuntimeIsolationProfile.fieldActivationRootKey: lease.root.path],
                processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument],
                canvasRuntimeState: .disabled)
            try profile.validateDisposableRootIdentity()
            try lease.validate(profile.rootDirectory)
            let binding = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                           RuntimeIsolationProfile.fieldActivationRootKey: profile.rootDirectory.path,
                           RuntimeIsolationProfile.profileIdentityKey: profile.launchIdentity,
                           "MEMA_OWNED_DEVICE": String(lease.device),
                           "MEMA_OWNED_INODE": String(lease.inode),
                           "MEMA_OWNED_OWNER": String(lease.owner)]
            guard binding[RuntimeIsolationProfile.fieldActivationRootKey] == profile.rootDirectory.path,
                  profile.environment[RuntimeIsolationProfile.profileIdentityKey] == profile.launchIdentity
            else { throw Failure.changedIdentity }
            print("MEMA_NORMALIZED_PROFILE root=\(profile.rootDirectory.path) dev=\(lease.device) inode=\(lease.inode) uid=\(lease.owner) profile=\(profile.launchIdentity) localRootBinding=\(binding[RuntimeIsolationProfile.fieldActivationRootKey] ?? "nil") processFormalROOT_UNCHANGED=true")
            return (lease, profile)
        } catch {
            print("MEMA_PROFILE_PREPARATION_FAILED_ROOT_RETAINED root=\(lease.root.path) dev=\(lease.device) inode=\(lease.inode) uid=\(lease.owner)")
            throw error
        }
    }

    static func formal(label: String) throws -> Self {
        let paths = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        return try create(parent: paths.rootDirectory, prefix: "mema-" + label + "-")
    }

    func validate(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_dev == device, info.st_ino == inode,
              info.st_uid == owner, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700
        else { throw Failure.changedIdentity }
    }

    private func validateTree(_ directory: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(entry.path, &info) == 0, info.st_dev == device, info.st_uid == owner,
                  (info.st_mode & S_IFMT) != S_IFLNK else { throw Failure.changedIdentity }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR { try validateTree(entry) }
            else if kind != S_IFREG || info.st_nlink != 1 { throw Failure.changedIdentity }
        }
    }

    func finish(_ businessFailure: (any Error)?, profile: RuntimeIsolationProfile? = nil) throws {
        do {
            try validate(root)
            try validateTree(root)
            if let profile {
                try validate(profile.rootDirectory)
                try profile.cleanupDisposableRoots()
            } else { try FileManager.default.removeItem(at: root) }
            var absent = stat()
            guard lstat(root.path, &absent) != 0, errno == ENOENT else { throw Failure.notRemoved }
            print("MEMA_LEASE_CLEANUP root=\(root.path) dev=\(device) inode=\(inode) uid=\(owner) ABSENT=true")
        } catch {
            if let businessFailure {
                throw Failure.businessAndCleanup(String(reflecting: businessFailure), String(reflecting: error))
            }
            throw error
        }
        if let businessFailure { throw businessFailure }
    }
}
