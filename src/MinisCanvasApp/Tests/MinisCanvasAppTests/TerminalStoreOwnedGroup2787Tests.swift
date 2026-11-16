import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Exercises the visible terminal's production Store -> adapter -> POSIX runner
/// path. The worker and its child are created only inside this disposable root.
@Suite("D-TERMINAL-06 visible owned process group", .serialized)
@MainActor
struct TerminalStoreOwnedGroup2787Tests {
    private struct OwnedPIDs: Decodable {
        let parent: Int32
        let child: Int32
        let group: Int32
    }

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

    @MainActor
    private final class OwnedFixture {
        let owned: OwnedRoot
        var stores: [TerminalStore] = []
        init(owned: OwnedRoot) { self.owned = owned }
        func store(in directory: URL) -> TerminalStore {
            let result = TerminalStore(contextSnapshot: TerminalContextSnapshot(
                sessionID: "terminal2787-session", turnID: "terminal2787-turn",
                taskID: "terminal2787-task", projectID: "terminal2787-project",
                workdir: directory.path
            ))
            stores.append(result)
            return result
        }
        func stopAndJoin() async throws {
            var handles: [Task<Void, Never>] = []
            for store in stores {
                let fields = Mirror(reflecting: store).children.filter { $0.label == "_activeExecutionTask" }
                let field = try #require(fields.count == 1 ? fields.first : nil)
                try #require(ObjectIdentifier(type(of: field.value)) == ObjectIdentifier(Optional<Task<Void, Never>>.self))
                let payload = Array(Mirror(reflecting: field.value).children)
                if !payload.isEmpty {
                    let child = try #require(payload.count == 1 ? payload.first : nil)
                    let handle = try #require(child.value as? Task<Void, Never>)
                    handles.append(handle)
                }
                store.stop()
            }
            for handle in handles { await handle.value }
            print("TERMINAL2787_ACTUAL_TASK_JOIN stores=\(stores.count) activeCaptured=\(handles.count) finished=true")
        }
    }

    private func withOwnedDirectory(_ body: @MainActor (OwnedFixture, URL) async throws -> Void) async throws {
        let owned = try OwnedRoot.make()
        let fixture = OwnedFixture(owned: owned)
        let business: Result<Void, Error>
        do {
            try owned.validate()
            print("TERMINAL2787_ROOT root=\(owned.url.path) uid=\(owned.identity.st_uid) dev=\(owned.identity.st_dev) inode=\(owned.identity.st_ino) mode=700")
            try await body(fixture, owned.url)
            business = .success(())
        } catch { business = .failure(error) }
        do { try await fixture.stopAndJoin() }
        catch {
            print("TERMINAL2787_ROOT_RETAINED actualTaskJoinQualification=false root=\(owned.url.path)")
            _ = Darwin.close(owned.rootFD)
            _ = Darwin.close(owned.parentFD)
            switch business {
            case .success: throw FixtureFailures(business: nil, cleanup: [error])
            case .failure(let original): throw FixtureFailures(business: original, cleanup: [error])
            }
        }
        try owned.finish(business)
    }

    private func wait(
        seconds: TimeInterval = 5,
        until condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func exists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    @Test func visibleStopReapsOwnedChildBeforeCancellationAndKeepsNextRunClean() async throws {
        try await withOwnedDirectory { fixture, directory in
        let script = """
        import json, os, subprocess, sys, time
        child = subprocess.Popen([sys.executable, "-c", "import pathlib,time; time.sleep(3); pathlib.Path('late-child.txt').write_text('late')"])
        with open('pids.partial', 'w') as file:
            json.dump({'parent': os.getpid(), 'child': child.pid, 'group': os.getpgid(0)}, file)
        os.replace('pids.partial', 'pids.json')
        while True:
            sys.stdout.write('old-stdout-界\\n'); sys.stdout.flush()
            sys.stderr.write('old-stderr-界\\n'); sys.stderr.flush()
            time.sleep(0.02)
        """
        try Data(script.utf8).write(to: directory.appendingPathComponent("worker.py"))
        let terminal = fixture.store(in: directory)
        defer { terminal.stop() }

        terminal.input = "python3 worker.py"
        terminal.submit()
        #expect(terminal.pendingConfirmation != nil)
        terminal.confirmPending()
        let ready = await wait {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("pids.json").path)
        }
        guard ready else {
            terminal.stop()
            let settled = await wait { !terminal.isRunning }
            #expect(settled)
            Issue.record("Visible terminal worker did not publish owned PIDs")
            return
        }
        let owned = try JSONDecoder().decode(
            OwnedPIDs.self, from: Data(contentsOf: directory.appendingPathComponent("pids.json"))
        )
        #expect(owned.parent > 0 && owned.child > 0 && owned.group > 0)
        #expect(owned.group != getpgrp())
        #expect(exists(owned.child))

        terminal.stop()
        let settled = await wait { !terminal.isRunning }
        #expect(settled)
        #expect(terminal.output.contains("错误：命令已取消"))
        #expect(!terminal.output.contains("（退出码 0）"))
        #expect(!terminal.output.contains("old-stdout-界"))
        #expect(!terminal.output.contains("old-stderr-界"))
        let reaped = await wait(seconds: 2) {
            !exists(-owned.group) && !exists(owned.parent) && !exists(owned.child)
        }
        #expect(reaped)

        terminal.input = "echo fresh-2787"
        terminal.submit()
        let freshFinished = await wait { !terminal.isRunning }
        #expect(freshFinished)
        #expect(terminal.output.contains("fresh-2787\n（退出码 0）"))
        #expect(terminal.output.components(separatedBy: "错误：命令已取消").count == 2)
        // The owned child would have created this file after three seconds if
        // stop() had only cancelled the visible parent or detached its pipes.
        try? await Task.sleep(for: .seconds(3.2))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-child.txt").path))
    }

    }

    @Test func visibleOutputHasBoundedUnicodeProjectionAndRealExit() async throws {
        try await withOwnedDirectory { fixture, directory in
        let script = """
        import sys
        sys.stdout.write('visible-utf8-界\\n' + '界' * 10000)
        sys.stdout.flush()
        sys.stderr.write('visible-stderr-界\\n' + 'ordinary' * 10000)
        sys.stderr.flush()
        sys.exit(17)
        """
        try Data(script.utf8).write(to: directory.appendingPathComponent("worker.py"))
        let terminal = fixture.store(in: directory)
        defer { terminal.stop() }

        terminal.input = "python3 worker.py"
        terminal.submit()
        #expect(terminal.pendingConfirmation != nil)
        terminal.confirmPending()
        let finished = await wait { !terminal.isRunning }
        #expect(finished)
        #expect(terminal.output.contains("visible-utf8-界"))
        #expect(terminal.output.contains("[truncated]"))
        #expect(terminal.output.contains("（退出码 17）"))
        #expect(!terminal.output.contains("错误：命令已取消"))
        #expect(terminal.output.count < 5_000)
    }
    }
}
