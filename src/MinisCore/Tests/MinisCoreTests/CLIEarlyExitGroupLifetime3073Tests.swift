import Darwin
import Foundation
import Testing
@testable import MinisCore

/// Actual CLI invocation with an exited leader and a live pipe-owning helper.
/// This is distinct from the existing fixture whose leader waits for its helper.
@Suite("D-CONC3 CLI exited leader retains owned pipe group", .serialized)
struct CLIEarlyExitGroupLifetime3073Tests: Sendable {
    enum Terminal: Sendable, CaseIterable {
        case timeout, runnerCancellation, taskCancellation
    }

    private struct Manifest: Decodable, Sendable {
        let leader: Int32
        let helper: Int32
        let group: Int32
    }

    private func setup() throws -> URL {
        let root = try minisCoreToolContractRoot("cli-early-exit3073")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let helper = """
        import json, os, sys, time
        name, leader = sys.argv[1], int(sys.argv[2])
        with open(name + '.partial', 'w') as f:
            json.dump({'leader': leader, 'helper': os.getpid(), 'group': os.getpgid(0)}, f)
        os.replace(name + '.partial', name + '.json')
        print('SYNTHETIC_3073_' + name + '_READY', flush=True)
        deadline = time.monotonic() + 10
        while not os.path.exists(name + '.helper-release') and time.monotonic() < deadline:
            time.sleep(0.01)
        if not os.path.exists(name + '.helper-release'):
            sys.exit(23)
        print('SYNTHETIC_3073_' + name + '_FINISHED', flush=True)
        """
        let launcher = """
        #!/usr/bin/python3
        import os, subprocess, sys, time
        name = sys.argv[-1]
        subprocess.Popen(['/usr/bin/python3', 'helper.py', name, str(os.getpid())])
        deadline = time.monotonic() + 10
        while not os.path.exists(name + '.leader-release') and time.monotonic() < deadline:
            time.sleep(0.01)
        if not os.path.exists(name + '.leader-release'):
            sys.exit(24)
        """
        try helper.write(to: root.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("launcher.py")
        try launcher.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return root
    }

    private func exists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func until(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func release(_ root: URL, name: String, part: String) throws {
        try Data().write(to: root.appendingPathComponent(name + "." + part + "-release"))
    }

    private func exitedLeader(_ root: URL, name: String) async throws -> Manifest {
        let file = root.appendingPathComponent(name + ".json")
        let ready = await until { FileManager.default.fileExists(atPath: file.path) }
        try #require(ready, "the actual CLI helper must publish ownership before judging cancellation")
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        try #require(value.leader > 1 && value.helper > 1 && value.group == value.leader)
        try #require(value.group != getpgrp() && exists(value.leader) && exists(value.helper))
        try release(root, name: name, part: "leader")
        let gone = await until { !exists(value.leader) }
        try #require(gone, "the leader must actually exit before the pipe-owning helper's terminal oracle")
        try #require(exists(value.helper) && exists(-value.group))
        return value
    }

    private func expectSuccess(_ output: String, name: String) {
        #expect(output == "SYNTHETIC_3073_" + name + "_READY\nSYNTHETIC_3073_" + name + "_FINISHED\n")
    }

    @Test
    func exitedLeaderStillAllowsLegitimateHelperOutput() async throws {
        let root = try setup()
        let runner = CodexAgentRunner(binaryPath: root.appendingPathComponent("launcher.py").path,
                                     workingDirectory: root, timeoutSeconds: 6)
        let task = SubAgentTask(id: "control3073", title: "synthetic", instructions: "control",
                                executionID: "control3073-\(UUID().uuidString)")
        let invocation = Task { try await runner.run(task: task) }
        defer { invocation.cancel(); try? release(root, name: "control", part: "leader");
                try? release(root, name: "control", part: "helper") }
        let process = try await exitedLeader(root, name: "control")
        try release(root, name: "control", part: "helper")
        expectSuccess(try await invocation.value, name: "control")
        let gone = await until { !exists(process.helper) && !exists(-process.group) }
        #expect(gone)
    }

    @Test(arguments: Terminal.allCases)
    func oldTerminalReclaimsExitedLeadersHelperWithoutTouchingNextInvocation(terminal: Terminal) async throws {
        let root = try setup()
        let oldRunner = CodexAgentRunner(binaryPath: root.appendingPathComponent("launcher.py").path,
                                        workingDirectory: root, timeoutSeconds: 4)
        // The same human task ID has distinct per-invocation execution IDs.
        let oldTask = SubAgentTask(id: "same-visible-task3073", title: "synthetic", instructions: "A",
                                   executionID: "old3073-\(UUID().uuidString)")
        let old = Task { try await oldRunner.run(task: oldTask) }
        defer { old.cancel(); try? release(root, name: "A", part: "leader");
                try? release(root, name: "A", part: "helper") }
        let previous = try await exitedLeader(root, name: "A")
        if terminal == .runnerCancellation { await oldRunner.cancel(task: oldTask) }
        if terminal == .taskCancellation { old.cancel() }
        do {
            _ = try await old.value
            Issue.record("a still-live pipe invocation cannot publish its exited leader's success after a terminal")
        } catch is CancellationError {
            #expect(terminal != .timeout)
        } catch let error as ExternalAgentError {
            #expect(terminal == .timeout)
            #expect(error == .timeout(oldRunner.binaryPath))
        }
        let reclaimed = await until { !exists(previous.helper) && !exists(-previous.group) }
        try #require(reclaimed, "terminal publication must include actual private helper/group reclamation")

        let nextRunner = CodexAgentRunner(binaryPath: oldRunner.binaryPath, workingDirectory: root, timeoutSeconds: 9)
        let nextTask = SubAgentTask(id: oldTask.id, title: "synthetic", instructions: "B",
                                    executionID: "next3073-\(UUID().uuidString)")
        try #require(oldTask.executionID != nextTask.executionID)
        let next = Task { try await nextRunner.run(task: nextTask) }
        defer { next.cancel(); try? release(root, name: "B", part: "leader");
                try? release(root, name: "B", part: "helper") }
        let fresh = try await exitedLeader(root, name: "B")
        try #require(fresh.group != previous.group && fresh.helper != previous.helper)
        await oldRunner.cancel(task: oldTask)
        await oldRunner.cancel(task: oldTask)
        // The previous four-second watchdog deadline has also passed while B
        // remains an actually live pipe invocation, not a registry-only model.
        try await Task.sleep(for: .milliseconds(4200))
        #expect(exists(fresh.helper) && exists(-fresh.group))
        #expect(!exists(previous.helper) && !exists(-previous.group))
        try release(root, name: "B", part: "helper")
        expectSuccess(try await next.value, name: "B")
        let gone = await until { !exists(fresh.helper) && !exists(-fresh.group) }
        #expect(gone)
    }
}
