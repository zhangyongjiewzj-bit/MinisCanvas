import Foundation
import Testing
@testable import MinisCore

private final class VariableExpansionMarkerRunner2734: TerminalProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let marker: URL?
    private var storedInvocationCount = 0

    init(marker: URL? = nil) {
        self.marker = marker
    }

    var invocationCount: Int {
        lock.withLock { storedInvocationCount }
    }

    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        lock.withLock { storedInvocationCount += 1 }
        if let marker {
            try Data("spawned".utf8).write(to: marker)
        }
        return TerminalProcessResult(exitCode: 0, stdout: "literal", stderr: "")
    }
}

/// D-TERMINAL-08: active variable expansion is refused before approval or
/// process spawn, including the executable position. Single-quoted or escaped
/// dollars are literal arguments and retain simple-command behavior.
@Suite("D-TERMINAL-08 variable expansion production boundary")
struct TerminalVariableExpansion2734Tests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-variable-2734-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func request(_ command: String, root: URL, approval: TerminalApproval? = nil) -> TerminalExecutionRequest {
        TerminalExecutionRequest(
            capabilityID: "shell_execute",
            command: command,
            context: TerminalExecutionContext(
                sessionID: "synthetic-session",
                turnID: "synthetic-turn",
                taskID: "synthetic-task",
                projectID: "synthetic-project",
                workdir: root.path
            ),
            approval: approval,
            timeout: .seconds(2)
        )
    }

    private func policy(root: URL) -> TerminalPolicy {
        TerminalPolicy(
            scopeID: "synthetic-project",
            allowedRoot: root,
            snapshot: TerminalPolicySnapshot(settings: TerminalPolicySettings(
                automaticAllowCommands: ["echo"],
                confirmationCommands: [],
                userDeniedCommands: []
            ))
        )
    }

    @Test("unquoted and double-quoted variables are refused before any file effect")
    func variableFormsReturnOriginalRefusalReceiptWithoutRunning() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("would-run.marker")
        let runner = VariableExpansionMarkerRunner2734(marker: marker)
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let snapshot = policy(root: root).snapshot
        let commands = [
            #"echo $VAR"#,
            #"echo ${VAR}"#,
            #"echo "$VAR""#,
            #"echo "${VAR}""#,
            #"$VAR would-run.marker"#,
            #"${VAR} would-run.marker"#,
        ]

        for command in commands {
            #expect(!TerminalGuard.inspect(command).isAllowed)
            #expect(snapshot.classify(command: command) == .confirmation)
            let receipt = await boundary.execute(request(command, root: root))
            #expect(receipt.error == TerminalBoundaryError.pathViolation.rawValue)
            #expect(receipt.exitCode == nil)
            #expect(receipt.command == nil)
            #expect(receipt.output.isEmpty)
            #expect(!receipt.requestFingerprint.isEmpty)
            #expect(runner.invocationCount == 0)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("single-quoted and escaped dollars remain literal allowed arguments")
    func literalDollarArgumentsKeepSimpleCommandBehavior() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = VariableExpansionMarkerRunner2734()
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)
        let snapshot = policy(root: root).snapshot
        let commands = [
            #"echo '$VAR'"#,
            #"echo '${VAR}'"#,
            #"echo \$VAR"#,
            #"echo "\$VAR""#,
        ]

        for command in commands {
            #expect(TerminalGuard.inspect(command).isAllowed)
            #expect(snapshot.classify(command: command) == .allowed)
            let receipt = await boundary.execute(request(command, root: root))
            #expect(receipt.error == nil)
            #expect(receipt.exitCode == 0)
        }
        #expect(runner.invocationCount == commands.count)
    }

    @Test("hard deny and even a matching approval leave active expansion without effect")
    func variableInputCannotDowngradeHardDenyOrUseApprovalToDispatch() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("would-run.marker")
        let runner = VariableExpansionMarkerRunner2734(marker: marker)
        let boundary = TerminalBoundary(policy: policy(root: root), runner: runner)

        for command in [#"halt echo "$VAR""#, #"echo $VAR; halt true"#] {
            let receipt = await boundary.execute(request(command, root: root))
            #expect(receipt.error == TerminalBoundaryError.denied.rawValue)
            #expect(receipt.exitCode == nil)
        }
        // `$-` is a shell special parameter outside the simple lexer's named
        // variable cases. The production boundary must still refuse it.
        let specialParameter = await boundary.execute(request(#"echo $-"#, root: root))
        #expect(specialParameter.error == TerminalBoundaryError.pathViolation.rawValue)
        #expect(specialParameter.exitCode == nil)
        // The literal-dollar exception must not relax an unrelated brace
        // argument that the established path guard still refuses.
        let unrelatedBrace = await boundary.execute(request(#"echo '{literal}'"#, root: root))
        #expect(unrelatedBrace.error == TerminalBoundaryError.pathViolation.rawValue)
        #expect(unrelatedBrace.exitCode == nil)
        let expansion = request(#"echo $VAR"#, root: root)
        let matchingApproval = TerminalApproval(
            scopeID: "synthetic-project",
            requestFingerprint: expansion.requestFingerprint,
            expiresAt: .distantFuture
        )
        let attempted = await boundary.execute(request(#"echo $VAR"#, root: root, approval: matchingApproval))
        #expect(attempted.error == TerminalBoundaryError.pathViolation.rawValue)
        #expect(attempted.exitCode == nil)
        #expect(runner.invocationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
