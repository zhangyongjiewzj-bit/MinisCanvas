import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class WP3TerminalCountingRunner: TerminalProcessRunner, @unchecked Sendable {
    private(set) var invocationCount = 0
    var delay: Duration?

    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        invocationCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return TerminalProcessResult(exitCode: 0, stdout: "terminal-ok", stderr: "")
    }
}

@Suite("WP-3 terminal context production consumer")
@MainActor
struct WP3TerminalContextProductionConsumerTests {
    @Test
    func currentSnapshotUsesActiveSessionAndExecutionIdentity() throws {
        let root = try makeRoot("alpha")
        defer { try? FileManager.default.removeItem(at: root) }

        let chat = ChatStore()
        chat.newSession(
            projectID: "project-alpha",
            projectName: "Alpha",
            workingDirectory: root.path
        )
        let sessionID = try #require(chat.activeSessionID)
        chat.markExecutionRunning(sessionID: sessionID, turnID: 7, taskID: "task-alpha")

        let snapshot = try #require(TerminalContextSnapshot.current(from: chat))
        #expect(snapshot.sessionID == sessionID.uuidString)
        #expect(snapshot.turnID == "7")
        #expect(snapshot.taskID == "task-alpha")
        #expect(snapshot.projectID == "project-alpha")
        #expect(snapshot.workdir == root.path)
        #expect(snapshot.scopeID == "project-alpha")
    }

    @Test
    func switchingSessionTurnTaskAndProjectChangesBoundaryIdentity() throws {
        let alphaRoot = try makeRoot("alpha")
        let betaRoot = try makeRoot("beta")
        defer {
            try? FileManager.default.removeItem(at: alphaRoot)
            try? FileManager.default.removeItem(at: betaRoot)
        }

        let chat = ChatStore()
        chat.newSession(
            projectID: "project-alpha",
            projectName: "Alpha",
            workingDirectory: alphaRoot.path
        )
        let alphaSessionID = try #require(chat.activeSessionID)
        chat.markExecutionRunning(sessionID: alphaSessionID, turnID: 7, taskID: "task-alpha")
        let alpha = try #require(TerminalContextSnapshot.current(from: chat))

        chat.newSession(
            projectID: "project-beta",
            projectName: "Beta",
            workingDirectory: betaRoot.path
        )
        let betaSessionID = try #require(chat.activeSessionID)
        chat.markExecutionRunning(sessionID: betaSessionID, turnID: 8, taskID: "task-beta")
        let beta = try #require(TerminalContextSnapshot.current(from: chat))

        let alphaRequest = TerminalContextPanelAdapter(snapshot: alpha)
            .makeRequest(command: "echo alpha", cwd: alpha.workdir, approved: false)
        let betaRequest = TerminalContextPanelAdapter(snapshot: beta)
            .makeRequest(command: "echo beta", cwd: beta.workdir, approved: false)

        #expect(alphaRequest.context.sessionID != betaRequest.context.sessionID)
        #expect(alphaRequest.context.turnID != betaRequest.context.turnID)
        #expect(alphaRequest.context.taskID != betaRequest.context.taskID)
        #expect(alphaRequest.context.projectID != betaRequest.context.projectID)
        #expect(alphaRequest.context.workdir != betaRequest.context.workdir)
        #expect(alphaRequest.requestFingerprint != betaRequest.requestFingerprint)
    }

    @Test
    func validSnapshotReachesExistingTerminalBoundaryWithIdentity() async throws {
        let root = try makeRoot("valid")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-valid",
            turnID: "turn-valid",
            taskID: "task-valid",
            projectID: "project-valid",
            workdir: root.path
        )
        let runner = WP3TerminalCountingRunner()
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(scopeID: snapshot.scopeID, allowedRoot: root),
            runner: runner
        )
        let receipt = await TerminalContextPanelAdapter(snapshot: snapshot, boundary: boundary)
            .execute(command: "echo valid", cwd: root.path, approved: false)

        #expect(runner.invocationCount == 1)
        #expect(receipt.error == nil)
        #expect(receipt.sessionID == "session-valid")
        #expect(receipt.turnID == "turn-valid")
        #expect(receipt.taskID == "task-valid")
        #expect(receipt.projectID == "project-valid")
        #expect(receipt.workdir == root.path)
    }

    @Test
    func terminalAdapterAndBoundaryConsumeTheSamePolicySnapshot() async throws {
        let root = try makeRoot("policy-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-policy",
            turnID: "turn-policy",
            taskID: "task-policy",
            projectID: "project-policy",
            workdir: root.path
        )
        let policySnapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo", "sudo"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["echo"]
        ))
        let runner = WP3TerminalCountingRunner()
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(
                scopeID: snapshot.scopeID,
                allowedRoot: root,
                snapshot: policySnapshot
            ),
            runner: runner
        )
        let adapter = TerminalContextPanelAdapter(
            snapshot: snapshot,
            boundary: boundary,
            policySnapshot: policySnapshot
        )

        let denied = await adapter.execute(
            command: "echo denied",
            cwd: root.path,
            approved: false
        )
        let confirmation = await adapter.execute(
            command: "git --version",
            cwd: root.path,
            approved: false
        )

        #expect(denied.error == TerminalBoundaryError.denied.rawValue)
        #expect(confirmation.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(runner.invocationCount == 0)
        #expect(policySnapshot.revision == TerminalPolicySnapshot(settings: policySnapshot.settings).revision)
    }

    @Test
    func visibleTerminalConsumesEffectiveMountedAndDeniedRootsFromSettings() async throws {
        let root = try makeRoot("settings-root")
        let mount = try makeRoot("settings-mount")
        let outside = try makeRoot("settings-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: outside)
        }
        let blocked = mount.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: mount.appendingPathComponent("escape"), withDestinationURL: outside
        )
        let state = root.appendingPathComponent("isolated-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let usageSuite = "WP3TerminalRoots-\(UUID().uuidString)"
        let usage = UsageStore(domain: .suite(usageSuite))
        defer { UserDefaults(suiteName: usageSuite)?.removePersistentDomain(forName: usageSuite) }
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: state.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: state.appendingPathComponent("env")),
            memoryStore: MemoryStore(directory: state.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: state.appendingPathComponent("sessions")),
            logManager: LogManager(directory: state.appendingPathComponent("logs"), ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: state.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: state.appendingPathComponent("skills")),
            usageStore: usage,
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        #expect(settings.mountFolder(mount.path))
        settings.fileAccessDeniedRoots = [blocked.path]
        let snapshot = TerminalContextSnapshot(
            sessionID: "session-roots",
            turnID: "turn-roots",
            taskID: "task-roots",
            projectID: "project-roots",
            workdir: root.path
        )
        settings.shellCommandTimeoutSeconds = 45
        let adapter = TerminalContextPanelAdapter(snapshot: snapshot, settings: settings)
        let commandBudget = adapter.makeRequest(command: "echo budget", cwd: root.path, approved: false)
        #expect(commandBudget.timeout == .seconds(45))

        let allowed = await adapter.execute(command: "echo mounted", cwd: mount.path, approved: false)
        let denied = await adapter.execute(
            command: "cat --path=\(blocked.path)/secret", cwd: root.path, approved: false
        )
        let deniedCwd = await adapter.execute(command: "echo blocked", cwd: blocked.path, approved: false)

        #expect(allowed.error == nil)
        #expect(allowed.exitCode == 0)
        #expect(denied.error == TerminalBoundaryError.pathViolation.rawValue)
        #expect(deniedCwd.error == TerminalBoundaryError.pathViolation.rawValue)

        let store = TerminalStore(contextSnapshot: snapshot, settings: settings)
        store.input = "cd \(mount.path)"
        store.submit()
        #expect(store.cwd == mount.path)
        for target in [blocked.path, outside.path, mount.appendingPathComponent("escape").path,
                       "../\(outside.lastPathComponent)"] {
            store.input = "cd \(target)"
            store.submit()
            #expect(store.cwd == mount.path)
        }
        #expect(await usage.waitForPersistence())
    }

    @Test
    func validScopedEchoReachesRealProcessBoundary() async throws {
        let root = try makeRoot("real-echo")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-real-echo",
            turnID: "turn-real-echo",
            taskID: "task-real-echo",
            projectID: "project-real-echo",
            workdir: root.path
        )
        let receipt = await TerminalContextPanelAdapter(snapshot: snapshot)
            .execute(command: "echo F07_REAL_BOUNDARY", cwd: root.path, approved: false)

        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 0)
        #expect(receipt.output.contains("F07_REAL_BOUNDARY"))
        #expect(receipt.projectID == snapshot.projectID)
        #expect(receipt.workdir == snapshot.workdir)
    }

    @Test
    func visibleTerminalShowsRealPwdOutputAndZeroExitFromSameInvocation() async throws {
        let root = try makeRoot("visible-pwd-zero-exit").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let snapshot = TerminalContextSnapshot(
            sessionID: "session-visible-pwd", turnID: "turn-visible-pwd",
            taskID: "task-visible-pwd", projectID: "project-visible-pwd",
            workdir: root.path
        )
        let store = TerminalStore(contextSnapshot: snapshot)
        defer { store.stop() }

        store.input = "pwd"
        store.submit()
        let finished = await waitUntil { !store.isRunning }
        #expect(finished)
        #expect(store.output.contains("\(root.path) $ pwd\n"))
        let outputLines = store.output.components(separatedBy: "\n")
        #expect(outputLines.count == 4)
        let pwdLine = try #require(outputLines.count == 4 ? outputLines[1] : nil)
        #expect(outputLines.first == "\(root.path) $ pwd")
        #expect(outputLines[2] == "（退出码 0）")
        let expectedPath = try #require(root.path.withCString { realpath($0, nil) })
        defer { free(expectedPath) }
        let actualPath = try #require(pwdLine.withCString { realpath($0, nil) })
        defer { free(actualPath) }
        #expect(String(cString: actualPath) == String(cString: expectedPath))
        #expect(store.output.components(separatedBy: "（退出码 0）").count == 2)
        #expect(!store.output.contains("错误："))
        #expect(!store.output.contains(NSHomeDirectory()))
    }

    @Test("visible terminal retains the same production pwd receipt for explicit export")
    func visibleTerminalExportsOriginalPwdReceipt1794() async throws {
        let root = try makeRoot("pwd-structured-receipt").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let snapshot = TerminalContextSnapshot(sessionID: "session-1794",
            turnID: "turn-1794", taskID: "task-1794",
            projectID: "project-1794", workdir: root.path)
        let store = TerminalStore(contextSnapshot: snapshot)
        defer { store.stop() }
        store.input = "pwd"
        store.submit()
        #expect(await waitUntil { !store.isRunning })
        let original = try #require(store.lastPwdReceipt)
        let bytes = try #require(store.pwdReceiptJSON?.data(using: .utf8))
        let exported = try JSONDecoder().decode(TerminalReceipt.self, from: bytes)
        #expect(exported == original)
        #expect(exported.command == "pwd")
        #expect(exported.workdir == root.path)
        let observedPath = exported.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // macOS may report the same temporary directory as /var or
        // /private/var. Compare the actual directory identity, not spelling.
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let observedAttributes = try FileManager.default.attributesOfItem(atPath: observedPath)
        let expectedDevice = try #require(expectedAttributes[.systemNumber] as? NSNumber)
        let observedDevice = try #require(observedAttributes[.systemNumber] as? NSNumber)
        let expectedInode = try #require(expectedAttributes[.systemFileNumber] as? NSNumber)
        let observedInode = try #require(observedAttributes[.systemFileNumber] as? NSNumber)
        #expect(expectedDevice == observedDevice)
        #expect(expectedInode == observedInode)
        #expect(exported.exitCode == 0)
        #expect(exported.error == nil)
        #expect(store.output.contains("\n\(observedPath)\n（退出码 0）\n"))

        store.input = "echo next-command"
        store.submit()
        #expect(store.pwdReceiptJSON == nil)
        #expect(await waitUntil { !store.isRunning })
        #expect(store.lastPwdReceipt == nil)
    }

    @Test("unbound terminal shows missing project instead of an executable cwd")
    func unboundPromptDoesNotUseHome1794() async {
        let store = TerminalStore()
        defer { store.stop() }
        #expect(store.cwd.isEmpty)
        store.input = "pwd"
        store.submit()
        #expect(await waitUntil { !store.isRunning })
        #expect(store.output.contains("未绑定项目 $ pwd"))
        #expect(!store.output.contains(NSHomeDirectory()))
        #expect(store.pwdReceiptJSON == nil)
    }

    @Test
    func explicitStopReachesTheOwnedProductionBoundary() async throws {
        let root = try makeRoot("stop-owned")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-stop-owned",
            turnID: "turn-stop-owned",
            taskID: "task-stop-owned",
            projectID: "project-stop-owned",
            workdir: root.path
        )
        let runner = WP3TerminalCountingRunner()
        runner.delay = .seconds(5)
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(scopeID: snapshot.scopeID, allowedRoot: root),
            runner: runner
        )
        let adapter = TerminalContextPanelAdapter(snapshot: snapshot, boundary: boundary)
        let request = adapter.makeRequest(command: "echo stop", cwd: root.path, approved: false)
        let operation = Task { await boundary.execute(request) }

        try await Task.sleep(for: .milliseconds(25))
        adapter.makeOwnedBoundary().stop()
        adapter.makeOwnedBoundary().stop()
        let receipt = await operation.value

        #expect(receipt.error == TerminalBoundaryError.cancelled.rawValue)
        #expect(receipt.exitCode == nil)
        #expect(runner.invocationCount == 1)
    }

    @Test
    func visibleTerminalStopAndImmediateNextRequestIgnoreLateOldReceipt() async throws {
        let root = try makeRoot("stop-late")
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyFile = root.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: emptyFile.path, contents: Data())
        let snapshot = TerminalContextSnapshot(
            sessionID: "session-stop-late",
            turnID: "turn-stop-late",
            taskID: "task-stop-late",
            projectID: "project-stop-late",
            workdir: root.path
        )
        let store = TerminalStore(contextSnapshot: snapshot)

        store.input = "tail -f empty.txt"
        store.submit()
        #expect(store.isRunning)
        store.stop()
        store.stop()

        // Exercise a new invocation before the old cancellation receipt can
        // write back. The old receipt must fail the Store's invocation fence.
        store.input = "echo next-request"
        store.submit()
        let deadline = Date().addingTimeInterval(5)
        while store.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(!store.isRunning)
        #expect(store.output.contains("next-request"))
        #expect(!store.output.contains("错误：命令已取消"))
    }

    @Test
    func visibleTerminalStopShowsCancellationAfterRealProcessStarts() async throws {
        let root = try makeRoot("visible-stop-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        from pathlib import Path
        import time
        Path("ready.txt").write_text("FAKE_TERMINAL1525_READY")
        time.sleep(8)
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("worker.py"))
        let snapshot = TerminalContextSnapshot(
            sessionID: "session-visible-stop", turnID: "turn-visible-stop",
            taskID: "task-visible-stop", projectID: "project-visible-stop",
            workdir: root.path
        )
        let store = TerminalStore(contextSnapshot: snapshot)
        defer { store.stop() }

        store.input = "python3 worker.py"
        store.submit()
        #expect(store.pendingConfirmation != nil)
        store.confirmPending()
        let started = await waitUntil {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.txt").path)
        }
        guard started else {
            Issue.record("Visible terminal process did not start")
            return
        }

        store.stop()
        let finished = await waitUntil { !store.isRunning }
        #expect(finished)
        #expect(store.output.contains("错误：命令已取消"))
        #expect(!store.output.contains("（退出码 0）"))
        #expect(!store.output.contains("（退出码 137）"))
    }

    @Test
    func visibleTerminalDisplaysRealStreamsRedactionAndExit() async throws {
        let root = try makeRoot("visible-stream-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "FAKE_TERMINAL1525_SECRET_SENTINEL"
        let script = """
        import sys
        print("terminal1525-stdout", flush=True)
        print("api" + "_key=" + "FAKE_TERMINAL1525_SECRET_SENTINEL", file=sys.stderr, flush=True)
        print("terminal1525-stderr", file=sys.stderr, flush=True)
        sys.exit(17)
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("worker.py"))
        let snapshot = TerminalContextSnapshot(
            sessionID: "session-visible-streams", turnID: "turn-visible-streams",
            taskID: "task-visible-streams", projectID: "project-visible-streams",
            workdir: root.path
        )
        let store = TerminalStore(contextSnapshot: snapshot)
        defer { store.stop() }

        store.input = "python3 worker.py"
        store.submit()
        #expect(store.pendingConfirmation != nil)
        store.confirmPending()
        let finished = await waitUntil { !store.isRunning }
        #expect(finished)
        #expect(store.output.contains("terminal1525-stdout"))
        #expect(store.output.contains("terminal1525-stderr"))
        #expect(store.output.contains(ContentSecretRedactor.mask(marker)))
        #expect(!store.output.contains(marker))
        #expect(store.output.contains("（退出码 17）"))
        #expect(!store.output.contains("错误：命令已取消"))
    }

    @Test
    func missingSnapshotNeverReachesRunner() async throws {
        let root = try makeRoot("missing-context")
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = WP3TerminalCountingRunner()
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(scopeID: "project-missing", allowedRoot: root),
            runner: runner
        )
        let receipt = await TerminalContextPanelAdapter(snapshot: nil, boundary: boundary)
            .execute(command: "echo should-not-run", cwd: root.path, approved: false)

        #expect(receipt.error == TerminalBoundaryError.contextUnavailable.rawValue)
        #expect(TerminalBoundaryError.contextUnavailable.actionableMessage.contains("工作目录"))
        #expect(runner.invocationCount == 0)
    }

    @Test
    func disabledSideEffectsAreActionablyRejectedWithoutRunner() async throws {
        let root = try makeRoot("disabled")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-disabled",
            turnID: "turn-disabled",
            taskID: "task-disabled",
            projectID: "project-disabled",
            workdir: root.path
        )
        let runner = WP3TerminalCountingRunner()
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(scopeID: snapshot.scopeID, allowedRoot: root),
            runner: runner
        )
        let request = TerminalExecutionRequest(
            capabilityID: "",
            command: "echo should-not-run",
            context: TerminalExecutionContext(
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                taskID: snapshot.taskID,
                projectID: snapshot.projectID,
                workdir: snapshot.workdir
            )
        )

        let receipt = await TerminalContextPanelAdapter(snapshot: snapshot, boundary: boundary)
            .execute(request)

        #expect(receipt.error == TerminalBoundaryError.permissionDenied.rawValue)
        #expect(TerminalBoundaryError.permissionDenied.actionableMessage.contains("安全设置"))
        #expect(runner.invocationCount == 0)
    }

    @Test
    func unknownAndOutOfScopeRequestsNeverReachRunner() async throws {
        let root = try makeRoot("root")
        let outside = try makeRoot("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-negative",
            turnID: "turn-negative",
            taskID: "task-negative",
            projectID: "project-negative",
            workdir: root.path
        )
        let runner = WP3TerminalCountingRunner()
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(scopeID: snapshot.scopeID, allowedRoot: root),
            runner: runner
        )
        let adapter = TerminalContextPanelAdapter(snapshot: snapshot, boundary: boundary)

        let unknown = await adapter.execute(
            command: "unknown-command",
            cwd: root.path,
            approved: false
        )
        let outOfScope = await adapter.execute(
            command: "echo outside",
            cwd: outside.path,
            approved: false
        )

        #expect(unknown.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(outOfScope.error == TerminalBoundaryError.pathViolation.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func wrongScopeAndExpiredApprovalsNeverReachRunner() async throws {
        let root = try makeRoot("approval")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = TerminalContextSnapshot(
            sessionID: "session-approval",
            turnID: "turn-approval",
            taskID: "task-approval",
            projectID: "project-approval",
            workdir: root.path
        )
        let runner = WP3TerminalCountingRunner()
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(
                scopeID: snapshot.scopeID,
                allowedRoot: root,
                now: { now }
            ),
            runner: runner
        )
        let adapter = TerminalContextPanelAdapter(snapshot: snapshot, boundary: boundary)
        let base = adapter.makeRequest(command: "git --version", cwd: root.path, approved: false)

        let wrongScope = TerminalExecutionRequest(
            capabilityID: base.capabilityID,
            command: base.command,
            context: base.context,
            approval: TerminalApproval(
                scopeID: "project-other",
                requestFingerprint: base.requestFingerprint,
                expiresAt: now.addingTimeInterval(60)
            )
        )
        let expired = TerminalExecutionRequest(
            capabilityID: base.capabilityID,
            command: base.command,
            context: base.context,
            approval: TerminalApproval(
                scopeID: snapshot.scopeID,
                requestFingerprint: base.requestFingerprint,
                expiresAt: now.addingTimeInterval(-1)
            )
        )

        let wrongScopeReceipt = await adapter.execute(wrongScope)
        let expiredReceipt = await adapter.execute(expired)

        #expect(wrongScopeReceipt.error == TerminalBoundaryError.scopeMismatch.rawValue)
        #expect(expiredReceipt.error == TerminalBoundaryError.approvalExpired.rawValue)
        #expect(runner.invocationCount == 0)
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP3Terminal-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
