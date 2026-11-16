import Foundation
import CryptoKit
import Darwin
import Testing
@testable import MinisCore

private final class CountingTerminalRunner: TerminalProcessRunner, @unchecked Sendable {
    private(set) var invocationCount = 0
    var result = TerminalProcessResult(exitCode: 0, stdout: "ok", stderr: "")
    var delay: Duration?

    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        invocationCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return result
    }
}

private final class CommandBudgetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

@Suite("WP-3 terminal boundary")
struct TerminalBoundaryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

    private func context(workdir: URL) -> TerminalExecutionContext {
        TerminalExecutionContext(
            sessionID: "session-1",
            turnID: "turn-1",
            taskID: "task-1",
            projectID: "project-1",
            workdir: workdir.path
        )
    }

    private func request(
        command: String,
        context: TerminalExecutionContext,
        approval: TerminalApproval? = nil
    ) -> TerminalExecutionRequest {
        TerminalExecutionRequest(
            capabilityID: "shell_execute",
            command: command,
            context: context,
            approval: approval,
            timeout: .seconds(1)
        )
    }

    private func policy(
        root: URL,
        additionalAllowedRoots: [String] = [],
        deniedRoots: [String] = [],
        snapshot: TerminalPolicySnapshot = .default
    ) -> TerminalPolicy {
        TerminalPolicy(
            scopeID: "project-1",
            allowedRoot: root,
            additionalAllowedRoots: additionalAllowedRoots,
            deniedRoots: deniedRoots,
            now: { self.now },
            snapshot: snapshot
        )
    }

    @Test
    func allowedRunsAndProducesUnifiedReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let receipt = await boundary.execute(request(command: "echo ok", context: context(workdir: root)))
        #expect(runner.invocationCount == 1)
        #expect(receipt.exitCode == 0)
        #expect(receipt.error == nil)
        #expect(receipt.sessionID == "session-1")
        #expect(receipt.turnID == "turn-1")
        #expect(receipt.taskID == "task-1")
        #expect(receipt.projectID == "project-1")
        #expect(receipt.workdir == root.path)
        #expect(!receipt.requestFingerprint.isEmpty)
    }

    @Test("only the exact safe pwd command is carried by the structured receipt")
    func safePwdReceiptCarriesCommandWithoutOrdinaryInput1794() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        runner.result = TerminalProcessResult(exitCode: 0, stdout: root.path + "\n", stderr: "")
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let pwd = await boundary.execute(request(command: "pwd", context: context(workdir: root)))
        #expect(pwd.command == "pwd")
        #expect(pwd.workdir == root.path)
        #expect(pwd.output.contains(root.path))
        #expect(pwd.exitCode == 0)
        #expect(try JSONDecoder().decode(TerminalReceipt.self,
            from: JSONEncoder().encode(pwd)) == pwd)

        let ordinary = await boundary.execute(request(
            command: "echo token=synthetic-secret", context: context(workdir: root)))
        #expect(ordinary.command == nil)
        let encoded = try String(data: JSONEncoder().encode(ordinary), encoding: .utf8)
        #expect(encoded?.contains("synthetic-secret") == false)
    }

    @Test
    func approvalDeniedUnknownAndCancelledNeverReachRunner() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)

        let approval = await boundary.execute(request(command: "git --version", context: context(workdir: root)))
        #expect(approval.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(runner.invocationCount == 0)

        let denied = await boundary.execute(request(command: "sudo ls", context: context(workdir: root)))
        #expect(denied.error == TerminalBoundaryError.denied.rawValue)
        let unknown = await boundary.execute(request(command: "foobar", context: context(workdir: root)))
        #expect(unknown.error == TerminalBoundaryError.approvalRequired.rawValue)
        let cancelled = await boundary.execute(request(
            command: "git --version",
            context: context(workdir: root),
            approval: TerminalApproval.cancelled
        ))
        #expect(cancelled.error == TerminalBoundaryError.cancelled.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func customSnapshotChangesClassificationWithoutWeakeningHardDeny() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policySnapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo", "sudo"],
            confirmationCommands: [],
            userDeniedCommands: ["echo"]
        ).editingConfirmationCommands(["git"]))
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(
            policy: policy(root: root, snapshot: policySnapshot),
            runner: runner
        )

        let denied = await boundary.execute(request(
            command: "echo denied",
            context: context(workdir: root)
        ))
        let hardDenied = await boundary.execute(request(
            command: "sudo ls",
            context: context(workdir: root)
        ))
        let confirmation = await boundary.execute(request(
            command: "git status",
            context: context(workdir: root)
        ))

        #expect(denied.error == TerminalBoundaryError.denied.rawValue)
        #expect(hardDenied.error == TerminalBoundaryError.denied.rawValue)
        #expect(confirmation.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test("editable wrapper allow rules cannot execute a nested hard or user deny")
    func wrappedDeniedCommandNeverReachesEitherExecutionConsumer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["env", "nice", "echo", "open", "printf"],
            confirmationCommands: [],
            userDeniedCommands: ["printf"]
        ))
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root, snapshot: snapshot), runner: runner)
        let deniedCommands = [
            "env open Synthetic.app",
            "nice -n 2 open Synthetic.app",
            "env nice -- printf synthetic",
        ]
        for command in deniedCommands {
            let receipt = await boundary.execute(request(command: command, context: context(workdir: root)))
            #expect(receipt.error == TerminalBoundaryError.denied.rawValue)
            #expect(runner.invocationCount == 0)
        }

        // Both production consumers use this immutable snapshot. Agent must
        // reject these inputs before any shell is spawned; only denied probes
        // are sent through this test executor.
        let agent = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: snapshot)
        for command in deniedCommands {
            await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
                _ = try await agent.execute(name: "shell_execute", input: ["command": command])
            }
        }

        // Quoted open remains an argument, not a nested hard deny. The env
        // wrapper itself requires confirmation (production contract 1ef65f7).
        let quoted = await boundary.execute(request(
            command: #"env echo "open""#, context: context(workdir: root)
        ))
        #expect(quoted.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func agentShellExecuteConsumesTheSameSnapshotBeforeSpawning() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo"],
            confirmationCommands: [],
            userDeniedCommands: ["echo"]
        ))
        let executor = BuiltinToolExecutor(
            allowedRoot: root,
            terminalPolicySnapshot: snapshot
        )

        do {
            _ = try await executor.execute(
                name: "shell_execute",
                input: ["command": "echo agent-denied"]
            )
            Issue.record("Agent shell_execute should reject a user-denied command")
        } catch let error as ToolExecutorError {
            #expect(error == .shellRejected("command denied by terminal policy"))
        }

        // The approval layer admits unregistered commands; the executor no
        // longer rejects them merely for being absent from this snapshot.
        let input: [String: Any] = ["command": "__h03_synthetic_unregistered_command__"]
        let raw = try await withFreshShellApprovalForTest(input: input) {
            try await executor.execute(name: "shell_execute", input: input)
        }
        let result = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect((result["exit_code"] as? Int) == 127)
    }

    @Test
    func missingContextAndDisabledCapabilityAreTypedAndFailClosed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)

        let missingContext = await boundary.execute(request(
            command: "echo missing-context",
            context: TerminalExecutionContext(
                sessionID: "",
                turnID: "",
                taskID: "",
                projectID: "",
                workdir: ""
            )
        ))
        #expect(missingContext.error == TerminalBoundaryError.contextUnavailable.rawValue)
        #expect(TerminalBoundaryError.contextUnavailable.actionableMessage.contains("项目"))

        let disabled = await boundary.execute(TerminalExecutionRequest(
            capabilityID: "",
            command: "echo disabled",
            context: context(workdir: root),
            timeout: .seconds(1)
        ))
        #expect(disabled.error == TerminalBoundaryError.permissionDenied.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func projectScopeMismatchNeverReachesRunner() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let mismatchedContext = TerminalExecutionContext(
            sessionID: "session-1",
            turnID: "turn-1",
            taskID: "task-1",
            projectID: "project-other",
            workdir: root.path
        )

        let receipt = await boundary.execute(request(
            command: "echo wrong-scope",
            context: mismatchedContext
        ))
        #expect(receipt.error == TerminalBoundaryError.scopeMismatch.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func traversalSymlinkWrongScopeAndExpiredApprovalNeverReachRunner() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let traversal = await boundary.execute(request(
            command: "echo nope",
            context: context(workdir: root.appendingPathComponent("..").appendingPathComponent(outside.lastPathComponent))
        ))
        #expect(traversal.error == TerminalBoundaryError.pathViolation.rawValue)
        let symlink = await boundary.execute(request(
            command: "echo nope",
            context: context(workdir: link)
        ))
        #expect(symlink.error == TerminalBoundaryError.pathViolation.rawValue)

        let wrongScope = TerminalApproval(
            scopeID: "other-project",
            requestFingerprint: "ignored",
            expiresAt: now.addingTimeInterval(60)
        )
        let wrong = await boundary.execute(request(
            command: "git --version",
            context: context(workdir: root),
            approval: wrongScope
        ))
        #expect(wrong.error == TerminalBoundaryError.scopeMismatch.rawValue)

        let expired = TerminalApproval(
            scopeID: "project-1",
            requestFingerprint: "ignored",
            expiresAt: now.addingTimeInterval(-1)
        )
        let stale = await boundary.execute(request(
            command: "git --version",
            context: context(workdir: root),
            approval: expired
        ))
        #expect(stale.error == TerminalBoundaryError.approvalExpired.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func argumentPathTraversalAndSymlinkNeverReachRunner() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)

        let traversal = await boundary.execute(request(
            command: "cat ../\(outside.lastPathComponent)/secret.txt",
            context: context(workdir: root)
        ))
        #expect(traversal.error == TerminalBoundaryError.pathViolation.rawValue)
        let symlink = await boundary.execute(request(
            command: "cat linked/secret.txt",
            context: context(workdir: root)
        ))
        #expect(symlink.error == TerminalBoundaryError.pathViolation.rawValue)
        #expect(runner.invocationCount == 0)
    }

    @Test
    func mountedAndDeniedRootsApplyToCwdAndEveryPathArgument() async throws {
        let root = try makeRoot()
        let mount = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: outside)
        }
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        let mountBlocked = mount.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mountBlocked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("bare-link"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: mount.appendingPathComponent("mount-link"), withDestinationURL: outside
        )
        let runner = CountingTerminalRunner()
        let boundary = TerminalBoundary(policy: policy(
            root: root,
            additionalAllowedRoots: [mount.path],
            deniedRoots: [blocked.path, mountBlocked.path]
        ), runner: runner)

        let mountedCwd = await boundary.execute(request(
            command: "echo mounted", context: context(workdir: mount)
        ))
        let mountedArgument = await boundary.execute(request(
            command: "cat \(mount.path)/ok.txt", context: context(workdir: root)
        ))
        #expect(mountedCwd.error == nil)
        #expect(mountedArgument.error == nil)
        #expect(runner.invocationCount == 2)

        let rejected = [
            request(command: "echo blocked", context: context(workdir: blocked)),
            request(command: "cat blocked/secret", context: context(workdir: root)),
            request(command: "cat --path=\(mountBlocked.path)/secret", context: context(workdir: root)),
            request(command: "cat \(mount.path)/BLOCKED/secret", context: context(workdir: root)),
            request(command: "cat bare-link", context: context(workdir: root)),
            request(command: "cat \(mount.path)/mount-link/secret", context: context(workdir: root)),
            request(command: "cat ../\(outside.lastPathComponent)/secret", context: context(workdir: root)),
            request(command: "echo outside", context: context(workdir: outside)),
        ]
        for item in rejected {
            let receipt = await boundary.execute(item)
            #expect(receipt.error == TerminalBoundaryError.pathViolation.rawValue)
        }
        #expect(runner.invocationCount == 2)
    }

    @Test
    func malformedMountOrDenyRootFailsClosedBeforeRunner() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        for policy in [
            policy(root: root, additionalAllowedRoots: ["relative/mount"]),
            policy(root: root, additionalAllowedRoots: ["/"]),
            policy(root: root, deniedRoots: ["relative/deny"]),
        ] {
            let receipt = await TerminalBoundary(policy: policy, runner: runner)
                .execute(request(command: "echo safe", context: context(workdir: root)))
            #expect(receipt.error == TerminalBoundaryError.pathViolation.rawValue)
        }
        #expect(runner.invocationCount == 0)
    }

    @Test
    func timeoutAndLargeOutputAreRecordedAndRedacted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        runner.delay = .seconds(2)
        runner.result = TerminalProcessResult(
            exitCode: 0,
            stdout: String(repeating: "Bearer secret-token-1234567890 ", count: 500),
            stderr: ""
        )
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let context = self.context(workdir: root)
        let fingerprint = TerminalExecutionRequest(
            capabilityID: "shell_execute",
            command: "git --version",
            context: context,
            approval: nil,
            timeout: .milliseconds(10)
        ).requestFingerprint
        let approval = TerminalApproval(
            scopeID: "project-1",
            requestFingerprint: fingerprint,
            expiresAt: now.addingTimeInterval(60)
        )
        let receipt = await boundary.execute(TerminalExecutionRequest(
            capabilityID: "shell_execute",
            command: "git --version",
            context: context,
            approval: approval,
            timeout: .milliseconds(10)
        ))
        #expect(receipt.error == TerminalBoundaryError.timeout.rawValue)
        #expect(receipt.output.count <= TerminalReceipt.maximumOutputCharacters)
        #expect(!receipt.output.contains("secret-token-1234567890"))
    }

    @Test
    func explicitStopReturnsCancelledAndRepeatedStopIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        runner.delay = .seconds(5)
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let operation = Task {
            await boundary.execute(request(command: "echo stop-me", context: context(workdir: root)))
        }

        try await Task.sleep(for: .milliseconds(25))
        boundary.stop()
        boundary.stop()
        let receipt = await operation.value

        #expect(receipt.error == TerminalBoundaryError.cancelled.rawValue)
        #expect(receipt.exitCode == nil)
        #expect(runner.invocationCount == 1)
    }

    @Test
    func normalCompletionKeepsActualExitCodeSeparateFromCancellation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingTerminalRunner()
        runner.result = TerminalProcessResult(exitCode: 17, stdout: "failed", stderr: "")
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)

        let receipt = await boundary.execute(request(command: "echo exit-code", context: context(workdir: root)))

        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 17)
        #expect(receipt.output == "failed")
    }

    @Test
    func realRunnerTimeoutTerminatesProcess() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyFile = root.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: emptyFile.path, contents: Data())
        let boundary = TerminalBoundary(policy: policy(root: root))
        let context = self.context(workdir: root)
        let receipt = await boundary.execute(TerminalExecutionRequest(
            capabilityID: "shell_execute",
            command: "tail -f empty.txt",
            context: context,
            timeout: .milliseconds(100)
        ))
        #expect(receipt.error == TerminalBoundaryError.timeout.rawValue)
    }

    @Test
    func realRunnerTimeoutReapsDescendantHoldingPipe() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyFile = root.appendingPathComponent("empty-descendant.txt")
        FileManager.default.createFile(atPath: emptyFile.path, contents: Data())
        let boundary = TerminalBoundary(policy: policy(root: root))
        let context = self.context(workdir: root)
        let command = "tail -f empty-descendant.txt & wait"
        let base = request(command: command, context: context)
        let approved = TerminalExecutionRequest(
            capabilityID: base.capabilityID,
            command: base.command,
            context: base.context,
            approval: TerminalApproval(
                scopeID: "project-1",
                requestFingerprint: base.requestFingerprint,
                expiresAt: now.addingTimeInterval(60)
            ),
            timeout: .milliseconds(100)
        )

        let receipt = await boundary.execute(approved)

        #expect(receipt.error == TerminalBoundaryError.timeout.rawValue)
        #expect(receipt.exitCode == nil)
    }

    @Test("default subprocess environment contains only controlled ordinary values")
    func subprocessEnvironmentUsesControlledPathsAndExplicitMCPConfiguration() throws {
        let environment = ChildProcessEnvironment.values(ordinary: [:])
        #expect(Set(environment.keys) == Set([
            "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "TERM", "ZDOTDIR"
        ]))
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"]?.hasPrefix("/") == true)
        #expect(environment["TMPDIR"]?.hasPrefix("/") == true)
        #expect(environment["USER"]?.isEmpty == false)
        #expect(environment["USER"] == environment["LOGNAME"])
        #expect(environment["SHELL"] == "/bin/zsh")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["ZDOTDIR"] == "/var/empty")
        let configured = try ChildProcessEnvironment.mcpValues(configured: [
            "MCP_SERVER_TOKEN": "synthetic-configured-token",
            "MCP_WORKSPACE_ID": "synthetic-workspace",
            "PATH": "/synthetic-explicit-toolchain:/usr/bin:/bin",
            "BAD=NAME": "synthetic-invalid",
            "MCP_NUL": "synthetic\0invalid"
        ])
        #expect(configured["MCP_SERVER_TOKEN"] == "synthetic-configured-token")
        #expect(configured["MCP_WORKSPACE_ID"] == "synthetic-workspace")
        #expect(configured["PATH"] == "/synthetic-explicit-toolchain:/usr/bin:/bin")
        #expect(configured["BAD=NAME"] == nil)
        #expect(configured["MCP_NUL"] == nil)
    }

    @Test("ordinary locale and terminal identifiers survive without importing aliases or startup hooks")
    func ordinaryEnvironmentRetainsOnlyValidatedLocaleAndTerminalValues() {
        let environment = ChildProcessEnvironment.values(ordinary: [
            "LANG": "zh_CN.UTF-8", "LC_CTYPE": "UTF-8", "LC_TIME": "de_DE.UTF-8",
            "LC_ALL": "C", "TERM": "screen-256color", "COLORTERM": "truecolor",
            "LC_SECRET": "synthetic-secret", "LC_MESSAGES": "bad/value",
            "BASH_ENV": "/synthetic/hook", "APP_PROVIDER_API_KEY": "synthetic-only"
        ])
        #expect(environment["LANG"] == "zh_CN.UTF-8")
        #expect(environment["LC_CTYPE"] == "UTF-8")
        #expect(environment["LC_TIME"] == "de_DE.UTF-8")
        #expect(environment["LC_ALL"] == "C")
        #expect(environment["TERM"] == "screen-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["LC_SECRET"] == nil)
        #expect(environment["LC_MESSAGES"] == nil)
        #expect(environment["BASH_ENV"] == nil)
        #expect(environment["APP_PROVIDER_API_KEY"] == nil)
    }

    @Test("ordinary proxy values survive while credential-bearing addresses and hooks do not")
    func proxyEnvironmentRetainsOnlyCredentialFreeEndpoints() {
        let valid: [String: String] = [
            "http_proxy": "http://127.0.0.1:7890", "https_proxy": "https://proxy.example:443/",
            "HTTP_PROXY": "proxy.example:8080", "HTTPS_PROXY": "http://[::1]:7890",
            "no_proxy": "localhost,127.0.0.1,.example,10.0.0.0/8", "NO_PROXY": "*"
        ]
        let retained = ChildProcessEnvironment.values(ordinary: valid)
        for (name, value) in valid { #expect(retained[name] == value) }
        for invalid in ["http://user:synthetic@proxy.example", "http://proxy.example/?token=synthetic",
                        "http://proxy.example/#synthetic", "http://proxy.example/path-secret",
                        "http://proxy.example/%40synthetic", "http://proxy.example\n", "file:///tmp/proxy"] {
            #expect(ChildProcessEnvironment.values(ordinary: ["http_proxy": invalid])["http_proxy"] == nil)
        }
        let denied = ChildProcessEnvironment.values(ordinary: [
            "no_proxy": "user@localhost", "NO_PROXY": "localhost?token=synthetic",
            "ALL_PROXY": "http://proxy.example", "all_proxy": "http://proxy.example",
            "SSH_AUTH_SOCK": "/synthetic/socket", "APP_PROVIDER_API_KEY": "synthetic-only"
        ])
        for name in ["no_proxy", "NO_PROXY", "ALL_PROXY", "all_proxy", "SSH_AUTH_SOCK", "APP_PROVIDER_API_KEY"] {
            #expect(denied[name] == nil)
        }
    }

    @Test("filtered environment notice stays pending until visible and records once")
    func environmentNoticeIsPendingAndOnceOnly() {
        let state = EnvironmentNoticeState()
        #expect(!state.takePending())
        #expect(state.recordDiscard())
        #expect(!state.recordDiscard())
        #expect(state.takePending())
        #expect(!state.takePending())
        #expect(!state.recordDiscard())
        #expect(!state.takePending())
    }

    @Test("only credential-like names trigger a persisted notice, separated from isolated profiles")
    func environmentNoticePersistsAfterPresentationAndKeepsProfilesSeparate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("notice")
        var syntheticProductionPresented = false
        let production = EnvironmentNoticeState(
            hasPresented: { syntheticProductionPresented },
            markPresented: { syntheticProductionPresented = true })
        #expect(!production.recordDiscard(name: "XPC_SERVICE_NAME"))
        #expect(!production.recordDiscard(name: "__CF_USER_TEXT_ENCODING"))
        #expect(!production.takePending())
        #expect(production.recordDiscard(name: "synthetic_api_key"))
        #expect(!syntheticProductionPresented)
        #expect(production.takePending())
        #expect(syntheticProductionPresented)
        let nextProduction = EnvironmentNoticeState(
            hasPresented: { syntheticProductionPresented },
            markPresented: { syntheticProductionPresented = true })
        #expect(!nextProduction.recordDiscard(name: "SYNTHETIC_TOKEN"))
        let isolated = EnvironmentNoticeState(markerURL: marker)
        #expect(isolated.recordDiscard(name: "SYNTHETIC_CREDENTIAL"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(isolated.takePending())
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!EnvironmentNoticeState(markerURL: marker).recordDiscard(name: "SYNTHETIC_AUTH"))
        #expect(EnvironmentNoticeState(markerURL: root.appendingPathComponent("other-profile-notice"))
            .recordDiscard(name: "SYNTHETIC_SECRET"))
        #expect(syntheticProductionPresented)
    }

    @Test("field profile subprocess HOME and TMPDIR remain isolated and invalid profiles fail closed")
    func subprocessDirectoriesStayInsideExistingProfile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ["MINISCANVAS_FIELD_PROFILE": "1", "MINISCANVAS_FIELD_PROFILE_ROOT": root.path]
        let resolved = try #require(try ChildProcessEnvironment.profileRoot(configuration: configuration,
            arguments: ["/synthetic/MinisCanvas", "--miniscanvas-field-profile"], processName: "MinisCanvas"))
        #expect(resolved == root.resolvingSymlinksInPath())
        let directories = try ChildProcessEnvironment.isolatedDirectories(root: resolved)
        let environment = ChildProcessEnvironment.values(ordinary: [:], directories: directories)
        #expect(environment["HOME"] == resolved.appendingPathComponent("home", isDirectory: true).path)
        #expect(environment["TMPDIR"] == resolved.appendingPathComponent("temporary", isDirectory: true).path)
        #expect(FileManager.default.fileExists(atPath: directories.home))
        #expect(FileManager.default.fileExists(atPath: directories.temporary))
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(throws: FormalTestIsolationPaths.IsolationError.self) {
            try ChildProcessEnvironment.profileRoot(configuration: ["MINISCANVAS_FIELD_PROFILE": "1"],
                arguments: ["/synthetic/MinisCanvas", "--miniscanvas-field-profile"], processName: "MinisCanvas")
        }
        try FileManager.default.removeItem(atPath: directories.home)
        try FileManager.default.createSymbolicLink(atPath: directories.home, withDestinationPath: directories.temporary)
        #expect(throws: FormalTestIsolationPaths.IsolationError.self) {
            try ChildProcessEnvironment.isolatedDirectories(root: resolved)
        }
    }

    /// Only named noncredential fields are read. Neither the snapshot nor its
    /// original values enter a script or diagnostic; real children compare hashes.
    private func capturedShellEnvironmentChecks(failureCode: Int, pathOnly: Bool = false) throws -> String {
        let captured = try ModelShellEnvironment.values()
        let names = pathOnly ? ["PATH"] : [
            "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "ZDOTDIR",
            "GIT_TERMINAL_PROMPT", "GIT_EDITOR", "GIT_PAGER", "PAGER"
        ]
        var expected = Data()
        var fieldDiagnostics: [String] = []
        // Shells can create a local SHELL variable when the inherited environment
        // omits it. Inspect exported fields, not shell-local parameter expansion.
        let environmentDigest = #"/usr/bin/perl -MDigest::SHA=sha256_hex -e 'print sha256_hex(join("", map { $_ . "\0" . (exists $ENV{$_} ? "x" : "") . "\0" . ($ENV{$_} // "") . "\0" } @ARGV)), "  -"'"#
        for name in names {
            let value = captured[name]
            var fieldData = Data()
            for field in [name, value == nil ? "" : "x", value ?? ""] {
                fieldData.append(contentsOf: field.utf8)
                fieldData.append(0)
            }
            expected.append(fieldData)
            let fieldDigest = SHA256.hash(data: fieldData).map { String(format: "%02x", $0) }.joined()
            fieldDiagnostics.append("[ \"$(\(environmentDigest) '\(name)')\" = '\(fieldDigest)  -' ] || printf 'TERMINAL_ENV_MISMATCH field=\(name)\\n'")
        }
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        let arguments = names.map { "'\($0)'" }.joined(separator: " ")
        // Per-field diagnostics run only after a mismatch and print names, never values.
        return "[ \"$(\(environmentDigest) \(arguments))\" = '\(digest)  -' ] || { \(fieldDiagnostics.joined(separator: "; ")); exit \(failureCode); }"
    }

    @Test("both real shell consumers retain the cached login environment and exclude late synthetic App variables, through nested zsh")
    func realShellConsumersUseCleanEnvironmentAndKeepArgumentsCwdAndExitCode() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Freeze the shared login snapshot before adding our owned parent canaries.
        let capturedChecks = try capturedShellEnvironmentChecks(failureCode: 42)
        let synthetic = ["PATH": "/synthetic/login/bin:/bin", "GH_TOKEN": "synthetic-only-token",
                         "ORDINARY_ALIAS": "synthetic-only-value", "HOME": "/synthetic/login-home",
                         "TMPDIR": "/synthetic/login-tmp"]
        let defaultRule = ModelShellEnvironment.values(snapshot: synthetic, stripCredentials: false,
            noninteractive: true, directories: (root.path, root.path))
        let strippedRule = ModelShellEnvironment.values(snapshot: synthetic, stripCredentials: true,
            noninteractive: true, directories: (root.path, root.path))
        #expect(defaultRule["GH_TOKEN"] == synthetic["GH_TOKEN"])
        #expect(strippedRule["GH_TOKEN"] == nil)
        #expect(strippedRule["ORDINARY_ALIAS"] == synthetic["ORDINARY_ALIAS"])
        #expect(strippedRule["PATH"] == synthetic["PATH"])
        #expect(strippedRule["HOME"] == root.path && strippedRule["TMPDIR"] == root.path)
        #expect(strippedRule["ZDOTDIR"] == "/var/empty")
        #expect(strippedRule["GIT_TERMINAL_PROMPT"] == "0")
        #expect(strippedRule["GIT_EDITOR"] == "true")
        #expect(strippedRule["GIT_PAGER"] == "cat" && strippedRule["PAGER"] == "cat")
        let prefix = "MINISCANVAS_SYNTH_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let names = ["API_KEY", "TOKEN", "SECRET", "PASSWORD", "AUTHORIZATION", "UNKNOWN", "ORDINARY_ALIAS"]
            .map { prefix + "_" + $0 }
        var installed: [String] = []
        defer { for name in installed { unsetenv(name) } }
        for name in names {
            // Unique synthetic additions after capture: never enumerate/getenv/save
            // or overwrite any pre-existing credential in the testing process.
            try #require(setenv(name, "synthetic-parent-value-not-for-output", 0) == 0)
            installed.append(name)
        }
        let checks = names.map { "[ \"${\($0)+x}\" != x ] || exit 41" }.joined(separator: "\n")
        let isolatedDirectoryChecks: String
        if let profile = try ChildProcessEnvironment.profileRoot() {
            let home = profile.appendingPathComponent("home", isDirectory: true).path.replacingOccurrences(of: "'", with: "'\\''")
            let temporary = profile.appendingPathComponent("temporary", isDirectory: true).path.replacingOccurrences(of: "'", with: "'\\''")
            isolatedDirectoryChecks = "[ \"$HOME\" = '\(home)' ] && [ \"$TMPDIR\" = '\(temporary)' ] || exit 50"
        } else { isolatedDirectoryChecks = "" }
        let stage = root.appendingPathComponent("clean-environment-stage")
        let stagePath = stage.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        if [ "$1" = nested ]; then
            printf '%s' nested-start > '\(stagePath)'
        else
            printf '%s' top-start > '\(stagePath)'
        fi
        \(checks)
        \(isolatedDirectoryChecks)
        \(capturedChecks)
        [ -d "$TMPDIR" ] || exit 44
        [ "$ZDOTDIR" = /var/empty ] || exit 45
        /usr/bin/which uname >/dev/null || exit 46
        # Directory identity keeps the cwd assertion independent of a file
        # URL's optional trailing slash or a canonical /private alias.
        [ . -ef "$2" ] || exit 47
        if [ "$1" = nested ]; then
            printf '%s' nested-clean
            printf '%s' nested-complete > '\(stagePath)'
            exit 0
        fi
        [ "$1" = 'argument with spaces' ] || exit 48
        /bin/zsh "$0" nested "$2" || exit 49
        printf '%s' environment-clean
        printf '%s' top-complete > '\(stagePath)'
        exit 17
        """
        try script.write(to: root.appendingPathComponent("environment-check.sh"), atomically: true, encoding: .utf8)
        let canonical = root.resolvingSymlinksInPath().path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "/bin/sh environment-check.sh 'argument with spaces' '\(canonical)'"
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["sh"], confirmationCommands: [], userDeniedCommands: []))
        let boundary = TerminalBoundary(policy: policy(root: root, snapshot: snapshot))
        // Shell interpreters remain confirmation-only. Pin the real visible
        // boundary's existing approval to this exact command/context.
        #expect(snapshot.classify(command: command) == .confirmation)
        let base = request(command: command, context: context(workdir: root))
        let terminalStartedAt = DispatchTime.now().uptimeNanoseconds
        let receipt = await boundary.execute(TerminalExecutionRequest(
            capabilityID: base.capabilityID, command: base.command, context: base.context,
            approval: TerminalApproval(scopeID: "project-1", requestFingerprint: base.requestFingerprint,
                expiresAt: now.addingTimeInterval(60)), timeout: base.timeout))
        let terminalStage = (try? String(contentsOf: stage, encoding: .utf8)) ?? "not-started"
        print("TERMINAL_ENV_WITNESS consumer=terminal elapsed_ns=\(DispatchTime.now().uptimeNanoseconds - terminalStartedAt) stage=\(terminalStage)")
        #expect(receipt.error == nil)
        #expect(receipt.exitCode == 17)
        #expect(receipt.output.contains("nested-clean"))
        #expect(receipt.output.contains("environment-clean"))
        #expect(!receipt.output.contains("synthetic-parent-value"))

        let executor = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: snapshot)
        try? FileManager.default.removeItem(at: stage)
        let modelStartedAt = DispatchTime.now().uptimeNanoseconds
        let raw = try await executor.execute(name: "shell_execute", input: ["command": command, "timeout": 2])
        let modelStage = (try? String(contentsOf: stage, encoding: .utf8)) ?? "not-started"
        print("TERMINAL_ENV_WITNESS consumer=model elapsed_ns=\(DispatchTime.now().uptimeNanoseconds - modelStartedAt) stage=\(modelStage)")
        let result = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect((result["exit_code"] as? Int) == 17)
        let output = try #require(result["stdout"] as? String)
        #expect(output.contains("nested-clean") && output.contains("environment-clean"))
        #expect(!output.contains("synthetic-parent-value"))
    }

    @Test("clean environments retain actual timeout and cancellation behavior", arguments: [
        "terminal-timeout", "terminal-cancel", "agent-timeout", "agent-cancel"
    ])
    func cleanEnvironmentKeepsProcessLifetimeControls(mode: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capturedChecks = try capturedShellEnvironmentChecks(failureCode: 41, pathOnly: true)
        try """
        \(capturedChecks)
        printf ready > started
        exec /bin/sleep 5
        """.write(to: root.appendingPathComponent("bounded-wait.sh"), atomically: true, encoding: .utf8)
        let command = "/bin/sh bounded-wait.sh"
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["sh"], confirmationCommands: [], userDeniedCommands: []))
        let marker = root.appendingPathComponent("started")
        if mode.hasPrefix("terminal") {
            let boundary = TerminalBoundary(policy: policy(root: root, snapshot: snapshot))
            let base = TerminalExecutionRequest(
                capabilityID: "shell_execute", command: command, context: context(workdir: root),
                timeout: mode == "terminal-timeout" ? .milliseconds(100) : .seconds(3))
            let approved = TerminalExecutionRequest(
                capabilityID: base.capabilityID, command: base.command, context: base.context,
                approval: TerminalApproval(scopeID: "project-1", requestFingerprint: base.requestFingerprint,
                    expiresAt: now.addingTimeInterval(60)), timeout: base.timeout)
            let operation = Task { await boundary.execute(approved) }
            if mode == "terminal-cancel" {
                for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                boundary.stop()
            }
            let result = await operation.value
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(result.error == (mode == "terminal-timeout"
                ? TerminalBoundaryError.timeout.rawValue : TerminalBoundaryError.cancelled.rawValue))
            #expect(result.exitCode == nil)
        } else {
            let executor = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: snapshot)
            let operation = Task {
                try await executor.execute(name: "shell_execute", input: [
                    "command": command, "timeout": mode == "agent-timeout" ? 0.1 : 3.0
                ])
            }
            if mode == "agent-cancel" {
                for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                operation.cancel()
                await #expect(throws: CancellationError.self) { _ = try await operation.value }
            } else {
                do {
                    _ = try await operation.value
                    Issue.record("the real shell timeout must not become a successful result")
                } catch let error as ToolExecutorError {
                    guard case .shellTimeout = error else { throw error }
                }
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("command budget is independent of legacy tool settings and bounded at one parser")
    func commandBudgetDefaultsCapsAndLegacySettingsStaySeparate() throws {
        #expect(ShellCommandTimeoutPolicy.seconds(nil) == 120)
        #expect(ShellCommandTimeoutPolicy.seconds(900) == 600)
        #expect(ShellCommandTimeoutPolicy.seconds(Double.nan) == 120)
        #expect(ShellCommandTimeoutPolicy.seconds(-1) == 120)
        #expect(ShellCommandTimeoutPolicy.seconds(0.1) == 0.1)
        let legacy = try JSONDecoder().decode(AgentSettings.self,
            from: Data("{\"toolTimeoutSeconds\":5}".utf8))
        #expect(legacy.toolTimeoutSeconds == 5)
        #expect(legacy.shellCommandTimeoutSeconds == 120)
        #expect(AgentSettings.default.toolTimeoutSeconds == 300)
        var settings = legacy
        settings.shellCommandTimeoutSeconds = 900
        let roundTrip = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.toolTimeoutSeconds == 5)
        #expect(roundTrip.shellCommandTimeoutSeconds == 600)
        let command = request(command: "pwd", context: context(workdir: URL(fileURLWithPath: "/synthetic")))
        #expect(command.timeout == .seconds(1)) // This suite's explicit request override is retained.
        #expect(TerminalExecutionRequest(capabilityID: "shell_execute", command: "pwd",
            context: command.context).timeout == .seconds(120))
        #expect(TerminalExecutionRequest(capabilityID: "shell_execute", command: "pwd",
            context: command.context, timeout: .seconds(900)).timeout == .seconds(600))
    }

    @Test("command timeout retains redacted partial output after owned process cleanup", arguments: ["model", "terminal"])
    func commandTimeoutRetainsPartialOutputWithoutBecomingSuccess(consumer: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        printf '%s' "$$" > owned-pid
        printf '%s' 'partial-output'
        printf '%s' 'partial-error' >&2
        printf '%s' ' API_KEY=synthetic-sensitive-value' >&2
        exec /bin/sleep 5
        """.write(to: root.appendingPathComponent("partial-timeout.sh"), atomically: true, encoding: .utf8)
        let command = "/bin/sh partial-timeout.sh synthetic-command-argument"
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["sh"], confirmationCommands: [], userDeniedCommands: []))
        if consumer == "model" {
            let executor = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: snapshot)
            do {
                _ = try await executeToolWithTimeout(name: "shell_execute", timeout: 0.01,
                    input: ["timeout": 0.1], executor: executor) {
                    try await executor.execute(name: "shell_execute", input: ["command": command, "timeout": 0.1])
                }
                Issue.record("a timeout must remain an error")
            } catch let error as ToolExecutorError {
                guard case .shellTimeout(let detail) = error else { throw error }
                let envelope = try #require(try JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
                #expect(envelope["timed_out"] as? Bool == true)
                #expect((envelope["stdout"] as? String)?.contains("partial-output") == true)
                #expect((envelope["stderr"] as? String)?.contains("partial-error") == true)
                #expect(!detail.contains("synthetic-sensitive-value"))
                #expect(!detail.contains("synthetic-command-argument"))
            }
        } else {
            let boundary = TerminalBoundary(policy: policy(root: root, snapshot: snapshot))
            let base = TerminalExecutionRequest(capabilityID: "shell_execute", command: command,
                context: context(workdir: root), timeout: .milliseconds(100))
            let approved = TerminalExecutionRequest(capabilityID: base.capabilityID, command: base.command,
                context: base.context, approval: TerminalApproval(scopeID: "project-1",
                    requestFingerprint: base.requestFingerprint, expiresAt: now.addingTimeInterval(60)), timeout: base.timeout)
            let receipt = await boundary.execute(approved)
            #expect(receipt.error == TerminalBoundaryError.timeout.rawValue)
            #expect(receipt.exitCode == nil)
            #expect(receipt.output.contains("partial-output") && receipt.output.contains("partial-error"))
            #expect(!receipt.output.contains("synthetic-sensitive-value"))
        }
        let text = try String(contentsOf: root.appendingPathComponent("owned-pid"), encoding: .utf8)
        let pid = try #require(Int32(text))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("deadline cancellation keeps timeout output while an earlier user cancel stays cancellation", arguments: ["deadline", "user"])
    func commandCancellationCauseSurvivesOwnedCleanup(cause: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        printf '%s' "$$" > owned-pid
        printf '%s' partial-before-cancel
        exec /bin/sleep 5
        """.write(to: root.appendingPathComponent("cancel-budget.sh"), atomically: true, encoding: .utf8)
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["sh"], confirmationCommands: [], userDeniedCommands: []))
        let executor = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: snapshot)
        let budget = ShellCommandBudget(seconds: 0.2)
        let task = Task {
            try await ShellCommandTimeoutPolicy.$currentBudget.withValue(budget) {
                try await executor.execute(name: "shell_execute", input: [
                    "command": "/bin/sh cancel-budget.sh", "timeout": 0.2])
            }
        }
        let marker = root.appendingPathComponent("owned-pid")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        if cause == "deadline" { try await Task.sleep(for: .milliseconds(220)) }
        let cancelRequestedAt = DispatchTime.now().uptimeNanoseconds
        let remainingBeforeCancel = budget.remaining
        task.cancel()
        let cancelReturnedAt = DispatchTime.now().uptimeNanoseconds
        let remainingAfterCancel = budget.remaining
        print("COMMAND_CANCEL_WITNESS cause=\(cause) requested_ns=\(cancelRequestedAt) returned_ns=\(cancelReturnedAt) started=\(budget.executionStarted) remaining_before=\(remainingBeforeCancel) remaining_after=\(remainingAfterCancel)")
        if cause == "user" {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else {
            do {
                _ = try await task.value
                Issue.record("the expired command cannot become a successful result")
            } catch let error as ToolExecutorError {
                guard case .shellTimeout(let detail) = error else { throw error }
                #expect(detail.contains("partial-before-cancel"))
            }
        }
        let pid = try #require(Int32(try String(contentsOf: marker, encoding: .utf8)))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("approval waiting does not consume command time but expired parent prevents spawning")
    func commandExecutionClockStartsAfterApprovalAndNeverRevivesExpiredParent() async throws {
        let clock = CommandBudgetTestClock()
        let waiting = ShellCommandBudget(seconds: 120, clock: { clock.now })
        clock.advance(900) // A long human wait consumes no command execution time.
        #expect(!waiting.executionStarted && waiting.cleanupRemaining == 0)
        #expect(waiting.beginExecution() == 120)
        let expired = ShellCommandBudget(seconds: 120, childTimeout: 1, clock: { clock.now })
        clock.advance(2)
        #expect(expired.beginExecution() == 0)
        #expect(!expired.executionStarted && expired.cleanupRemaining == 0)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["sh"], confirmationCommands: [], userDeniedCommands: []))
        let executor = BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: snapshot)
        try "printf '%s' started > started".write(to: root.appendingPathComponent("approval-wait.sh"),
            atomically: true, encoding: .utf8)
        do {
            _ = try await ShellCommandTimeoutPolicy.$currentBudget.withValue(expired) {
                try await executor.execute(name: "shell_execute", input: ["command": "/bin/sh approval-wait.sh"])
            }
            Issue.record("an expired parent cannot launch a command")
        } catch let error as ToolExecutorError {
            guard case .shellTimeout = error else { throw error }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        // A controlled pre-execution gate outlasts the requested command budget.
        // Execution still gets the full budget after that gate releases.
        let result = try await executeToolWithTimeout(name: "shell_execute", timeout: 0.01,
            input: ["timeout": 0.2], executor: executor) {
            try await Task.sleep(for: .milliseconds(250))
            return try await executor.execute(name: "shell_execute", input: [
                "command": "/bin/sh approval-wait.sh", "timeout": 0.2])
        }
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(envelope["exit_code"] as? Int == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
    }

    @Test("Composer budget lookup preserves configured 45 seconds without authorizing execution")
    func composerCommandBudgetReadsConfigurationWithoutBypassingApproval() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BuiltinToolExecutor(allowedRoot: root, defaultShellTimeout: 45)
        let stamp = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", workspaceID: "synthetic-workspace",
            createdAt: stamp, policyRevision: "synthetic-revision", autonomyCeiling: .l1)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: "synthetic-workspace", revision: "synthetic-revision",
            leaseID: "synthetic-lease", expiresAt: stamp.addingTimeInterval(60), autonomyCeiling: .l1)
        let composer = ComposerPolicyEnforcedToolExecutor(base: owner,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts))
        let budget = try #require(ShellCommandTimeoutPolicy.budget(name: "shell_execute", input: [:],
            executor: composer, childTimeout: nil))
        #expect(budget.seconds == 45)
        #expect(!budget.executionStarted && budget.cleanupRemaining == 0)
        #expect(ShellCommandTimeoutPolicy.budget(name: "shell_execute", input: ["timeout": 8],
            executor: composer, childTimeout: nil)?.seconds == 8)
        try "printf '%s' forbidden > forbidden".write(to: root.appendingPathComponent("blocked.sh"),
            atomically: true, encoding: .utf8)
        await #expect(throws: ComposerAuthorizationError.self) {
            _ = try await composer.execute(name: "shell_execute", input: ["command": "/bin/sh blocked.sh"])
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        try #require(root.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}


@Suite("Explicit terminal confirmation provenance")
struct ExplicitTerminalConfirmationProvenanceTests {
    private func manuallyConfirmedGit(_ policy: TerminalPolicySettings = .default) -> TerminalPolicySettings {
        policy.editingConfirmationCommands(policy.confirmationCommands.filter { $0 != "git" })
            .editingConfirmationCommands(policy.confirmationCommands)
    }

    @Test func defaultsAndNamedEditorPreserveDenyAndFrozenBoundaries() throws {
        let frozen = TerminalPolicySnapshot.default
        let edited = manuallyConfirmedGit()
        let explicit = TerminalPolicySnapshot(settings: edited)
        #expect(frozen.classify(command: "git status") == .allowed)
        #expect(frozen.classify(command: "git commit -m fixture") == .confirmation)
        #expect(explicit.classify(command: "git status") == .confirmation)
        #expect(explicit.classify(command: "nice -n 2 git status") == .confirmation)
        #expect(explicit.revision != frozen.revision)
        #expect(explicit.settings == edited)
        #expect(try JSONDecoder().decode(TerminalPolicySnapshot.self,
            from: JSONEncoder().encode(explicit)) == explicit)
        #expect(frozen.classify(command: "git status") == .allowed)
        #expect(explicit.classify(command: "git status && sudo ls") == .denied)
        var denied = edited
        denied.userDeniedCommands = ["git"]
        #expect(denied.normalized().explicitConfirmationCommands.isEmpty)
        #expect(TerminalPolicySnapshot(settings: denied).classify(command: "git status") == .denied)
        let hard = edited.editingConfirmationCommands(edited.confirmationCommands + ["sudo"])
        #expect(!hard.explicitConfirmationCommands.contains("sudo"))
        #expect(TerminalPolicySnapshot(settings: hard).classify(command: "sudo ls") == .denied)
        let removed = edited.editingConfirmationCommands(edited.confirmationCommands.filter { $0 != "git" })
        var allowed = removed
        allowed.automaticAllowCommands.append("git")
        #expect(allowed.normalized().explicitConfirmationCommands.isEmpty)
        #expect(TerminalPolicySnapshot(settings: allowed).classify(command: "git status") == .allowed)
        let unrelated = TerminalPolicySettings.default.editingConfirmationCommands(
            TerminalPolicySettings.default.confirmationCommands + ["fixture-command"])
        #expect(!unrelated.explicitConfirmationCommands.contains("git"))
        #expect(TerminalPolicySnapshot(settings: unrelated).classify(command: "git status") == .allowed)
        #expect(TerminalPolicySettings.default.explicitConfirmationCommands.isEmpty)
    }

    @Test func legacyUnknownSurvivesNewEditsAndRestart() throws {
        let bytes = Data(#"{"automaticAllowCommands":["echo"],"confirmationCommands":["git"],"userDeniedCommands":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(TerminalPolicySettings.self, from: bytes)
        #expect(legacy.confirmationProvenanceVersion == nil)
        #expect(legacy.explicitConfirmationCommands.isEmpty)
        #expect(TerminalPolicySnapshot(settings: legacy).classify(command: "git status") == .allowed)
        let explicit = manuallyConfirmedGit(legacy)
        #expect(explicit != legacy)
        #expect(explicit.confirmationProvenanceVersion == nil)
        #expect(explicit.explicitConfirmationCommands == ["git"])
        let restarted = try JSONDecoder().decode(TerminalPolicySettings.self,
            from: JSONEncoder().encode(explicit))
        #expect(restarted == explicit)
        #expect(TerminalPolicySnapshot(settings: restarted).classify(command: "git status") == .confirmation)
        let ordinary = TerminalPolicySettings(confirmationCommands: ["git"])
        #expect(ordinary.explicitConfirmationCommands.isEmpty)
        #expect(TerminalPolicySnapshot(settings: ordinary).classify(command: "git status") == .allowed)
    }

    @Test func futureProvenancePreservesOriginalFileAndBlocksWrites() throws {
        guard let isolation = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            throw FormalTestIsolationPaths.IsolationError.missingContract
        }
        let root = isolation.rootDirectory.appendingPathComponent("future-provenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        var agent = try #require(object["agent"] as? [String: Any])
        var terminal = try #require(agent["terminalPolicy"] as? [String: Any])
        terminal["confirmationProvenanceVersion"] = 2
        agent["terminalPolicy"] = terminal
        object["agent"] = agent
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = root.appendingPathComponent("settings.json")
        try original.write(to: url)
        #expect(throws: TerminalPolicyDecodingError.unsupportedProvenanceVersion(2)) {
            _ = try SettingsMigration.migrate(data: original)
        }
        let store = SettingsStore(directory: root)
        #expect(store.lastPersistenceError == .transactionRecoveryRequired)
        _ = store.update(\.agent.terminalPolicy, to: .default)
        #expect(try Data(contentsOf: url) == original)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.contains(".corrupt-") })
    }
}
