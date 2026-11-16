import AppKit
import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Owned fixture adaptation only. Original S20 assertions and host actions remain intact.
@MainActor
enum S20OriginalOwnedFixture {
    private struct FixtureFailure: Error {
        let stage: String
        let code: Int32
    }
    private struct FixtureFailures: Error {
        let business: Error?
        let cleanup: [Error]
    }

    /// Pins the actual FileManager temporary parent and an immediately fresh
    /// UUID child. The formal contract supplies the expected uid/device; no
    /// environment string is accepted as the child's observed identity.
    private struct OwnedRoot {
        let url: URL
        let parentURL: URL
        let name: String
        let parentFD: Int32
        let rootFD: Int32
        let parentIdentity: stat
        let identity: stat
        let formal: FormalTestIsolationPaths

        static func make() throws -> OwnedRoot {
            guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess() else {
                throw FixtureFailure(stage: "formal profile missing", code: EINVAL)
            }
            let parentURL = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
            let parentFD = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentFD >= 0 else { throw FixtureFailure(stage: "open actualFM", code: errno) }
            var parentIdentity = stat()
            guard fstat(parentFD, &parentIdentity) == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "stat actualFM", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "stat actualFM", code: code)
            }
            guard parentIdentity.st_mode & S_IFMT == S_IFDIR,
                  parentIdentity.st_mode & 0o7777 == 0o700,
                  parentIdentity.st_uid == geteuid(), parentIdentity.st_uid == formal.rootOwner,
                  UInt64(parentIdentity.st_dev) == formal.rootDevice else {
                let error = FixtureFailure(stage: "actualFM parent uid/device/700", code: ESTALE)
                guard Darwin.close(parentFD) == 0 else {
                    throw FixtureFailures(business: error,
                        cleanup: [FixtureFailure(stage: "close invalid actualFM parent", code: errno)])
                }
                throw error
            }
            let name = "settings20-original-\(UUID().uuidString)"
            let created = name.withCString { mkdirat(parentFD, $0, 0o700) }
            guard created == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "mkdir fresh UUID", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "mkdir fresh UUID", code: code)
            }
            let rootFD = name.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            var identity = stat()
            guard rootFD >= 0, fstat(rootFD, &identity) == 0 else {
                let code = errno
                var errors: [Error] = []
                // mkdirat just created this still-empty child; unlinkat removes
                // only that directory entry, never follows a replacement link.
                if name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) != 0 {
                    errors.append(FixtureFailure(stage: "remove uninitialized fresh child", code: errno))
                }
                if rootFD >= 0, Darwin.close(rootFD) != 0 {
                    errors.append(FixtureFailure(stage: "close fresh child", code: errno))
                }
                if Darwin.close(parentFD) != 0 {
                    errors.append(FixtureFailure(stage: "close actualFM", code: errno))
                }
                throw FixtureFailures(business: FixtureFailure(stage: "open/stat fresh child", code: code),
                                      cleanup: errors)
            }
            // All later validation is business work under a cleanup owner.
            return OwnedRoot(url: parentURL.appendingPathComponent(name, isDirectory: true),
                             parentURL: parentURL, name: name, parentFD: parentFD, rootFD: rootFD,
                             parentIdentity: parentIdentity, identity: identity, formal: formal)
        }

        func validate() throws {
            var parentNow = stat()
            var childNow = stat()
            var rootNow = stat()
            guard parentURL.path.withCString({ fstatat(AT_FDCWD, $0, &parentNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  parentNow.st_mode & S_IFMT == S_IFDIR,
                  parentNow.st_mode & 0o7777 == 0o700,
                  parentNow.st_dev == parentIdentity.st_dev,
                  parentNow.st_ino == parentIdentity.st_ino,
                  parentNow.st_uid == geteuid(), parentNow.st_uid == formal.rootOwner,
                  UInt64(parentNow.st_dev) == formal.rootDevice,
                  name.withCString({ fstatat(parentFD, $0, &childNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  fstat(rootFD, &rootNow) == 0,
                  childNow.st_mode & S_IFMT == S_IFDIR,
                  childNow.st_uid == geteuid(), childNow.st_uid == formal.rootOwner,
                  childNow.st_mode & 0o7777 == 0o700,
                  childNow.st_dev == parentNow.st_dev,
                  childNow.st_dev == identity.st_dev, childNow.st_ino == identity.st_ino,
                  rootNow.st_dev == identity.st_dev, rootNow.st_ino == identity.st_ino,
                  childNow.st_ino != parentNow.st_ino,
                  UInt64(childNow.st_ino) != formal.rootInode,
                  url.deletingLastPathComponent().path == parentURL.path,
                  url.standardizedFileURL.resolvingSymlinksInPath().path == url.path else {
                throw FixtureFailure(stage: "freshFM uid/dev/inode/700/nosymlink", code: ESTALE)
            }
        }

        func finish<T>(_ business: Result<T, Error>) throws -> T {
            var errors: [Error] = []
            do {
                try validate()
                try FileManager.default.removeItem(at: url)
                var absent = stat()
                let result = name.withCString {
                    fstatat(parentFD, $0, &absent, AT_SYMLINK_NOFOLLOW)
                }
                guard result == -1, errno == ENOENT else {
                    throw FixtureFailure(stage: "cleanup verify ENOENT", code: errno)
                }
            } catch { errors.append(error) }
            if Darwin.close(rootFD) != 0 {
                errors.append(FixtureFailure(stage: "close fresh child", code: errno))
            }
            if Darwin.close(parentFD) != 0 {
                errors.append(FixtureFailure(stage: "close actualFM", code: errno))
            }
            if !errors.isEmpty {
                switch business {
                case .failure(let error): throw FixtureFailures(business: error, cleanup: errors)
                case .success: throw FixtureFailures(business: nil, cleanup: errors)
                }
            }
            print("S20_ORIGINAL_FIXTURE_CLEANUP root=\(url.path) uid=\(identity.st_uid) dev=\(identity.st_dev) inode=\(identity.st_ino) ENOENT=true")
            return try business.get()
        }
    }

    private static func removeOwnedUsageLock(_ path: String, formal: FormalTestIsolationPaths) throws {
        var identity = stat()
        let result = path.withCString { lstat($0, &identity) }
        if result == -1, errno == ENOENT { return }
        guard result == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_mode & 0o7777 == 0o600,
              identity.st_uid == geteuid(), identity.st_uid == formal.rootOwner,
              UInt64(identity.st_dev) == formal.rootDevice else {
            throw FixtureFailure(stage: "owned Usage lock uid/dev/type/600", code: ESTALE)
        }
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw FixtureFailure(stage: "open owned Usage lock", code: errno) }
        let business = Result<Void, Error> {
            var held = stat()
            var current = stat()
            guard fstat(fd, &held) == 0,
                  path.withCString({ lstat($0, &current) }) == 0,
                  held.st_dev == identity.st_dev, held.st_ino == identity.st_ino,
                  current.st_dev == held.st_dev, current.st_ino == held.st_ino else {
                throw FixtureFailure(stage: "owned Usage lock replaced", code: ESTALE)
            }
            guard path.withCString({ unlink($0) }) == 0 else {
                throw FixtureFailure(stage: "unlink owned Usage lock", code: errno)
            }
            var absent = stat()
            guard path.withCString({ lstat($0, &absent) }) == -1, errno == ENOENT else {
                throw FixtureFailure(stage: "Usage lock ENOENT", code: ESTALE)
            }
        }
        if Darwin.close(fd) != 0 {
            let error = FixtureFailure(stage: "close owned Usage lock", code: errno)
            switch business {
            case .success: throw error
            case .failure(let original): throw FixtureFailures(business: original, cleanup: [error])
            }
        }
        try business.get()
    }


    static func withFixture(_ body: (SettingsCenter) throws -> Void) async throws {
        let caller = Test.current?.id
        let owned = try OwnedRoot.make()
        let token = UUID().uuidString
        let suite = "MinisCanvas.S20.Original.\(token)"
        let key = "s20.original.\(token)"
        let lockPath = UsageStore.persistenceLockPath(for: key)
        var suiteAdmitted = false
        var lockAdmitted = false
        var center: SettingsCenter?
        var preparationError: Error?
        do {
            try owned.validate()
            guard UserDefaults.standard.persistentDomain(forName: suite) == nil else {
                throw FixtureFailure(stage: "fresh suite collision", code: EEXIST)
            }
            suiteAdmitted = true
            var oldLock = stat()
            guard lstat(lockPath, &oldLock) == -1, errno == ENOENT else {
                throw FixtureFailure(stage: "fresh Usage lock collision", code: EEXIST)
            }
            lockAdmitted = true
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw FixtureFailure(stage: "owned suite unavailable", code: EINVAL)
            }
            let usage = UsageStore(domain: .suite(suite), storageKey: key)
            // Await init's actual self-heal tail before host creation. S20 body has no Usage mutation.
            let joined = await usage.waitForPersistence()
            guard joined else { throw FixtureFailure(stage: "Usage initial tail failed", code: EIO) }
            let root = owned.url
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            center = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                     privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
                logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 50),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: usage,
                providerReadinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessDeployment: .mock,
                providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        } catch { preparationError = error }
        let finish: (Result<Void, Error>) throws -> Void = { business in
            var cleanup: [Error] = []
            if lockAdmitted {
                do { try removeOwnedUsageLock(lockPath, formal: owned.formal) }
                catch { cleanup.append(error) }
            }
            if suiteAdmitted {
                UserDefaults.standard.removePersistentDomain(forName: suite)
                if UserDefaults.standard.persistentDomain(forName: suite) != nil {
                    cleanup.append(FixtureFailure(stage: "owned suite removal failed", code: EIO))
                }
            }
            let result: Result<Void, Error>
            if cleanup.isEmpty { result = business }
            else {
                switch business {
                case .success: result = .failure(FixtureFailures(business: nil, cleanup: cleanup))
                case .failure(let error): result = .failure(FixtureFailures(business: error, cleanup: cleanup))
                }
            }
            try owned.finish(result)
        }
        var entered = false
        do {
            try withOwnedS20NativeRunLoopScope {
                entered = true
                let business = Result<Void, Error> {
                    guard caller != nil, Test.current?.id == caller,
                          withUnsafeCurrentTask(body: { $0 != nil }) else {
                        let context = FixtureFailure(stage: "Testing context lost", code: ESTALE)
                        if let preparationError {
                            throw FixtureFailures(business: preparationError, cleanup: [context])
                        }
                        throw context
                    }
                    if let preparationError { throw preparationError }
                    guard let center else { throw FixtureFailure(stage: "center missing", code: EINVAL) }
                    try body(center)
                }
                // Original body closes host and restores policy on return before synchronous cleanup.
                try finish(business)
            }
        } catch {
            if !entered {
                if let preparationError {
                    try finish(.failure(FixtureFailures(business: preparationError, cleanup: [error])))
                } else { try finish(.failure(error)) }
            }
            throw error
        }
    }
}
