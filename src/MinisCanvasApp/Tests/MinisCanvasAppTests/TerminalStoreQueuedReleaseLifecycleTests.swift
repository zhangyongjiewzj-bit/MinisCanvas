import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

/// No NSApp/NSWindow/SwiftUI host. The actual Store and POSIX boundary execute
/// only the finite owned script; reflection observes a Task, never substitutes it.
@Suite("ARCH3 actual TerminalStore queued release", .serialized)
@MainActor
struct TerminalStoreQueuedReleaseLifecycleTests {
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
            let name = "terminal-queued-release-\(UUID().uuidString)"
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
            print("TERMINAL_QUEUE_ROOT_CLEANUP root=\(url.path) uid=\(identity.st_uid) dev=\(identity.st_dev) inode=\(identity.st_ino) ENOENT=true")
            return try business.get()
        }
    }

    /// The UUID key is proved absent before construction. Cleanup follows
    /// actual UsageStore-tail completion, never just cancellation or timeout.
    private func removeOwnedUsageLock(_ path: String, formal: FormalTestIsolationPaths) throws {
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

    @MainActor
    private final class Fixture {
        let root: URL
        let settings: SettingsCenter
        let usage: UsageStore
        let nonce: String
        var handles: [Task<Void, Never>] = []
        var unjoinedSubmission = false
        init(root: URL, suite: String, usageKey: String, nonce: String) throws {
            self.root = root
            self.nonce = nonce
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw FixtureFailure(stage: "owned preferences unavailable", code: EINVAL)
            }
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            usage = UsageStore(domain: .suite(suite), storageKey: usageKey)
            settings = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain,
                                     privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
                logManager: LogManager(directory: root.appendingPathComponent("logs")),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: usage,
                providerReadinessTransport: FailClosedProviderReadinessTransport(),
                providerReadinessDeployment: .mock,
                providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        }
    }

    private func withFixture<T>(_ body: @MainActor (Fixture) async throws -> T) async throws -> T {
        let owned = try OwnedRoot.make()
        let token = UUID().uuidString
        let suite = "MinisCanvas.TerminalQueuedRelease.\(token)"
        let usageKey = "terminalQueuedRelease.\(token)"
        let lockPath = UsageStore.persistenceLockPath(for: usageKey)
        var suiteAdmitted = false
        var lockAdmitted = false
        var fixture: Fixture?
        let business: Result<T, Error>
        do {
            try owned.validate()
            guard UserDefaults.standard.persistentDomain(forName: suite) == nil else {
                throw FixtureFailure(stage: "owned preferences collision", code: EEXIST)
            }
            suiteAdmitted = true
            var prior = stat()
            guard lockPath.withCString({ lstat($0, &prior) }) == -1, errno == ENOENT else {
                throw FixtureFailure(stage: "owned Usage key collision", code: EEXIST)
            }
            lockAdmitted = true
            let created = try Fixture(root: owned.url, suite: suite, usageKey: usageKey, nonce: token)
            fixture = created
            print("TERMINAL_QUEUE_ROOT root=\(owned.url.path) uid=\(owned.identity.st_uid) dev=\(owned.identity.st_dev) inode=\(owned.identity.st_ino) mode=700 nosymlink=true")
            business = .success(try await body(created))
        } catch { business = .failure(error) }
        var cleanupErrors: [Error] = []
        if let fixture {
            // No cancellation here: cancelling the observed queued Task would
            // manufacture the negative's result. Join the real submitted work.
            for handle in fixture.handles { await handle.value }
            let usageJoined = await fixture.usage.waitForPersistence()
            print("TERMINAL_QUEUE_JOIN capturedHandles=\(fixture.handles.count) allCapturedActualFinished=true usageSuccess=\(usageJoined)")
            if !usageJoined {
                cleanupErrors.append(FixtureFailure(stage: "Usage persistence join", code: EIO))
            }
            if fixture.unjoinedSubmission {
                // This is a qualification failure, not a lifecycle result.
                // A missing private handle must never permit root deletion.
                if Darwin.close(owned.rootFD) != 0 {
                    cleanupErrors.append(FixtureFailure(stage: "close retained root FD", code: errno))
                }
                if Darwin.close(owned.parentFD) != 0 {
                    cleanupErrors.append(FixtureFailure(stage: "close retained parent FD", code: errno))
                }
                cleanupErrors.append(FixtureFailure(stage: "submitted handle not captured; root retained", code: EBUSY))
                print("TERMINAL_QUEUE_ROOT_RETAINED unjoinedSubmission=true ENOENT=false root=\(owned.url.path)")
                switch business {
                case .success: throw FixtureFailures(business: nil, cleanup: cleanupErrors)
                case .failure(let original): throw FixtureFailures(business: original, cleanup: cleanupErrors)
                }
            }
        }
        if lockAdmitted {
            do { try removeOwnedUsageLock(lockPath, formal: owned.formal) }
            catch { cleanupErrors.append(error) }
        }
        if suiteAdmitted {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if UserDefaults.standard.persistentDomain(forName: suite) != nil {
                cleanupErrors.append(FixtureFailure(stage: "owned preferences removal", code: EIO))
            }
        }
        let combined: Result<T, Error>
        if cleanupErrors.isEmpty { combined = business }
        else {
            switch business {
            case .success: combined = .failure(FixtureFailures(business: nil, cleanup: cleanupErrors))
            case .failure(let original): combined = .failure(FixtureFailures(business: original, cleanup: cleanupErrors))
            }
        }
        return try owned.finish(combined)
    }

    /// The exact @Observable backing label is a qualification precondition.
    /// No fallback label, scan-by-type or silent absence is accepted.
    private func observedExecutionHandle(_ store: TerminalStore, required: Bool) throws -> Task<Void, Never>? {
        let mirror = Mirror(reflecting: store)
        let fields = mirror.children.filter { $0.label == "_activeExecutionTask" }
        print("TERMINAL_QUEUE_MIRROR sourceProperty=activeExecutionTask expectedLabel=_activeExecutionTask actualLabels=\(mirror.children.compactMap(\.label).joined(separator: ","))")
        let field = try #require(fields.count == 1 ? fields.first : nil)
        try #require(ObjectIdentifier(type(of: field.value)) == ObjectIdentifier(Optional<Task<Void, Never>>.self))
        let payload = Array(Mirror(reflecting: field.value).children)
        if required {
            let child = try #require(payload.count == 1 ? payload.first : nil)
            let handle = try #require(child.value as? Task<Void, Never>)
            print("TERMINAL_QUEUE_HANDLE label=\(field.label ?? "nil") type=Task<Void,Never> captured=true")
            return handle
        }
        try #require(payload.isEmpty)
        return nil
    }

    private func makeStore(_ fixture: Fixture, phase: String) -> TerminalStore {
        TerminalStore(contextSnapshot: TerminalContextSnapshot(
            sessionID: "owned-terminal-\(phase)", turnID: "owned-turn-\(phase)",
            taskID: "owned-task-\(phase)", projectID: "owned-project-\(fixture.nonce)",
            workdir: fixture.root.path
        ), settings: fixture.settings)
    }

    private func submit(_ store: TerminalStore, fixture: Fixture, phase: String) throws {
        // Whitelisted formal runner uses scratch HOME and no inherited env;
        // absolute Python avoids a PATH-selected interpreter or shell alias.
        let raw = "/usr/bin/python3 -B lifecycle_worker.py \(phase) \(fixture.nonce)"
        let classification = MinisCanvasApp.TerminalGuard.classify(raw, policy: fixture.settings.terminalPolicySnapshot)
        try #require(classification.kind == .confirmation)
        store.input = raw
        // A post-submit qualification failure conservatively retains the root
        // until the exact Task was captured; no guessed completion is accepted.
        fixture.unjoinedSubmission = true
        store.submit()
        let confirmation = try #require(store.pendingConfirmation)
        try #require(confirmation.raw == raw)
        store.confirmPending()
        print("TERMINAL_QUEUE_SUBMIT phase=\(phase) command=\(raw) cwd=\(fixture.root.path) sameMainActor=true")
        try #require(store.isRunning)
    }

    private struct OwnedProcess: Decodable {
        let nonce: String
        let phase: String
        let pid: Int32
        let group: Int32
        let uid: UInt32
        let rootDevice: UInt64
        let rootInode: UInt64
    }

    private func readAndVerifyOwnedProcess(_ fixture: Fixture, phase: String) throws -> OwnedProcess {
        let url = fixture.root.appendingPathComponent("\(phase).pid.json")
        let data = try Data(contentsOf: url)
        print("TERMINAL_QUEUE_OWNED_JSON phase=\(phase) json=\(String(decoding: data, as: UTF8.self))")
        let record = try JSONDecoder().decode(OwnedProcess.self, from: data)
        var rootIdentity = stat()
        let rootStatResult = fixture.root.path.withCString { lstat($0, &rootIdentity) }
        try #require(rootStatResult == 0)
        try #require(record.nonce == fixture.nonce && record.phase == phase)
        try #require(record.uid == geteuid())
        try #require(record.rootDevice == UInt64(rootIdentity.st_dev) && record.rootInode == UInt64(rootIdentity.st_ino))
        // Only signed-in-fixture IDs may receive signal 0 (observation only).
        // Never inspect PID42070, our own process/group, or any discovered PID.
        try #require(record.pid > 1 && record.group > 1)
        try #require(record.pid != 42070 && record.group != 42070)
        try #require(record.pid != getpid() && record.group != getpgrp())
        return record
    }

    private func verifyOwnedProcessesGone(_ record: OwnedProcess) {
        let pidResult = Darwin.kill(record.pid, 0)
        let pidCode = errno
        let groupResult = Darwin.kill(-record.group, 0)
        let groupCode = errno
        print("TERMINAL_QUEUE_OWNED_REAP pid=\(record.pid) pidResult=\(pidResult) pidErrno=\(pidCode) group=\(record.group) groupResult=\(groupResult) groupErrno=\(groupCode) observedAfterHandleJoin=true")
        #expect(pidResult == -1 && pidCode == ESRCH)
        #expect(groupResult == -1 && groupCode == ESRCH)
    }

    private func runPositive(_ fixture: Fixture, phase: String) async throws {
        let store = makeStore(fixture, phase: phase)
        _ = try observedExecutionHandle(store, required: false)
        try submit(store, fixture: fixture, phase: phase)
        let handle = try #require(try observedExecutionHandle(store, required: true))
        fixture.handles.append(handle)
        fixture.unjoinedSubmission = false
        await handle.value
        print("TERMINAL_QUEUE_POSITIVE phase=\(phase) output=\(String(reflecting: store.output)) actualHandleJoined=true")
        try #require(!store.isRunning)
        try #require(store.output.contains("（退出码 0）"))
        let marker = try String(contentsOf: fixture.root.appendingPathComponent("\(phase).sentinel"), encoding: .utf8)
        try #require(marker == "\(fixture.nonce):\(phase)")
        verifyOwnedProcessesGone(try readAndVerifyOwnedProcess(fixture, phase: phase))
    }

    /// Entire function is synchronous on MainActor: no yield between actual
    /// confirmPending -> run -> capture and dropping the only Store reference.
    private func queueAndRelease(_ fixture: Fixture) throws -> (Task<Void, Never>, Bool) {
        var store: TerminalStore? = makeStore(fixture, phase: "queued")
        weak let weakStore = store
        _ = try observedExecutionHandle(store!, required: false)
        try submit(store!, fixture: fixture, phase: "queued")
        let handle = try #require(try observedExecutionHandle(store!, required: true))
        fixture.handles.append(handle)
        fixture.unjoinedSubmission = false
        store = nil
        let deinitialized = weakStore == nil
        print("TERMINAL_QUEUE_RELEASE weakStoreNil=\(deinitialized) noAwaitOrYieldBeforeRelease=true taskCancelledAtRelease=\(handle.isCancelled)")
        return (handle, deinitialized)
    }

    @Test
    func queuedOwnedSubmissionCannotExecuteAfterStoreRelease() async throws {
        try await withFixture { fixture in
            try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
            try #require(fixture.settings.safetyRuntimeSnapshot.isEnabled(.browserTerminalSideEffects))
            let script = """
            import json, os, pathlib, sys
            phase, nonce = sys.argv[1:]
            assert phase in ('positive', 'queued', 'successor')
            root = pathlib.Path.cwd()
            identity = root.stat()
            record = dict(nonce=nonce, phase=phase, pid=os.getpid(), group=os.getpgid(0), uid=os.geteuid(), rootDevice=identity.st_dev, rootInode=identity.st_ino)
            fd = os.open(phase + '.pid.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump(record, stream, sort_keys=True)
            fd = os.open(phase + '.sentinel', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(nonce + ':' + phase)
            print('OWNED_TERMINAL_FINISHED:' + phase)
            """
            try Data(script.utf8).write(to: fixture.root.appendingPathComponent("lifecycle_worker.py"), options: .withoutOverwriting)
            try await runPositive(fixture, phase: "positive")
            let (queued, deinitialized) = try queueAndRelease(fixture)
            // Always join, including when the weak-lifetime qualification fails.
            await queued.value
            print("TERMINAL_QUEUE_NEGATIVE actualHandleJoined=true taskCancelled=\(queued.isCancelled)")
            try #require(deinitialized)
            let markerExists = FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("queued.sentinel").path)
            let processRecordExists = FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("queued.pid.json").path)
            print("TERMINAL_QUEUE_EFFECT markerExists=\(markerExists) processRecordExists=\(processRecordExists)")
            #expect(!markerExists)
            #expect(!processRecordExists)
            if processRecordExists {
                // Retain public owned evidence in raw before strict root cleanup.
                verifyOwnedProcessesGone(try readAndVerifyOwnedProcess(fixture, phase: "queued"))
            }
            try await runPositive(fixture, phase: "successor")
        }
    }
}
