import Darwin
import Foundation
import Testing
@testable import MinisCore

/// One immutable Builtin owner, used only by its one captured execution Task.
/// This test custody does not make the production executor generally Sendable.
private final class App12ShellTestOwner: @unchecked Sendable {
    let builtin: BuiltinToolExecutor

    init(root: URL) {
        builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
    }
}

@Suite("APP12 cancellation reclaims the existing private shell group", .serialized)
struct App12CancellationReapsProcessGroupTests: Sendable {
    private struct OwnedProcess: Decodable, Sendable {
        let pid: Int32
        let group: Int32
        let uid: UInt32
    }

    private func exists(_ pidOrGroup: Int32) -> Bool {
        Darwin.kill(pidOrGroup, 0) == 0 || errno == EPERM
    }

    private func makeRoot(ignoresTERM: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app12-exit-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let worker = """
        import json, os, signal, time
        ignore_term = \(ignoresTERM ? "True" : "False")
        def on_term(signum, frame):
            with open('term-observed.json', 'w') as f:
                json.dump({'signal': signum, 'pid': os.getpid()}, f)
                f.flush()
                os.fsync(f.fileno())
            if not ignore_term:
                raise SystemExit(0)
        signal.signal(signal.SIGTERM, on_term)
        with open('owned.partial', 'w') as f:
            json.dump({'pid': os.getpid(), 'group': os.getpgrp(), 'uid': os.geteuid()}, f)
        os.replace('owned.partial', 'owned.json')
        # A broken cancellation cannot leave an unbounded fixture behind.
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            time.sleep(0.01)
        """
        try Data(worker.utf8).write(to: root.appendingPathComponent("app12_exit_worker.py"))
        return root
    }

    private func ready(_ root: URL) async throws -> OwnedProcess {
        let path = root.appendingPathComponent("owned.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: path.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: path.path),
                     "the real worker must publish its PID/group before cancellation")
        let actual = try JSONDecoder().decode(OwnedProcess.self, from: Data(contentsOf: path))
        try #require(actual.pid > 1 && actual.group > 1 && actual.uid == geteuid())
        try #require(actual.group != getpgrp(), "never signal or infer ownership of the test runner group")
        try #require(exists(actual.pid) && exists(-actual.group),
                     "the original worker and its private process group must actually be live")
        return actual
    }

    private func runCancellation(ignoresTERM: Bool) async throws {
        let root = try makeRoot(ignoresTERM: ignoresTERM)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = App12ShellTestOwner(root: root)
        let work = Task {
            try await owner.builtin.execute(name: "shell_execute", input: [
                "command": "/usr/bin/python3 app12_exit_worker.py", "timeout": 8
            ])
        }
        let actual: OwnedProcess
        do {
            actual = try await ready(root)
        } catch {
            work.cancel()
            _ = try? await work.value
            throw error
        }
        let began = ContinuousClock.now
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("cancelled production shell must publish cancellation, not success")
        } catch is CancellationError {
            // The original production executor owns TERM/KILL and waitpid.
        } catch {
            Issue.record("unexpected terminal result from the actual Builtin owner: \(error)")
        }
        let elapsed = began.duration(to: ContinuousClock.now)
        #expect(elapsed <= .seconds(3), "exit cancellation must remain bounded to three seconds")
        #expect(!exists(actual.pid), "the original worker cannot survive the tool's terminal return")
        #expect(!exists(-actual.group), "the private group must be physically gone, not merely logically cancelled")
        if ignoresTERM {
            let marker = root.appendingPathComponent("term-observed.json")
            #expect(FileManager.default.fileExists(atPath: marker.path),
                    "TERM must reach the actual worker before KILL; direct KILL skips the approved grace path")
            if FileManager.default.fileExists(atPath: marker.path) {
                let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Int])
                #expect(object["signal"] == Int(SIGTERM) && object["pid"] == Int(actual.pid))
            }
        }
    }

    @Test
    func cancellationReapsLongRunningShellBeforeReturning() async throws {
        try await runCancellation(ignoresTERM: false)
    }

    @Test
    func termIgnoringShellReceivesTERMThenIsKilledAndReapedWithinThreeSeconds() async throws {
        try await runCancellation(ignoresTERM: true)
    }
}
