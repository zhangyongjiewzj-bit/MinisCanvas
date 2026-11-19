import Foundation
import Testing
@testable import MinisCore

/// D-TERMINAL-04 danger-syntax sub-scenario (wave-3 lane 020 advisory):
/// the Agent `shell_execute` path and the visible right-side terminal must
/// agree on ONE classification result produced from ONE immutable snapshot.
/// Before this contract was closed, `BuiltinToolExecutor.runShell` threw
/// `shellRejected` for every `TerminalGuard` syntax rejection BEFORE any
/// classification, while `TerminalPolicy.decision` routed the same non-denied
/// input to `.approvalRequired` (confirmation) — a two-category shape for the
/// danger-syntax class.
///
/// Unified fail-closed mapping pinned here (identical to `TerminalPolicy.decision`):
/// - product/user hard-deny (including names nested inside compound syntax,
///   recovered by `classify(command:)` whole-line tokens) → hard throw, no
///   execution, no side effect;
/// - guard-rejected (danger) syntax that the snapshot does not deny → the
///   confirmation class. Execution may only happen after the per-call
///   `shell_execute` approval the `ApprovalGate` can never auto-approve
///   (input risk is pinned `.high`, so even an `.autoApprove` user policy
///   still prompts for the exact command; a delegate-less gate denies);
/// - well-formed unknown commands require approval and then execute; the
///   shell reports a normal command-not-found exit for missing executables.
@Suite("D-TERMINAL-04 danger-syntax classification parity")
struct TerminalDangerSyntaxParityTests {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("w4-032-danger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func snapshot() -> TerminalPolicySnapshot {
        TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["ls", "echo", "printf", "grep", "cat", "pwd"],
            confirmationCommands: [],
            userDeniedCommands: ["rm"]
        ).editingConfirmationCommands(["git"]))
    }

    private func executor(root: URL, policy: TerminalPolicySnapshot) -> BuiltinToolExecutor {
        BuiltinToolExecutor(allowedRoot: root, terminalPolicySnapshot: policy)
    }

    private func contents(_ root: URL, _ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: Shared single-snapshot classification (terminal entry point)

    @Test("one snapshot classifies the danger-syntax battery identically")
    func dangerSyntaxBatteryClassifiesFromSingleSnapshot() {
        let policy = snapshot()
        let battery: [(command: String, expected: TerminalCommandDisposition)] = [
            ("ls && ls", .confirmation),                       // canonical 020 repro
            ("ls && git status", .confirmation),
            ("echo hi > out.txt", .confirmation),              // redirect
            ("cat p.txt | grep x", .confirmation),             // pipeline
            ("printf one > a.txt; printf two > b.txt", .confirmation),
            ("(ls)", .confirmation),                           // grouping
            ("ls\npwd", .confirmation),                        // newline separator
            ("ls | qqqnotacommand", .confirmation),            // unknown tail: terminal confirms
            ("ls && halt now", .denied),                       // nested product hard-deny
            ("ls; rm -rf .", .denied),                         // nested user-denied
            ("echo seed && dd if=/dev/zero of=x", .denied),    // nested hard-deny token
            ("qqqnotacommand", .unknown),                      // well-formed but unlisted
            ("git status", .confirmation),                     // unchanged simple category
        ]
        for probe in battery {
            let disposition = policy.classify(command: probe.command)
            #expect(disposition == probe.expected, "snapshot view of \(probe.command)")
            // 020 invariant: guard-rejected syntax must never classify allowed.
            if !TerminalGuard.inspect(probe.command).isAllowed {
                #expect(disposition != .allowed,
                        "danger syntax must not auto-allow: \(probe.command)")
            }
        }
    }

    // MARK: Agent path agrees where both reach classification

    @Test("agent runs the danger-syntax class the snapshot confirms after approval", arguments: [
        // (command, files the command must leave behind only if it executed)
        ("printf danger-parity > marker.txt", ["marker.txt"]),
        ("echo one > a.txt; echo two > b.txt", ["a.txt", "b.txt"]),
    ])
    func dangerSyntaxNotDeniedReachesSameConfirmationClassAsTerminal(
        command: String, expectedFiles: [String]
    ) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = snapshot()
        // Precondition from the single snapshot: this input is the
        // confirmation class, not a denial — the same verdict the terminal
        // shows its confirmation bar for.
        #expect(policy.classify(command: command) == .confirmation)

        _ = try await executor(root: root, policy: policy).execute(
            name: "shell_execute",
            input: ["command": command]
        )
        // Post-approval execution evidence; the approval itself is pinned by
        // the gate tests below (it cannot be skipped in production).
        for name in expectedFiles {
            #expect(contents(root, name) != nil, "confirmed-class command did not run: \(command)")
        }
    }

    @Test("nested hard-deny inside danger syntax never reaches a shell")
    func nestedHardDenyInsideCompoundSyntaxNeverExecutes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = snapshot()
        let executor = self.executor(root: root, policy: policy)

        for command in [
            "echo seed > s.txt && halt s.txt",
            "echo seed > s.txt; dd if=/dev/zero of=s.txt",
        ] {
            await #expect(throws: (any Error).self) {
                _ = try await executor.execute(name: "shell_execute", input: ["command": command])
            }
            // The redirect and the denied wrapper must both have been refused
            // before any process spawn: fail-closed, no side effect.
            #expect(contents(root, "s.txt") == nil,
                    "denied-class compound produced a side effect: \(command)")
        }
    }

    @Test("approved unknown commands execute while policy denials remain effective")
    func approvedUnknownCommandsExecuteAndDenialsRemainEffective() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = snapshot()
        let executor = self.executor(root: root, policy: policy)

        let input: [String: Any] = ["command": "qqqnotacommand"]
        let delegate = CountingDelegate()
        let capture = ApprovedShellReceiptCapture()
        var gate = ApprovalGate(delegate: delegate)
        gate.onApprovalReceipt = { capture.record($0) }
        let approvalContext = ApprovalAuthorizationContext(
            actorID: "terminal-policy-fixture", sessionID: "terminal-policy-session",
            turnID: 1, taskID: "terminal-policy-task", runID: "terminal-policy-run",
            attemptID: "terminal-policy-attempt", effectID: "terminal-policy-call",
            scope: "request", payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: input)),
            expiresAt: Date().addingTimeInterval(30), policyRevision: "terminal-policy-fixture",
            grantEpoch: "terminal-policy-grant", toolName: "shell_execute"
        )
        let approval = try await gate.gate(tool: "shell_execute", input: input, context: approvalContext)
        #expect(approval.approved)
        #expect(delegate.requests.count == 1)
        let presented = try #require(delegate.requests.first)
        #expect(presented.inputSummary.contains("批准后执行此命令"))
        #expect(presented.inputSummary.contains("qqqnotacommand"))
        // 未登记命令一次确认即可；只有不可逆命令（rm、git push --force 等）才需要第二次确认。
        #expect(presented.requiresApproval && !presented.requiresSecondConfirmation)
        let capturedReceipt: ApprovalReceipt = try #require(capture.load())
        let result = try await ApprovedShellCallScope.$currentLegacyReceipt.withValue(capturedReceipt) {
            try await executor.execute(name: "shell_execute", input: input)
        }
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect((envelope["exit_code"] as? Int) == 127)
        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await executor.execute(name: "shell_execute", input: ["command": "rm note.txt"])
        }
    }

    // MARK: Approval floor — the confirmation cannot be auto-approved

    private final class CountingDelegate: ApprovalDelegate, @unchecked Sendable {
        private(set) var requests: [ApprovalRequest] = []
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(approved: true, reason: "fixture", confirmed: true,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
    }

    @Test("shell_execute confirmation floor survives every user approval policy")
    func gateNeverAutoApprovesShellExecute() async throws {
        // Even the most permissive user-facing policy must still prompt for
        // the exact command (including danger-syntax commands the executor
        // now executes post-approval).
        let delegate = CountingDelegate()
        let autoGate = ApprovalGate(policy: .autoApprove, delegate: delegate)
        let decision = try await autoGate.gate(
            tool: "shell_execute",
            input: ["command": "printf danger-parity > marker.txt"]
        )
        #expect(decision.approved)
        #expect(delegate.requests.count == 1,
                "danger-syntax shell_execute must ask the user, never auto-approve")

        // A delegate-less gate with the same permissive policy fails closed.
        let silentGate = ApprovalGate(policy: .autoApprove)
        await #expect(throws: ApprovalError.denied(reason: "Input requires approval for tool 'shell_execute'")) {
            _ = try await silentGate.gate(
                tool: "shell_execute",
                input: ["command": "printf danger-parity > marker.txt"]
            )
        }

        // Deny policy still wins outright.
        let denyGate = ApprovalGate(policy: .never)
        await #expect(throws: ApprovalError.denied(reason: "Tool 'shell_execute' is blocked by policy")) {
            _ = try await denyGate.gate(
                tool: "shell_execute",
                input: ["command": "printf danger-parity > marker.txt"]
            )
        }

        // The floor is structural, not input-shaped: every shell_execute
        // input is high risk, so no command text can look its way out of the
        // confirmation.
        for probe in ["ls", "ls && ls", "echo a > b.txt", "qqq"] {
            #expect(ApprovalGate.inputRiskLevel(tool: "shell_execute", input: ["command": probe]) == .high)
            let request = autoGate.makeRequest(tool: "shell_execute", input: ["command": probe])
            #expect(request.requiresApproval)
        }
    }
}
