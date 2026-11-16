import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("B1407 normal Terminal output with a finite owned descendant", .serialized)
struct TerminalSuccessfulDescendantOutputB1407Tests {
    @Test("normal success keeps complete parent and descendant stdout and stderr")
    func normalSuccessPreservesCompleteDescendantOutput() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("B1407-success-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let script = #"""
        import json, os, sys, time

        def publish(name, value):
            temporary = name + ".partial"
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(value, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, name)

        print("PARENT_STDOUT_BEGIN", flush=True)
        print("PARENT_STDERR_BEGIN", file=sys.stderr, flush=True)
        child = os.fork()
        if child == 0:
            # A finite same-group child, not a detached daemon. No signal or
            # independent controller is involved, even on a broken pipe.
            try:
                time.sleep(0.25)
                print("CHILD_STDOUT_" + "o" * 512, flush=True)
                print("CHILD_STDERR_" + "e" * 512, file=sys.stderr, flush=True)
            except BaseException:
                os._exit(1)
            os._exit(0)
        publish("pids.json", {"parent": os.getpid(), "child": child,
                              "uid": os.geteuid(), "group": os.getpgrp()})
        waited, status = os.waitpid(child, 0)
        publish("child-reaped.json", {"pid": waited, "status": status,
                                      "actual_waitpid_of_own_child": True})
        if waited != child or status != 0:
            sys.exit(1)
        print("PARENT_STDOUT_END", flush=True)
        print("PARENT_STDERR_END", file=sys.stderr, flush=True)
        """#
        let worker = root.appendingPathComponent("worker.py")
        try Data(script.utf8).write(to: worker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
        let context = TerminalExecutionContext(sessionID: "B1407-session", turnID: "B1407-turn",
            taskID: "B1407-task", projectID: "B1407-project", workdir: root.path)
        let command = "/usr/bin/python3 worker.py"
        let request = TerminalExecutionRequest(capabilityID: "shell_execute", command: command,
                                               context: context, timeout: .seconds(8))
        let approved = TerminalExecutionRequest(capabilityID: request.capabilityID, command: command,
            context: context, approval: TerminalApproval(scopeID: context.projectID,
                requestFingerprint: request.requestFingerprint, expiresAt: Date().addingTimeInterval(60)),
            timeout: request.timeout)
        let boundary = TerminalBoundary(policy: TerminalPolicy(scopeID: context.projectID, allowedRoot: root))
        let receipt = await boundary.execute(approved)

        let expectedOut = "PARENT_STDOUT_BEGIN\nCHILD_STDOUT_" + String(repeating: "o", count: 512)
            + "\nPARENT_STDOUT_END\n"
        let expectedErr = "PARENT_STDERR_BEGIN\nCHILD_STDERR_" + String(repeating: "e", count: 512)
            + "\nPARENT_STDERR_END\n"
        // The complete two-stream fixture is below the receipt's 4096-character
        // cap, so whole equality proves completeness rather than truncation.
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output == expectedOut + "\n" + expectedErr)
        let pids = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("pids.json"))) as? [String: Any])
        let reaped = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("child-reaped.json"))) as? [String: Any])
        let parent = try #require((pids["parent"] as? NSNumber)?.int32Value)
        let child = try #require((pids["child"] as? NSNumber)?.int32Value)
        #expect(parent > 1 && child > 1 && parent != child)
        #expect((pids["uid"] as? NSNumber)?.uint32Value == geteuid())
        #expect((reaped["pid"] as? NSNumber)?.int32Value == child)
        #expect((reaped["status"] as? NSNumber)?.intValue == 0)
        #expect(reaped["actual_waitpid_of_own_child"] as? Bool == true)
        print("B1407_SUCCESS_DESCENDANT parent=\(parent) child=\(child) trueChildWait=true outputBytes=\(receipt.output.utf8.count) evidence=\(root.path)")
        // Preserve source, PID/wait proof, and output evidence for the SDK owner.
    }
}
