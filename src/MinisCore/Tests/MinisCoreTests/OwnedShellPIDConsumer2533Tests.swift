import Darwin
import Foundation
import Testing
@testable import MinisCore

/// Explicit test custody for the existing non-Sendable production executor,
/// like the original bound-executor consumers. This fixture never changes its
/// configuration; A's physical PID/group must be gone before B is launched.
/// It does not declare BuiltinToolExecutor or arbitrary callers race-free.
private final class Shell2533BuiltinOwner: @unchecked Sendable {
    let builtin: BuiltinToolExecutor
    init(root: URL) { builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: []) }
}

/// The production child-resource guard deliberately forbids shell_execute.
/// These are actual Builtin shell invocations, not a fabricated child grant or
/// an assertion that the child global permit has been exercised by a shell.
@Suite("D-CONC2 actual Builtin owned PID terminal and next invocation", .serialized)
struct OwnedShellPIDConsumer2533Tests: Sendable {
    private struct OwnedProcess: Decodable, Sendable {
        let pid: Int32
        let group: Int32
    }
    enum Terminal: String, Sendable, CaseIterable {
        case cancelled, shellTimeout, operationTimeout
    }

    private func setup() throws -> URL {
        let root = try minisCoreToolContractRoot("owned-shell2533")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let script = """
        import json, os, sys, time
        name = sys.argv[1]
        with open(name + '.partial', 'w') as f:
            json.dump({'pid': os.getpid(), 'group': os.getpgid(0)}, f)
        os.replace(name + '.partial', name + '.json')
        print('SYNTHETIC_2533_' + name + '_READY', flush=True)
        deadline = time.monotonic() + 8
        while not os.path.exists(name + '.release') and time.monotonic() < deadline:
            time.sleep(0.01)
        if not os.path.exists(name + '.release'):
            sys.exit(23)
        print('SYNTHETIC_2533_' + name + '_FINISHED', flush=True)
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("worker.py"))
        return root
    }

    private func exists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func until(_ duration: Duration = .seconds(3),
                       _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func manifest(_ root: URL, name: String) async throws -> OwnedProcess {
        let file = root.appendingPathComponent(name + ".json")
        let ready = await until { FileManager.default.fileExists(atPath: file.path) }
        try #require(ready, "the actual shell must publish its owned PID before the lifecycle oracle runs")
        let process = try JSONDecoder().decode(OwnedProcess.self, from: Data(contentsOf: file))
        try #require(process.pid > 1 && process.group > 1 && process.group != getpgrp())
        try #require(exists(process.pid) && exists(process.group) && exists(-process.group),
                     "the real worker and private group leader must be live before timeout or cancellation")
        return process
    }

    private func release(_ root: URL, name: String) throws {
        try Data().write(to: root.appendingPathComponent(name + ".release"))
    }

    private func expectSuccess(_ output: String, name: String) throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["exit_code"] as? Int == 0)
        #expect(object["stdout"] as? String == "SYNTHETIC_2533_" + name + "_READY\nSYNTHETIC_2533_" + name + "_FINISHED\n")
        #expect(object["stderr"] as? String == "")
    }

    @Test
    func successfulOwnedProcessIsActuallyReaped() async throws {
        let root = try setup()
        let owner = Shell2533BuiltinOwner(root: root)
        let work = Task {
            try await owner.builtin.execute(name: "shell_execute", input: [
                "command": "/usr/bin/python3 worker.py control", "timeout": 6
            ])
        }
        defer { work.cancel(); try? release(root, name: "control") }
        let process = try await manifest(root, name: "control")
        try release(root, name: "control")
        try expectSuccess(await work.value, name: "control")
        let gone = await until { !exists(process.pid) && !exists(process.group) && !exists(-process.group) }
        #expect(gone, "success must include actual owned-process and private-group disappearance")
    }

    @Test(arguments: Terminal.allCases)
    func oldTerminalCannotKillNextOwnedInvocation(terminal: Terminal) async throws {
        let root = try setup()
        let owner = Shell2533BuiltinOwner(root: root)
        let old = Task {
            if terminal == .operationTimeout {
                return try await executeToolWithTimeout(name: "shell_execute", timeout: 0.5) {
                    try await owner.builtin.execute(name: "shell_execute", input: [
                        "command": "/usr/bin/python3 worker.py A", "timeout": 1.5
                    ])
                }
            }
            return try await owner.builtin.execute(name: "shell_execute", input: [
                "command": "/usr/bin/python3 worker.py A", "timeout": terminal == .shellTimeout ? 1 : 1.5
            ])
        }
        defer { old.cancel(); try? release(root, name: "A") }
        let previous = try await manifest(root, name: "A")
        if terminal == .cancelled { old.cancel() }
        do {
            _ = try await old.value
            Issue.record("an actually live A must fail under its requested terminal condition")
        } catch is CancellationError {
            #expect(terminal == .cancelled)
        } catch let error as ToolExecutorError {
            switch error {
            case .shellTimeout: #expect(terminal == .shellTimeout)
            case .toolTimeout: #expect(terminal == .operationTimeout)
            default: Issue.record("unexpected actual shell error: \(error)")
            }
        }
        // The outer tool race may publish first; physical reclamation is a
        // separate bounded assertion, not inferred from that logical error.
        let oldGone = await until { !exists(previous.pid) && !exists(previous.group) && !exists(-previous.group) }
        try #require(oldGone, "A's actual owned PID/group must disappear before reusing its Builtin owner")
        let fresh = Task {
            try await owner.builtin.execute(name: "shell_execute", input: [
                "command": "/usr/bin/python3 worker.py B", "timeout": 6
            ])
        }
        defer { fresh.cancel(); try? release(root, name: "B") }
        let next = try await manifest(root, name: "B")
        try #require(next.pid != previous.pid && next.group != previous.group,
                     "this bounded test requires two distinct real invocations, not simulated PID reuse")
        old.cancel()
        old.cancel()
        // Keep B live beyond A's original 1.5s shell deadline. This observes
        // real late timer/cancel effects on a reused owner, without pretending
        // that distinct PIDs prove kernel PID-reuse protection.
        try await Task.sleep(for: .milliseconds(1700))
        #expect(exists(next.pid) && exists(next.group) && exists(-next.group))
        #expect(!exists(previous.pid) && !exists(-previous.group))
        try release(root, name: "B")
        try expectSuccess(await fresh.value, name: "B")
        let nextGone = await until { !exists(next.pid) && !exists(next.group) && !exists(-next.group) }
        #expect(nextGone)
    }
}
